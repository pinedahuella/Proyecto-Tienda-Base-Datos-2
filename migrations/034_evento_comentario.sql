-- ============================================================
-- 034_evento_comentario.sql
-- ============================================================
-- Buscar resenas por significado, la cola. Es el evento-comentario.sql de
-- Jose David (fa3281c), hecho migracion sin cambiar nada de lo que crea; el
-- plan y el worker estan en
-- backend/elementos Generales/plan pendiente/evento-comentario.md.
--
-- Es el hermano de 030_evento_producto.sql: misma forma de tabla, mismo
-- trigger AFTER en la misma transaccion. Esta lleva "este comentario cambio"
-- al worker EventoComentarioSyncService, que lo indexa con su vector en el
-- indice mesh_comentarios de Elasticsearch: el texto de cada resena (el
-- comentario raiz) y el de sus respuestas. De ese indice leen las senales de
-- fraude por texto (035) y GET /buscador/productos/intencion.
--
-- No se amplio evento_grafo: es la cola de Neo4j, una fila por id de RESENA
-- que consume otro worker, y sus triggers solo miran `resena`. Las respuestas
-- cuelgan de `comentario`.
--
-- UNA fila pendiente por comentario: el trigger hace UPSERT sobre la fila
-- pendiente y le renueva `fecha`; el worker marca `procesado_en` solo si
-- `fecha` sigue siendo la que leyo.
--
-- Como la migracion corre antes que migrations/datos/, una base recien creada
-- queda con una fila pendiente por comentario sembrado. Una base que ya tenia
-- comentarios no: esos los encola arrancar.ps1 una sola vez, cuando crea el
-- indice mesh_comentarios (paso "Indice de comentarios").
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
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
