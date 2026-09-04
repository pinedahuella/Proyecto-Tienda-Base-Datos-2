-- ============================================================
-- 015_outbox_grafo.sql
-- ============================================================
-- La cola que mantiene el grafo de Neo4j al dia: una tabla de pendientes y un
-- trigger que la llena en la MISMA transaccion que escribe la resena.
--
-- Es una tabla y un trigger, pero decide como se sincronizan dos bases, asi
-- que la explicacion va aqui, que es donde alguien la va a buscar.
--
--
-- QUE PROBLEMA RESUELVE
-- ============================================================
-- Hoy el grafo se llena corriendo `etl/cargar_grafo.sh` a mano. Eso deja dos
-- costuras, las dos medidas:
--
--   1. El grafo se queda viejo y NO LO DICE. Una resena escrita despues de la
--      ultima corrida no esta en Neo4j, y `GET /admin/fraude/anillos` la
--      ignora sin ninguna senal: ensena un analisis correcto sobre datos
--      incompletos, que es peor que fallar. Un panel que falla se arregla; uno
--      que miente se cree.
--
--   2. El ETL relee TODO cada vez. Es idempotente porque escribe con MERGE,
--      pero no es incremental: con 90 resenas tarda 14 segundos, y ese numero
--      crece con el catalogo aunque no haya cambiado ni una fila.
--
--
-- POR QUE UN OUTBOX Y NO UNA ESCRITURA DIRECTA A NEO4J
-- ============================================================
-- La alternativa obvia es que `POST /resenas` le escriba a Neo4j despues de
-- commitear en PostgreSQL. Tiene un hueco que no se puede cerrar: si el
-- proceso se cae ENTRE el COMMIT y esa escritura, la resena existe en
-- PostgreSQL, no existe en el grafo, y no queda constancia de que falte. Nadie
-- se entera nunca.
--
-- El outbox no tiene ese hueco porque el evento se escribe DENTRO de la misma
-- transaccion que la resena: o entran las dos cosas o no entra ninguna. Si
-- Neo4j esta caido, la resena se guarda igual y su evento espera.
--
-- Y cumple las tres condiciones que puso el profesor para esta sincronizacion:
-- no bloquea nada (el POST nunca le habla a Neo4j), el envio es asincrono (lo
-- vacia un trabajo aparte), y se puede conciliar (unos count que comparan las
-- dos bases). Es literalmente la "aceptacion documentada de una ventana de
-- consistencia eventual" que pide el documento de estrategia de la Entrega 3.
--
--
-- LAS DOS COLUMNAS QUE NO ESTAN, Y NO ES UN OLVIDO
-- ============================================================
-- `docs/PENDIENTE-OUTBOX.md` proponia dos columnas mas y las dos se quitaron a
-- proposito. Se deja escrito aqui para que nadie las "restaure" leyendo aquel
-- documento y creyendo que faltan:
--
--   `entidad varchar(30)`   era especulativa. La tabla se llama evento_grafo y
--                           el trigger siempre escribiria 'resena'. Una columna
--                           con un solo valor posible no informa de nada.
--
--   `operacion varchar(10)` era redundante y ademas fragil. El que vacia la
--                           cola relee la resena por su id: si la fila existe
--                           es un alta y hace MERGE, si no existe es una baja y
--                           hace DETACH DELETE. Lo INFIERE del estado actual,
--                           que es el mismo principio que "guardar solo el id".
--                           Guardar la operacion congela un pedacito de "que
--                           paso" que puede contradecir a la base: un
--                           'alta' viejo sobre una resena ya borrada mandaria a
--                           crear un nodo que no debe existir.
--
--
-- QUE NO HACE ESTA MIGRACION
-- ============================================================
-- No siembra la cola, y no hace falta: este archivo corre ANTES que
-- `migrations/datos/001_catalogo.sql` (arrancar.ps1 hace primero migrations/ y
-- despues migrations/datos/), asi que cuando la semilla inserta sus 90 resenas
-- el trigger ya existe y la cola se llena sola. Una base recien creada queda
-- con 90 eventos pendientes, que es exactamente la verdad: eso es lo que hay
-- que proyectar.
--
-- Y por eso NO se eligio la otra opcion que estaba sobre la mesa, que era
-- correr `cargar_grafo.sh --limpiar` en cada arranque: `--limpiar` borra el
-- grafo entero, y comandos.txt ya dejo escrito por que eso va detras de una
-- bandera y nunca automatico -- se llevaria por delante cualquier anillo
-- sembrado a mano para una demostracion, en medio de la demostracion.
--
-- Quien vacia la cola es `etl/cargar_grafo.sh`, que al terminar una carga
-- completa marca como procesado todo lo que estuviera pendiente: una
-- proyeccion completa aplica, por definicion, todo lo que habia en la cola.
-- ============================================================

BEGIN;


-- ============================================================
-- La cola
-- ============================================================
-- Es una tabla normal de PostgreSQL. No tiene nada de Neo4j: es la lista de
-- lo que falta por llevar alla.
CREATE TABLE IF NOT EXISTS evento_grafo (
    id_evento     bigserial PRIMARY KEY,
    id_resena     bigint NOT NULL,
    fecha         timestamptz NOT NULL DEFAULT now(),
    procesado_en  timestamptz,
    intentos      integer NOT NULL DEFAULT 0 CHECK (intentos >= 0),
    ultimo_error  text
);

COMMENT ON TABLE evento_grafo IS
    'Cola de outbox: resenas pendientes de proyectar a Neo4j. La escribe un trigger en la misma transaccion que la resena; la vacia el ETL del grafo (o un worker), que infiere alta o baja segun si la resena todavia existe';

-- El ORDEN de aplicacion es el del serial, no el de `fecha`. Dos eventos
-- escritos en el mismo milisegundo tendrian la misma fecha y quedarian sin
-- desempate; el serial no empata nunca.
COMMENT ON COLUMN evento_grafo.id_evento IS
    'Serial. Su orden ES el orden de aplicacion -- no ordenar por fecha, que puede empatar';

-- SIN llave foranea a `resena`, y es obligatorio que no la tenga: el trigger
-- dispara tambien AFTER DELETE, o sea que intentaria insertar una fila que
-- apunta a un id_resena recien borrado. Con FK eso seria una violacion y el
-- DELETE de la resena quedaria bloqueado para siempre. Mismo trato que
-- oferta.id_producto_mongo, que apunta a un id que vive en MongoDB.
COMMENT ON COLUMN evento_grafo.id_resena IS
    'La resena que cambio. SIN FK a proposito: un evento encolado por AFTER DELETE apunta a un id que ya no existe';

COMMENT ON COLUMN evento_grafo.procesado_en IS
    'NULL = pendiente. Con fecha = ya esta en el grafo';

COMMENT ON COLUMN evento_grafo.intentos IS
    'Reintentos fallidos. Sirve para apartar un evento que falla siempre y no deja avanzar a los de atras';

COMMENT ON COLUMN evento_grafo.ultimo_error IS
    'El mensaje del ultimo fallo, para poder mirar un evento apartado sin adivinar';

-- Indice PARCIAL, y ahi esta la gracia. Lo procesado se acumula para siempre y
-- la cola no lo mira nunca: un indice sobre toda la tabla crece con el
-- historico entero para responder una pregunta que solo mira lo pendiente.
-- Asi el indice se mantiene del tamano de la cola de verdad, que casi siempre
-- esta vacia.
CREATE INDEX IF NOT EXISTS idx_evento_grafo_cola
    ON evento_grafo (id_evento)
    WHERE procesado_en IS NULL;


-- ============================================================
-- El trigger que la llena
-- ============================================================
CREATE OR REPLACE FUNCTION encolar_evento_grafo_resena()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    -- Se ramifica por TG_OP porque en un DELETE la fila NEW no esta asignada y
    -- leer NEW.id_resena ahi revienta. Es la misma trampa que ya mordio en el
    -- trigger de `likes` de la 011.
    IF TG_OP = 'DELETE' THEN
        INSERT INTO evento_grafo (id_resena) VALUES (OLD.id_resena);
    ELSE
        INSERT INTO evento_grafo (id_resena) VALUES (NEW.id_resena);
    END IF;

    -- AFTER trigger: lo que devuelva no lo mira nadie.
    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_grafo_resena() IS
    'Encola en evento_grafo el id de la resena tocada, en la misma transaccion. Los tres eventos encolan lo mismo: quien vacia la cola decide alta o baja mirando si la resena todavia existe';

DROP TRIGGER IF EXISTS trg_resena_al_grafo ON resena;

-- UPDATE va incluido aunque hoy NADA actualice una resena: el controlador solo
-- tiene crear, responder, votar, quitar voto y tres GET. Cuesta cero (encola el
-- mismo id) y cubre gratis el dia que aparezca "editar la calificacion".
--
-- Y NO hay trigger sobre `comentario`, donde viven el texto y la fecha de la
-- resena, porque en el alta el comentario raiz se inserta ANTES que la resena y
-- en la misma transaccion: cuando este trigger dispara, el comentario ya esta
-- ahi y quien vacie la cola lo lee bien. Hara falta el dia que exista una ruta
-- para editar el texto de una resena ya publicada.
CREATE TRIGGER trg_resena_al_grafo
    AFTER INSERT OR UPDATE OR DELETE ON resena
    FOR EACH ROW
    EXECUTE FUNCTION encolar_evento_grafo_resena();


COMMIT;


-- ============================================================
-- Se comprueba a si misma
-- ============================================================
-- El mismo criterio que la 014 y que 001_catalogo.sql: una migracion que no se
-- verifica es una migracion que puede haber dejado media cosa. Aqui importa
-- especialmente porque lo que se crea es un mecanismo que NADIE mira hasta que
-- hace falta -- un trigger que no quedo puesto no se nota el dia que se aplica,
-- se nota semanas despues cuando el grafo esta viejo y nadie sabe por que.
DO $verificar$
DECLARE
    v_tabla     text;
    v_indice    integer;
    v_trigger   integer;
    v_habilit   char;
    v_fk        integer;
    v_pendientes bigint;
BEGIN
    -- 1. La tabla existe.
    SELECT to_regclass('public.evento_grafo')::text INTO v_tabla;
    IF v_tabla IS NULL THEN
        RAISE EXCEPTION 'La tabla evento_grafo no quedo creada';
    END IF;

    -- 2. El indice parcial existe. Sin el la cola sigue funcionando, asi que
    --    esto no protege la correccion: protege que nadie lo quite "porque no
    --    se usa" sin leer por que es parcial.
    SELECT count(*) INTO v_indice
      FROM pg_indexes
     WHERE tablename = 'evento_grafo' AND indexname = 'idx_evento_grafo_cola';

    IF v_indice <> 1 THEN
        RAISE EXCEPTION 'Falta el indice parcial idx_evento_grafo_cola';
    END IF;

    -- 3. El trigger existe Y ESTA HABILITADO. Las dos cosas: un
    --    ALTER TABLE resena DISABLE TRIGGER lo deja puesto y mudo, y desde
    --    fuera se ve igual que si estuviera funcionando. 001_catalogo.sql
    --    apaga y vuelve a encender triggers de `oferta`, asi que la maniobra
    --    se usa en este proyecto y una corrida interrumpida a la mitad puede
    --    dejar uno apagado para siempre.
    SELECT count(*), max(tgenabled) INTO v_trigger, v_habilit
      FROM pg_trigger
     WHERE tgrelid = 'resena'::regclass
       AND tgname = 'trg_resena_al_grafo'
       AND NOT tgisinternal;

    IF v_trigger <> 1 THEN
        RAISE EXCEPTION 'El trigger trg_resena_al_grafo no quedo creado sobre resena';
    END IF;

    IF v_habilit <> 'O' THEN
        RAISE EXCEPTION 'trg_resena_al_grafo existe pero esta deshabilitado (tgenabled = %)', v_habilit;
    END IF;

    -- 4. Que NO tenga llave foranea a resena. Es la comprobacion menos obvia y
    --    la mas util: alguien que "mejore" el esquema agregandole la FK que
    --    parece que falta bloquearia el borrado de cualquier resena, y el
    --    sintoma seria un DELETE que falla en un sitio sin relacion aparente.
    SELECT count(*) INTO v_fk
      FROM pg_constraint
     WHERE conrelid = 'evento_grafo'::regclass
       AND contype = 'f';

    IF v_fk <> 0 THEN
        RAISE EXCEPTION 'evento_grafo tiene % llave(s) foranea(s) y no debe tener ninguna: la FK a resena bloquearia el AFTER DELETE', v_fk;
    END IF;

    SELECT count(*) INTO v_pendientes
      FROM evento_grafo WHERE procesado_en IS NULL;

    RAISE NOTICE 'Outbox del grafo listo. Eventos pendientes ahora mismo: %', v_pendientes;
    RAISE NOTICE 'Se vacia con: bash etl/cargar_grafo.sh';
END
$verificar$;
