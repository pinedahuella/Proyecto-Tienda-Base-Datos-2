-- 007_flujo_pedido.sql
-- Separa armar el pedido de comprarlo.
--
-- El 006 hacia las dos cosas de un golpe, y no son lo mismo:
--
--   Armar el pedido    se agregan lineas, se quitan, se cambia la cantidad.
--                      Se COMPRUEBA que haya stock, pero no se descuenta nada:
--                      el pedido esta pendiente y todavia no es una venta.
--
--   Comprar el pedido  aqui si. Se vuelve a mirar el stock, se descuenta, se
--                      escribe el movimiento y el pedido pasa a comprado. Todo
--                      junto o nada.
--
-- Y una consecuencia que hay que tener clara: mientras el pedido esta
-- pendiente, el stock NO esta reservado. Dos personas pueden meter la ultima
-- unidad en su pedido; se la lleva la primera que compre, y la segunda recibe
-- "no hay suficiente stock" al comprar. Es como funciona cualquier tienda: lo
-- que se comprueba al agregar es informativo, lo que manda es la compra.
--
-- Reservar el stock desde que se agrega tambien es defendible, pero obliga a
-- soltar las reservas de los pedidos que nadie termina, y eso pide un proceso
-- que las vaya venciendo. No se hizo.


-- ============================================================
-- El estado se llama comprado, no pagado
-- ============================================================
-- Comprar y pagar no son lo mismo: un pedido contra entrega esta comprado y
-- todavia no pagado. El estado del dinero vive en pago, que tiene el suyo.
UPDATE estado_pedido SET estado_pedido_nombre = 'comprado'
WHERE estado_pedido_nombre = 'pagado';


-- ============================================================
-- Fuera la del 006
-- ============================================================
-- Hacia las dos cosas a la vez. Se reemplaza por crear_pedido + comprar_pedido.
DROP FUNCTION IF EXISTS crear_pedido(bigint, bigint, varchar, jsonb);


-- ============================================================
-- crear_pedido
-- ============================================================
-- Abre un pedido vacio, en pendiente. Nada mas. Sin lineas y sin pago: el pago
-- se registra al comprar, porque hasta entonces no hay nada que cobrar.
CREATE OR REPLACE FUNCTION crear_pedido(
    p_id_usuario              bigint,
    p_id_direccion_historial  bigint
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_pedido bigint;
BEGIN
    -- La direccion tiene que ser de quien compra. Sin esto, alguien podria
    -- mandar su pedido a la direccion de otra persona pasando su id.
    IF NOT EXISTS (
        SELECT 1
        FROM direccion_historial dh
        JOIN direcciones d ON d.id_direccion = dh.id_direccion
        WHERE dh.id_direccion_historial = p_id_direccion_historial
          AND d.id_usuario = p_id_usuario
    ) THEN
        RAISE EXCEPTION 'Esa direccion no es de este usuario'
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    INSERT INTO pedido (id_usuario, id_direccion_historial, id_estado_pedido)
    VALUES (
        p_id_usuario,
        p_id_direccion_historial,
        (SELECT id_estado_pedido FROM estado_pedido WHERE estado_pedido_nombre = 'pendiente')
    )
    RETURNING id_pedido INTO v_id_pedido;

    RETURN v_id_pedido;
END;
$$;

COMMENT ON FUNCTION crear_pedido(bigint, bigint) IS
    'Abre un pedido vacio en estado pendiente. No toca el stock';


-- ============================================================
-- agregar_linea
-- ============================================================
-- Mete un producto al pedido, o le suma cantidad si ya estaba.
--
-- Comprueba que haya stock suficiente, pero NO lo descuenta ni lo reserva. Es
-- una cortesia para avisar temprano, no una garantia: entre que se agrega y se
-- compra, otro puede llevarse las unidades.
--
-- El nombre, el precio y la comision vienen como parametro porque viven en
-- MongoDB y PostgreSQL no los puede leer. Se congelan en el momento de
-- agregar; si el vendedor sube el precio despues, este pedido conserva el que
-- se le mostro a la persona.
CREATE OR REPLACE FUNCTION agregar_linea(
    p_id_pedido  bigint,
    p_linea      jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado    varchar;
    v_cantidad  integer;
    v_stock     integer;
    v_total     integer;
BEGIN
    SELECT ep.estado_pedido_nombre INTO v_estado
    FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
    WHERE p.id_pedido = p_id_pedido;

    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- Un pedido comprado ya es una venta: cambiarlo seria reescribir lo que
    -- alguien pago.
    IF v_estado <> 'pendiente' THEN
        RAISE EXCEPTION 'El pedido % esta % y ya no se puede cambiar', p_id_pedido, v_estado
            USING ERRCODE = 'check_violation';
    END IF;

    v_cantidad := (p_linea->>'cantidad')::integer;

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad tiene que ser mayor a 0'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT stock INTO v_stock
    FROM inventario
    WHERE id_producto_mongo          = (p_linea->>'id_producto')::bigint
      AND id_producto_variante_mongo = (p_linea->>'id_producto_variante')::bigint;

    IF v_stock IS NULL THEN
        RAISE EXCEPTION 'No hay inventario para la variante % del producto %',
                        p_linea->>'id_producto_variante', p_linea->>'id_producto'
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- Lo que ya tenia el pedido de esa variante, mas lo que se agrega ahora
    SELECT coalesce(pp.cantidad, 0) + v_cantidad INTO v_total
    FROM (SELECT 1) x
    LEFT JOIN pedido_producto pp
           ON pp.id_pedido                  = p_id_pedido
          AND pp.id_producto_mongo          = (p_linea->>'id_producto')::bigint
          AND pp.id_producto_variante_mongo = (p_linea->>'id_producto_variante')::bigint;

    IF v_stock < v_total THEN
        RAISE EXCEPTION 'No hay suficiente stock de "%": quedan % y el pedido pide %',
                        p_linea->>'nombre_variante', v_stock, v_total
            USING ERRCODE = 'check_violation';
    END IF;

    -- Si esa variante ya estaba en el pedido se le suma la cantidad: eso es
    -- una linea con mas unidades, no dos lineas.
    INSERT INTO pedido_producto (
        id_pedido, id_producto_mongo, id_producto_variante_mongo,
        nombre_producto, nombre_variante, precio_unitario, porcentaje_comision, cantidad)
    VALUES (
        p_id_pedido,
        (p_linea->>'id_producto')::bigint,
        (p_linea->>'id_producto_variante')::bigint,
        p_linea->>'nombre_producto',
        p_linea->>'nombre_variante',
        (p_linea->>'precio_unitario')::numeric,
        (p_linea->>'porcentaje_comision')::numeric,
        v_cantidad
    )
    ON CONFLICT (id_pedido, id_producto_mongo, id_producto_variante_mongo)
    DO UPDATE SET cantidad = pedido_producto.cantidad + EXCLUDED.cantidad;

    RETURN jsonb_build_object(
        'id_pedido',            p_id_pedido,
        'id_producto',          (p_linea->>'id_producto')::bigint,
        'id_producto_variante', (p_linea->>'id_producto_variante')::bigint,
        'cantidad',             v_total,
        'stock_disponible',     v_stock
    );
END;
$$;

COMMENT ON FUNCTION agregar_linea(bigint, jsonb) IS
    'Agrega un producto a un pedido pendiente. Comprueba el stock pero no lo descuenta';


-- ============================================================
-- quitar_linea
-- ============================================================
CREATE OR REPLACE FUNCTION quitar_linea(
    p_id_pedido             bigint,
    p_id_producto           bigint,
    p_id_producto_variante  bigint
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado  varchar;
    v_filas   integer;
BEGIN
    SELECT ep.estado_pedido_nombre INTO v_estado
    FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
    WHERE p.id_pedido = p_id_pedido;

    IF v_estado <> 'pendiente' THEN
        RAISE EXCEPTION 'El pedido % esta % y ya no se puede cambiar', p_id_pedido, v_estado
            USING ERRCODE = 'check_violation';
    END IF;

    DELETE FROM pedido_producto
    WHERE id_pedido                  = p_id_pedido
      AND id_producto_mongo          = p_id_producto
      AND id_producto_variante_mongo = p_id_producto_variante;

    GET DIAGNOSTICS v_filas = ROW_COUNT;
    RETURN v_filas > 0;
END;
$$;

COMMENT ON FUNCTION quitar_linea(bigint, bigint, bigint) IS
    'Saca un producto de un pedido pendiente';


-- ============================================================
-- comprar_pedido
-- ============================================================
-- Aqui si se vende. Se vuelve a mirar el stock de cada linea, se descuenta, se
-- escribe el movimiento, se registra el pago y el pedido pasa a comprado.
--
-- Es una sola transaccion: o pasan las cinco cosas o no pasa ninguna. Y el
-- bloqueo de la fila del inventario es lo unico que impide que dos personas se
-- lleven la ultima unidad.
CREATE OR REPLACE FUNCTION comprar_pedido(
    p_id_pedido    bigint,
    p_metodo_pago  varchar
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado           varchar;
    v_id_usuario       bigint;
    v_id_metodo        smallint;
    v_id_motivo_venta  smallint;
    v_linea            record;
    v_inventario       inventario%ROWTYPE;
    v_total            numeric(12,2) := 0;
    v_stock_final      jsonb := '[]'::jsonb;
BEGIN
    SELECT ep.estado_pedido_nombre, p.id_usuario INTO v_estado, v_id_usuario
    FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
    WHERE p.id_pedido = p_id_pedido;

    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_estado <> 'pendiente' THEN
        RAISE EXCEPTION 'El pedido % ya esta %', p_id_pedido, v_estado
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pedido_producto WHERE id_pedido = p_id_pedido) THEN
        RAISE EXCEPTION 'El pedido % no tiene ninguna linea', p_id_pedido
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT id_metodo_pago INTO v_id_metodo
    FROM metodo_pago WHERE metodo_nombre = p_metodo_pago;

    IF v_id_metodo IS NULL THEN
        RAISE EXCEPTION 'El metodo de pago "%" no existe', p_metodo_pago
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    SELECT id_motivo_movimiento INTO v_id_motivo_venta
    FROM motivo_movimiento WHERE motivo_nombre = 'venta';

    -- ORDENADAS por producto y variante. Si dos compras simultaneas tomaran
    -- las mismas variantes en orden distinto, cada una bloquearia la que la
    -- otra espera y quedarian trabadas. Con un orden fijo, la segunda espera.
    FOR v_linea IN
        SELECT * FROM pedido_producto
        WHERE id_pedido = p_id_pedido
        ORDER BY id_producto_mongo, id_producto_variante_mongo
    LOOP
        -- FOR UPDATE: bloquea la fila hasta que termine la transaccion, asi
        -- que otra compra de la misma variante espera y luego lee el saldo ya
        -- descontado. Sin esto las dos leen "queda 1" y las dos venden.
        SELECT * INTO v_inventario
        FROM inventario
        WHERE id_producto_mongo          = v_linea.id_producto_mongo
          AND id_producto_variante_mongo = v_linea.id_producto_variante_mongo
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'No hay inventario para la variante % del producto %',
                            v_linea.id_producto_variante_mongo, v_linea.id_producto_mongo
                USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF v_inventario.stock < v_linea.cantidad THEN
            RAISE EXCEPTION 'No hay suficiente stock de "%": quedan % y se pidieron %',
                            v_linea.nombre_variante, v_inventario.stock, v_linea.cantidad
                USING ERRCODE = 'check_violation';
        END IF;

        INSERT INTO stock_movimiento (
            id_inventario, id_motivo_movimiento, id_usuario, id_pedido,
            cantidad, stock_resultante)
        VALUES (
            v_inventario.id_inventario, v_id_motivo_venta, v_id_usuario, p_id_pedido,
            v_linea.cantidad, v_inventario.stock - v_linea.cantidad
        );

        UPDATE inventario
        SET stock = stock - v_linea.cantidad,
            fecha_actualizacion = now()
        WHERE id_inventario = v_inventario.id_inventario;

        v_total := v_total + v_linea.precio_unitario * v_linea.cantidad;

        v_stock_final := v_stock_final || jsonb_build_object(
            'id_producto',          v_linea.id_producto_mongo,
            'id_producto_variante', v_linea.id_producto_variante_mongo,
            'stock',                v_inventario.stock - v_linea.cantidad
        );
    END LOOP;

    -- El pago nace pendiente: el pedido esta comprado, el dinero todavia no
    -- entro. Quien confirme el cobro le pone la fecha y lo pasa a aprobado.
    INSERT INTO pago (id_pedido, id_metodo_pago, monto, fecha_cancelacion, id_estado_pago)
    VALUES (
        p_id_pedido, v_id_metodo, v_total, NULL,
        (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = 'pendiente')
    );

    UPDATE pedido
    SET id_estado_pedido = (SELECT id_estado_pedido FROM estado_pedido WHERE estado_pedido_nombre = 'comprado')
    WHERE id_pedido = p_id_pedido;

    RETURN jsonb_build_object(
        'id_pedido', p_id_pedido,
        'total',     v_total::text,
        'stock',     v_stock_final
    );
END;
$$;

COMMENT ON FUNCTION comprar_pedido(bigint, varchar) IS
    'Confirma la compra: descuenta el stock, registra el pago y pasa el pedido a comprado. Todo o nada';


-- ============================================================
-- cancelar_pedido
-- ============================================================
-- Cancelar un pendiente no toca el stock, porque nunca se descontó. Cancelar
-- uno comprado si: devuelve las unidades con un movimiento de devolucion.
--
-- La salida NO se borra. Un libro mayor no se corrige quitando renglones: se
-- compensa con la entrada contraria, y asi queda constancia de las dos cosas.
CREATE OR REPLACE FUNCTION cancelar_pedido(
    p_id_pedido bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado           varchar;
    v_id_usuario       bigint;
    v_id_motivo_dev    smallint;
    v_linea            record;
    v_inventario       inventario%ROWTYPE;
    v_stock_final      jsonb := '[]'::jsonb;
BEGIN
    SELECT ep.estado_pedido_nombre, p.id_usuario INTO v_estado, v_id_usuario
    FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
    WHERE p.id_pedido = p_id_pedido;

    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_estado = 'cancelado' THEN
        RAISE EXCEPTION 'El pedido % ya estaba cancelado', p_id_pedido
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_estado IN ('enviado', 'entregado') THEN
        RAISE EXCEPTION 'El pedido % ya esta % y no se cancela desde aqui', p_id_pedido, v_estado
            USING ERRCODE = 'check_violation';
    END IF;

    -- Solo devuelve mercaderia si de verdad salio
    IF v_estado = 'comprado' THEN
        SELECT id_motivo_movimiento INTO v_id_motivo_dev
        FROM motivo_movimiento WHERE motivo_nombre = 'devolucion';

        FOR v_linea IN
            SELECT * FROM pedido_producto
            WHERE id_pedido = p_id_pedido
            ORDER BY id_producto_mongo, id_producto_variante_mongo
        LOOP
            SELECT * INTO v_inventario
            FROM inventario
            WHERE id_producto_mongo          = v_linea.id_producto_mongo
              AND id_producto_variante_mongo = v_linea.id_producto_variante_mongo
            FOR UPDATE;

            INSERT INTO stock_movimiento (
                id_inventario, id_motivo_movimiento, id_usuario, id_pedido,
                cantidad, stock_resultante)
            VALUES (
                v_inventario.id_inventario, v_id_motivo_dev, v_id_usuario, p_id_pedido,
                v_linea.cantidad, v_inventario.stock + v_linea.cantidad
            );

            UPDATE inventario
            SET stock = stock + v_linea.cantidad,
                fecha_actualizacion = now()
            WHERE id_inventario = v_inventario.id_inventario;

            v_stock_final := v_stock_final || jsonb_build_object(
                'id_producto',          v_linea.id_producto_mongo,
                'id_producto_variante', v_linea.id_producto_variante_mongo,
                'stock',                v_inventario.stock + v_linea.cantidad
            );
        END LOOP;

        -- El dinero tambien se deshace
        UPDATE pago
        SET id_estado_pago = (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = 'reembolsado')
        WHERE id_pedido = p_id_pedido
          AND id_estado_pago <> (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = 'rechazado');
    END IF;

    UPDATE pedido
    SET id_estado_pedido = (SELECT id_estado_pedido FROM estado_pedido WHERE estado_pedido_nombre = 'cancelado')
    WHERE id_pedido = p_id_pedido;

    RETURN jsonb_build_object(
        'id_pedido',      p_id_pedido,
        'estado_previo',  v_estado,
        'stock',          v_stock_final
    );
END;
$$;

COMMENT ON FUNCTION cancelar_pedido(bigint) IS
    'Cancela un pedido. Si estaba comprado, devuelve el stock con un movimiento de devolucion';
