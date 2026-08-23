-- 006_crear_pedido.sql
-- La compra, en una sola llamada.
--
-- Una compra son cinco escrituras: el pedido, sus lineas, un movimiento de
-- stock por linea, el saldo del inventario y el pago. Si se hacen sueltas y
-- algo falla en medio, queda basura: un pedido sin lineas, o stock descontado
-- de algo que nadie compro.
--
-- Aqui van juntas. Una funcion de PostgreSQL corre dentro de una transaccion,
-- asi que o se guardan las cinco o no se guarda ninguna. No hay forma de
-- olvidarse de abrir el BEGIN.
--
-- Y el control de stock vive aqui adentro, no en la aplicacion. Es lo unico
-- que impide que dos personas compren la ultima unidad: la funcion bloquea la
-- fila del inventario, mira el saldo y decide. Si eso quedara en el backend,
-- cualquier ruta nueva que descuente stock por su cuenta lo romperia.


-- ============================================================
-- Lo que la funcion NO puede hacer sola
-- ============================================================
-- El nombre, el precio y la comision de lo que se vende viven en MongoDB, y
-- PostgreSQL no los puede leer. Por eso vienen como parametro: quien llama los
-- saca del documento y los manda. La funcion los guarda tal cual, que es lo
-- correcto -- una venta conserva lo acordado, no lo que diga el catalogo
-- manana.


-- ============================================================
-- crear_pedido
-- ============================================================
-- p_lineas es un arreglo JSON. Cada elemento:
--
--   {
--     "id_producto": 1,
--     "id_producto_variante": 1,
--     "nombre_producto": "Camisa de lino manga larga",
--     "nombre_variante": "M azul",
--     "precio_unitario": "169.00",
--     "porcentaje_comision": "12.00",
--     "cantidad": 2
--   }
--
-- Devuelve un JSON con el pedido creado, su total, y el stock que quedo en
-- cada variante. Ese ultimo dato esta para que quien llama actualice el
-- documento de Mongo sin tener que volver a preguntar.
--
--   {
--     "id_pedido": 8,
--     "total": "338.00",
--     "stock": [ { "id_producto": 1, "id_producto_variante": 1, "stock": 7 } ]
--   }

CREATE OR REPLACE FUNCTION crear_pedido(
    p_id_usuario              bigint,
    p_id_direccion_historial  bigint,
    p_metodo_pago             varchar,
    p_lineas                  jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_pedido        bigint;
    v_id_metodo        smallint;
    v_id_motivo_venta  smallint;
    v_linea            jsonb;
    v_inventario       inventario%ROWTYPE;
    v_cantidad         integer;
    v_total            numeric(12,2) := 0;
    v_stock_final      jsonb := '[]'::jsonb;
BEGIN
    -- ------------------------------------------------------------
    -- Comprobaciones de lo que llega
    -- ------------------------------------------------------------
    IF p_lineas IS NULL OR jsonb_typeof(p_lineas) <> 'array' OR jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'El pedido necesita al menos una linea'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT id_metodo_pago INTO v_id_metodo
    FROM metodo_pago WHERE metodo_nombre = p_metodo_pago;

    IF v_id_metodo IS NULL THEN
        RAISE EXCEPTION 'El metodo de pago "%" no existe', p_metodo_pago
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- La direccion tiene que ser de quien compra. Sin esto, alguien podria
    -- mandar un pedido a la direccion de otra persona pasando su id.
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

    SELECT id_motivo_movimiento INTO v_id_motivo_venta
    FROM motivo_movimiento WHERE motivo_nombre = 'venta';

    -- ------------------------------------------------------------
    -- El pedido
    -- ------------------------------------------------------------
    -- Nace pendiente. Lo mueve a pagado quien confirme el pago, que es otra
    -- historia y otro momento.
    INSERT INTO pedido (id_usuario, id_direccion_historial, id_estado_pedido)
    VALUES (
        p_id_usuario,
        p_id_direccion_historial,
        (SELECT id_estado_pedido FROM estado_pedido WHERE estado_pedido_nombre = 'pendiente')
    )
    RETURNING id_pedido INTO v_id_pedido;

    -- ------------------------------------------------------------
    -- Las lineas, una por una
    -- ------------------------------------------------------------
    -- Se recorren ORDENADAS por producto y variante. No es un capricho: si dos
    -- compras simultaneas tomaran las mismas dos variantes en orden distinto,
    -- cada una bloquearia la que la otra espera y se quedarian trabadas. Con
    -- un orden fijo, la segunda simplemente espera.
    FOR v_linea IN
        SELECT valor
        FROM jsonb_array_elements(p_lineas) AS t(valor)
        ORDER BY (valor->>'id_producto')::bigint, (valor->>'id_producto_variante')::bigint
    LOOP
        v_cantidad := (v_linea->>'cantidad')::integer;

        IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
            RAISE EXCEPTION 'La cantidad de "%" tiene que ser mayor a 0',
                            v_linea->>'nombre_producto'
                USING ERRCODE = 'check_violation';
        END IF;

        -- FOR UPDATE: aqui esta la clave de todo. Bloquea esta fila hasta que
        -- la transaccion termine, asi que otra compra de la misma variante
        -- espera y despues lee el saldo ya descontado. Sin esto las dos leen
        -- "queda 1" y las dos venden.
        SELECT * INTO v_inventario
        FROM inventario
        WHERE id_producto_mongo          = (v_linea->>'id_producto')::bigint
          AND id_producto_variante_mongo = (v_linea->>'id_producto_variante')::bigint
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'No hay inventario para la variante % del producto %',
                            v_linea->>'id_producto_variante', v_linea->>'id_producto'
                USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF v_inventario.stock < v_cantidad THEN
            RAISE EXCEPTION 'No hay suficiente stock de "%": quedan % y se pidieron %',
                            v_linea->>'nombre_variante', v_inventario.stock, v_cantidad
                USING ERRCODE = 'check_violation';
        END IF;

        -- La linea, con lo acordado copiado tal cual vino
        INSERT INTO pedido_producto (
            id_pedido, id_producto_mongo, id_producto_variante_mongo,
            nombre_producto, nombre_variante, precio_unitario, porcentaje_comision, cantidad)
        VALUES (
            v_id_pedido,
            (v_linea->>'id_producto')::bigint,
            (v_linea->>'id_producto_variante')::bigint,
            v_linea->>'nombre_producto',
            v_linea->>'nombre_variante',
            (v_linea->>'precio_unitario')::numeric,
            (v_linea->>'porcentaje_comision')::numeric,
            v_cantidad
        );

        -- El renglon del libro mayor
        INSERT INTO stock_movimiento (
            id_inventario, id_motivo_movimiento, id_usuario, id_pedido,
            cantidad, stock_resultante)
        VALUES (
            v_inventario.id_inventario,
            v_id_motivo_venta,
            p_id_usuario,
            v_id_pedido,
            v_cantidad,
            v_inventario.stock - v_cantidad
        );

        -- Y el saldo
        UPDATE inventario
        SET stock = stock - v_cantidad,
            fecha_actualizacion = now()
        WHERE id_inventario = v_inventario.id_inventario;

        v_total := v_total + (v_linea->>'precio_unitario')::numeric * v_cantidad;

        v_stock_final := v_stock_final || jsonb_build_object(
            'id_producto',          (v_linea->>'id_producto')::bigint,
            'id_producto_variante', (v_linea->>'id_producto_variante')::bigint,
            'stock',                v_inventario.stock - v_cantidad
        );
    END LOOP;

    -- ------------------------------------------------------------
    -- El pago
    -- ------------------------------------------------------------
    -- Pendiente y sin fecha: el pedido existe, el dinero todavia no. La fecha
    -- se pone cuando se salda.
    INSERT INTO pago (id_pedido, id_metodo_pago, monto, fecha_cancelacion, id_estado_pago)
    VALUES (
        v_id_pedido,
        v_id_metodo,
        v_total,
        NULL,
        (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = 'pendiente')
    );

    RETURN jsonb_build_object(
        'id_pedido', v_id_pedido,
        'total',     v_total::text,
        'stock',     v_stock_final
    );
END;
$$;

COMMENT ON FUNCTION crear_pedido(bigint, bigint, varchar, jsonb) IS
    'Crea un pedido con sus lineas, descuenta el stock y deja el pago pendiente. Todo o nada';
