-- ============================================================
-- 051_pedidos_de_la_tienda.sql
-- ============================================================
-- La tienda gestiona los pedidos de todos (2026-11-07). Hasta hoy un pedido
-- solo lo podia cancelar su comprador, y solo mientras estuviera `comprado`.
-- Los estados `enviado` y `entregado` existian desde la 006 pero ninguna
-- funcion llevaba un pedido hasta ellos.
--
--   pedido_cambio_estado    cada cambio de estado de un pedido pagado: de que
--                           estado a cual, quien lo hizo, si fue la tienda y
--                           por que. Responde "quien cancelo este pedido".
--   cancelar_pedido_por()   la cancelacion con su autor. El comprador cancela
--                           solo lo `comprado`; la tienda tambien lo
--                           `enviado` y lo `entregado`. En los tres casos
--                           devuelve las unidades y reembolsa, igual que la
--                           cancelar_pedido() de la 007.
--   marcar_envio_pedido()   `comprado` a `enviado`, y `comprado` o `enviado` a
--                           `entregado`. Solo la tienda.
--   pedidos.administrar     el permiso de las dos rutas nuevas, solo el admin.
--
-- Por que el autor importa. Al cancelar, el backend corre dos detectores de
-- fraude contra el comprador: resenar y cancelar la compra, y las devoluciones
-- seriales en ClickHouse. Si la que cancela es la tienda, el comprador no hizo
-- nada y no puede quedar marcado. El movimiento de stock de la devolucion
-- guarda a quien cancelo en `id_usuario_modifico`; el detector de resenas
-- canceladas solo cuenta las que cancelo el mismo comprador, y el backend no
-- manda la devolucion a ClickHouse cuando cancela la tienda.
--
-- cancelar_pedido(bigint) de la 007 no se toca y sigue igual. El backend usa
-- desde hoy la nueva para las dos cancelaciones.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- ============================================================
-- pedido_cambio_estado
-- ============================================================
CREATE TABLE IF NOT EXISTS pedido_cambio_estado (
    id_pedido_cambio_estado  bigserial PRIMARY KEY,

    -- CASCADE: es la historia del pedido, sin el pedido no dice nada. Las
    -- pruebas que borran sus pedidos de prueba no se cortan aqui.
    id_pedido           bigint   NOT NULL REFERENCES pedido(id_pedido)
                        ON DELETE CASCADE,
    id_estado_anterior  smallint NOT NULL REFERENCES estado_pedido(id_estado_pedido)
                        ON DELETE RESTRICT,
    id_estado_nuevo     smallint NOT NULL REFERENCES estado_pedido(id_estado_pedido)
                        ON DELETE RESTRICT,

    -- SET NULL: si se borra la cuenta, el cambio sigue en la historia.
    id_usuario          bigint   REFERENCES usuarios(id_usuario)
                        ON DELETE SET NULL,
    por_la_tienda       boolean  NOT NULL,
    motivo              varchar(300),
    fecha               timestamptz NOT NULL DEFAULT now(),

    CHECK (id_estado_anterior <> id_estado_nuevo)
);

COMMENT ON TABLE pedido_cambio_estado IS
    'Cada cambio de estado de un pedido pagado, con quien lo hizo y si fue la tienda';
COMMENT ON COLUMN pedido_cambio_estado.por_la_tienda IS
    'true si lo hizo el admin desde el panel. Se guarda y no se deduce del rol, que puede cambiar';
COMMENT ON COLUMN pedido_cambio_estado.motivo IS
    'Opcional. Lo que escribio la tienda al cancelar';

CREATE INDEX IF NOT EXISTS idx_pedido_cambio_estado_pedido
    ON pedido_cambio_estado(id_pedido, fecha);

-- ============================================================
-- cancelar_pedido_por()
-- ============================================================
CREATE OR REPLACE FUNCTION cancelar_pedido_por(
    p_id_pedido      bigint,
    p_id_usuario     bigint,
    p_por_la_tienda  boolean,
    p_motivo         varchar DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_estado          varchar;
    v_id_estado       smallint;
    v_id_cancelado    smallint;
    v_id_motivo_dev   smallint;
    v_linea           record;
    v_oferta          oferta%ROWTYPE;
    v_stock_final     jsonb := '[]'::jsonb;
BEGIN
    -- FOR UPDATE: dos cancelaciones a la vez del mismo pedido, la del
    -- comprador y la de la tienda, no devuelven las unidades dos veces.
    SELECT ep.estado_pedido_nombre, p.id_estado_pedido
      INTO v_estado, v_id_estado
      FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
     WHERE p.id_pedido = p_id_pedido
       FOR UPDATE OF p;

    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_estado = 'cancelado' THEN
        RAISE EXCEPTION 'El pedido % ya estaba cancelado', p_id_pedido
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_estado = 'pendiente' THEN
        -- El pendiente es el carrito de alguien: se vacia por /carrito.
        RAISE EXCEPTION 'El pedido % todavia es un carrito y no se cancela', p_id_pedido
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_estado IN ('enviado', 'entregado') AND NOT p_por_la_tienda THEN
        RAISE EXCEPTION 'El pedido % ya esta % y solo la tienda lo puede cancelar', p_id_pedido, v_estado
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT id_motivo_movimiento INTO v_id_motivo_dev
      FROM motivo_movimiento WHERE motivo_nombre = 'devolucion';

    FOR v_linea IN
        SELECT pp.*, ph.id_oferta
          FROM pedido_producto pp
          JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
         WHERE pp.id_pedido = p_id_pedido
         ORDER BY ph.id_oferta
    LOOP
        SELECT * INTO v_oferta
          FROM oferta WHERE id_oferta = v_linea.id_oferta
           FOR UPDATE;

        -- id_usuario_modifico es quien cancelo. El detector de resenas
        -- canceladas lo compara con el comprador.
        INSERT INTO stock_movimiento (
            id_oferta, id_motivo_movimiento, id_usuario_modifico, id_pedido,
            cantidad, stock_resultante)
        VALUES (
            v_oferta.id_oferta, v_id_motivo_dev, p_id_usuario, p_id_pedido,
            v_linea.cantidad, v_oferta.stock + v_linea.cantidad
        );

        UPDATE oferta SET stock = stock + v_linea.cantidad
         WHERE id_oferta = v_oferta.id_oferta;

        v_stock_final := v_stock_final || jsonb_build_object(
            'id_oferta',            v_oferta.id_oferta,
            'id_usuario',           v_oferta.id_usuario,
            'id_producto',          v_linea.id_producto_mongo,
            'id_producto_variante', v_linea.id_producto_variante_mongo,
            'stock',                v_oferta.stock + v_linea.cantidad
        );
    END LOOP;

    UPDATE pago
       SET id_estado_pago = (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = 'reembolsado')
     WHERE id_pedido = p_id_pedido
       AND id_estado_pago <> (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = 'fallido');

    SELECT id_estado_pedido INTO v_id_cancelado
      FROM estado_pedido WHERE estado_pedido_nombre = 'cancelado';

    UPDATE pedido SET id_estado_pedido = v_id_cancelado
     WHERE id_pedido = p_id_pedido;

    INSERT INTO pedido_cambio_estado (
        id_pedido, id_estado_anterior, id_estado_nuevo, id_usuario, por_la_tienda, motivo)
    VALUES (
        p_id_pedido, v_id_estado, v_id_cancelado, p_id_usuario, p_por_la_tienda,
        NULLIF(btrim(p_motivo), ''));

    RETURN jsonb_build_object(
        'id_pedido',      p_id_pedido,
        'estado_previo',  v_estado,
        'por_la_tienda',  p_por_la_tienda,
        'stock',          v_stock_final
    );
END;
$fn$;

COMMENT ON FUNCTION cancelar_pedido_por(bigint, bigint, boolean, varchar) IS
    'Cancela un pedido pagado y anota quien. Devuelve las unidades y reembolsa. La tienda tambien cancela lo enviado o entregado';

-- ============================================================
-- marcar_envio_pedido()
-- ============================================================
CREATE OR REPLACE FUNCTION marcar_envio_pedido(
    p_id_pedido   bigint,
    p_estado      varchar,
    p_id_usuario  bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_estado     varchar;
    v_id_estado  smallint;
    v_id_nuevo   smallint;
BEGIN
    IF p_estado NOT IN ('enviado', 'entregado') THEN
        RAISE EXCEPTION 'El estado % no es de envio', p_estado
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT ep.estado_pedido_nombre, p.id_estado_pedido
      INTO v_estado, v_id_estado
      FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
     WHERE p.id_pedido = p_id_pedido
       FOR UPDATE OF p;

    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- Solo hacia adelante. Enviado sale de comprado; entregado de comprado
    -- (se entrego en mano) o de enviado.
    IF NOT (   (p_estado = 'enviado'   AND v_estado = 'comprado')
            OR (p_estado = 'entregado' AND v_estado IN ('comprado', 'enviado'))) THEN
        RAISE EXCEPTION 'El pedido % esta % y no puede pasar a %', p_id_pedido, v_estado, p_estado
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT id_estado_pedido INTO v_id_nuevo
      FROM estado_pedido WHERE estado_pedido_nombre = p_estado;

    UPDATE pedido SET id_estado_pedido = v_id_nuevo
     WHERE id_pedido = p_id_pedido;

    INSERT INTO pedido_cambio_estado (
        id_pedido, id_estado_anterior, id_estado_nuevo, id_usuario, por_la_tienda)
    VALUES (p_id_pedido, v_id_estado, v_id_nuevo, p_id_usuario, true);

    RETURN jsonb_build_object(
        'id_pedido',      p_id_pedido,
        'estado_previo',  v_estado,
        'estado',         p_estado
    );
END;
$fn$;

COMMENT ON FUNCTION marcar_envio_pedido(bigint, varchar, bigint) IS
    'Lleva un pedido pagado a enviado o entregado, solo hacia adelante, y lo anota';

-- ============================================================
-- El permiso
-- ============================================================
-- Igual que la 050: el permiso se reparte solo la primera vez que se crea.
WITH v (modulo, permiso, descripcion, roles) AS (
    VALUES
    ('pedidos', 'administrar', 'Cancelar cualquier pedido y marcarlo enviado o entregado', ARRAY['admin'])
),
nuevos AS (
    INSERT INTO permiso (id_modulo_permiso, permiso_nombre, descripcion)
    SELECT m.id_modulo_permiso, v.permiso, v.descripcion
      FROM v
      JOIN modulo_permiso m ON m.modulo_permiso_nombre = v.modulo
    ON CONFLICT (id_modulo_permiso, permiso_nombre) DO NOTHING
    RETURNING id_permiso, id_modulo_permiso, permiso_nombre
)
INSERT INTO rol_permiso (id_rol_usuario, id_permiso)
SELECT r.id_rol_usuario, n.id_permiso
  FROM nuevos n
  JOIN modulo_permiso m ON m.id_modulo_permiso = n.id_modulo_permiso
  JOIN v ON v.modulo = m.modulo_permiso_nombre AND v.permiso = n.permiso_nombre
  CROSS JOIN LATERAL unnest(v.roles) AS rn(nombre)
  JOIN rol_usuario r ON r.rol_usuario_nombre = rn.nombre
ON CONFLICT DO NOTHING;

COMMIT;
