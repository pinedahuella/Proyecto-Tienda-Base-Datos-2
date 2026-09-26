-- ============================================================
-- 025_hallazgos_evento_fraude.sql
-- ============================================================
-- Donde se guardan los hallazgos F1 a F6, las seis consultas de fraude sobre
-- los eventos de ClickHouse (`clickhouse/consultas/F1..F6.sql`). Los detecta
-- una vez al dia HallazgosEventoFraudeDetectorService y el admin los revisa
-- por GET y PATCH /admin/fraude/alertas-eventos.
--
--
-- DE DONDE SALE
-- ============================================================
-- Del SQL de referencia del companero, en
-- `backend/elementos Generales/plan pendiente/hallazgos-evento-fraude.sql`,
-- copiado tal cual salvo dos cosas que el mismo pide quitar o que solo le
-- servian a el. El `ALTER TABLE ... DROP COLUMN id_usuario`, que migraba una
-- version anterior de su propia base, y los SELECT de comprobacion del final.
-- En su lugar va el candado de ids, igual que en la 019 y la 023. El diseno
-- completo esta en `hallazgos-evento-fraude.md`, en la misma carpeta.
--
--
-- LAS TRES TABLAS
-- ============================================================
--   tipo_hallazgo_evento           catalogo, ids 1 a 6 = F1 a F6. El backend
--                                  los fija como constantes en
--                                  `src/models/hallazgo-evento-fraude.ts`
--   hallazgo_evento_fraude         un hallazgo, con clave, ventana y contador
--                                  como `alerta_fraude`
--   hallazgo_evento_fraude_cuenta  las cuentas de cada hallazgo, una fila por
--                                  cuenta
--
-- Es idempotente, con IF NOT EXISTS y ON CONFLICT, porque `arrancar.ps1` la
-- vuelve a correr en cada arranque y la base del companero ya la tiene.
--
-- Iba a ser la 024. La 024 se la quedaron la noche anterior los vectores de
-- la recomendacion semantica, y la propuesta de casos de fraude pasa a la 026.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. tipo_hallazgo_evento: catalogo de los seis hallazgos (F1-F6)
-- ------------------------------------------------------------
-- Catalogo aparte de tipo_alerta_fraude (login) y tipo_anillo_fraude
-- (grafo/resenas) -- misma razon que esos dos: fuentes de deteccion
-- distintas, con su propio ciclo de vida.
CREATE TABLE IF NOT EXISTS tipo_hallazgo_evento (
    id_tipo_hallazgo_evento      smallserial PRIMARY KEY,
    tipo_hallazgo_evento_nombre  varchar(30) NOT NULL UNIQUE
);

-- El orden del INSERT fija los ids: 1 vistas_infladas (F1) .. 6
-- granja_de_registros (F6). src/models/hallazgo-evento-fraude.ts los fija
-- como constantes, igual que ID_TIPO_ANILLO_FRAUDE_* / ID_TIPO_ALERTA_FRAUDE_*.
INSERT INTO tipo_hallazgo_evento (tipo_hallazgo_evento_nombre) VALUES
    ('vistas_infladas'),
    ('compras_en_rafaga'),
    ('ip_multicuenta_compras'),
    ('carrito_acaparador'),
    ('devoluciones_seriales'),
    ('granja_de_registros')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE tipo_hallazgo_evento IS
    'Catalogo de los seis hallazgos de fraude sobre eventos de ClickHouse (F1-F6, docs/fraude-entrega3/03-consultas-clickhouse.md): vistas_infladas, compras_en_rafaga, ip_multicuenta_compras, carrito_acaparador, devoluciones_seriales, granja_de_registros';


-- ------------------------------------------------------------
-- 2. hallazgo_evento_fraude: una fila por hallazgo detectado
-- ------------------------------------------------------------
-- Mismo molde que alerta_fraude (fraude de login) para clave +
-- ventana_inicio + contador (no duplicar el mismo hallazgo dentro de la
-- misma ventana). A diferencia de la primera version de esta tabla, las
-- cuentas involucradas ya NO van en el jsonb `detalle` -- normalizado a
-- `hallazgo_evento_fraude_cuenta` (mas abajo), mismo patron que propone
-- `docs/fraude-entrega3/02-reglas-backend.md` para su `hallazgo_fraude_cuenta`.
-- `detalle` se queda solo con la evidencia que NO es una cuenta (conteos,
-- ventana, tasa).
CREATE TABLE IF NOT EXISTS hallazgo_evento_fraude (
    id_hallazgo_evento_fraude  bigserial PRIMARY KEY,

    id_tipo_hallazgo_evento    smallint NOT NULL
                               REFERENCES tipo_hallazgo_evento(id_tipo_hallazgo_evento),

    -- El origen de la senal: id de cuenta, id de producto (Mongo), la IP,
    -- o "idUsuario-idProductoMongo" en carrito_acaparador -- ver la tabla
    -- de hallazgos-evento-fraude.md para el detalle exacto de cada tipo.
    clave                      varchar(255) NOT NULL,

    -- El producto (Mongo) del hallazgo, cuando aplica (vistas_infladas,
    -- carrito_acaparador). Sin FK -- el producto vive en Mongo, no en
    -- Postgres, mismo criterio que oferta.id_producto_mongo. No se
    -- normaliza a una tabla de pivote aparte: ningun hallazgo de F1-F6
    -- involucra mas de un producto a la vez, a diferencia de las cuentas.
    id_producto_mongo          bigint,

    -- Evidencia que NO es una cuenta: conteos, ventana, tasa. Las cuentas
    -- involucradas van en hallazgo_evento_fraude_cuenta, no aqui.
    detalle                    jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- Cuantas veces el detector volvio a cruzar el umbral dentro de esta
    -- misma ventana. Sube con el UPSERT de registrarHallazgoEventoFraude();
    -- nace en 1.
    contador                   integer NOT NULL DEFAULT 1 CHECK (contador > 0),

    -- El inicio de la ventana de deteccion vigente -- la granularidad
    -- (minuto, hora, dia) la decide cada detector segun su propia consulta,
    -- esta tabla no la impone.
    ventana_inicio             timestamptz NOT NULL,

    -- Reusa el catalogo de fraude de login (pendiente/revisada/descartada):
    -- es generico, sin logica propia de ningun dominio -- mismo criterio
    -- que ya aplico anillo_fraude.
    id_estado_alerta_fraude    smallint NOT NULL
                               REFERENCES estado_alerta_fraude(id_estado_alerta_fraude),

    -- Quien la reviso, con el id REAL del admin (memoria
    -- atribucion-usa-el-id-real).
    id_usuario_reviso          bigint REFERENCES usuarios(id_usuario)
                               ON DELETE RESTRICT,
    fecha_revision             timestamptz,

    fecha_creacion             timestamptz NOT NULL DEFAULT now(),
    fecha_actualizacion        timestamptz NOT NULL DEFAULT now(),

    UNIQUE (id_tipo_hallazgo_evento, clave, ventana_inicio)
);

COMMENT ON TABLE hallazgo_evento_fraude IS
    'Hallazgos de fraude sobre eventos de ClickHouse (F1-F6) para revision de un admin. Mismo molde que alerta_fraude (fraude de login): clave+ventana_inicio+contador evitan duplicar el mismo hallazgo. Las cuentas involucradas viven en hallazgo_evento_fraude_cuenta, no aqui';
COMMENT ON COLUMN hallazgo_evento_fraude.clave IS
    'El origen de la senal segun el tipo: id de cuenta, id de producto (Mongo), la IP, o "idUsuario-idProductoMongo" en carrito_acaparador';
COMMENT ON COLUMN hallazgo_evento_fraude.contador IS
    'Cuantas veces se volvio a cruzar el umbral dentro de la misma ventana (ver ventana_inicio). Nace en 1';

-- El listado del admin: mas reciente primero, con o sin filtro por estado.
CREATE INDEX IF NOT EXISTS idx_hallazgo_evento_fraude_listado
    ON hallazgo_evento_fraude (fecha_actualizacion DESC);

-- Filtrar por estado (la cola de pendientes) sin barrer toda la tabla.
CREATE INDEX IF NOT EXISTS idx_hallazgo_evento_fraude_estado
    ON hallazgo_evento_fraude (id_estado_alerta_fraude);

-- Filtrar/ordenar por tipo (un panel que separe F1 de F2..F6, por ejemplo).
CREATE INDEX IF NOT EXISTS idx_hallazgo_evento_fraude_tipo
    ON hallazgo_evento_fraude (id_tipo_hallazgo_evento);


-- ------------------------------------------------------------
-- 3. hallazgo_evento_fraude_cuenta: pivote de cuentas involucradas
-- ------------------------------------------------------------
-- Una fila por cada cuenta de un hallazgo -- normalizado, en vez de una
-- lista dentro de `detalle` (jsonb). Mismo patron que propone
-- `docs/fraude-entrega3/02-reglas-backend.md` para su `hallazgo_fraude_cuenta`
-- (la version grande, con grafo+eventos+login juntos, que sigue sin
-- construirse) -- aca es la version acotada a F1-F6.
--
-- Cubre los dos casos por igual: un hallazgo de UNA sola cuenta
-- (compras_en_rafaga, devoluciones_seriales, carrito_acaparador) tiene una
-- sola fila aqui; uno de VARIAS (ip_multicuenta_compras, granja_de_registros)
-- tiene una fila por cada cuenta. vistas_infladas (es de un producto, no
-- de una cuenta) no tiene ninguna.
--
-- `es_nucleo` -- hoy SIEMPRE true: un hallazgo de F1-F6 por si solo no
-- distingue nucleo de periferia (esa distincion nace al AGRUPAR varios
-- hallazgos en un caso, seccion 2 de `02-reglas-backend.md`, que no esta
-- construido). La columna ya existe para cuando ese agrupador se
-- construya, en vez de tener que agregarla despues.
CREATE TABLE IF NOT EXISTS hallazgo_evento_fraude_cuenta (
    id_hallazgo_evento_fraude  bigint NOT NULL
                               REFERENCES hallazgo_evento_fraude(id_hallazgo_evento_fraude)
                               ON DELETE CASCADE,

    id_usuario                 bigint NOT NULL
                               REFERENCES usuarios(id_usuario)
                               ON DELETE RESTRICT,

    es_nucleo                  boolean NOT NULL DEFAULT true,

    PRIMARY KEY (id_hallazgo_evento_fraude, id_usuario)
);

COMMENT ON TABLE hallazgo_evento_fraude_cuenta IS
    'Pivote: que cuentas participan de un hallazgo_evento_fraude -- una fila por cuenta, en vez de una lista dentro de detalle (jsonb). es_nucleo siempre true por ahora (la distincion nucleo/periferia nace al agrupar varios hallazgos en un caso, sin construir todavia)';

-- Ir de una cuenta a en que hallazgos participa (el motivo real de
-- normalizar esto en vez de dejarlo en jsonb).
CREATE INDEX IF NOT EXISTS idx_hallazgo_evento_fraude_cuenta_usuario
    ON hallazgo_evento_fraude_cuenta (id_usuario);

COMMIT;


-- ------------------------------------------------------------
-- El candado. Los ids del catalogo son los que el backend espera
-- ------------------------------------------------------------
DO $candado$
DECLARE
    r     record;
    v_id  smallint;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('vistas_infladas',         1),
            ('compras_en_rafaga',       2),
            ('ip_multicuenta_compras',  3),
            ('carrito_acaparador',      4),
            ('devoluciones_seriales',   5),
            ('granja_de_registros',     6)
        ) AS c(nombre, id_esperado)
    LOOP
        SELECT id_tipo_hallazgo_evento INTO v_id
          FROM tipo_hallazgo_evento
         WHERE tipo_hallazgo_evento_nombre = r.nombre;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Falta % en tipo_hallazgo_evento: el backend lo usa con el id %',
                r.nombre, r.id_esperado;
        END IF;

        IF v_id <> r.id_esperado THEN
            RAISE EXCEPTION '% en tipo_hallazgo_evento tiene el id % y el backend espera el % (models/hallazgo-evento-fraude.ts)',
                r.nombre, v_id, r.id_esperado;
        END IF;
    END LOOP;
END
$candado$;
