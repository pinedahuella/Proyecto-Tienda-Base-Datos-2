-- ============================================================
-- 016_alerta_fraude.sql
-- ============================================================
-- Donde caen las alertas de fraude del inicio de sesion, y el aviso de que
-- log_login y log_registro ya no se escriben.
--
--
-- DE DONDE SALE
-- ============================================================
-- El backend ya la usa. `FraudeLoginService` lleva contadores en Redis en el
-- propio camino del login y, cuando uno cruza su umbral, hace un UPSERT aqui:
--
--   fuerza_bruta_ip       8 fallos desde la misma IP en 60 s
--   fuerza_bruta_cuenta   5 fallos contra el mismo identificador en 60 s
--   multi_cuenta_ip       4 identificadores distintos desde la misma IP en 300 s
--
-- Y `GET /admin/fraude/alertas-login` la lee. Sin esta tabla las dos cosas
-- fallan: la escritura se pierde en silencio (es best-effort y solo deja un
-- warn en el log) y el listado contesta con error.
--
-- La definicion es la del SQL de referencia del companero, en
-- `backend/elementos Generales/plan pendiente/fraude-login-eventos.sql`,
-- copiada columna por columna y con los mismos nombres. No es pereza: ese SQL
-- ya se corrio a mano en alguna base, y ahi el CREATE TABLE IF NOT EXISTS de
-- abajo se salta entero. Cualquier diferencia que se le agregue aqui (una
-- columna, un CHECK) quedaria puesta en unas bases y en otras no, sin que
-- nadie se entere. Si algo hay que cambiarle, va en una migracion nueva con
-- un ALTER, que si llega a todas.
--
--
-- NO ES UN LOG
-- ============================================================
-- Una fila aqui es "esto merece que un admin lo mire", no "esto paso". Cada
-- intento de entrada, bueno o malo, vive en la coleccion eventos_autenticacion
-- de MongoDB (ver mongo/003_eventos_autenticacion.js) y de ahi se copia a
-- Elasticsearch. Esta tabla solo recibe lo que cruzo un umbral.
--
--
-- LOS IDS DE LOS CATALOGOS, Y POR QUE HAY UN CANDADO
-- ============================================================
-- `backend/src/models/alerta-fraude.ts` fija los ids como constantes: 1, 2 y 3
-- para los tipos y para los estados, en el orden de abajo. Lo hace para no
-- consultar el catalogo en cada login, igual que ID_ROL_ADMIN.
--
-- Aqui NO se escribe ningun id (regla de migrations/README.md): los pone la
-- secuencia, en el orden del VALUES. En una base limpia salen 1, 2 y 3. Pero
-- "en una base limpia" es una suposicion, y si no se cumple el backend
-- guardaria una fuerza_bruta_ip con el id de otro tipo, sin un solo error:
-- la llave foranea se cumple igual, solo que apunta a la fila equivocada.
--
-- Por eso el bloque del final comprueba, nombre por nombre, que cada id es el
-- que el backend espera, y si no FALLA la migracion. Los numeros aparecen ahi
-- y solo ahi: como una comprobacion, nunca en un INSERT.
--
--
-- POR QUE WHERE NOT EXISTS Y NO ON CONFLICT
-- ============================================================
-- Las dos cosas son idempotentes, pero ON CONFLICT DO NOTHING pide el
-- nextval de la secuencia ANTES de descubrir el choque, y lo quema. Como este
-- archivo se corre en cada arranque, cada arranque le sumaria tres a las dos
-- secuencias. No rompe las tres filas que ya estan; rompe la cuarta: el dia
-- que otra migracion agregue un tipo, su id seria cualquier numero y no el 4.
-- Con NOT EXISTS la fila que ya esta no llega al INSERT y la secuencia no se
-- mueve. El ON CONFLICT se deja igual detras, por si alguien corre esto dos
-- veces a la vez.
--
--
-- POR QUE NO LLEVA BEGIN/COMMIT
-- ============================================================
-- Como la mayoria de las de esta carpeta. Y aqui ademas no hace falta: todo es
-- IF NOT EXISTS o NOT EXISTS, asi que una corrida que se cae a la mitad la
-- termina la siguiente, en vez de quedarse como "ya aplicada" que es lo que
-- avisa el README. arrancar.ps1 corre este archivo en CADA arranque y tiene
-- que salir con codigo 0 todas las veces, no solo la primera.
-- ============================================================


-- ------------------------------------------------------------
-- tipo_alerta_fraude: que senal disparo la alerta
-- ------------------------------------------------------------
-- En tabla y no en un CHECK de texto, como cualquier otro catalogo del
-- proyecto (estado_oferta, estado_producto, motivo_movimiento).
--
-- Solo estos tres, porque son los que se calculan con contadores de Redis sin
-- geolocalizacion. Viaje imposible o IP nueva tras fallos se agregan como
-- filas nuevas, en otra migracion, el dia que se decida la geolocalizacion.
CREATE TABLE IF NOT EXISTS tipo_alerta_fraude (
    id_tipo_alerta_fraude      smallserial PRIMARY KEY,
    tipo_alerta_fraude_nombre  varchar(30) NOT NULL UNIQUE
);

INSERT INTO tipo_alerta_fraude (tipo_alerta_fraude_nombre)
SELECT v.nombre
  FROM (VALUES (1, 'fuerza_bruta_ip'),
               (2, 'fuerza_bruta_cuenta'),
               (3, 'multi_cuenta_ip')) AS v(orden, nombre)
 WHERE NOT EXISTS (SELECT 1 FROM tipo_alerta_fraude t
                    WHERE t.tipo_alerta_fraude_nombre = v.nombre)
 ORDER BY v.orden
ON CONFLICT DO NOTHING;

COMMENT ON TABLE tipo_alerta_fraude IS
    'Catalogo de senales de fraude de login que detecta el backend: fuerza_bruta_ip, fuerza_bruta_cuenta, multi_cuenta_ip. El backend fija sus ids (models/alerta-fraude.ts); la 016 lo comprueba';


-- ------------------------------------------------------------
-- estado_alerta_fraude: en que va la revision del admin
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS estado_alerta_fraude (
    id_estado_alerta_fraude      smallserial PRIMARY KEY,
    estado_alerta_fraude_nombre  varchar(30) NOT NULL UNIQUE
);

INSERT INTO estado_alerta_fraude (estado_alerta_fraude_nombre)
SELECT v.nombre
  FROM (VALUES (1, 'pendiente'),
               (2, 'revisada'),
               (3, 'descartada')) AS v(orden, nombre)
 WHERE NOT EXISTS (SELECT 1 FROM estado_alerta_fraude e
                    WHERE e.estado_alerta_fraude_nombre = v.nombre)
 ORDER BY v.orden
ON CONFLICT DO NOTHING;

COMMENT ON TABLE estado_alerta_fraude IS
    'Catalogo de estados de revision de una alerta_fraude: pendiente, revisada, descartada. El backend fija sus ids (models/alerta-fraude.ts); la 016 lo comprueba';


-- ------------------------------------------------------------
-- alerta_fraude
-- ------------------------------------------------------------
-- `clave` es el ORIGEN de la senal (la IP, o el identificador que se tecleo),
-- no la victima.
--
-- `ventana_inicio` es el minuto truncado de la deteccion. Junto con el tipo y
-- la clave forma la llave del UPSERT del backend: varios cruces del umbral en
-- el mismo minuto suben `contador` en una sola fila. Al minuto siguiente nace
-- otra, a proposito: una alerta que un admin ya reviso no se reabre sola.
--
-- Ese UNIQUE es lo unico de esta tabla que el backend no puede perder. Su
-- ON CONFLICT (id_tipo_alerta_fraude, clave, ventana_inicio) necesita un
-- indice unico sobre esas tres columnas exactas; sin el, el INSERT revienta
-- con "there is no unique or exclusion constraint matching". El candado de
-- abajo lo comprueba.
CREATE TABLE IF NOT EXISTS alerta_fraude (
    id_alerta_fraude        bigserial PRIMARY KEY,

    id_tipo_alerta_fraude   smallint NOT NULL
                            REFERENCES tipo_alerta_fraude(id_tipo_alerta_fraude),

    clave                   varchar(255) NOT NULL,

    -- Solo en fuerza_bruta_cuenta, y solo si el identificador es de una
    -- cuenta real. NULL en las dos senales por IP.
    id_usuario              bigint REFERENCES usuarios(id_usuario)
                            ON DELETE RESTRICT,

    -- Evidencia para un humano: conteos, ventana, y en multi_cuenta_ip los
    -- identificadores vistos (hasta 20). No se consulta por campo.
    detalle                 jsonb NOT NULL DEFAULT '{}'::jsonb,

    contador                integer NOT NULL DEFAULT 1 CHECK (contador > 0),

    ventana_inicio          timestamptz NOT NULL,

    id_estado_alerta_fraude smallint NOT NULL
                            REFERENCES estado_alerta_fraude(id_estado_alerta_fraude),

    -- El id REAL del admin que la reviso. Aqui no hay sustitucion por la
    -- tienda: un vendedor no toca esta tabla nunca.
    id_usuario_reviso       bigint REFERENCES usuarios(id_usuario)
                            ON DELETE RESTRICT,
    fecha_revision          timestamptz,

    fecha_creacion          timestamptz NOT NULL DEFAULT now(),
    fecha_actualizacion     timestamptz NOT NULL DEFAULT now(),

    UNIQUE (id_tipo_alerta_fraude, clave, ventana_inicio)
);

COMMENT ON TABLE alerta_fraude IS
    'Alertas de fraude de login para revision de un admin. Las escribe FraudeLoginService cuando un contador de Redis cruza su umbral; no es un log de cada intento (eso vive en eventos_autenticacion de MongoDB)';
COMMENT ON COLUMN alerta_fraude.clave IS
    'El origen de la senal: la IP (fuerza_bruta_ip, multi_cuenta_ip) o el identificador intentado (fuerza_bruta_cuenta)';
COMMENT ON COLUMN alerta_fraude.ventana_inicio IS
    'El minuto (truncado) en que se detecto. Junto con (tipo, clave) evita una fila nueva por cada fallo sucesivo en el mismo minuto: el UPSERT suma contador en vez de duplicar';
COMMENT ON COLUMN alerta_fraude.contador IS
    'Cuantas veces se volvio a cruzar el umbral dentro de la misma ventana (ver ventana_inicio). Nace en 1';

-- El listado del admin: lo mas reciente primero, con o sin filtro por estado.
CREATE INDEX IF NOT EXISTS idx_alerta_fraude_listado
    ON alerta_fraude (fecha_actualizacion DESC);


-- ------------------------------------------------------------
-- log_login y log_registro se quedan, pero ya no se escriben
-- ------------------------------------------------------------
-- No se borran: guardan el historico de antes del cambio y el ETL de
-- ClickHouse (etl/extraer_eventos.sql) todavia las lee. Pero quien las abra
-- tiene que saber que desde el 2026-09-10 no reciben filas nuevas, o va a
-- sacar conclusiones de una tabla congelada creyendo que esta al dia. El
-- sitio donde lo va a leer es el comentario de la tabla, que es lo que
-- ensena \d+ y pgAdmin.
COMMENT ON TABLE log_login IS
    'Cada entrada y salida de un usuario, HASTA el 2026-09-10. Desde esa fecha el backend ya no la escribe: el log de autenticacion vive en la coleccion eventos_autenticacion de MongoDB (y su copia en Elasticsearch). Se conserva por el historico';
COMMENT ON TABLE log_registro IS
    'Desde donde se creo cada cuenta, HASTA el 2026-09-10. Desde esa fecha el backend ya no la escribe: el log de autenticacion vive en la coleccion eventos_autenticacion de MongoDB (y su copia en Elasticsearch). Se conserva por el historico';


-- ============================================================
-- El candado
-- ============================================================
-- Falla la migracion si algun id no es el que el backend tiene escrito, o si
-- falta el indice unico de su UPSERT.
--
-- OJO al redactar los mensajes: Correr-Migraciones de arrancar.ps1 perdona
-- un error cuya linea de ERROR diga "already exists", y lo pinta como "ya
-- estaba aplicada". Un mensaje de este candado con esas dos palabras se
-- colaria en amarillo en vez de parar el arranque.
--
-- Hasta el 2026-09-12 era peor: el perdon miraba la salida entera, y los
-- NOTICE "relation ... already exists, skipping" de los CREATE ... IF NOT
-- EXISTS de arriba salen en cada corrida sobre una base ya migrada. Con eso
-- este candado se colaba en amarillo dijera lo que dijera su mensaje.
DO $candado$
DECLARE
    r          record;
    v_id       integer;
    v_unico    integer;
BEGIN
    -- Los pares (nombre, id) son copia de backend/src/models/alerta-fraude.ts.
    -- Si alli cambian, cambian aqui en una migracion nueva.
    FOR r IN
        SELECT * FROM (VALUES
            ('tipo_alerta_fraude',   'fuerza_bruta_ip',     1),
            ('tipo_alerta_fraude',   'fuerza_bruta_cuenta', 2),
            ('tipo_alerta_fraude',   'multi_cuenta_ip',     3),
            ('estado_alerta_fraude', 'pendiente',           1),
            ('estado_alerta_fraude', 'revisada',            2),
            ('estado_alerta_fraude', 'descartada',          3)
        ) AS c(tabla, nombre, id_esperado)
    LOOP
        IF r.tabla = 'tipo_alerta_fraude' THEN
            SELECT id_tipo_alerta_fraude INTO v_id
              FROM tipo_alerta_fraude
             WHERE tipo_alerta_fraude_nombre = r.nombre;
        ELSE
            SELECT id_estado_alerta_fraude INTO v_id
              FROM estado_alerta_fraude
             WHERE estado_alerta_fraude_nombre = r.nombre;
        END IF;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Falta % en %: el backend lo usa con el id %',
                r.nombre, r.tabla, r.id_esperado;
        END IF;

        IF v_id <> r.id_esperado THEN
            RAISE EXCEPTION '% en % tiene el id % y el backend espera el % (models/alerta-fraude.ts). Las alertas se guardarian con el tipo o el estado cambiado',
                r.nombre, r.tabla, v_id, r.id_esperado;
        END IF;
    END LOOP;

    -- El indice unico del ON CONFLICT: justo esas tres columnas, ni una mas
    -- ni una menos. Se busca en pg_index y no en pg_constraint porque al
    -- ON CONFLICT le sirve igual un UNIQUE que un CREATE UNIQUE INDEX.
    SELECT count(*) INTO v_unico
      FROM pg_index i
     WHERE i.indrelid = 'alerta_fraude'::regclass
       AND i.indisunique
       AND i.indpred IS NULL
       AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text)
              FROM unnest(i.indkey) AS k(attnum)
              JOIN pg_attribute a
                ON a.attrelid = i.indrelid AND a.attnum = k.attnum)
           = ARRAY['clave', 'id_tipo_alerta_fraude', 'ventana_inicio'];

    IF v_unico = 0 THEN
        RAISE EXCEPTION 'alerta_fraude no tiene el indice unico (id_tipo_alerta_fraude, clave, ventana_inicio) y el UPSERT del backend lo necesita';
    END IF;

    RAISE NOTICE 'alerta_fraude lista. Alertas pendientes de revisar: %',
        (SELECT count(*) FROM alerta_fraude af
           JOIN estado_alerta_fraude e
             ON e.id_estado_alerta_fraude = af.id_estado_alerta_fraude
          WHERE e.estado_alerta_fraude_nombre = 'pendiente');
END
$candado$;
