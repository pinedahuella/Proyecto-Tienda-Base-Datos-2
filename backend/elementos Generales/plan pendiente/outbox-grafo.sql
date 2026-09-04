-- ============================================================
-- outbox-grafo.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), como migrations/015_outbox_grafo.sql,
-- integrada en el orden correcto y en migrations/README.md.
--
-- Este archivo existe para dos cosas:
--   1. Dejar por escrito, en la forma exacta, que cambio de esquema pide el
--      plan `outbox-grafo.md` (mismo folder).
--   2. Poder aplicarlo al contenedor local `mesh-postgres` mientras se
--      desarrolla el backend en paralelo, sin esperar la migracion.
--
-- Aplicado en local el 2026-09-03 con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS / CREATE OR REPLACE / DROP + CREATE del
-- trigger) y reversible: un `.\arrancar.ps1 -Reiniciar` reconstruye la base
-- desde las migraciones reales y borra todo esto.
--
-- DIVERGE de docs/PENDIENTE-OUTBOX.md a proposito: ese diseno traia columnas
-- `entidad` ('resena' por ahora) y `operacion` ('alta'|'baja'). Las dos se
-- quitaron -- ver `outbox-grafo.md` seccion "La tabla" para el porque. En
-- resumen: la tabla ya ES de eventos de resena, y el worker infiere
-- alta/baja de si la resena todavia existe cuando procesa el evento (mismo
-- principio que "guardar solo el id y releer el estado actual").
--
-- NO siembra la cola con las resenas que ya existen. Para desarrollo se
-- prueba insertando resenas nuevas. La decision de sembrar (o correr
-- `cargar_grafo.sh --limpiar`) es del companero y va en la migracion real;
-- ver `outbox-grafo.md` seccion "Semilla".
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. La tabla: la cola de resenas pendientes de proyectar al grafo
-- ------------------------------------------------------------
-- Es una tabla NORMAL de PostgreSQL, no de Neo4j. El trigger de mas abajo
-- escribe aqui DENTRO de la transaccion de la resena, asi que "la resena
-- existe pero su evento no" es imposible. Un worker (tarea @Interval de
-- NestJS) la vacia despues, aplicando cada evento a Neo4j con MERGE.
CREATE TABLE IF NOT EXISTS evento_grafo (
    id_evento     bigserial PRIMARY KEY,

    -- Que resena cambio. SIN llave foranea a `resena`: si la hubiera, el
    -- trigger AFTER DELETE intentaria insertar una fila que apunta a un
    -- id_resena recien borrado -> violacion de FK -> el DELETE quedaria
    -- bloqueado. Es el mismo trato que `oferta.id_producto_mongo` y
    -- `pedido_producto.id_producto_mongo`.
    id_resena     bigint NOT NULL,

    -- Cuando se encolo. Es informativo: el ORDEN de aplicacion lo da
    -- id_evento (serial), NO esta fecha -- dos eventos en el mismo
    -- milisegundo quedarian sin desempate.
    fecha         timestamptz NOT NULL DEFAULT now(),

    -- NULL = pendiente. Con fecha = ya proyectado en Neo4j. Lo procesado se
    -- acumula para siempre; lo poda el worker (procesado_en < now() - 7d).
    procesado_en  timestamptz,

    -- Un evento que falla siempre (dato torcido, resena que no existe y nodo
    -- que tampoco) taparia la cola si se procesa en orden. A los 5 intentos
    -- el worker lo salta; la conciliacion los reporta.
    intentos      integer NOT NULL DEFAULT 0 CHECK (intentos >= 0),
    ultimo_error  text
);

COMMENT ON TABLE evento_grafo IS
    'Cola de outbox: resenas pendientes de proyectar a Neo4j. La escribe un trigger en la misma transaccion que la resena; la vacia un worker que infiere alta/baja de si la resena aun existe';
COMMENT ON COLUMN evento_grafo.id_evento IS
    'Serial. Su orden ES el orden de aplicacion -- no usar fecha para ordenar';
COMMENT ON COLUMN evento_grafo.id_resena IS
    'La resena que cambio. Sin FK: un evento encolado por AFTER DELETE apunta a un id ya borrado';
COMMENT ON COLUMN evento_grafo.procesado_en IS
    'NULL = pendiente. Con fecha = proyectado. El worker poda lo procesado a los 7 dias';
COMMENT ON COLUMN evento_grafo.intentos IS
    'Reintentos fallidos. A los 5 el worker lo aparta para no tapar la cola';

-- La cola: lo pendiente, lo mas viejo primero. PARCIAL, porque lo procesado
-- se acumula y la cola no lo mira nunca.
CREATE INDEX IF NOT EXISTS idx_evento_grafo_cola
    ON evento_grafo (id_evento)
    WHERE procesado_en IS NULL;


-- ------------------------------------------------------------
-- 2. El trigger: cada cambio en `resena` encola su id
-- ------------------------------------------------------------
-- Se ramifica por TG_OP y no con un CASE / COALESCE sobre NEW/OLD: en un
-- DELETE la fila NEW no esta asignada y nombrarla es fragil. Misma trampa
-- que el trigger de likes de la 011.
--
-- INSERT, UPDATE y DELETE encolan lo mismo: el id de la resena. El worker,
-- al procesar el evento, mira si la resena todavia existe:
--   existe   -> MERGE del nodo :Resena y sus relaciones (alta / upsert)
--   no existe -> MATCH (r:Resena {id}) DETACH DELETE r (baja)
-- Por eso no hace falta guardar 'alta'/'baja' en la fila.
--
-- NO hay trigger equivalente sobre `comentario` (donde viven el texto y la
-- fecha de la resena): en el alta, POST /resenas inserta el comentario raiz
-- en la misma transaccion ANTES que la resena, asi que cuando este trigger
-- dispara el comentario ya existe. Un trigger en comentario solo haria falta
-- si apareciera una ruta para editar el texto de una resena publicada -- hoy
-- resenas.controller.ts no la tiene.
CREATE OR REPLACE FUNCTION encolar_evento_grafo_resena()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO evento_grafo (id_resena) VALUES (OLD.id_resena);
    ELSE
        INSERT INTO evento_grafo (id_resena) VALUES (NEW.id_resena);
    END IF;

    -- AFTER trigger: lo que devuelva no se usa.
    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_grafo_resena() IS
    'Encola en evento_grafo el id de la resena tocada, en la misma transaccion. El worker decide alta/baja segun si la resena aun existe';

-- DROP y CREATE porque no existe CREATE TRIGGER IF NOT EXISTS, y el archivo
-- tiene que poder correrse dos veces.
DROP TRIGGER IF EXISTS trg_resena_al_grafo ON resena;

CREATE TRIGGER trg_resena_al_grafo
    AFTER INSERT OR UPDATE OR DELETE ON resena
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_grafo_resena();

COMMIT;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT to_regclass('public.evento_grafo') AS tabla_evento_grafo;

SELECT tgname AS trigger, tgenabled AS habilitado
FROM pg_trigger
WHERE tgrelid = 'resena'::regclass AND NOT tgisinternal;

SELECT count(*) AS eventos_encolados,
       count(*) FILTER (WHERE procesado_en IS NULL) AS pendientes
FROM evento_grafo;
