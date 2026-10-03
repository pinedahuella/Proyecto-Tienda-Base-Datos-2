-- ============================================================
-- evento-comentario.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada despues de la ultima migracion real
-- (hoy 033_sin_llaves_viejas_de_fraude.sql) -- mismo workflow de siempre. El
-- plan completo esta en evento-comentario.md.
--
-- Es el hermano de evento_producto y de evento_grafo: misma forma de tabla,
-- mismo trigger AFTER en la misma transaccion. Esta lleva "este comentario
-- cambio" al worker que lo indexa, con su vector, en Elasticsearch
-- (`mesh_comentarios`): el texto de cada resena (el comentario raiz) y el de
-- sus respuestas, que cuelgan unas de otras (`comentario.id_comentario_padre`).
--
-- Por que una cola propia y no `evento_grafo`: aquella es de Neo4j, una fila
-- por id de RESENA, y el worker del grafo la consume. Dos consumidores sobre
-- la misma fila se estorbarian. Ademas, sus triggers solo miran `resena`, y
-- aqui hay que mirar `comentario` (las respuestas no cuelgan de ninguna resena).
--
-- UNA fila pendiente por comentario, igual que evento_producto: indexar siempre
-- parte del estado actual, asi que varios cambios seguidos se resuelven con una
-- sola indexacion. El trigger hace UPSERT sobre la fila pendiente y le renueva
-- `fecha`. El worker marca `procesado_en` solo si `fecha` sigue siendo la que
-- leyo; si el comentario cambio mientras se indexaba, la fila sigue pendiente.
--
-- Como el worker del grafo, el de comentarios NO necesita saber si fue alta,
-- cambio o baja: mira si el comentario todavia existe. Existe -> indexa;
-- no existe -> borra el documento.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente y reversible: un `.\arrancar.ps1 -Reiniciar` reconstruye la
-- base desde las migraciones reales y borra esto.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS evento_comentario (
    id_evento      bigserial PRIMARY KEY,
    id_comentario  bigint NOT NULL,
    fecha          timestamptz NOT NULL DEFAULT now(),
    procesado_en   timestamptz,
    intentos       integer NOT NULL DEFAULT 0 CHECK (intentos >= 0),
    ultimo_error   text
);

COMMENT ON TABLE evento_comentario IS
    'Cola de outbox: comentarios (la raiz de cada resena y sus respuestas) que hay que indexar, con su vector, en Elasticsearch. La llenan triggers de comentario y resena en la misma transaccion; la vacia un worker. Una sola fila pendiente por comentario';
COMMENT ON COLUMN evento_comentario.id_comentario IS
    'El comentario que cambio. SIN FK a proposito: un AFTER DELETE apuntaria a una fila que ya no esta, y el worker justo necesita ver ese id para borrar el documento';
COMMENT ON COLUMN evento_comentario.fecha IS
    'Ultimo cambio visto sobre el comentario mientras esta pendiente. El worker marca procesado solo si sigue siendo la que leyo';
COMMENT ON COLUMN evento_comentario.procesado_en IS
    'NULL = pendiente. Con fecha = ya indexado (o borrado del indice)';
COMMENT ON COLUMN evento_comentario.intentos IS
    'Reintentos fallidos, para apartar un comentario que falla siempre y no deja avanzar a los demas';
COMMENT ON COLUMN evento_comentario.ultimo_error IS
    'El mensaje del ultimo fallo, para poder mirar un evento apartado sin adivinar';

-- UNA pendiente por comentario: es lo que permite el UPSERT del trigger. Parcial,
-- como el de evento_producto: lo procesado se acumula y no se vuelve a mirar.
-- Hace de indice de la cola tambien (el worker lee por aqui).
CREATE UNIQUE INDEX IF NOT EXISTS uq_evento_comentario_pendiente
    ON evento_comentario (id_comentario)
    WHERE procesado_en IS NULL;


-- ============================================================
-- Los triggers que la llenan
-- ============================================================

-- COMENTARIO: alta, baja y cambio del TEXTO. Los likes y dislikes
-- (cantidad_likes, cantidad_dislikes) no entran en el vector y cambian todo
-- el tiempo: por eso el UPDATE mira solo la columna `comentario`.
CREATE OR REPLACE FUNCTION encolar_evento_comentario()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_comentario bigint;
BEGIN
    -- Se ramifica por TG_OP: en un DELETE la fila NEW no esta asignada
    -- (misma trampa que encolar_evento_producto).
    IF TG_OP = 'DELETE' THEN
        v_comentario := OLD.id_comentario;
    ELSE
        v_comentario := NEW.id_comentario;
    END IF;

    INSERT INTO evento_comentario (id_comentario)
    VALUES (v_comentario)
    ON CONFLICT (id_comentario) WHERE procesado_en IS NULL
    -- intentos = 0: un cambio nuevo reactiva un comentario que el worker
    -- habia apartado por fallar demasiadas veces.
    DO UPDATE SET fecha = clock_timestamp(), intentos = 0;

    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_comentario() IS
    'Anota en evento_comentario el comentario tocado (alta, baja o cambio de texto), en la misma transaccion. Si ya hay uno pendiente solo le renueva la fecha';

DROP TRIGGER IF EXISTS trg_comentario_al_indice ON comentario;
CREATE TRIGGER trg_comentario_al_indice
    AFTER INSERT OR DELETE OR UPDATE OF comentario
    ON comentario
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_comentario();

-- RESENA: la calificacion y el producto no viven en `comentario` sino en
-- `resena`, y van en el documento del comentario raiz. Si cambian, o si la
-- resena se borra, hay que volver a indexar el comentario raiz (`id_comentario`
-- de la resena). El alta tambien: es redundante con el trigger de comentario
-- (la raiz se inserta antes, en la misma transaccion), pero cuesta nada porque
-- el UPSERT junta ambos en una sola fila, y cubre un camino que adjunte una
-- resena a un comentario que ya existia.
CREATE OR REPLACE FUNCTION encolar_evento_comentario_de_resena()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_comentario bigint;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_comentario := OLD.id_comentario;
    ELSE
        v_comentario := NEW.id_comentario;
    END IF;

    INSERT INTO evento_comentario (id_comentario)
    VALUES (v_comentario)
    ON CONFLICT (id_comentario) WHERE procesado_en IS NULL
    DO UPDATE SET fecha = clock_timestamp(), intentos = 0;

    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_comentario_de_resena() IS
    'Anota en evento_comentario el comentario raiz de la resena tocada (alta, baja o cambio de calificacion/producto), en la misma transaccion';

DROP TRIGGER IF EXISTS trg_resena_al_indice_comentario ON resena;
CREATE TRIGGER trg_resena_al_indice_comentario
    AFTER INSERT OR DELETE OR UPDATE OF calificacion, id_producto_mongo
    ON resena
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_comentario_de_resena();

COMMIT;


-- ============================================================
-- Se comprueba a si misma (mismo criterio que evento_producto)
-- ============================================================
DO $verificar$
DECLARE
    v_n integer;
    v_h char;
BEGIN
    IF to_regclass('public.evento_comentario') IS NULL THEN
        RAISE EXCEPTION 'La tabla evento_comentario no quedo creada';
    END IF;

    SELECT count(*) INTO v_n FROM pg_indexes
     WHERE tablename = 'evento_comentario' AND indexname = 'uq_evento_comentario_pendiente';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'Falta el indice unico parcial uq_evento_comentario_pendiente: sin el, el UPSERT del trigger falla';
    END IF;

    -- Existen Y estan habilitados (un DISABLE TRIGGER los deja puestos y mudos).
    SELECT count(*), max(tgenabled) INTO v_n, v_h FROM pg_trigger
     WHERE tgrelid = 'comentario'::regclass AND tgname = 'trg_comentario_al_indice' AND NOT tgisinternal;
    IF v_n <> 1 OR v_h <> 'O' THEN
        RAISE EXCEPTION 'trg_comentario_al_indice no esta creado y habilitado sobre comentario';
    END IF;

    SELECT count(*), max(tgenabled) INTO v_n, v_h FROM pg_trigger
     WHERE tgrelid = 'resena'::regclass AND tgname = 'trg_resena_al_indice_comentario' AND NOT tgisinternal;
    IF v_n <> 1 OR v_h <> 'O' THEN
        RAISE EXCEPTION 'trg_resena_al_indice_comentario no esta creado y habilitado sobre resena';
    END IF;

    -- Sin FK: igual que evento_grafo y evento_producto.
    SELECT count(*) INTO v_n FROM pg_constraint
     WHERE conrelid = 'evento_comentario'::regclass AND contype = 'f';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'evento_comentario no debe tener llaves foraneas';
    END IF;

    RAISE NOTICE 'Outbox de comentarios listo.';
END
$verificar$;
