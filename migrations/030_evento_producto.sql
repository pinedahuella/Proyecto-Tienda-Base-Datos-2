-- ============================================================
-- 030_evento_producto.sql
-- ============================================================
-- Comprar sin MongoDB, el outbox. Es el evento-producto.sql de Jose David
-- (6f89237), hecho migracion; el plan y el worker estan en
-- backend/elementos Generales/plan pendiente/evento-producto.md.
--
-- Es el hermano de 015_outbox_grafo.sql (evento_grafo): misma forma de tabla,
-- mismo trigger AFTER en la misma transaccion. Aquella lleva las resenas a
-- Neo4j; esta lleva "este producto cambio" al worker que recalcula en Mongo los
-- campos calculados (precio, stock, ofertas, descuento y nota de resenas). Asi
-- el checkout ya no espera a MongoDB despues de cobrar.
--
-- UNA fila pendiente por producto, no un log: recalcular siempre parte del
-- estado actual, asi que 50 cambios seguidos se resuelven con un solo
-- recalculo. El trigger hace UPSERT sobre la fila pendiente y le renueva
-- `fecha`; el worker marca `procesado_en` solo si `fecha` sigue siendo la que
-- leyo.
--
-- Como la migracion corre antes que migrations/datos/, una base recien creada
-- queda con una fila pendiente por producto sembrado, y el primer paso del
-- worker rehace los campos calculados de todo el catalogo.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS evento_producto (
    id_evento          bigserial PRIMARY KEY,
    id_producto_mongo  bigint NOT NULL,
    fecha              timestamptz NOT NULL DEFAULT now(),
    procesado_en       timestamptz,
    intentos           integer NOT NULL DEFAULT 0 CHECK (intentos >= 0),
    ultimo_error       text
);

COMMENT ON TABLE evento_producto IS
    'Cola de outbox: productos cuyos campos calculados en Mongo (precio, stock, ofertas, descuento, nota de resenas) hay que recalcular. La llenan triggers de oferta y resena en la misma transaccion; la vacia un worker. Una sola fila pendiente por producto';
COMMENT ON COLUMN evento_producto.id_producto_mongo IS
    'El producto que cambio. SIN FK a proposito: vive en MongoDB, igual que oferta.id_producto_mongo';
COMMENT ON COLUMN evento_producto.fecha IS
    'Ultimo cambio visto sobre el producto mientras esta pendiente. El worker marca procesado solo si sigue siendo la que leyo';
COMMENT ON COLUMN evento_producto.procesado_en IS
    'NULL = pendiente. Con fecha = ya recalculado';
COMMENT ON COLUMN evento_producto.intentos IS
    'Reintentos fallidos, para apartar un producto que falla siempre y no deja avanzar a los demas';
COMMENT ON COLUMN evento_producto.ultimo_error IS
    'El mensaje del ultimo fallo, para poder mirar un evento apartado sin adivinar';

-- UNA pendiente por producto: es lo que permite el UPSERT del trigger. Parcial,
-- como el indice de la cola de evento_grafo: lo procesado se acumula y no se
-- vuelve a mirar. Hace de indice de la cola tambien (el worker lee por aqui).
CREATE UNIQUE INDEX IF NOT EXISTS uq_evento_producto_pendiente
    ON evento_producto (id_producto_mongo)
    WHERE procesado_en IS NULL;


-- ============================================================
-- Los triggers que la llenan
-- ============================================================
CREATE OR REPLACE FUNCTION encolar_evento_producto()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_producto bigint;
BEGIN
    -- Se ramifica por TG_OP: en un DELETE la fila NEW no esta asignada
    -- (misma trampa que encolar_evento_grafo_resena).
    IF TG_OP = 'DELETE' THEN
        v_producto := OLD.id_producto_mongo;
    ELSE
        v_producto := NEW.id_producto_mongo;
    END IF;

    INSERT INTO evento_producto (id_producto_mongo)
    VALUES (v_producto)
    ON CONFLICT (id_producto_mongo) WHERE procesado_en IS NULL
    -- intentos = 0: un cambio nuevo reactiva un producto que el worker habia
    -- apartado por fallar demasiadas veces.
    DO UPDATE SET fecha = clock_timestamp(), intentos = 0;

    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_producto() IS
    'Anota en evento_producto el producto tocado (oferta o resena), en la misma transaccion. Si ya hay uno pendiente solo le renueva la fecha';

-- OFERTA: solo las columnas que entran en los campos calculados (ver
-- ProductosService.recalcularUnProducto): precio, descuento, stock y estado.
-- Ni fecha_actualizacion ni las columnas de vencimiento/aprobacion mueven
-- nada de lo que se copia a Mongo.
DROP TRIGGER IF EXISTS trg_oferta_al_producto ON oferta;
CREATE TRIGGER trg_oferta_al_producto
    AFTER INSERT OR DELETE
          OR UPDATE OF precio, porcentaje_descuento, stock, id_estado_oferta
    ON oferta
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_producto();

-- RESENA: la nota media y el total de resenas del producto.
DROP TRIGGER IF EXISTS trg_resena_al_producto ON resena;
CREATE TRIGGER trg_resena_al_producto
    AFTER INSERT OR UPDATE OR DELETE ON resena
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_producto();

COMMIT;


-- ============================================================
-- Se comprueba a si misma (mismo criterio que la 015)
-- ============================================================
DO $verificar$
DECLARE
    v_n integer;
    v_h char;
BEGIN
    IF to_regclass('public.evento_producto') IS NULL THEN
        RAISE EXCEPTION 'La tabla evento_producto no quedo creada';
    END IF;

    SELECT count(*) INTO v_n FROM pg_indexes
     WHERE tablename = 'evento_producto' AND indexname = 'uq_evento_producto_pendiente';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'Falta el indice unico parcial uq_evento_producto_pendiente: sin el, el UPSERT del trigger falla';
    END IF;

    -- Existen Y estan habilitados (un DISABLE TRIGGER los deja puestos y mudos).
    SELECT count(*), max(tgenabled) INTO v_n, v_h FROM pg_trigger
     WHERE tgrelid = 'oferta'::regclass AND tgname = 'trg_oferta_al_producto' AND NOT tgisinternal;
    IF v_n <> 1 OR v_h <> 'O' THEN
        RAISE EXCEPTION 'trg_oferta_al_producto no esta creado y habilitado sobre oferta';
    END IF;

    SELECT count(*), max(tgenabled) INTO v_n, v_h FROM pg_trigger
     WHERE tgrelid = 'resena'::regclass AND tgname = 'trg_resena_al_producto' AND NOT tgisinternal;
    IF v_n <> 1 OR v_h <> 'O' THEN
        RAISE EXCEPTION 'trg_resena_al_producto no esta creado y habilitado sobre resena';
    END IF;

    -- Sin FK: igual que evento_grafo, un AFTER DELETE apuntaria a algo que ya no esta.
    SELECT count(*) INTO v_n FROM pg_constraint
     WHERE conrelid = 'evento_producto'::regclass AND contype = 'f';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'evento_producto no debe tener llaves foraneas';
    END IF;

    RAISE NOTICE 'Outbox de productos listo.';
END
$verificar$;
