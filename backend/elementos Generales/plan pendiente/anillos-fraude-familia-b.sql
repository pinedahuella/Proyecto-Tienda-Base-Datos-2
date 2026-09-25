-- ============================================================
-- anillos-fraude-familia-b.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Extiende `anillo_fraude`/`anillo_fraude_resena` (ver
-- `anillos-fraude-persistencia.sql`, mismo folder, para el esquema
-- original de A.1/A.2) para poder persistir B.1-B.7
-- (`neo4j/consultas/B1..B7`). Ver `anillos-fraude-familia-b.md` (mismo
-- folder) para el razonamiento completo de cada decision.
--
-- Esto NO es una migracion real. La migracion de verdad la escribe quien
-- lleva migrations/ (el companero), integrada despues de la ultima
-- migracion existente -- mismo workflow de siempre.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente y reversible: un `.\arrancar.ps1 -Reiniciar` reconstruye
-- la base desde las migraciones reales y borra todo esto.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. Los 7 tipos nuevos en el catalogo. El orden fija los ids 4-10
--    (mutuo/ciclo/reiterado ya son 1/2/3) -- src/models/anillo-fraude.ts
--    los fija como constantes, mismo criterio que los tres existentes.
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
-- Antes, `clave` sola bastaba: mutuo/ciclo/reiterado son el MISMO
-- fenomeno subiendo o bajando de confianza sobre el mismo par/grupo, asi
-- que el UPSERT queria pisar la fila. Con B.1-B.7 eso deja de ser cierto:
-- dos patrones DISTINTOS (ej. B.3 persistente y B.5 favor devuelto) pueden
-- coincidir en el mismo par de cuentas sin ser el mismo caso -- si comparten
-- `clave` unica, el segundo pisaria la evidencia del primero. La unicidad
-- pasa a ser sobre (id_tipo_anillo_fraude, clave): sigue permitiendo que
-- mutuo/ciclo/reiterado se fusionen entre si (para eso, la aplicacion sigue
-- calculando "el tipo ganador" antes de llamar a registrarAnilloFraude,
-- igual que hoy hace AnillosDetectorService.agrupar()), pero ya no fusiona
-- dos tipos distintos sin querer.
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


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT id_tipo_anillo_fraude, tipo_anillo_fraude_nombre
FROM tipo_anillo_fraude ORDER BY id_tipo_anillo_fraude;

SELECT conname, contype
FROM pg_constraint
WHERE conrelid = 'anillo_fraude'::regclass AND contype = 'u';
