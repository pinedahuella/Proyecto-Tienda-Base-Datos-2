-- ============================================================
-- refactor-fraude-senales.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada despues de la ultima migracion real
-- existente y en migrations/README.md -- mismo workflow de siempre (ver
-- hallazgos-evento-fraude.sql y agrupador-fraude.sql, mismo folder).
--
-- ETAPA 1 del refactor de fraude (ver refactor-fraude-senales.md, mismo
-- folder, para el plan completo por etapas): las tablas del modelo unico de
-- senales, alimentadas SOLO desde anillo_fraude. Las tablas viejas no se
-- tocan; esto convive con ellas hasta la etapa que las apague.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS / ON CONFLICT) y reversible: un
-- `.\arrancar.ps1 -Reiniciar` reconstruye la base desde las migraciones
-- reales y borra todo esto.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. Catalogos
-- ------------------------------------------------------------
-- Cuatro catalogos chicos en lugar de tres catalogos de tipos que no se
-- hablaban (tipo_alerta_fraude, tipo_anillo_fraude, tipo_hallazgo_evento)
-- y de columnas de texto suelto para familia y fuente.

CREATE TABLE IF NOT EXISTS familia_senal_fraude (
    id_familia_senal_fraude      smallserial PRIMARY KEY,
    familia_senal_fraude_nombre  varchar(30) NOT NULL UNIQUE
);

INSERT INTO familia_senal_fraude (familia_senal_fraude_nombre)
SELECT v.nombre
  FROM (VALUES (1, 'anillo_resenas'),
               (2, 'patron_resenas'),
               (3, 'compras_navegacion'),
               (4, 'login')) AS v(orden, nombre)
 WHERE NOT EXISTS (SELECT 1 FROM familia_senal_fraude f
                    WHERE f.familia_senal_fraude_nombre = v.nombre)
 ORDER BY v.orden
ON CONFLICT DO NOTHING;

COMMENT ON TABLE familia_senal_fraude IS
    'Las cuatro familias de deteccion de fraude: anillo_resenas (A.1/A.2, Neo4j), patron_resenas (familia B, Neo4j), compras_navegacion (F1-F6, ClickHouse) y login (Redis, Elasticsearch y MongoDB)';


CREATE TABLE IF NOT EXISTS fuente_senal_fraude (
    id_fuente_senal_fraude      smallserial PRIMARY KEY,
    fuente_senal_fraude_nombre  varchar(30) NOT NULL UNIQUE
);

INSERT INTO fuente_senal_fraude (fuente_senal_fraude_nombre)
SELECT v.nombre
  FROM (VALUES (1, 'neo4j'),
               (2, 'clickhouse'),
               (3, 'login')) AS v(orden, nombre)
 WHERE NOT EXISTS (SELECT 1 FROM fuente_senal_fraude f
                    WHERE f.fuente_senal_fraude_nombre = v.nombre)
 ORDER BY v.orden
ON CONFLICT DO NOTHING;

COMMENT ON TABLE fuente_senal_fraude IS
    'De que motor sale la deteccion: neo4j (grafo de resenas), clickhouse (eventos) o login (contadores en Redis, Elasticsearch y eventos en MongoDB, que se leen juntos)';


CREATE TABLE IF NOT EXISTS rol_cuenta_senal (
    id_rol_cuenta_senal      smallserial PRIMARY KEY,
    rol_cuenta_senal_nombre  varchar(20) NOT NULL UNIQUE
);

INSERT INTO rol_cuenta_senal (rol_cuenta_senal_nombre)
SELECT v.nombre
  FROM (VALUES (1, 'autor'),
               (2, 'victima')) AS v(orden, nombre)
 WHERE NOT EXISTS (SELECT 1 FROM rol_cuenta_senal r
                    WHERE r.rol_cuenta_senal_nombre = v.nombre)
 ORDER BY v.orden
ON CONFLICT DO NOTHING;

COMMENT ON TABLE rol_cuenta_senal IS
    'Que papel juega una cuenta dentro de una senal: autor (la que actua o es sospechosa) o victima (la atacada, a la que se avisa y a la que NO se le suma puntaje de fraude). Es del par senal-cuenta, no de la senal: una misma senal puede tener las dos';


-- Los 25 tipos de hoy de las tres tablas viejas, con los mismos nombres.
-- Los nombres no chocan entre las tres (verificado contra la base local).
CREATE TABLE IF NOT EXISTS tipo_senal_fraude (
    id_tipo_senal_fraude      smallserial PRIMARY KEY,
    tipo_senal_fraude_nombre  varchar(40) NOT NULL UNIQUE,

    id_familia_senal_fraude   smallint NOT NULL
                              REFERENCES familia_senal_fraude(id_familia_senal_fraude),

    id_fuente_senal_fraude    smallint NOT NULL
                              REFERENCES fuente_senal_fraude(id_fuente_senal_fraude)
);

INSERT INTO tipo_senal_fraude (tipo_senal_fraude_nombre, id_familia_senal_fraude, id_fuente_senal_fraude)
SELECT v.tipo, fam.id_familia_senal_fraude, fu.id_fuente_senal_fraude
  FROM (VALUES
        ( 1, 'mutuo',                     'anillo_resenas',     'neo4j'),
        ( 2, 'ciclo',                     'anillo_resenas',     'neo4j'),
        ( 3, 'reiterado',                 'anillo_resenas',     'neo4j'),
        ( 4, 'cadena_abierta',            'patron_resenas',     'neo4j'),
        ( 5, 'satelites',                 'patron_resenas',     'neo4j'),
        ( 6, 'persistente',               'patron_resenas',     'neo4j'),
        ( 7, 'anillo_en_el_tiempo',       'patron_resenas',     'neo4j'),
        ( 8, 'favor_devuelto',            'patron_resenas',     'neo4j'),
        ( 9, 'coordinados',               'patron_resenas',     'neo4j'),
        (10, 'reputacion_expres',         'patron_resenas',     'neo4j'),
        (11, 'vistas_infladas',           'compras_navegacion', 'clickhouse'),
        (12, 'compras_en_rafaga',         'compras_navegacion', 'clickhouse'),
        (13, 'ip_multicuenta_compras',    'compras_navegacion', 'clickhouse'),
        (14, 'carrito_acaparador',        'compras_navegacion', 'clickhouse'),
        (15, 'devoluciones_seriales',     'compras_navegacion', 'clickhouse'),
        (16, 'granja_de_registros',       'compras_navegacion', 'clickhouse'),
        (17, 'fuerza_bruta_ip',           'login',              'login'),
        (18, 'fuerza_bruta_cuenta',       'login',              'login'),
        (19, 'fuerza_bruta_cuenta_lenta', 'login',              'login'),
        (20, 'multi_cuenta_ip',           'login',              'login'),
        (21, 'multi_cuenta_ip_lenta',     'login',              'login'),
        (22, 'ip_rotacion_cuenta',        'login',              'login'),
        (23, 'ip_rotacion_cuenta_lenta',  'login',              'login'),
        (24, 'toma_cuenta',               'login',              'login'),
        (25, 'viaje_imposible',           'login',              'login')
       ) AS v(orden, tipo, familia, fuente)
  JOIN familia_senal_fraude fam ON fam.familia_senal_fraude_nombre = v.familia
  JOIN fuente_senal_fraude  fu  ON fu.fuente_senal_fraude_nombre   = v.fuente
 WHERE NOT EXISTS (SELECT 1 FROM tipo_senal_fraude t
                    WHERE t.tipo_senal_fraude_nombre = v.tipo)
 ORDER BY v.orden
ON CONFLICT DO NOTHING;

COMMENT ON TABLE tipo_senal_fraude IS
    'Catalogo unico de tipos de senal. Reemplaza, en etapas, a tipo_anillo_fraude, tipo_hallazgo_evento y tipo_alerta_fraude. Por ahora solo nombre, familia y fuente; el peso base y la ventana de cada tipo se agregan en la etapa que mueva el puntaje (hoy viven en el codigo del agrupador)';


-- ------------------------------------------------------------
-- 2. senal_fraude: una fila por patron detectado
-- ------------------------------------------------------------
-- Una senal es UN patron sobre un conjunto de entidades, identificado por
-- (tipo, clave). Si el detector lo vuelve a encontrar es la MISMA fila:
-- sube total_detecciones y avanza ultima_deteccion. Cada re-deteccion con
-- su fecha va, en una etapa posterior, a deteccion_fraude (ClickHouse).
CREATE TABLE IF NOT EXISTS senal_fraude (
    id_senal_fraude          bigserial PRIMARY KEY,

    id_tipo_senal_fraude     smallint NOT NULL
                             REFERENCES tipo_senal_fraude(id_tipo_senal_fraude),

    -- Los ids del origen ordenados y unidos con "-" en los anillos ("9-10");
    -- la IP, la cuenta o "idUsuario-idProductoMongo" en las otras familias.
    clave                    varchar(255) NOT NULL,

    -- Reusa el catalogo de estados que ya usan las tres tablas viejas y
    -- caso_fraude (pendiente/revisada/descartada/confirmada).
    id_estado_alerta_fraude  smallint NOT NULL
                             REFERENCES estado_alerta_fraude(id_estado_alerta_fraude),

    -- Metricas y conteos que NO son una cuenta, una resena, un pedido ni un
    -- producto: esos tienen su propio pivote.
    detalle                  jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- Del DETECTOR. Nadie de la revision humana las toca; esa es la
    -- diferencia con fecha_actualizacion y lo que resuelve el C4.
    primera_deteccion        timestamptz NOT NULL DEFAULT now(),
    ultima_deteccion         timestamptz NOT NULL DEFAULT now(),
    total_detecciones        integer NOT NULL DEFAULT 1 CHECK (total_detecciones > 0),

    -- Quien la reviso, con el id REAL del admin (memoria
    -- atribucion-usa-el-id-real). NULL mientras nadie la haya revisado.
    id_usuario_reviso        bigint REFERENCES usuarios(id_usuario)
                             ON DELETE RESTRICT,
    fecha_revision           timestamptz,

    fecha_creacion           timestamptz NOT NULL DEFAULT now(),
    -- De la REVISION humana (ordena el listado del admin). Distinta de
    -- ultima_deteccion.
    fecha_actualizacion      timestamptz NOT NULL DEFAULT now(),

    UNIQUE (id_tipo_senal_fraude, clave)
);

COMMENT ON TABLE senal_fraude IS
    'Un patron de fraude detectado, sin importar de que motor viene. Identificado por (tipo, clave); re-detectarlo actualiza la misma fila. Las cuentas, resenas, pedidos y productos involucrados viven en sus pivotes senal_fraude_*';
COMMENT ON COLUMN senal_fraude.ultima_deteccion IS
    'La ultima vez que un DETECTOR vio esta senal. La revision del admin no la mueve: es la fecha que debe usar el puntaje para medir cuan reciente es la evidencia';
COMMENT ON COLUMN senal_fraude.fecha_actualizacion IS
    'La ultima vez que un ADMIN cambio algo. Ordena el listado del panel; NO sirve para medir recencia de la evidencia';
COMMENT ON COLUMN senal_fraude.total_detecciones IS
    'Cuantas veces se ha detectado. Nace en 1 (o en 1 al copiar desde las tablas viejas, que no guardan historia)';

-- El listado del admin: lo revisado mas reciente primero.
CREATE INDEX IF NOT EXISTS idx_senal_fraude_listado
    ON senal_fraude (fecha_actualizacion DESC);

-- Filtrar por estado (la cola de pendientes) sin barrer toda la tabla.
CREATE INDEX IF NOT EXISTS idx_senal_fraude_estado
    ON senal_fraude (id_estado_alerta_fraude);

-- Filtrar por tipo (y, via el catalogo, por familia o fuente).
CREATE INDEX IF NOT EXISTS idx_senal_fraude_tipo
    ON senal_fraude (id_tipo_senal_fraude);


-- ------------------------------------------------------------
-- 3. senal_fraude_cuenta: pivote de cuentas involucradas, con rol
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS senal_fraude_cuenta (
    id_senal_fraude      bigint NOT NULL
                         REFERENCES senal_fraude(id_senal_fraude)
                         ON DELETE CASCADE,

    id_usuario           bigint NOT NULL
                         REFERENCES usuarios(id_usuario)
                         ON DELETE RESTRICT,

    id_rol_cuenta_senal  smallint NOT NULL
                         REFERENCES rol_cuenta_senal(id_rol_cuenta_senal),

    -- Hoy siempre true: una senal por si sola no distingue nucleo de
    -- periferia (esa distincion la calcula el caso, en
    -- evidencia_caso_fraude_cuenta). Mismo criterio que
    -- hallazgo_evento_fraude_cuenta.
    es_nucleo            boolean NOT NULL DEFAULT true,

    PRIMARY KEY (id_senal_fraude, id_usuario)
);

COMMENT ON TABLE senal_fraude_cuenta IS
    'Pivote: que cuentas participan de una senal y con que rol (autor o victima). Una fila por cuenta. Reemplaza a hallazgo_evento_fraude_cuenta y a las cuentas que anillo_fraude solo derivaba con un JOIN a resena';

-- Ir de una cuenta a en que senales participa (el motivo real de
-- normalizar esto).
CREATE INDEX IF NOT EXISTS idx_senal_fraude_cuenta_usuario
    ON senal_fraude_cuenta (id_usuario);


-- ------------------------------------------------------------
-- 4. senal_fraude_resena: pivote a la evidencia en resenas
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS senal_fraude_resena (
    id_senal_fraude  bigint NOT NULL
                     REFERENCES senal_fraude(id_senal_fraude)
                     ON DELETE CASCADE,

    id_resena        bigint NOT NULL
                     REFERENCES resena(id_resena)
                     ON DELETE RESTRICT,

    PRIMARY KEY (id_senal_fraude, id_resena)
);

COMMENT ON TABLE senal_fraude_resena IS
    'Pivote: que resenas exactas son la evidencia de una senal. Reemplaza a anillo_fraude_resena';

-- Para ir de una resena a que senal(es) pertenece.
CREATE INDEX IF NOT EXISTS idx_senal_fraude_resena_resena
    ON senal_fraude_resena (id_resena);


-- ------------------------------------------------------------
-- 5. senal_fraude_producto: pivote a los productos involucrados
-- ------------------------------------------------------------
-- El producto vive en MongoDB, asi que no hay llave foranea (mismo criterio
-- que oferta.id_producto_mongo y hallazgo_evento_fraude.id_producto_mongo).
-- Es por PRODUCTO y no por variante: las resenas y las senales F1 a F6 son de
-- producto. Lo llenan las senales de la etapa 3 (vistas_infladas y
-- carrito_acaparador); las de anillos no tienen producto.
CREATE TABLE IF NOT EXISTS senal_fraude_producto (
    id_senal_fraude    bigint NOT NULL
                       REFERENCES senal_fraude(id_senal_fraude)
                       ON DELETE CASCADE,

    id_producto_mongo  bigint NOT NULL,

    PRIMARY KEY (id_senal_fraude, id_producto_mongo)
);

COMMENT ON TABLE senal_fraude_producto IS
    'Pivote: que productos (de MongoDB, sin llave foranea) involucra una senal. Es por producto y no por variante. Reemplaza a hallazgo_evento_fraude.id_producto_mongo';

-- Ir de un producto a en que senales aparece.
CREATE INDEX IF NOT EXISTS idx_senal_fraude_producto_producto
    ON senal_fraude_producto (id_producto_mongo);


-- ------------------------------------------------------------
-- 5a. senal_fraude_pedido: pivote a los pedidos involucrados
-- ------------------------------------------------------------
-- Los pedidos SI viven en PostgreSQL, asi que lleva llave foranea real (a
-- diferencia del producto, que vive en Mongo). La llenan F2 (los pedidos de la
-- peor rafaga), F3 (los de las cuentas en esa IP) y F5 (los pedidos devueltos).
-- No hay copia inicial: las tablas viejas nunca guardaron ids de pedido, solo
-- el conteo dentro de `detalle`.
CREATE TABLE IF NOT EXISTS senal_fraude_pedido (
    id_senal_fraude  bigint NOT NULL
                     REFERENCES senal_fraude(id_senal_fraude)
                     ON DELETE CASCADE,

    id_pedido        bigint NOT NULL
                     REFERENCES pedido(id_pedido)
                     ON DELETE RESTRICT,

    PRIMARY KEY (id_senal_fraude, id_pedido)
);

COMMENT ON TABLE senal_fraude_pedido IS
    'Pivote: que pedidos involucra una senal (F2: los de la peor rafaga, F3: los de las cuentas en esa IP, F5: los devueltos). Con tope por senal; los ids que ya no existan en pedido se descartan al enlazar';

-- Ir de un pedido a en que senales aparece.
CREATE INDEX IF NOT EXISTS idx_senal_fraude_pedido_pedido
    ON senal_fraude_pedido (id_pedido);


-- ------------------------------------------------------------
-- 5b. direccion_ip y senal_fraude_ip: las IP involucradas en una senal
-- ------------------------------------------------------------
-- Una tabla de IP y un pivote, por normalizacion: los datos propios de una IP
-- (mas adelante: si es de confianza, si esta bloqueada por un tiempo) viven en
-- UNA fila y no repetidos en cada senal. Hoy solo la IP y cuando se vio
-- primero; las columnas de confianza o bloqueo se agregan el dia que se
-- decida usarlas.
--
-- Las llena el login (las senales cuya clave es una IP, o que traen IP en el
-- detalle). En las senales de F3 y F6 la IP hoy es la `clave`; no se llena
-- todavia para esas.
CREATE TABLE IF NOT EXISTS direccion_ip (
    id_direccion_ip  bigserial PRIMARY KEY,
    ip               inet NOT NULL UNIQUE,
    fecha_creacion   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE direccion_ip IS
    'Una fila por direccion IP vista en el fraude. Las senales la enlazan por senal_fraude_ip. Por ahora solo la IP; confianza o bloqueo temporal se agregan cuando se decida usarlos';

CREATE TABLE IF NOT EXISTS senal_fraude_ip (
    id_senal_fraude  bigint NOT NULL
                     REFERENCES senal_fraude(id_senal_fraude)
                     ON DELETE CASCADE,

    id_direccion_ip  bigint NOT NULL
                     REFERENCES direccion_ip(id_direccion_ip)
                     ON DELETE RESTRICT,

    PRIMARY KEY (id_senal_fraude, id_direccion_ip)
);

COMMENT ON TABLE senal_fraude_ip IS
    'Pivote: que direcciones IP involucra una senal. Permite ir de una IP a todas las senales donde aparece';

-- Ir de una IP a en que senales aparece.
CREATE INDEX IF NOT EXISTS idx_senal_fraude_ip_direccion
    ON senal_fraude_ip (id_direccion_ip);


-- ------------------------------------------------------------
-- 6. Copia de lo que ya hay en anillo_fraude
-- ------------------------------------------------------------
-- anillo_fraude no se toca. Se copia a las tablas nuevas para poder
-- compararlas fila a fila. Lo que la copia NO puede traer, porque las
-- tablas viejas no lo guardan: la historia de detecciones (por eso
-- total_detecciones nace en 1) y quien reviso.
--
-- Es re-ejecutable: si se corre otra vez despues de que el detector siga
-- escribiendo en anillo_fraude, refresca las fechas y el estado, y no
-- duplica nada. Mientras el backend no escriba en senal_fraude (etapa 2),
-- esta copia es la unica que la llena.
INSERT INTO senal_fraude
       (id_tipo_senal_fraude, clave, id_estado_alerta_fraude, detalle,
        primera_deteccion, ultima_deteccion, fecha_creacion, fecha_actualizacion)
SELECT ts.id_tipo_senal_fraude, a.clave, a.id_estado_alerta_fraude, a.detalle,
       a.fecha_creacion, a.ultima_vez_confirmado_activo, a.fecha_creacion,
       a.fecha_actualizacion
  FROM anillo_fraude a
  JOIN tipo_anillo_fraude ta ON ta.id_tipo_anillo_fraude = a.id_tipo_anillo_fraude
  JOIN tipo_senal_fraude  ts ON ts.tipo_senal_fraude_nombre = ta.tipo_anillo_fraude_nombre
ON CONFLICT (id_tipo_senal_fraude, clave) DO UPDATE
   SET id_estado_alerta_fraude = EXCLUDED.id_estado_alerta_fraude,
       detalle                 = EXCLUDED.detalle,
       ultima_deteccion        = EXCLUDED.ultima_deteccion,
       fecha_actualizacion     = EXCLUDED.fecha_actualizacion;

-- Las resenas de evidencia de cada anillo.
INSERT INTO senal_fraude_resena (id_senal_fraude, id_resena)
SELECT s.id_senal_fraude, ar.id_resena
  FROM anillo_fraude_resena ar
  JOIN anillo_fraude a        ON a.id_anillo_fraude = ar.id_anillo_fraude
  JOIN tipo_anillo_fraude ta  ON ta.id_tipo_anillo_fraude = a.id_tipo_anillo_fraude
  JOIN tipo_senal_fraude ts   ON ts.tipo_senal_fraude_nombre = ta.tipo_anillo_fraude_nombre
  JOIN senal_fraude s         ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude
                             AND s.clave = a.clave
ON CONFLICT DO NOTHING;

-- Las cuentas de cada anillo: las de su clave (los ids de cuenta ordenados y
-- unidos con "-"), que es EXACTAMENTE el conjunto que detecto el detector. No
-- se derivan de las resenas: ese join metia al vendedor tambien en
-- `coordinados` (B.6), donde es un tercero ajeno al patron. Todas con rol
-- autor -- en un anillo de resenas la cuenta senalada es la SOSPECHOSA, nunca
-- la victima.
INSERT INTO senal_fraude_cuenta (id_senal_fraude, id_usuario, id_rol_cuenta_senal)
SELECT DISTINCT s.id_senal_fraude, u.id_usuario, rol.id_rol_cuenta_senal
  FROM senal_fraude s
  JOIN tipo_senal_fraude t ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
  JOIN familia_senal_fraude f ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
 CROSS JOIN LATERAL unnest(string_to_array(s.clave, '-')) AS c(id_texto)
  JOIN usuarios u ON u.id_usuario = CASE WHEN c.id_texto ~ '^\d+$'
                                         THEN c.id_texto::bigint END
  JOIN rol_cuenta_senal rol ON rol.rol_cuenta_senal_nombre = 'autor'
 WHERE f.familia_senal_fraude_nombre IN ('anillo_resenas', 'patron_resenas')
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- 7. Copia de lo que ya hay en hallazgo_evento_fraude (etapa 3)
-- ------------------------------------------------------------
-- hallazgo_evento_fraude tiene UNA FILA POR DIA (la llave es tipo + clave +
-- ventana_inicio, y el detector corre cada 24 horas mirando los ultimos 30
-- dias), asi que el mismo patron ocupa una fila por cada dia que siguio
-- visible, con casi la misma evidencia. La senal es UNA por (tipo, clave):
-- aqui se juntan esas filas.
--   - estado, detalle y quien reviso: los de la fila MAS RECIENTE. Si el
--     patron volvio a salir despues de que un admin lo descarto, la fila
--     reciente es una pendiente nueva, y asi queda la senal (reabierta).
--   - primera_deteccion / ultima_deteccion: la primera y la ultima
--     ventana_inicio. No se usa fecha_actualizacion para la ultima, porque
--     el PATCH del admin tambien la mueve (el C4).
--   - total_detecciones: la suma de los contador de todas las filas, que es
--     cuantas veces el detector lo vio.
-- Las cuentas y los productos son la union de los de todas las filas.
-- Mismo criterio de re-ejecucion que la copia de anillos; el contador solo
-- sube (GREATEST), para no pisar detecciones que la doble escritura ya sumo.

-- Una IP mal escrita no debe tumbar la copia entera: esta funcion temporal
-- (vive solo en la sesion) la convierte a NULL y se descarta. La usan esta
-- seccion y la 8.
-- Tambien normaliza las IPv4 "mapeadas" a IPv6 (::ffff:1.2.3.4, como las
-- guarda ClickHouse) a IPv4 (1.2.3.4, como las guarda el login), para que
-- direccion_ip tenga UNA fila por maquina.
CREATE OR REPLACE FUNCTION pg_temp.ip_segura(texto text) RETURNS inet
LANGUAGE plpgsql IMMUTABLE AS $f$
BEGIN
    RETURN regexp_replace(texto, '^::ffff:(\d{1,3}(\.\d{1,3}){3})$', '\1', 'i')::inet;
EXCEPTION WHEN others THEN
    RETURN NULL;
END
$f$;

WITH agrupados AS (
    SELECT DISTINCT ON (h.id_tipo_hallazgo_evento, h.clave)
           ts.id_tipo_senal_fraude,
           h.clave,
           h.id_estado_alerta_fraude,
           h.detalle,
           h.id_usuario_reviso,
           h.fecha_revision,
           min(h.ventana_inicio)       OVER w AS primera_deteccion,
           max(h.ventana_inicio)       OVER w AS ultima_deteccion,
           sum(h.contador)             OVER w AS total_detecciones,
           min(h.fecha_creacion)       OVER w AS fecha_creacion,
           max(h.fecha_actualizacion)  OVER w AS fecha_actualizacion
      FROM hallazgo_evento_fraude h
      JOIN tipo_hallazgo_evento th
        ON th.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
      JOIN tipo_senal_fraude ts
        ON ts.tipo_senal_fraude_nombre = th.tipo_hallazgo_evento_nombre
    WINDOW w AS (PARTITION BY h.id_tipo_hallazgo_evento, h.clave)
     ORDER BY h.id_tipo_hallazgo_evento, h.clave, h.ventana_inicio DESC
)
INSERT INTO senal_fraude
       (id_tipo_senal_fraude, clave, id_estado_alerta_fraude, detalle,
        primera_deteccion, ultima_deteccion, total_detecciones,
        id_usuario_reviso, fecha_revision, fecha_creacion, fecha_actualizacion)
SELECT id_tipo_senal_fraude, clave, id_estado_alerta_fraude, detalle,
       primera_deteccion, ultima_deteccion, total_detecciones,
       id_usuario_reviso, fecha_revision, fecha_creacion, fecha_actualizacion
  FROM agrupados
ON CONFLICT (id_tipo_senal_fraude, clave) DO UPDATE
   SET id_estado_alerta_fraude = EXCLUDED.id_estado_alerta_fraude,
       detalle                 = EXCLUDED.detalle,
       id_usuario_reviso       = EXCLUDED.id_usuario_reviso,
       fecha_revision          = EXCLUDED.fecha_revision,
       ultima_deteccion        = EXCLUDED.ultima_deteccion,
       total_detecciones       = GREATEST(senal_fraude.total_detecciones,
                                          EXCLUDED.total_detecciones),
       fecha_actualizacion     = EXCLUDED.fecha_actualizacion;

-- Las cuentas de todas las filas del mismo (tipo, clave). Todas 'autor': en
-- F1-F6 la cuenta senalada es la sospechosa, nunca la victima.
INSERT INTO senal_fraude_cuenta (id_senal_fraude, id_usuario, id_rol_cuenta_senal, es_nucleo)
SELECT DISTINCT s.id_senal_fraude, hc.id_usuario, rol.id_rol_cuenta_senal, hc.es_nucleo
  FROM hallazgo_evento_fraude_cuenta hc
  JOIN hallazgo_evento_fraude h
    ON h.id_hallazgo_evento_fraude = hc.id_hallazgo_evento_fraude
  JOIN tipo_hallazgo_evento th
    ON th.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
  JOIN tipo_senal_fraude ts
    ON ts.tipo_senal_fraude_nombre = th.tipo_hallazgo_evento_nombre
  JOIN senal_fraude s
    ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude AND s.clave = h.clave
  JOIN rol_cuenta_senal rol ON rol.rol_cuenta_senal_nombre = 'autor'
ON CONFLICT DO NOTHING;

-- Los productos (Mongo) de todas las filas del mismo (tipo, clave).
INSERT INTO senal_fraude_producto (id_senal_fraude, id_producto_mongo)
SELECT DISTINCT s.id_senal_fraude, h.id_producto_mongo
  FROM hallazgo_evento_fraude h
  JOIN tipo_hallazgo_evento th
    ON th.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
  JOIN tipo_senal_fraude ts
    ON ts.tipo_senal_fraude_nombre = th.tipo_hallazgo_evento_nombre
  JOIN senal_fraude s
    ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude AND s.clave = h.clave
 WHERE h.id_producto_mongo IS NOT NULL
ON CONFLICT DO NOTHING;

-- Las IP de F3 (ip_multicuenta_compras) y F6 (granja_de_registros): en los dos
-- la clave ES la IP.
INSERT INTO direccion_ip (ip)
SELECT DISTINCT pg_temp.ip_segura(h.clave)
  FROM hallazgo_evento_fraude h
  JOIN tipo_hallazgo_evento th
    ON th.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
 WHERE th.tipo_hallazgo_evento_nombre IN ('ip_multicuenta_compras', 'granja_de_registros')
   AND pg_temp.ip_segura(h.clave) IS NOT NULL
ON CONFLICT (ip) DO NOTHING;

INSERT INTO senal_fraude_ip (id_senal_fraude, id_direccion_ip)
SELECT DISTINCT s.id_senal_fraude, d.id_direccion_ip
  FROM hallazgo_evento_fraude h
  JOIN tipo_hallazgo_evento th
    ON th.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
  JOIN tipo_senal_fraude ts
    ON ts.tipo_senal_fraude_nombre = th.tipo_hallazgo_evento_nombre
  JOIN senal_fraude s
    ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude AND s.clave = h.clave
  JOIN direccion_ip d ON d.ip = pg_temp.ip_segura(h.clave)
 WHERE th.tipo_hallazgo_evento_nombre IN ('ip_multicuenta_compras', 'granja_de_registros')
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- 8. Copia de lo que ya hay en alerta_fraude (etapa 4, login)
-- ------------------------------------------------------------
-- alerta_fraude tiene una fila por VENTANA (minuto en las de Redis y las
-- puntuales, hora en las retrospectivas de Elasticsearch). Igual que en la
-- seccion 7, la senal es UNA por (tipo, clave): se juntan las filas.
--   - estado, detalle y quien reviso: los de la fila mas reciente.
--   - primera/ultima deteccion: la primera y la ultima ventana_inicio.
--   - total_detecciones: la suma de los contador.
-- Las cuentas son VICTIMAS (las que se avisan en notificacion_fraude, mas el
-- id_usuario de la alerta cuando lo hay). Las IP: la clave en los tipos que
-- nacen de una IP, detalle.ips en ip_rotacion_cuenta (y _lenta) y
-- detalle.ip_nueva en toma_cuenta. fuerza_bruta_cuenta y viaje_imposible no
-- traen IP.
WITH agrupadas AS (
    SELECT DISTINCT ON (a.id_tipo_alerta_fraude, a.clave)
           ts.id_tipo_senal_fraude,
           a.clave,
           a.id_estado_alerta_fraude,
           a.detalle,
           a.id_usuario_reviso,
           a.fecha_revision,
           min(a.ventana_inicio)       OVER w AS primera_deteccion,
           max(a.ventana_inicio)       OVER w AS ultima_deteccion,
           sum(a.contador)             OVER w AS total_detecciones,
           min(a.fecha_creacion)       OVER w AS fecha_creacion,
           max(a.fecha_actualizacion)  OVER w AS fecha_actualizacion
      FROM alerta_fraude a
      JOIN tipo_alerta_fraude ta
        ON ta.id_tipo_alerta_fraude = a.id_tipo_alerta_fraude
      JOIN tipo_senal_fraude ts
        ON ts.tipo_senal_fraude_nombre = ta.tipo_alerta_fraude_nombre
    WINDOW w AS (PARTITION BY a.id_tipo_alerta_fraude, a.clave)
     ORDER BY a.id_tipo_alerta_fraude, a.clave, a.ventana_inicio DESC
)
INSERT INTO senal_fraude
       (id_tipo_senal_fraude, clave, id_estado_alerta_fraude, detalle,
        primera_deteccion, ultima_deteccion, total_detecciones,
        id_usuario_reviso, fecha_revision, fecha_creacion, fecha_actualizacion)
SELECT id_tipo_senal_fraude, clave, id_estado_alerta_fraude, detalle,
       primera_deteccion, ultima_deteccion, total_detecciones,
       id_usuario_reviso, fecha_revision, fecha_creacion, fecha_actualizacion
  FROM agrupadas
ON CONFLICT (id_tipo_senal_fraude, clave) DO UPDATE
   SET id_estado_alerta_fraude = EXCLUDED.id_estado_alerta_fraude,
       detalle                 = EXCLUDED.detalle,
       id_usuario_reviso       = EXCLUDED.id_usuario_reviso,
       fecha_revision          = EXCLUDED.fecha_revision,
       ultima_deteccion        = EXCLUDED.ultima_deteccion,
       total_detecciones       = GREATEST(senal_fraude.total_detecciones,
                                          EXCLUDED.total_detecciones),
       fecha_actualizacion     = EXCLUDED.fecha_actualizacion;

-- Las cuentas, todas 'victima'.
INSERT INTO senal_fraude_cuenta (id_senal_fraude, id_usuario, id_rol_cuenta_senal)
SELECT DISTINCT s.id_senal_fraude, u.id_usuario, rol.id_rol_cuenta_senal
  FROM (SELECT n.id_alerta_fraude, n.id_usuario FROM notificacion_fraude n
        UNION
        SELECT a2.id_alerta_fraude, a2.id_usuario FROM alerta_fraude a2
         WHERE a2.id_usuario IS NOT NULL) AS u
  JOIN alerta_fraude a ON a.id_alerta_fraude = u.id_alerta_fraude
  JOIN tipo_alerta_fraude ta ON ta.id_tipo_alerta_fraude = a.id_tipo_alerta_fraude
  JOIN tipo_senal_fraude ts ON ts.tipo_senal_fraude_nombre = ta.tipo_alerta_fraude_nombre
  JOIN senal_fraude s ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude AND s.clave = a.clave
  JOIN rol_cuenta_senal rol ON rol.rol_cuenta_senal_nombre = 'victima'
ON CONFLICT DO NOTHING;

-- Las IP (la funcion temporal pg_temp.ip_segura se define en la seccion 7).
CREATE TEMP TABLE ips_de_alertas ON COMMIT DROP AS
SELECT DISTINCT a.id_alerta_fraude, pg_temp.ip_segura(x.ip_texto) AS ip
  FROM alerta_fraude a
  JOIN tipo_alerta_fraude ta ON ta.id_tipo_alerta_fraude = a.id_tipo_alerta_fraude
 CROSS JOIN LATERAL (
        SELECT a.clave AS ip_texto
         WHERE ta.tipo_alerta_fraude_nombre IN ('fuerza_bruta_ip', 'multi_cuenta_ip', 'multi_cuenta_ip_lenta')
        UNION ALL
        SELECT jsonb_array_elements_text(a.detalle -> 'ips')
         WHERE ta.tipo_alerta_fraude_nombre IN ('ip_rotacion_cuenta', 'ip_rotacion_cuenta_lenta')
           AND jsonb_typeof(a.detalle -> 'ips') = 'array'
        UNION ALL
        SELECT a.detalle ->> 'ip_nueva'
         WHERE ta.tipo_alerta_fraude_nombre = 'toma_cuenta'
    ) AS x
 WHERE pg_temp.ip_segura(x.ip_texto) IS NOT NULL;

INSERT INTO direccion_ip (ip)
SELECT DISTINCT ip FROM ips_de_alertas
ON CONFLICT (ip) DO NOTHING;

INSERT INTO senal_fraude_ip (id_senal_fraude, id_direccion_ip)
SELECT DISTINCT s.id_senal_fraude, d.id_direccion_ip
  FROM ips_de_alertas i
  JOIN alerta_fraude a ON a.id_alerta_fraude = i.id_alerta_fraude
  JOIN tipo_alerta_fraude ta ON ta.id_tipo_alerta_fraude = a.id_tipo_alerta_fraude
  JOIN tipo_senal_fraude ts ON ts.tipo_senal_fraude_nombre = ta.tipo_alerta_fraude_nombre
  JOIN senal_fraude s ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude AND s.clave = a.clave
  JOIN direccion_ip d ON d.ip = i.ip
ON CONFLICT DO NOTHING;

COMMIT;
