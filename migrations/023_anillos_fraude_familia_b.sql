-- ============================================================
-- 023_anillos_fraude_familia_b.sql
-- ============================================================
-- Amplia la 019 para que `anillo_fraude` guarde tambien los patrones B.1 a
-- B.7 de resenas (`neo4j/consultas/B1..B7`), que desde el 2026-09-24 detecta
-- y persiste PatronesFraudeDetectorService.
--
--
-- DE DONDE SALE
-- ============================================================
-- Del SQL de referencia del companero, en
-- `backend/elementos Generales/plan pendiente/anillos-fraude-familia-b.sql`,
-- copiado tal cual en sus dos cambios. Lo unico que se agrega es el candado
-- del final, igual que el de la 019. El razonamiento completo esta en
-- `anillos-fraude-familia-b.md`, en la misma carpeta.
--
--
-- LOS DOS CAMBIOS
-- ============================================================
-- 1. Siete filas nuevas en `tipo_anillo_fraude`, con los ids 4 a 10:
--      4 cadena_abierta      B.1
--      5 satelites           B.2
--      6 persistente         B.3
--      7 anillo_en_el_tiempo B.4, reservado. El backend no lo persiste
--      8 favor_devuelto      B.5
--      9 coordinados         B.6
--     10 reputacion_expres   B.7
--    `src/models/anillo-fraude.ts` los fija como constantes, asi que el
--    orden del INSERT importa y el candado lo comprueba.
--
-- 2. La unicidad de `anillo_fraude.clave` pasa a (id_tipo_anillo_fraude,
--    clave). Con la clave sola, dos patrones distintos sobre el mismo par de
--    cuentas (por ejemplo B.3 y B.5) se pisarian la evidencia. El backend ya
--    escribe con `ON CONFLICT (id_tipo_anillo_fraude, clave)`: sin esta
--    migracion ese INSERT falla en una base nueva, porque no hay un indice
--    unico que case con esas dos columnas.
--
--
-- ES IDEMPOTENTE
-- ============================================================
-- El catalogo se inserta con WHERE NOT EXISTS, que no quema la secuencia en
-- cada arranque (ver migrations/README.md, la 016). El constraint se quita y
-- se pone solo si hace falta. Correrla dos veces, o encima del SQL de
-- referencia ya aplicado a mano, sale con codigo 0.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. Los 7 tipos nuevos en el catalogo
-- ------------------------------------------------------------
INSERT INTO tipo_anillo_fraude (tipo_anillo_fraude_nombre)
SELECT v.nombre
  FROM (VALUES (4, 'cadena_abierta'),
               (5, 'satelites'),
               (6, 'persistente'),
               (7, 'anillo_en_el_tiempo'),
               (8, 'favor_devuelto'),
               (9, 'coordinados'),
               (10, 'reputacion_expres')) AS v(orden, nombre)
 WHERE NOT EXISTS (SELECT 1 FROM tipo_anillo_fraude t
                    WHERE t.tipo_anillo_fraude_nombre = v.nombre)
 ORDER BY v.orden
ON CONFLICT DO NOTHING;

COMMENT ON TABLE tipo_anillo_fraude IS
    'Catalogo de tipos de fraude en resenas: mutuo/ciclo/reiterado (A.1/A.2, AnillosDetectorService) y cadena_abierta/satelites/persistente/anillo_en_el_tiempo/favor_devuelto/coordinados/reputacion_expres (B.1-B.7, ver anillos-fraude-familia-b.md). anillo_en_el_tiempo (B.4) NO se persiste como fila propia -- es enriquecimiento del detalle de un ciclo/reiterado ya existente -- pero su id de catalogo se deja reservado por si esa decision cambia.';


-- ------------------------------------------------------------
-- 2. La unicidad de `clave` pasa a (tipo, clave)
-- ------------------------------------------------------------
DO $constraint$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'anillo_fraude_clave_key'
           AND conrelid = 'anillo_fraude'::regclass
    ) THEN
        ALTER TABLE anillo_fraude DROP CONSTRAINT anillo_fraude_clave_key;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'anillo_fraude_tipo_clave_key'
           AND conrelid = 'anillo_fraude'::regclass
    ) THEN
        ALTER TABLE anillo_fraude
            ADD CONSTRAINT anillo_fraude_tipo_clave_key
            UNIQUE (id_tipo_anillo_fraude, clave);
    END IF;
END
$constraint$;

COMMENT ON COLUMN anillo_fraude.clave IS
    'Los ids de cuenta del caso, ordenados y unidos con "-" (ej. "9-10"). Unico junto con id_tipo_anillo_fraude (ver el comentario de ese constraint): el mismo par/grupo de cuentas puede escalar de mutuo a reiterado (o bajar) sin cambiar de fila -- son el MISMO tipo de fenomeno -- pero dos TIPOS distintos (ej. persistente y favor_devuelto) sobre el mismo par son casos separados.';


COMMIT;


-- ============================================================
-- El candado
-- ============================================================
-- Falla la migracion si algun id no es el que espera el backend, o si la
-- unicidad no quedo como la necesita su ON CONFLICT. Los mensajes no dicen
-- "already exists" a proposito: Correr-Migraciones perdona ese texto.
DO $candado$
DECLARE
    r    record;
    v_id integer;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('cadena_abierta',       4),
            ('satelites',            5),
            ('persistente',          6),
            ('anillo_en_el_tiempo',  7),
            ('favor_devuelto',       8),
            ('coordinados',          9),
            ('reputacion_expres',   10)
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

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'anillo_fraude_tipo_clave_key'
           AND conrelid = 'anillo_fraude'::regclass
    ) THEN
        RAISE EXCEPTION 'anillo_fraude no tiene la unicidad (id_tipo_anillo_fraude, clave) que pide el ON CONFLICT del backend';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'anillo_fraude_clave_key'
           AND conrelid = 'anillo_fraude'::regclass
    ) THEN
        RAISE EXCEPTION 'anillo_fraude sigue con la unicidad vieja sobre clave sola: dos tipos sobre el mismo par se pisarian';
    END IF;
END
$candado$;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT id_tipo_anillo_fraude, tipo_anillo_fraude_nombre
FROM tipo_anillo_fraude ORDER BY id_tipo_anillo_fraude;

SELECT conname, contype
FROM pg_constraint
WHERE conrelid = 'anillo_fraude'::regclass AND contype = 'u';
