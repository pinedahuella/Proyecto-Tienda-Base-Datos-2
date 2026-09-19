-- ============================================================
-- 019_anillo_fraude.sql
-- ============================================================
-- Persiste lo que hasta ahora solo detectaba y logueaba
-- AnillosDetectorService: los anillos mutuo/ciclo/reiterado (A.1/A.2) del
-- grafo de resenas en Neo4j. A.4 (misma direccion) sigue fuera de alcance.
--
-- DE DONDE SALE
-- ============================================================
-- La definicion es la del SQL de referencia del companero, en
-- `backend/elementos Generales/plan pendiente/anillos-fraude-persistencia.sql`,
-- copiada tal cual.
--
--
-- POR QUE NO REUSA alerta_fraude
-- ============================================================
-- alerta_fraude.ventana_inicio esta pensado para "un umbral se cruzo en un
-- momento" (un intento de login). Un anillo es "esto existe ahora mismo en
-- el grafo", una pregunta distinta. Forzarlo en la misma tabla mezclaria
-- dos responsabilidades. Si reusa id_estado_alerta_fraude (pendiente /
-- revisada / descartada): es un catalogo generico de 3 valores sin logica
-- de dominio, no arrastra el mismo problema.
--
--
-- POR QUE clave NO LLEVA EL TIPO
-- ============================================================
-- Un mismo par/grupo de cuentas puede subir de mutuo a reiterado (o bajar)
-- sin dejar de ser, para persistencia, el mismo caso: se actualiza la fila,
-- no se crea una nueva.
--
--
-- SIN JSON DE EVIDENCIA Y SIN TABLA DE CUENTAS APARTE
-- ============================================================
-- La evidencia vive en anillo_fraude_resena (ids de resena reales, iguales
-- en Postgres y Neo4j). Las cuentas del anillo se derivan con un join
-- contra resena.id_usuario / id_usuario_vendedor -- guardarlas aparte seria
-- redundante.
--
--
-- SIN NOTIFICACION A LAS CUENTAS DEL ANILLO
-- ============================================================
-- A diferencia del fraude de login (la cuenta senalada es la VICTIMA), en
-- un anillo de resenas la cuenta senalada es la SOSPECHOSA: avisarle le
-- daria la oportunidad de evadir la deteccion. El caso es 100% interno
-- para que un admin lo revise.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. tipo_anillo_fraude: catalogo de los tipos de anillo
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tipo_anillo_fraude (
    id_tipo_anillo_fraude      smallserial PRIMARY KEY,
    tipo_anillo_fraude_nombre  varchar(20) NOT NULL UNIQUE
);

-- El orden del INSERT fija los ids: 1 mutuo, 2 ciclo, 3 reiterado.
-- src/models/anillo-fraude.ts los fija como constantes.
INSERT INTO tipo_anillo_fraude (tipo_anillo_fraude_nombre)
SELECT v.nombre
  FROM (VALUES (1, 'mutuo'),
               (2, 'ciclo'),
               (3, 'reiterado')) AS v(orden, nombre)
 WHERE NOT EXISTS (SELECT 1 FROM tipo_anillo_fraude t
                    WHERE t.tipo_anillo_fraude_nombre = v.nombre)
 ORDER BY v.orden
ON CONFLICT DO NOTHING;

COMMENT ON TABLE tipo_anillo_fraude IS
    'Catalogo de tipos de anillo de fraude en resenas que detecta AnillosDetectorService: mutuo (2 cuentas se califican entre si), ciclo (3-4 cuentas en circulo), reiterado (mutuo ademas sobre el mismo producto -- pisa a mutuo del mismo par). El backend fija sus ids (models/anillo-fraude.ts); el candado de abajo lo comprueba';


-- ------------------------------------------------------------
-- 2. anillo_fraude: una fila por anillo detectado
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS anillo_fraude (
    id_anillo_fraude              bigserial PRIMARY KEY,

    id_tipo_anillo_fraude         smallint NOT NULL
                                   REFERENCES tipo_anillo_fraude(id_tipo_anillo_fraude),

    clave                         varchar(255) NOT NULL UNIQUE,

    id_estado_alerta_fraude       smallint NOT NULL
                                   REFERENCES estado_alerta_fraude(id_estado_alerta_fraude),

    fecha_creacion                timestamptz NOT NULL DEFAULT now(),

    -- Se actualiza cada vez que una corrida (worker o acotada) vuelve a
    -- encontrar este mismo anillo.
    ultima_vez_confirmado_activo  timestamptz NOT NULL DEFAULT now(),

    -- Cuando un admin cambio el estado. Distinta de la de arriba: esa es
    -- sobre deteccion, esta es sobre revision humana.
    fecha_actualizacion           timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE anillo_fraude IS
    'Un anillo de fraude en resenas (mutuo/ciclo/reiterado, A.1/A.2) detectado por AnillosDetectorService. No guarda evidencia en JSON: ver anillo_fraude_resena para las resenas exactas, y consultar Neo4j/resena con esos ids para el detalle de la relacion';
COMMENT ON COLUMN anillo_fraude.clave IS
    'Los ids de cuenta del anillo, ordenados y unidos con "-" (ej. "9-10"). NO lleva el tipo: el mismo par/grupo de cuentas puede subir de mutuo a reiterado (o bajar) sin cambiar de fila';
COMMENT ON COLUMN anillo_fraude.ultima_vez_confirmado_activo IS
    'La ultima corrida (worker de 15 min o chequeo acotado por resena) que volvio a encontrar este anillo. Si deja de avanzar, no aparecio en corridas recientes -- no se borra ni se marca solo, queda para que un admin lo revise';

-- El listado de admin: los anillos que siguen activos primero.
CREATE INDEX IF NOT EXISTS idx_anillo_fraude_listado
    ON anillo_fraude (ultima_vez_confirmado_activo DESC);

-- Filtrar por estado (la cola de pendientes) sin barrer toda la tabla.
CREATE INDEX IF NOT EXISTS idx_anillo_fraude_estado
    ON anillo_fraude (id_estado_alerta_fraude);


-- ------------------------------------------------------------
-- 3. anillo_fraude_resena: pivote a la evidencia
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS anillo_fraude_resena (
    id_anillo_fraude  bigint NOT NULL
                      REFERENCES anillo_fraude(id_anillo_fraude)
                      ON DELETE RESTRICT,

    id_resena         bigint NOT NULL
                      REFERENCES resena(id_resena)
                      ON DELETE RESTRICT,

    PRIMARY KEY (id_anillo_fraude, id_resena)
);

COMMENT ON TABLE anillo_fraude_resena IS
    'Pivote: que resenas exactas son la evidencia de un anillo_fraude. Sin columna de lectura (las cuentas del anillo son sospechosas, no se les notifica) y sin tabla de cuentas aparte (se derivan via join con resena.id_usuario/id_usuario_vendedor)';

-- Para ir de una resena a que anillo(s) pertenece, si hiciera falta.
CREATE INDEX IF NOT EXISTS idx_anillo_fraude_resena_resena
    ON anillo_fraude_resena (id_resena);

COMMIT;


-- ============================================================
-- El candado
-- ============================================================
DO $candado$
DECLARE
    r    record;
    v_id integer;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('mutuo',     1),
            ('ciclo',     2),
            ('reiterado', 3)
        ) AS c(nombre, id_esperado)
    LOOP
        SELECT id_tipo_anillo_fraude INTO v_id
          FROM tipo_anillo_fraude
         WHERE tipo_anillo_fraude_nombre = r.nombre;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Falta % en tipo_anillo_fraude: el backend lo usa con el id %',
                r.nombre, r.id_esperado;
        END IF;

        IF v_id <> r.id_esperado THEN
            RAISE EXCEPTION '% en tipo_anillo_fraude tiene el id % y el backend espera el % (models/anillo-fraude.ts)',
                r.nombre, v_id, r.id_esperado;
        END IF;
    END LOOP;

    RAISE NOTICE 'anillo_fraude listo. Anillos pendientes de revisar: %',
        (SELECT count(*) FROM anillo_fraude af
           JOIN estado_alerta_fraude e
             ON e.id_estado_alerta_fraude = af.id_estado_alerta_fraude
          WHERE e.estado_alerta_fraude_nombre = 'pendiente');
END
$candado$;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT id_tipo_anillo_fraude, tipo_anillo_fraude_nombre
FROM tipo_anillo_fraude ORDER BY id_tipo_anillo_fraude;

SELECT to_regclass('public.anillo_fraude') AS tabla_anillo_fraude;
SELECT to_regclass('public.anillo_fraude_resena') AS tabla_anillo_fraude_resena;
