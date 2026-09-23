-- ============================================================
-- descuentos-oferta.sql -- REFERENCIA, no es la migracion real
-- ============================================================
-- Aplicado a mano contra la base LOCAL (mesh-postgres) para poder
-- desarrollar el backend de "descuentos en ofertas" sin esperar la
-- migracion real del companero. Idempotente: se puede correr mas de una
-- vez sin romper nada. Ver
-- `elementos Generales/plan pendiente/descuentos-oferta.md` para el diseno
-- completo y el porque.
--
-- Un `.\arrancar.ps1 -Reiniciar` borra esto y deja solo lo que digan las
-- migraciones reales. Cuando la migracion real este lista, este archivo se
-- puede tirar.
--
-- **Revision 2026-09-23 (tarde): diseno normalizado.** La primera version
-- de este archivo guardaba el precio YA con descuento en `oferta.precio`
-- mas una columna `precio_original` para poder revertir. El usuario pidio
-- explicitamente lo contrario: `precio` NUNCA se toca por un descuento, el
-- % es una columna aparte, y el precio final se calcula EN LAS CONSULTAS,
-- nunca se guarda en ningun lado (ni siquiera como columna GENERATED de
-- Postgres -- se considero y se descarto a proposito). Esta version
-- reemplaza a la anterior por completo.


-- ============================================================
-- Por que dos tablas y no una
-- ============================================================
-- `oferta.porcentaje_descuento` es el descuento VIGENTE ahora mismo -- un
-- atributo mas de la fila viva, igual que `precio` o `stock`.
--
-- `precio_historial.porcentaje_descuento` es la misma idea pero para el
-- LIBRO: cada fila de `precio_historial` ya es un snapshot de "asi estaba
-- la oferta en este instante" (ver el comentario de 005_ofertas.sql sobre
-- por que precio_historial es snapshot y no delta). Sin esta columna, el
-- historial olvidaria si una compra vieja tuvo descuento o no -- perderia
-- justo el dato que un reporte necesitaria para explicar por que un pedido
-- de marzo costo menos de lo que el precio de catalogo de marzo decia.
--
-- Las dos son NULLABLE e INDEPENDIENTES entre si (no hay un CHECK que las
-- obligue a ir "juntas" con ninguna otra columna, a diferencia de la
-- version anterior de este archivo): NULL quiere decir simplemente "sin
-- descuento en ese momento".


ALTER TABLE oferta
    ADD COLUMN IF NOT EXISTS porcentaje_descuento numeric(5,2);

COMMENT ON COLUMN oferta.porcentaje_descuento IS
    'El % de descuento VIGENTE ahora mismo (1-90, hasta 2 decimales). '
    'NULL si no hay descuento activo. oferta.precio NUNCA se modifica por '
    'esto -- sigue siendo el precio de lista. El precio a cobrar/mostrar '
    'se calcula en cada consulta: ROUND(precio * (1 - '
    'COALESCE(porcentaje_descuento,0)/100), 2). Nunca se guarda ese '
    'resultado en ninguna columna.';

ALTER TABLE oferta
    DROP CONSTRAINT IF EXISTS oferta_descuento_juntas;

ALTER TABLE oferta
    DROP COLUMN IF EXISTS precio_original;

-- Cota de sanidad -- el rango real (1-90) lo exige el backend al validar
-- la peticion; aqui solo se descartan los casos absurdos: 0 (no es
-- descuento), negativo, o >=100 (dejaria el precio a cobrar en 0 o
-- negativo).
ALTER TABLE oferta
    DROP CONSTRAINT IF EXISTS oferta_descuento_porcentaje_rango;

ALTER TABLE oferta
    ADD CONSTRAINT oferta_descuento_porcentaje_rango
    CHECK (porcentaje_descuento IS NULL
           OR (porcentaje_descuento > 0 AND porcentaje_descuento < 100));


-- ============================================================
-- precio_historial -- la misma columna, para que el libro no pierda el dato
-- ============================================================
ALTER TABLE precio_historial
    ADD COLUMN IF NOT EXISTS porcentaje_descuento numeric(5,2);

COMMENT ON COLUMN precio_historial.porcentaje_descuento IS
    'El % de descuento vigente en el momento de este snapshot (copiado de '
    'oferta.porcentaje_descuento por el trigger). NULL si en ese momento '
    'no habia descuento. precio en esta tabla sigue siendo el precio de '
    'lista, igual que en oferta -- el monto realmente cobrado se calcula '
    'igual que en cualquier otra consulta: ROUND(precio * (1 - '
    'COALESCE(porcentaje_descuento,0)/100), 2).';

ALTER TABLE precio_historial
    DROP CONSTRAINT IF EXISTS precio_historial_descuento_porcentaje_rango;

ALTER TABLE precio_historial
    ADD CONSTRAINT precio_historial_descuento_porcentaje_rango
    CHECK (porcentaje_descuento IS NULL
           OR (porcentaje_descuento > 0 AND porcentaje_descuento < 100));


-- ============================================================
-- El trigger: se dispara tambien cuando cambia el descuento, no solo el precio
-- ============================================================
-- Version original (005_ofertas.sql): `AFTER INSERT OR UPDATE OF precio`.
-- Si un vendedor SOLO cambia `porcentaje_descuento` (sin tocar `precio`),
-- eso tiene que dejar una fila nueva en el historial igual que un cambio
-- de precio -- es la misma clase de hecho economico ("desde este momento,
-- esta oferta se ve/cobra distinto"), y el libro no puede tener un hueco
-- justo ahi.
CREATE OR REPLACE FUNCTION oferta_registrar_precio()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_actor bigint;
BEGIN
    v_actor := COALESCE(
        NULLIF(current_setting('mesh.id_usuario', true), '')::bigint,
        NEW.id_usuario
    );

    IF TG_OP = 'INSERT' THEN
        INSERT INTO precio_historial (id_oferta, precio, porcentaje_descuento, id_usuario_modifico, fecha_creacion)
        VALUES (NEW.id_oferta, NEW.precio, NEW.porcentaje_descuento, v_actor, NEW.fecha_creacion);

    ELSIF NEW.precio IS DISTINCT FROM OLD.precio
       OR NEW.porcentaje_descuento IS DISTINCT FROM OLD.porcentaje_descuento THEN
        INSERT INTO precio_historial (id_oferta, precio, porcentaje_descuento, id_usuario_modifico)
        VALUES (NEW.id_oferta, NEW.precio, NEW.porcentaje_descuento, v_actor);
    END IF;

    RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_oferta_registrar_precio ON oferta;

CREATE TRIGGER trg_oferta_registrar_precio
    AFTER INSERT OR UPDATE OF precio, porcentaje_descuento ON oferta
    FOR EACH ROW EXECUTE FUNCTION oferta_registrar_precio();

COMMENT ON FUNCTION oferta_registrar_precio() IS
    'Escribe el precio (y el descuento vigente) de nacimiento y cada '
    'cambio en precio_historial. La base, no la costumbre. Se dispara con '
    'un cambio de precio, de porcentaje_descuento, o los dos juntos.';


-- ------------------------------------------------------------
-- Sin indice nuevo todavia
-- ------------------------------------------------------------
-- No hay hoy ninguna consulta "dame todas las ofertas con descuento" -- si
-- aparece esa necesidad, ahi se gana un indice parcial
-- `WHERE porcentaje_descuento IS NOT NULL` sobre `oferta`, mismo criterio
-- que `idx_oferta_inventario_limitado` (014). El indice existente
-- `idx_oferta_catalogo_precio (id_producto_mongo, id_producto_variante_mongo, precio)`
-- deja de servir para el `ORDER BY` de la ficha en cuanto ese ORDER BY
-- pase a ser por el precio CON descuento (una expresion, no la columna
-- cruda) -- ver el plan .md, seccion de la ficha del producto. No se
-- soluciona aqui: es un ajuste de la consulta en el backend, no del
-- esquema.


-- ============================================================
-- comprar_pedido() -- la UNICA funcion del flujo de pedido que cambia
-- ============================================================
-- `agregar_linea()` no se toca: sigue congelando el id de la fila de
-- precio_historial tal cual, sin importar cuantas columnas tenga esa fila.
-- Es `comprar_pedido()` la que LEE el precio de esa fila para totalizar, y
-- por eso es la unica que tiene que aplicar la formula del descuento.
--
-- Los dos cambios contra la version de 007_flujo_pedido.sql:
--   1. El SELECT del FOR trae tambien `ph.porcentaje_descuento` (variable
--      `record`, no hace falta declarar nada nuevo -- se adapta sola).
--   2. La linea que suma al total pasa de `v_linea.precio * v_linea.cantidad`
--      a la formula completa, redondeada a 2 decimales ANTES de multiplicar
--      por la cantidad (no despues -- redondear el total en vez del precio
--      unitario acumularia el error de redondeo linea a linea en pedidos
--      con muchas unidades de la misma oferta).
--
-- `cancelar_pedido()` NO se toca: nunca calcula dinero, solo pone
-- `pago.id_estado_pago = 'reembolsado'` -- el monto que se reembolsa es el
-- que `comprar_pedido()` ya calculo bien al momento de comprar.
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
        SELECT pp.*, ph.id_oferta, ph.precio, ph.porcentaje_descuento
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

        -- La formula del descuento, redondeada ANTES de multiplicar por la
        -- cantidad -- mismo criterio de redondeo que el resto del proyecto
        -- (2 decimales, siempre sobre el precio unitario, nunca sobre el
        -- total acumulado).
        v_total := v_total + ROUND(
            v_linea.precio * (1 - COALESCE(v_linea.porcentaje_descuento, 0) / 100),
            2
        ) * v_linea.cantidad;

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
    'Confirma la compra: descuenta el stock de cada oferta, aplica el descuento vigente al momento de comprar si lo hay, registra el pago y pasa el pedido a comprado. Todo o nada';


-- ------------------------------------------------------------
-- Comprobarse a si misma
-- ------------------------------------------------------------
DO $verificar$
DECLARE
    v_tipo_oferta       text;
    v_tipo_historial    text;
    v_check_oferta      integer;
    v_check_historial   integer;
    v_trigger_columnas  text;
    v_definicion_fn     text;
BEGIN
    SELECT data_type INTO v_tipo_oferta
      FROM information_schema.columns
     WHERE table_name = 'oferta' AND column_name = 'porcentaje_descuento';
    IF v_tipo_oferta IS DISTINCT FROM 'numeric' THEN
        RAISE EXCEPTION 'oferta.porcentaje_descuento no quedo como numeric (esta: %)', v_tipo_oferta;
    END IF;

    SELECT data_type INTO v_tipo_historial
      FROM information_schema.columns
     WHERE table_name = 'precio_historial' AND column_name = 'porcentaje_descuento';
    IF v_tipo_historial IS DISTINCT FROM 'numeric' THEN
        RAISE EXCEPTION 'precio_historial.porcentaje_descuento no quedo como numeric (esta: %)', v_tipo_historial;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'oferta' AND column_name = 'precio_original'
    ) THEN
        RAISE EXCEPTION 'oferta.precio_original deberia haberse borrado (diseno anterior, ya no aplica)';
    END IF;

    SELECT count(*) INTO v_check_oferta
      FROM pg_constraint
     WHERE conrelid = 'oferta'::regclass AND conname = 'oferta_descuento_porcentaje_rango';
    IF v_check_oferta <> 1 THEN
        RAISE EXCEPTION 'Falta el CHECK oferta_descuento_porcentaje_rango';
    END IF;

    SELECT count(*) INTO v_check_historial
      FROM pg_constraint
     WHERE conrelid = 'precio_historial'::regclass AND conname = 'precio_historial_descuento_porcentaje_rango';
    IF v_check_historial <> 1 THEN
        RAISE EXCEPTION 'Falta el CHECK precio_historial_descuento_porcentaje_rango';
    END IF;

    -- El trigger tiene que escuchar las DOS columnas, no solo precio.
    SELECT string_agg(a.attname, ',' ORDER BY a.attname)
      INTO v_trigger_columnas
      FROM pg_trigger t
      JOIN pg_attribute a
        ON a.attrelid = t.tgrelid AND a.attnum = ANY(t.tgattr)
     WHERE t.tgname = 'trg_oferta_registrar_precio' AND t.tgrelid = 'oferta'::regclass;

    IF v_trigger_columnas IS DISTINCT FROM 'porcentaje_descuento,precio' THEN
        RAISE EXCEPTION 'trg_oferta_registrar_precio deberia escuchar precio Y porcentaje_descuento (escucha: %)', v_trigger_columnas;
    END IF;

    -- comprar_pedido() de verdad tiene que mencionar porcentaje_descuento en
    -- su cuerpo -- si alguien reemplazo la funcion por la version vieja (por
    -- ejemplo, reaplicando 007_flujo_pedido.sql encima de esto sin darse
    -- cuenta), este archivo lo detecta en vez de dejar el checkout cobrando
    -- sin descuento en silencio.
    SELECT pg_get_functiondef(p.oid) INTO v_definicion_fn
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'comprar_pedido';

    IF v_definicion_fn IS NULL THEN
        RAISE EXCEPTION 'No existe la funcion comprar_pedido';
    END IF;

    IF v_definicion_fn NOT LIKE '%porcentaje_descuento%' THEN
        RAISE EXCEPTION 'comprar_pedido() no aplica el descuento -- quedo la version vieja de 007_flujo_pedido.sql';
    END IF;

    RAISE NOTICE 'descuentos-oferta (diseno normalizado) lista. Ofertas con descuento activo: %',
                 (SELECT count(*) FROM oferta WHERE porcentaje_descuento IS NOT NULL);
END
$verificar$;
