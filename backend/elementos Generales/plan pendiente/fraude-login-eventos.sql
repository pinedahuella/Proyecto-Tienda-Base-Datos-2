-- ============================================================
-- fraude-login-eventos.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada en el orden correcto (despues de
-- 015_outbox_grafo.sql) y en migrations/README.md.
--
-- Este archivo existe para dos cosas:
--   1. Dejar por escrito, en la forma exacta, que cambio de esquema pide el
--      punto 4 de `fraude-login-eventos.md` (mismo folder): la tabla donde
--      caen las alertas que detecta DeteccionFraudeLoginService.
--   2. Poder aplicarlo al contenedor local `mesh-postgres` mientras se
--      desarrolla el backend en paralelo, sin esperar la migracion.
--
-- Aplicado en local el 2026-09-10 con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS / ON CONFLICT) y reversible: un
-- `.\arrancar.ps1 -Reiniciar` reconstruye la base desde las migraciones
-- reales y borra todo esto.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. tipo_alerta_fraude: catalogo de senales que detecta el backend
-- ------------------------------------------------------------
-- Catalogo chico y controlado por el codigo (no lo edita nadie desde una
-- pantalla), pero igual va en tabla -- no un CHECK de texto -- porque asi
-- lo hace el resto del proyecto con cualquier "estado"/"tipo" enumerado
-- (estado_oferta, estado_producto, motivo_movimiento). El orden del
-- INSERT fija los ids: 1 fuerza_bruta_ip, 2 fuerza_bruta_cuenta,
-- 3 multi_cuenta_ip. `src/models/alerta-fraude.ts` los fija como
-- constantes, igual que ID_ROL_COMPRADOR/ID_ROL_VENDEDOR/ID_ROL_ADMIN.
--
-- Solo estos tres: son las senales que se pueden calcular con contadores
-- Redis en el propio camino del login (punto 4 del plan). Viaje imposible
-- e IP/ASN nueva tras fallos (punto 3 del plan, retrospectivo sobre
-- Elasticsearch) dependen de geolocalizacion, todavia sin decidir (punto
-- 2) -- se agregan filas nuevas a este catalogo cuando eso se resuelva,
-- sin tocar las que ya existen.
CREATE TABLE IF NOT EXISTS tipo_alerta_fraude (
    id_tipo_alerta_fraude      smallserial PRIMARY KEY,
    tipo_alerta_fraude_nombre  varchar(30) NOT NULL UNIQUE
);

INSERT INTO tipo_alerta_fraude (tipo_alerta_fraude_nombre) VALUES
    ('fuerza_bruta_ip'),
    ('fuerza_bruta_cuenta'),
    ('multi_cuenta_ip')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE tipo_alerta_fraude IS
    'Catalogo de senales de fraude de login que detecta el backend: fuerza_bruta_ip, fuerza_bruta_cuenta, multi_cuenta_ip';


-- ------------------------------------------------------------
-- 2. estado_alerta_fraude: catalogo del triage del admin
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS estado_alerta_fraude (
    id_estado_alerta_fraude      smallserial PRIMARY KEY,
    estado_alerta_fraude_nombre  varchar(30) NOT NULL UNIQUE
);

INSERT INTO estado_alerta_fraude (estado_alerta_fraude_nombre) VALUES
    ('pendiente'),
    ('revisada'),
    ('descartada')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE estado_alerta_fraude IS
    'Catalogo de estados de revision de una alerta_fraude: pendiente, revisada, descartada';


-- ------------------------------------------------------------
-- 3. alerta_fraude: lo que dispara cada senal
-- ------------------------------------------------------------
-- La escribe DeteccionFraudeLoginService cuando un contador de Redis cruza
-- su umbral -- ver `fraude-login-eventos.md` punto 4. NO es un log de cada
-- fallo (eso ya vive en `eventos_autenticacion` de Mongo): una fila aqui
-- es "esto merece que un admin lo mire", no "esto paso".
--
-- `clave` es la IP o el identificador segun el tipo -- lo que identifica
-- AL ORIGEN de la senal, no a la victima. `ventana_inicio` es el reloj
-- truncado al minuto en el momento de la deteccion: junto con
-- (tipo, clave) es la llave natural que evita una fila nueva por cada
-- fallo sucesivo dentro del mismo minuto mientras el ataque sigue -- el
-- UPSERT de mas abajo suma `contador` en vez de duplicar. Si el ataque
-- sigue en el minuto siguiente, nace una fila nueva (a proposito: son
-- momentos de deteccion distintos, y una alerta ya revisada no debe
-- reabrirse silenciosamente).
CREATE TABLE IF NOT EXISTS alerta_fraude (
    id_alerta_fraude        bigserial PRIMARY KEY,

    id_tipo_alerta_fraude   smallint NOT NULL
                            REFERENCES tipo_alerta_fraude(id_tipo_alerta_fraude),

    clave                   varchar(255) NOT NULL,

    -- Solo se conoce en fuerza_bruta_cuenta cuando el identificador
    -- corresponde a una cuenta real (credenciales_invalidas / cuenta_inactiva).
    -- NULL en fuerza_bruta_ip y multi_cuenta_ip (el origen es la IP, no una
    -- cuenta), y en fuerza_bruta_cuenta contra un identificador que no existe.
    id_usuario              bigint REFERENCES usuarios(id_usuario)
                            ON DELETE RESTRICT,

    -- Evidencia de la deteccion: conteos, ventana en segundos, y (solo en
    -- multi_cuenta_ip) los identificadores vistos. Estructura por tipo, no
    -- normalizada -- es evidencia para un humano, no algo que se consulte
    -- por campo.
    detalle                 jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- Cuantas veces se volvio a cruzar el umbral dentro de esta misma
    -- ventana (ver comentario de ventana_inicio arriba). Sube con el UPDATE
    -- del UPSERT; nace en 1.
    contador                integer NOT NULL DEFAULT 1 CHECK (contador > 0),

    ventana_inicio          timestamptz NOT NULL,

    id_estado_alerta_fraude smallint NOT NULL
                            REFERENCES estado_alerta_fraude(id_estado_alerta_fraude),

    -- Quien la reviso, con el id REAL del admin (memoria
    -- atribucion-usa-el-id-real) -- no aplica aqui sustitucion de tienda
    -- porque esto no lo toca nunca un vendedor.
    id_usuario_reviso       bigint REFERENCES usuarios(id_usuario)
                            ON DELETE RESTRICT,
    fecha_revision          timestamptz,

    fecha_creacion          timestamptz NOT NULL DEFAULT now(),
    fecha_actualizacion     timestamptz NOT NULL DEFAULT now(),

    UNIQUE (id_tipo_alerta_fraude, clave, ventana_inicio)
);

COMMENT ON TABLE alerta_fraude IS
    'Alertas de fraude de login para revision de un admin. Las escribe DeteccionFraudeLoginService cuando un contador de Redis cruza su umbral; no es un log de cada intento (eso vive en eventos_autenticacion de Mongo)';
COMMENT ON COLUMN alerta_fraude.clave IS
    'El origen de la senal: la IP (fuerza_bruta_ip, multi_cuenta_ip) o el identificador intentado (fuerza_bruta_cuenta)';
COMMENT ON COLUMN alerta_fraude.ventana_inicio IS
    'El minuto (truncado) en que se detecto. Junto con (tipo, clave) evita una fila nueva por cada fallo sucesivo en el mismo minuto: el UPSERT suma contador en vez de duplicar';
COMMENT ON COLUMN alerta_fraude.contador IS
    'Cuantas veces se volvio a cruzar el umbral dentro de la misma ventana (ver ventana_inicio). Nace en 1';

-- El listado del admin: mas reciente primero, con o sin filtro por estado.
CREATE INDEX IF NOT EXISTS idx_alerta_fraude_listado
    ON alerta_fraude (fecha_actualizacion DESC);

COMMIT;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT id_tipo_alerta_fraude, tipo_alerta_fraude_nombre
FROM tipo_alerta_fraude ORDER BY id_tipo_alerta_fraude;

SELECT id_estado_alerta_fraude, estado_alerta_fraude_nombre
FROM estado_alerta_fraude ORDER BY id_estado_alerta_fraude;

SELECT to_regclass('public.alerta_fraude') AS tabla_alerta_fraude;
