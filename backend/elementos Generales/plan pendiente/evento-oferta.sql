-- ============================================================
-- evento-oferta.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada despues de la ultima migracion real
-- (hoy 039_senales_resenas_canceladas.sql) -- mismo workflow de siempre. El
-- plan completo esta en evento-oferta.md.
--
-- Es el hermano de evento_producto y de evento_comentario: misma forma de
-- tabla, mismo trigger AFTER en la misma transaccion. Esta lleva "esta oferta
-- cambio" al worker que la indexa en Elasticsearch (`mesh_ofertas`, el
-- buscador de ofertas).
--
-- Por que una cola propia y no `evento_producto`: aquella guarda el PRODUCTO,
-- no la oferta, y su worker recalcula campos en MongoDB. Si Mongo se cae, se
-- frenaria tambien el indice de ofertas. Ademas, el documento de una oferta
-- lleva nombres que viven en otras tablas (producto, variante, vendedor), y
-- ninguna de ellas tiene hoy un trigger.
--
-- UNA fila pendiente por oferta, igual que evento_producto: indexar siempre
-- parte del estado actual, asi que varios cambios seguidos se resuelven con
-- una sola indexacion. El trigger hace UPSERT sobre la fila pendiente y le
-- renueva `fecha`. El worker marca `procesado_en` solo si `fecha` sigue siendo
-- la que leyo.
--
-- El worker NO necesita saber si fue alta, cambio o baja: mira si la oferta
-- todavia existe. Existe -> indexa; no existe -> borra el documento.
--
-- Al final se encolan TODAS las ofertas que ya existen, para que el primer
-- paso del worker llene el indice entero (lo mismo que pasa con
-- evento_producto en una base recien creada).
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente y reversible: un `.\arrancar.ps1 -Reiniciar` reconstruye la
-- base desde las migraciones reales y borra esto.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS evento_oferta (
    id_evento     bigserial PRIMARY KEY,
    id_oferta     bigint NOT NULL,
    fecha         timestamptz NOT NULL DEFAULT now(),
    procesado_en  timestamptz,
    intentos      integer NOT NULL DEFAULT 0 CHECK (intentos >= 0),
    ultimo_error  text
);

COMMENT ON TABLE evento_oferta IS
    'Cola de outbox: ofertas que hay que indexar en Elasticsearch (mesh_ofertas). La llenan triggers de oferta, producto_catalogo, variante_catalogo y usuarios en la misma transaccion; la vacia un worker. Una sola fila pendiente por oferta';
COMMENT ON COLUMN evento_oferta.id_oferta IS
    'La oferta que cambio. SIN FK a proposito: un AFTER DELETE apuntaria a una fila que ya no esta, y el worker justo necesita ver ese id para borrar el documento';
COMMENT ON COLUMN evento_oferta.fecha IS
    'Ultimo cambio visto sobre la oferta mientras esta pendiente. El worker marca procesado solo si sigue siendo la que leyo';
COMMENT ON COLUMN evento_oferta.procesado_en IS
    'NULL = pendiente. Con fecha = ya indexada (o borrada del indice)';
COMMENT ON COLUMN evento_oferta.intentos IS
    'Reintentos fallidos, para apartar una oferta que falla siempre y no deja avanzar a las demas';
COMMENT ON COLUMN evento_oferta.ultimo_error IS
    'El mensaje del ultimo fallo, para poder mirar un evento apartado sin adivinar';

-- UNA pendiente por oferta: es lo que permite el UPSERT de los triggers.
-- Parcial, como el de evento_producto. Hace de indice de la cola tambien.
CREATE UNIQUE INDEX IF NOT EXISTS uq_evento_oferta_pendiente
    ON evento_oferta (id_oferta)
    WHERE procesado_en IS NULL;


-- ============================================================
-- Los triggers que la llenan
-- ============================================================

-- 1. OFERTA: alta, baja y las columnas que van en el documento (precio,
-- descuento, stock y estado). Las mismas que mira trg_oferta_al_producto: ni
-- fecha_actualizacion ni las de vencimiento/aprobacion entran al indice.
CREATE OR REPLACE FUNCTION encolar_evento_oferta()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_oferta bigint;
BEGIN
    -- Se ramifica por TG_OP: en un DELETE la fila NEW no esta asignada
    -- (misma trampa que encolar_evento_producto).
    IF TG_OP = 'DELETE' THEN
        v_oferta := OLD.id_oferta;
    ELSE
        v_oferta := NEW.id_oferta;
    END IF;

    INSERT INTO evento_oferta (id_oferta)
    VALUES (v_oferta)
    ON CONFLICT (id_oferta) WHERE procesado_en IS NULL
    -- intentos = 0: un cambio nuevo reactiva una oferta que el worker
    -- habia apartado por fallar demasiadas veces.
    DO UPDATE SET fecha = clock_timestamp(), intentos = 0;

    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_oferta() IS
    'Anota en evento_oferta la oferta tocada (alta, baja o cambio de precio, descuento, stock o estado), en la misma transaccion. Si ya hay una pendiente solo le renueva la fecha';

DROP TRIGGER IF EXISTS trg_oferta_al_indice ON oferta;
CREATE TRIGGER trg_oferta_al_indice
    AFTER INSERT OR DELETE
          OR UPDATE OF precio, porcentaje_descuento, stock, id_estado_oferta
    ON oferta
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_oferta();

-- 2. PRODUCTO_CATALOGO: el nombre del producto va en el documento de cada
-- oferta suya. El alta tambien, por si una oferta se creo antes que la fila
-- del catalogo y quedo indexada sin nombre. Un UPDATE que deja el mismo
-- nombre (el helper del catalogo lo reescribe al editar) no encola nada.
CREATE OR REPLACE FUNCTION encolar_evento_oferta_de_producto()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.nombre IS NOT DISTINCT FROM NEW.nombre THEN
        RETURN NULL;
    END IF;

    INSERT INTO evento_oferta (id_oferta)
    SELECT o.id_oferta
      FROM oferta o
     WHERE o.id_producto_mongo = NEW.id_producto_mongo
    ON CONFLICT (id_oferta) WHERE procesado_en IS NULL
    DO UPDATE SET fecha = clock_timestamp(), intentos = 0;

    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_oferta_de_producto() IS
    'Anota en evento_oferta todas las ofertas del producto cuyo nombre cambio (o que acaba de entrar al catalogo)';

DROP TRIGGER IF EXISTS trg_producto_catalogo_al_indice_oferta ON producto_catalogo;
CREATE TRIGGER trg_producto_catalogo_al_indice_oferta
    AFTER INSERT OR UPDATE OF nombre
    ON producto_catalogo
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_oferta_de_producto();

-- 3. VARIANTE_CATALOGO: el nombre de la variante y su estado (una variante
-- inactiva no se le muestra al comprador). Por el PAR producto + variante,
-- no por la variante sola (ver el comentario de oferta en 005_ofertas.sql).
CREATE OR REPLACE FUNCTION encolar_evento_oferta_de_variante()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF TG_OP = 'UPDATE'
       AND OLD.nombre_variante IS NOT DISTINCT FROM NEW.nombre_variante
       AND OLD.estado IS NOT DISTINCT FROM NEW.estado THEN
        RETURN NULL;
    END IF;

    INSERT INTO evento_oferta (id_oferta)
    SELECT o.id_oferta
      FROM oferta o
     WHERE o.id_producto_mongo = NEW.id_producto_mongo
       AND o.id_producto_variante_mongo = NEW.id_producto_variante_mongo
    ON CONFLICT (id_oferta) WHERE procesado_en IS NULL
    DO UPDATE SET fecha = clock_timestamp(), intentos = 0;

    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_oferta_de_variante() IS
    'Anota en evento_oferta todas las ofertas de la variante cuyo nombre o estado cambio (o que acaba de entrar al catalogo)';

DROP TRIGGER IF EXISTS trg_variante_catalogo_al_indice_oferta ON variante_catalogo;
CREATE TRIGGER trg_variante_catalogo_al_indice_oferta
    AFTER INSERT OR UPDATE OF nombre_variante, estado
    ON variante_catalogo
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_oferta_de_variante();

-- 4. USUARIOS: el nombre del vendedor (usuario, nombre, apellido) y su estado
-- (las ofertas de un vendedor suspendido no se le muestran al comprador).
-- Solo UPDATE: un usuario recien creado no tiene ofertas, y uno con ofertas
-- no se puede borrar (oferta.id_usuario es ON DELETE RESTRICT).
CREATE OR REPLACE FUNCTION encolar_evento_oferta_de_usuario()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF OLD.usuario IS NOT DISTINCT FROM NEW.usuario
       AND OLD.nombre IS NOT DISTINCT FROM NEW.nombre
       AND OLD.apellido IS NOT DISTINCT FROM NEW.apellido
       AND OLD.id_estado_usuario IS NOT DISTINCT FROM NEW.id_estado_usuario THEN
        RETURN NULL;
    END IF;

    INSERT INTO evento_oferta (id_oferta)
    SELECT o.id_oferta
      FROM oferta o
     WHERE o.id_usuario = NEW.id_usuario
    ON CONFLICT (id_oferta) WHERE procesado_en IS NULL
    DO UPDATE SET fecha = clock_timestamp(), intentos = 0;

    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_oferta_de_usuario() IS
    'Anota en evento_oferta todas las ofertas del vendedor cuyo nombre o estado cambio';

DROP TRIGGER IF EXISTS trg_usuarios_al_indice_oferta ON usuarios;
CREATE TRIGGER trg_usuarios_al_indice_oferta
    AFTER UPDATE OF usuario, nombre, apellido, id_estado_usuario
    ON usuarios
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_oferta_de_usuario();


-- ============================================================
-- Carga inicial: todas las ofertas que ya existen, pendientes
-- ============================================================
INSERT INTO evento_oferta (id_oferta)
SELECT o.id_oferta
  FROM oferta o
ON CONFLICT (id_oferta) WHERE procesado_en IS NULL
DO NOTHING;

COMMIT;


-- ============================================================
-- Se comprueba a si misma (mismo criterio que evento_comentario)
-- ============================================================
DO $verificar$
DECLARE
    v_n integer;
    v_h char;
    v_tabla text;
    v_trigger text;
BEGIN
    IF to_regclass('public.evento_oferta') IS NULL THEN
        RAISE EXCEPTION 'La tabla evento_oferta no quedo creada';
    END IF;

    SELECT count(*) INTO v_n FROM pg_indexes
     WHERE tablename = 'evento_oferta' AND indexname = 'uq_evento_oferta_pendiente';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'Falta el indice unico parcial uq_evento_oferta_pendiente: sin el, el UPSERT de los triggers falla';
    END IF;

    -- Existen Y estan habilitados (un DISABLE TRIGGER los deja puestos y mudos).
    FOR v_tabla, v_trigger IN
        VALUES ('oferta', 'trg_oferta_al_indice'),
               ('producto_catalogo', 'trg_producto_catalogo_al_indice_oferta'),
               ('variante_catalogo', 'trg_variante_catalogo_al_indice_oferta'),
               ('usuarios', 'trg_usuarios_al_indice_oferta')
    LOOP
        SELECT count(*), max(tgenabled) INTO v_n, v_h FROM pg_trigger
         WHERE tgrelid = v_tabla::regclass AND tgname = v_trigger AND NOT tgisinternal;
        IF v_n <> 1 OR v_h <> 'O' THEN
            RAISE EXCEPTION '% no esta creado y habilitado sobre %', v_trigger, v_tabla;
        END IF;
    END LOOP;

    -- Sin FK: igual que evento_producto y evento_comentario.
    SELECT count(*) INTO v_n FROM pg_constraint
     WHERE conrelid = 'evento_oferta'::regclass AND contype = 'f';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'evento_oferta no debe tener llaves foraneas';
    END IF;

    RAISE NOTICE 'Outbox de ofertas listo.';
END
$verificar$;
