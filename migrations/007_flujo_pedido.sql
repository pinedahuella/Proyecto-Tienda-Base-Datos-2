-- 007_flujo_pedido.sql
-- Armar el pedido y comprarlo, que no son lo mismo.
--
--   Armar el pedido    se agregan lineas y se quitan. Se COMPRUEBA que haya
--                      stock, pero no se descuenta nada: el pedido esta
--                      pendiente y todavia no es una venta.
--
--   Comprar el pedido  aqui si. Se vuelve a mirar el stock, se descuenta, se
--                      escribe el movimiento y el pedido pasa a comprado. Todo
--                      junto o nada.
--
-- Y una consecuencia que hay que tener clara: mientras el pedido esta
-- pendiente, el stock NO esta reservado. Dos personas pueden meter la ultima
-- unidad en su pedido; se la lleva la primera que compre, y la segunda recibe
-- "no hay suficiente stock" al comprar. Lo que se comprueba al agregar es
-- informativo; lo que manda es la compra.


-- ============================================================
-- Lo que cambio al volverse multi-vendedor
-- ============================================================
-- Antes se compraba una VARIANTE y el stock salia de inventario. Ahora se
-- compra una OFERTA: la misma variante la venden cuatro personas a cuatro
-- precios y con cuatro stocks distintos, asi que el pedido tiene que decir a
-- quien se le compro.
--
-- De ahi los tres cambios:
--
--   1. agregar_linea recibe id_oferta, no producto + variante.
--   2. El precio no viene por parametro. La funcion busca la fila vigente de
--      precio_historial y guarda su id: asi el backend no puede mandar un
--      precio que no sea el que estaba publicado.
--   3. El bloqueo FOR UPDATE es sobre la fila de oferta. Es lo unico que
--      impide que dos personas compren la ultima unidad DEL MISMO VENDEDOR.
--      Que otro vendedor tenga stock de lo mismo ya no estorba: son filas
--      distintas y no se bloquean entre si.
--
-- El nombre del producto y el de la variante si vienen por parametro, porque
-- el catalogo se lee desde MongoDB y PostgreSQL no lo puede consultar. El del
-- vendedor NO: ese sale de usuarios, y asi no se puede falsear.


-- ============================================================
-- crear_pedido
-- ============================================================
-- Abre un pedido vacio, en pendiente. Sin lineas y sin pago: el pago se
-- registra al comprar, porque hasta entonces no hay nada que cobrar.
CREATE OR REPLACE FUNCTION crear_pedido(
    p_id_usuario              bigint,
    p_id_direccion_historial  bigint
) RETURNS bigint
LANGUAGE plpgsql
AS $fn$
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
$fn$;

COMMENT ON FUNCTION crear_pedido(bigint, bigint) IS
    'Abre un pedido vacio en estado pendiente. No toca el stock';


-- ============================================================
-- agregar_linea
-- ============================================================
-- Mete una oferta al pedido, o le suma cantidad si ya estaba.
--
-- Comprueba que haya stock suficiente, pero NO lo descuenta ni lo reserva. Es
-- una cortesia para avisar temprano, no una garantia.
--
-- El precio se congela AQUI, al agregar al carrito, y no al comprar: si el
-- vendedor lo sube despues, este pedido conserva el que se le mostro a la
-- persona. Se congela guardando el id de la fila vigente de precio_historial,
-- que no se actualiza nunca.
--
-- p_linea = {
--   "id_oferta": 12, "cantidad": 2,
--   "id_producto": 5, "id_producto_variante": 9,
--   "nombre_producto": "...", "nombre_variante": "..."
-- }
CREATE OR REPLACE FUNCTION agregar_linea(
    p_id_pedido  bigint,
    p_linea      jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_estado_pedido  varchar;
    v_id_oferta      bigint;
    v_cantidad       integer;
    v_oferta         oferta%ROWTYPE;
    v_estado_oferta  varchar;
    v_id_precio      bigint;
    v_nombre_vend    varchar(200);
    v_ya             integer;
    v_total          integer;
    v_id_linea       bigint;
BEGIN
    SELECT ep.estado_pedido_nombre INTO v_estado_pedido
    FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
    WHERE p.id_pedido = p_id_pedido;

    IF v_estado_pedido IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- Un pedido comprado ya es una venta: cambiarlo seria reescribir lo que
    -- alguien pago.
    IF v_estado_pedido <> 'pendiente' THEN
        RAISE EXCEPTION 'El pedido % esta % y ya no se puede cambiar',
                        p_id_pedido, v_estado_pedido
            USING ERRCODE = 'check_violation';
    END IF;

    v_id_oferta := (p_linea->>'id_oferta')::bigint;
    v_cantidad  := (p_linea->>'cantidad')::integer;

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad tiene que ser mayor a 0'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_oferta FROM oferta WHERE id_oferta = v_id_oferta;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la oferta %', v_id_oferta
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    SELECT estado_oferta_nombre INTO v_estado_oferta
    FROM estado_oferta WHERE id_estado_oferta = v_oferta.id_estado_oferta;

    IF v_estado_oferta <> 'activa' THEN
        RAISE EXCEPTION 'La oferta % esta % y no se puede comprar',
                        v_id_oferta, v_estado_oferta
            USING ERRCODE = 'check_violation';
    END IF;

    -- La fila de precio que rige hoy. Siempre existe: la escribe el trigger
    -- del 005 cuando nace la oferta.
    SELECT id_precio_historial INTO v_id_precio
    FROM precio_historial
    WHERE id_oferta = v_id_oferta
    ORDER BY fecha_creacion DESC, id_precio_historial DESC
    LIMIT 1;

    IF v_id_precio IS NULL THEN
        RAISE EXCEPTION 'La oferta % no tiene precio registrado', v_id_oferta
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- El nombre del vendedor sale de la base, no del parametro
    SELECT trim(u.nombre || ' ' || coalesce(u.apellido, '')) INTO v_nombre_vend
    FROM usuarios u WHERE u.id_usuario = v_oferta.id_usuario;

    -- "Una linea por oferta" no se puede escribir como UNIQUE, porque la
    -- oferta no esta en pedido_producto: se llega a ella cruzando
    -- precio_historial. Por eso se busca a mano antes de insertar. Ver el
    -- comentario del 006.
    SELECT pp.id_pedido_producto, pp.cantidad INTO v_id_linea, v_ya
    FROM pedido_producto pp
    JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
    WHERE pp.id_pedido = p_id_pedido
      AND ph.id_oferta = v_id_oferta;

    v_total := coalesce(v_ya, 0) + v_cantidad;

    IF v_oferta.stock < v_total THEN
        RAISE EXCEPTION 'No hay suficiente stock de "%": quedan % y el pedido pide %',
                        p_linea->>'nombre_variante', v_oferta.stock, v_total
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_id_linea IS NOT NULL THEN
        -- Se le suma la cantidad y se CONSERVA el precio con el que entro.
        UPDATE pedido_producto SET cantidad = v_total
        WHERE id_pedido_producto = v_id_linea;
    ELSE
        INSERT INTO pedido_producto (
            id_pedido, id_precio_historial,
            id_producto_mongo, id_producto_variante_mongo,
            cantidad, nombre_producto, nombre_variante, nombre_vendedor)
        VALUES (
            p_id_pedido, v_id_precio,
            (p_linea->>'id_producto')::bigint,
            (p_linea->>'id_producto_variante')::bigint,
            v_cantidad,
            p_linea->>'nombre_producto',
            p_linea->>'nombre_variante',
            v_nombre_vend
        )
        RETURNING id_pedido_producto INTO v_id_linea;
    END IF;

    RETURN jsonb_build_object(
        'id_pedido',          p_id_pedido,
        'id_pedido_producto', v_id_linea,
        'id_oferta',          v_id_oferta,
        'id_usuario_vendedor', v_oferta.id_usuario,
        'cantidad',           v_total,
        'stock_disponible',   v_oferta.stock
    );
END;
$fn$;

COMMENT ON FUNCTION agregar_linea(bigint, jsonb) IS
    'Agrega una oferta a un pedido pendiente. Congela el precio pero no descuenta stock';


-- ============================================================
-- restar_linea
-- ============================================================
-- El "-1" de agregar_linea: resta cantidad de una oferta que ya esta en
-- el pedido, en vez de sumarla. Si la resta deja la cantidad en 0 o
-- menos, la linea se borra entera -- mismo resultado final que
-- quitar_linea, disparado por llegar a 0 en vez de un DELETE aparte.
--
-- Sin chequeo de stock: restar unidades nunca puede dejar sin stock a
-- nadie, a diferencia de agregar_linea.
CREATE OR REPLACE FUNCTION restar_linea(
    p_id_pedido  bigint,
    p_id_oferta  bigint,
    p_cantidad   integer
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_estado_pedido  varchar;
    v_id_linea       bigint;
    v_actual         integer;
    v_nueva          integer;
BEGIN
    SELECT ep.estado_pedido_nombre INTO v_estado_pedido
    FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
    WHERE p.id_pedido = p_id_pedido;

    IF v_estado_pedido IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_estado_pedido <> 'pendiente' THEN
        RAISE EXCEPTION 'El pedido % esta % y ya no se puede cambiar',
                        p_id_pedido, v_estado_pedido
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad tiene que ser mayor a 0'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pp.id_pedido_producto, pp.cantidad INTO v_id_linea, v_actual
    FROM pedido_producto pp
    JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
    WHERE pp.id_pedido = p_id_pedido
      AND ph.id_oferta = p_id_oferta;

    IF v_id_linea IS NULL THEN
        RAISE EXCEPTION 'La oferta % no esta en el pedido %', p_id_oferta, p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    v_nueva := v_actual - p_cantidad;

    IF v_nueva <= 0 THEN
        DELETE FROM pedido_producto WHERE id_pedido_producto = v_id_linea;

        RETURN jsonb_build_object(
            'id_pedido', p_id_pedido,
            'id_oferta', p_id_oferta,
            'cantidad', 0,
            'eliminada', true
        );
    END IF;

    UPDATE pedido_producto SET cantidad = v_nueva
    WHERE id_pedido_producto = v_id_linea;

    RETURN jsonb_build_object(
        'id_pedido', p_id_pedido,
        'id_pedido_producto', v_id_linea,
        'id_oferta', p_id_oferta,
        'cantidad', v_nueva,
        'eliminada', false
    );
END;
$fn$;

COMMENT ON FUNCTION restar_linea(bigint, bigint, integer) IS
    'Resta cantidad de una linea del pedido pendiente; si llega a 0 la borra';


-- ============================================================
-- quitar_linea
-- ============================================================
CREATE OR REPLACE FUNCTION quitar_linea(
    p_id_pedido  bigint,
    p_id_oferta  bigint
) RETURNS boolean
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_estado  varchar;
    v_filas   integer;
BEGIN
    SELECT ep.estado_pedido_nombre INTO v_estado
    FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
    WHERE p.id_pedido = p_id_pedido;

    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_estado <> 'pendiente' THEN
        RAISE EXCEPTION 'El pedido % esta % y ya no se puede cambiar', p_id_pedido, v_estado
            USING ERRCODE = 'check_violation';
    END IF;

    DELETE FROM pedido_producto pp
    USING precio_historial ph
    WHERE ph.id_precio_historial = pp.id_precio_historial
      AND pp.id_pedido = p_id_pedido
      AND ph.id_oferta = p_id_oferta;

    GET DIAGNOSTICS v_filas = ROW_COUNT;
    RETURN v_filas > 0;
END;
$fn$;

COMMENT ON FUNCTION quitar_linea(bigint, bigint) IS
    'Saca una oferta de un pedido pendiente';


-- ============================================================
-- cambiar_direccion_pedido
-- ============================================================
-- Cambia a donde apunta un pedido pendiente. Solo mientras esta pendiente,
-- igual que agregar_linea/quitar_linea: una vez comprado, id_direccion_historial
-- ya es la version que regia cuando se compro, y cambiarla despues reescribiria
-- a donde se dijo que se mando de verdad.
--
-- La ownership de la direccion (que sea del mismo usuario) ya se resolvio en
-- el backend antes de llamar aqui -- p_id_direccion_historial ya es la fila
-- correcta, no un id_direccion suelto.
CREATE OR REPLACE FUNCTION cambiar_direccion_pedido(
    p_id_pedido               bigint,
    p_id_direccion_historial  bigint
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_estado  varchar;
BEGIN
    SELECT ep.estado_pedido_nombre INTO v_estado
    FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
    WHERE p.id_pedido = p_id_pedido;

    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_estado <> 'pendiente' THEN
        RAISE EXCEPTION 'El pedido % esta % y ya no se puede cambiar',
                        p_id_pedido, v_estado
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE pedido SET id_direccion_historial = p_id_direccion_historial
    WHERE id_pedido = p_id_pedido;
END;
$fn$;

COMMENT ON FUNCTION cambiar_direccion_pedido(bigint, bigint) IS
    'Cambia la direccion de un pedido pendiente';


-- ============================================================
-- comprar_pedido
-- ============================================================
-- Aqui si se vende. Se vuelve a mirar el stock de cada linea, se descuenta, se
-- escribe el movimiento, se registra el pago y el pedido pasa a comprado.
--
-- Es una sola transaccion: o pasan las cinco cosas o no pasa ninguna. Y el
-- bloqueo de la fila de oferta es lo unico que impide que dos personas se
-- lleven la ultima unidad del mismo vendedor.
CREATE OR REPLACE FUNCTION comprar_pedido(
    p_id_pedido    bigint,
    p_metodo_pago  varchar
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_estado           varchar;
    v_id_usuario       bigint;
    v_id_metodo        smallint;
    v_id_motivo_venta  smallint;
    v_linea            record;
    v_oferta           oferta%ROWTYPE;
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

    -- ORDENADAS por oferta. Si dos compras simultaneas tomaran las mismas
    -- ofertas en orden distinto, cada una bloquearia la que la otra espera y
    -- quedarian trabadas. Con un orden fijo, la segunda espera y sigue.
    FOR v_linea IN
        SELECT pp.*, ph.id_oferta, ph.precio
        FROM pedido_producto pp
        JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
        WHERE pp.id_pedido = p_id_pedido
        ORDER BY ph.id_oferta
    LOOP
        -- FOR UPDATE: bloquea la fila hasta que termine la transaccion, asi
        -- que otra compra de la MISMA oferta espera y luego lee el saldo ya
        -- descontado. Sin esto las dos leen "queda 1" y las dos venden.
        SELECT * INTO v_oferta
        FROM oferta WHERE id_oferta = v_linea.id_oferta
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'No existe la oferta %', v_linea.id_oferta
                USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF v_oferta.stock < v_linea.cantidad THEN
            RAISE EXCEPTION 'No hay suficiente stock de "%" (%): quedan % y se pidieron %',
                            v_linea.nombre_variante, v_linea.nombre_vendedor,
                            v_oferta.stock, v_linea.cantidad
                USING ERRCODE = 'check_violation';
        END IF;

        INSERT INTO stock_movimiento (
            id_oferta, id_motivo_movimiento, id_usuario_modifico, id_pedido,
            cantidad, stock_resultante)
        VALUES (
            v_oferta.id_oferta, v_id_motivo_venta, v_id_usuario, p_id_pedido,
            v_linea.cantidad, v_oferta.stock - v_linea.cantidad
        );

        UPDATE oferta SET stock = stock - v_linea.cantidad
        WHERE id_oferta = v_oferta.id_oferta;

        v_total := v_total + v_linea.precio * v_linea.cantidad;

        -- Se devuelve para que quien llama ponga MongoDB al dia sin volver a
        -- consultar. Por eso van los tres ids: el documento del catalogo se
        -- localiza con los de Mongo y la oferta con el suyo.
        v_stock_final := v_stock_final || jsonb_build_object(
            'id_oferta',            v_oferta.id_oferta,
            'id_usuario',           v_oferta.id_usuario,
            'id_producto',          v_linea.id_producto_mongo,
            'id_producto_variante', v_linea.id_producto_variante_mongo,
            'stock',                v_oferta.stock - v_linea.cantidad
        );
    END LOOP;

    -- Para la primera entrega, todo pago nace pagado de una vez, sin
    -- importar el metodo -- no hay quien confirme transferencia/efectivo
    -- todavia (ver el problema de fondo: un pedido puede mezclar
    -- vendedores y el pago es uno solo, no uno por vendedor). Decision del
    -- equipo: simplificar por ahora, retomarlo despues si hace falta.
    INSERT INTO pago (id_pedido, id_metodo_pago, monto, fecha_cancelacion, id_estado_pago)
    VALUES (
        p_id_pedido, v_id_metodo, v_total, now(),
        (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = 'pagado')
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
$fn$;

COMMENT ON FUNCTION comprar_pedido(bigint, varchar) IS
    'Confirma la compra: descuenta el stock de cada oferta, registra el pago y pasa el pedido a comprado. Todo o nada';


-- ============================================================
-- cancelar_pedido
-- ============================================================
-- Cancelar un pendiente no toca el stock, porque nunca se descontó. Cancelar
-- uno comprado si: devuelve las unidades con un movimiento de devolucion.
--
-- La salida NO se borra. Un libro mayor no se corrige quitando renglones: se
-- compensa con la entrada contraria, y asi queda constancia de las dos cosas.
--
-- Es todo o nada para el pedido entero, aunque mezcle vendedores. Cancelar la
-- linea de un solo vendedor pide decidir que pasa con el pago, que es uno
-- solo: no se hizo.
CREATE OR REPLACE FUNCTION cancelar_pedido(
    p_id_pedido bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_estado         varchar;
    v_id_usuario     bigint;
    v_id_motivo_dev  smallint;
    v_linea          record;
    v_oferta         oferta%ROWTYPE;
    v_stock_final    jsonb := '[]'::jsonb;
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
            SELECT pp.*, ph.id_oferta
            FROM pedido_producto pp
            JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
            WHERE pp.id_pedido = p_id_pedido
            ORDER BY ph.id_oferta
        LOOP
            SELECT * INTO v_oferta
            FROM oferta WHERE id_oferta = v_linea.id_oferta
            FOR UPDATE;

            INSERT INTO stock_movimiento (
                id_oferta, id_motivo_movimiento, id_usuario_modifico, id_pedido,
                cantidad, stock_resultante)
            VALUES (
                v_oferta.id_oferta, v_id_motivo_dev, v_id_usuario, p_id_pedido,
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

        -- El dinero tambien se deshace. Un pago fallido no se reembolsa:
        -- nunca entro.
        UPDATE pago
        SET id_estado_pago = (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = 'reembolsado')
        WHERE id_pedido = p_id_pedido
          AND id_estado_pago <> (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = 'fallido');
    END IF;

    UPDATE pedido
    SET id_estado_pedido = (SELECT id_estado_pedido FROM estado_pedido WHERE estado_pedido_nombre = 'cancelado')
    WHERE id_pedido = p_id_pedido;

    RETURN jsonb_build_object(
        'id_pedido',     p_id_pedido,
        'estado_previo', v_estado,
        'stock',         v_stock_final
    );
END;
$fn$;

COMMENT ON FUNCTION cancelar_pedido(bigint) IS
    'Cancela un pedido. Si estaba comprado, devuelve el stock con un movimiento de devolucion';


-- ============================================================
-- reponer_stock
-- ============================================================
-- La entrada al kardex que no viene de un pedido: el vendedor agrega unidades
-- a su oferta, o corrige un descuadre.
--
-- Existe como funcion y no como un UPDATE suelto desde el backend por lo
-- mismo que las otras: si el saldo se pudiera cambiar sin escribir el
-- movimiento, el libro dejaria de explicar el stock y nadie se enteraria.
CREATE OR REPLACE FUNCTION reponer_stock(
    p_id_oferta     bigint,
    p_cantidad      integer,
    p_motivo        varchar,
    p_id_usuario    bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_oferta   oferta%ROWTYPE;
    v_motivo   motivo_movimiento%ROWTYPE;
    v_nuevo    integer;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad tiene que ser mayor a 0'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_motivo FROM motivo_movimiento WHERE motivo_nombre = p_motivo;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El motivo "%" no existe', p_motivo
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- venta y devolucion son del flujo del pedido: entran por comprar_pedido y
    -- cancelar_pedido, que ademas escriben el id_pedido. Meterlas por aqui
    -- dejaria movimientos de venta sin venta.
    IF p_motivo IN ('venta', 'devolucion') THEN
        RAISE EXCEPTION 'El motivo "%" solo lo escribe el flujo del pedido', p_motivo
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_oferta FROM oferta WHERE id_oferta = p_id_oferta FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la oferta %', p_id_oferta
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    v_nuevo := v_oferta.stock + (p_cantidad * v_motivo.valor);

    IF v_nuevo < 0 THEN
        RAISE EXCEPTION 'El ajuste dejaria la oferta % en % unidades', p_id_oferta, v_nuevo
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO stock_movimiento (
        id_oferta, id_motivo_movimiento, id_usuario_modifico, id_pedido,
        cantidad, stock_resultante)
    VALUES (
        p_id_oferta, v_motivo.id_motivo_movimiento, p_id_usuario, NULL,
        p_cantidad, v_nuevo
    );

    UPDATE oferta SET stock = v_nuevo WHERE id_oferta = p_id_oferta;

    RETURN jsonb_build_object(
        'id_oferta',  p_id_oferta,
        'id_usuario', v_oferta.id_usuario,
        'motivo',     p_motivo,
        'stock',      v_nuevo
    );
END;
$fn$;

COMMENT ON FUNCTION reponer_stock(bigint, integer, varchar, bigint) IS
    'Suma o resta unidades de una oferta escribiendo su movimiento. No admite venta ni devolucion';
