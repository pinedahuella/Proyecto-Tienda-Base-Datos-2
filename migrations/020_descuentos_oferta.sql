-- ============================================================
-- 020_descuentos_oferta.sql
-- ============================================================
-- Una oferta puede llevar un descuento: el vendedor le pone un % y eso se ve
-- en la ficha, en el catalogo y en el carrito, y se cobra al pagar.
--
--   oferta.porcentaje_descuento            el % vigente ahora mismo
--   precio_historial.porcentaje_descuento  el % vigente en ese snapshot
--   trg_oferta_registrar_precio            ahora escucha precio Y descuento
--   comprar_pedido()                       cobra el precio con descuento
--
--
-- DE DONDE SALE
-- ============================================================
-- El backend ya lo usa: POST y DELETE /vendedor/ofertas/:id/descuento escriben
-- la columna, y la ficha, el carrito y los reportes la leen. La definicion es
-- la del SQL de referencia del companero, en
-- `backend/elementos Generales/plan pendiente/descuentos-oferta.sql`, con los
-- mismos nombres de columna, de CHECK y de trigger. Ese SQL ya se corrio a mano
-- en su base local, asi que aqui todo tiene que convivir con que ya este puesto:
-- por eso los IF NOT EXISTS y los candados que miran el catalogo antes de
-- agregar algo. El diseno completo, y el porque, esta en el `.md` del mismo
-- folder.
--
--
-- EL PRECIO NO SE TOCA
-- ============================================================
-- `oferta.precio` sigue siendo el precio de LISTA, con o sin descuento. El
-- precio que se ensena y se cobra no se guarda en ningun lado, ni como columna
-- normal ni como GENERATED (se considero y se descarto a proposito): se calcula
-- en cada consulta con
--
--   ROUND(precio * (1 - COALESCE(porcentaje_descuento, 0) / 100), 2)
--
-- Son dos hechos independientes -- a cuanto se vende y cuanto se le rebaja --
-- y guardar uno ya mezclado con el otro es justo el dato derivado que un
-- esquema normalizado evita. El costo es que la formula se repite en cada
-- consulta que necesita el precio final: la ficha, los campos que se copian a
-- Mongo, el carrito, los reportes y `comprar_pedido()`. Si manana aparece un
-- sexto lugar que lee `oferta.precio` y se olvida de la formula, ese lugar
-- ensena el precio sin descuento y nada lo avisa.
--
--
-- POR QUE TAMBIEN EN precio_historial
-- ============================================================
-- Cada fila de `precio_historial` ya es un snapshot de "asi estaba la oferta
-- en este instante" (ver 005), y la linea del pedido apunta a esa fila para
-- saber que se cobro. Sin el % en el snapshot, una compra vieja con descuento
-- se leeria al precio de lista: el libro olvidaria justo el dato que explica
-- por que ese pedido costo menos.
--
--
-- EL RANGO
-- ============================================================
-- El CHECK solo descarta lo absurdo: 0 no es descuento, y 100 o mas dejaria el
-- precio en cero o negativo. El rango de verdad (1 a 90, dos decimales) lo
-- exige el backend al validar la peticion; ponerlo aqui obligaria a otra
-- migracion el dia que el negocio cambie de opinion sobre el tope.
--
-- La venta relampago (014) exige un descuento activo para abrirse, y el
-- descuento no se puede quitar mientras la venta esta abierta. Esa regla vive
-- en el backend y no aqui: "abierta" solo lo sabe Redis (ver 014).
--
--
-- EL ORDEN DE ARRANQUE: 005 Y 007 VAN ANTES, EN CADA ARRANQUE
-- ============================================================
-- `arrancar.ps1` corre TODOS los .sql en orden en cada arranque. Dos de los
-- anteriores definen lo mismo que este archivo reemplaza:
--
--   005  crea el trigger viejo (`UPDATE OF precio`). En una base nueva corre
--        entero; en una ya cargada muere en su primer CREATE TABLE con
--        "already exists" y no llega al trigger. En los dos casos esta 020
--        pasa despues y deja la version nueva.
--
--   007  es todo CREATE OR REPLACE, asi que SI corre entero en cada arranque
--        y reinstala el `comprar_pedido()` viejo, el que cobra el precio de
--        lista. Esta 020 lo vuelve a reemplazar unos segundos despues. Si el
--        backend ya estaba levantado, una compra justo en ese hueco se
--        cobraria sin descuento: es un hueco de segundos y solo al arrancar.
--        Lo que no puede pasar es que el arranque TERMINE con la version
--        vieja puesta, y eso lo impide el candado del final.
--
-- Ninguna de las posteriores (012, 013, 014) toca estas dos funciones: la 012
-- LLAMA a `comprar_pedido()` por su nombre, asi que hereda la version nueva
-- sin cambiar, y la 013 solo reemplaza `agregar_linea()`, que congela el id
-- de la fila de precio_historial y no necesita saber cuantas columnas tiene.
-- Si una migracion futura reemplaza cualquiera de las dos, tiene que llevar
-- el descuento -- y si no lo lleva, este candado ya no la cubre, porque corre
-- antes: ese archivo necesita el suyo.
--
--
-- IDEMPOTENTE DE VERDAD
-- ============================================================
-- Sale con codigo 0 en cada corrida, no por el perdon de "already exists" de
-- `arrancar.ps1`. Las columnas van con IF NOT EXISTS, los CHECK se agregan
-- solo si falta uno con ese nombre (asi no se revalida la tabla entera en
-- cada arranque), y las funciones y el trigger se reemplazan. Ningun mensaje
-- de los candados dice "already exists": si lo dijera, un candado que dispara
-- se leeria como "ya estaba aplicada" y el arranque saldria en verde.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. oferta.porcentaje_descuento
-- ------------------------------------------------------------
ALTER TABLE oferta
    ADD COLUMN IF NOT EXISTS porcentaje_descuento numeric(5,2);

COMMENT ON COLUMN oferta.porcentaje_descuento IS
    'El % de descuento VIGENTE ahora mismo (el backend acepta 1-90, hasta 2 decimales). NULL si no hay descuento. oferta.precio NUNCA se modifica por esto: sigue siendo el precio de lista. El precio a cobrar se calcula en cada consulta: ROUND(precio * (1 - COALESCE(porcentaje_descuento,0)/100), 2), y no se guarda en ninguna columna';

-- La primera version del SQL de referencia guardaba el precio ya rebajado en
-- `precio` y el de antes en `precio_original`, con un CHECK que las amarraba.
-- Se descarto, pero pudo quedar puesta en la base donde se probo. En una base
-- que nunca la tuvo estas dos lineas no hacen nada.
ALTER TABLE oferta DROP CONSTRAINT IF EXISTS oferta_descuento_juntas;
ALTER TABLE oferta DROP COLUMN IF EXISTS precio_original;


-- ------------------------------------------------------------
-- 2. precio_historial.porcentaje_descuento
-- ------------------------------------------------------------
ALTER TABLE precio_historial
    ADD COLUMN IF NOT EXISTS porcentaje_descuento numeric(5,2);

COMMENT ON COLUMN precio_historial.porcentaje_descuento IS
    'El % de descuento vigente en el momento de este snapshot, copiado de oferta.porcentaje_descuento por el trigger. NULL si en ese momento no habia. precio sigue siendo el de lista: lo cobrado es ROUND(precio * (1 - COALESCE(porcentaje_descuento,0)/100), 2)';


-- ------------------------------------------------------------
-- 3. Los dos CHECK de rango, solo si faltan
-- ------------------------------------------------------------
-- El SQL de referencia los borra y los vuelve a crear. Aqui eso seria
-- revalidar las dos tablas enteras con un candado exclusivo en cada arranque,
-- para no cambiar nada. Se agregan solo la primera vez.
DO $rango$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'oferta'::regclass
                      AND conname = 'oferta_descuento_porcentaje_rango') THEN
        ALTER TABLE oferta
            ADD CONSTRAINT oferta_descuento_porcentaje_rango
            CHECK (porcentaje_descuento IS NULL
                   OR (porcentaje_descuento > 0 AND porcentaje_descuento < 100));
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'precio_historial'::regclass
                      AND conname = 'precio_historial_descuento_porcentaje_rango') THEN
        ALTER TABLE precio_historial
            ADD CONSTRAINT precio_historial_descuento_porcentaje_rango
            CHECK (porcentaje_descuento IS NULL
                   OR (porcentaje_descuento > 0 AND porcentaje_descuento < 100));
    END IF;
END
$rango$;


-- ------------------------------------------------------------
-- 4. El trigger: tambien cuando cambia el descuento
-- ------------------------------------------------------------
-- La version de 005 solo miraba `precio`. Si un vendedor cambia SOLO el %, eso
-- tiene que dejar fila nueva en el historial igual que un cambio de precio: es
-- el mismo hecho ("desde ahora esta oferta se cobra distinto") y el libro no
-- puede tener un hueco justo ahi.
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
    'Escribe el precio (y el descuento vigente) de nacimiento y cada cambio en precio_historial. Se dispara con un cambio de precio, de porcentaje_descuento o de los dos. La base, no la costumbre';


-- ------------------------------------------------------------
-- 5. comprar_pedido(): cobra el precio con descuento
-- ------------------------------------------------------------
-- La unica funcion del flujo de pedido que cambia. `agregar_linea()` sigue
-- congelando el id de la fila de precio_historial; es esta la que LEE el
-- precio de esa fila para totalizar, y por eso es la que aplica la formula.
--
-- Contra la version de 007 cambian dos cosas:
--
--   1. El SELECT del FOR trae tambien `ph.porcentaje_descuento`.
--   2. Lo que se suma al total pasa de `precio * cantidad` a la formula,
--      redondeada ANTES de multiplicar por la cantidad. Redondear el total
--      en vez del precio unitario daria otro centavo en pedidos de muchas
--      unidades, y el carrito ensena el precio unitario ya redondeado.
--
-- Como el % sale de la fila CONGELADA y no de la oferta viva, se cobra el
-- descuento de la fila a la que apunta la linea, igual que el precio. Que esa
-- fila sea la de ahora lo cuida el backend: antes de pagar compara la foto
-- del carrito contra el precio vigente y avisa si cambio.
--
-- `cancelar_pedido()` no se toca: nunca calcula dinero, reembolsa el monto que
-- esta funcion ya escribio en `pago`.
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

        -- El precio unitario con descuento, redondeado a 2 decimales, y
        -- despues por la cantidad. Sin descuento da el precio tal cual.
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

    -- Todo pago nace pagado de una vez, sin importar el metodo: no hay quien
    -- confirme transferencia o efectivo todavia. Igual que en 007.
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
    'Confirma la compra: descuenta el stock de cada oferta, cobra cada linea con el descuento de su fila de precio_historial si lo tiene, registra el pago y pasa el pedido a comprado. Todo o nada';

COMMIT;


-- ============================================================
-- El candado
-- ============================================================
-- Comprueba lo que el backend da por hecho. Sobre todo el ultimo punto: si
-- `comprar_pedido()` quedara en la version de 007, el checkout cobraria el
-- precio de lista en silencio mientras la ficha y el carrito ensenan el
-- rebajado.
DO $candado$
DECLARE
    v_tipo_oferta       text;
    v_tipo_historial    text;
    v_check_oferta      integer;
    v_check_historial   integer;
    v_trigger_columnas  text;
    v_funciones         integer;
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

    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name = 'oferta' AND column_name = 'precio_original') THEN
        RAISE EXCEPTION 'oferta.precio_original sigue en la tabla: es del diseno anterior y ya no aplica';
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
        RAISE EXCEPTION 'trg_oferta_registrar_precio deberia escuchar precio y porcentaje_descuento (escucha: %)', v_trigger_columnas;
    END IF;

    -- Una sola comprar_pedido. Con dos firmas, el SELECT INTO de abajo leeria
    -- una cualquiera y el candado podria aprobar la que nadie llama.
    SELECT count(*) INTO v_funciones
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'comprar_pedido';

    IF v_funciones <> 1 THEN
        RAISE EXCEPTION 'Hay % funciones comprar_pedido y deberia haber una', v_funciones;
    END IF;

    -- El candado del SQL de referencia, tal cual: la funcion de verdad tiene
    -- que mencionar porcentaje_descuento. Si 007 la pisara despues de esta
    -- (un orden de archivos distinto, o alguien reaplicando 007 a mano), se
    -- ve aqui y no en un pedido cobrado de mas.
    SELECT pg_get_functiondef(p.oid) INTO v_definicion_fn
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'comprar_pedido';

    IF v_definicion_fn NOT LIKE '%porcentaje_descuento%' THEN
        RAISE EXCEPTION 'comprar_pedido() no aplica el descuento: quedo la version vieja de 007_flujo_pedido.sql';
    END IF;

    RAISE NOTICE 'descuentos en ofertas listos. Ofertas con descuento activo: %',
                 (SELECT count(*) FROM oferta WHERE porcentaje_descuento IS NOT NULL);
END
$candado$;
