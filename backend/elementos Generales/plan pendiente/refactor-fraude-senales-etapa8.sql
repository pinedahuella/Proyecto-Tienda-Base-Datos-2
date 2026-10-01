-- ============================================================
-- refactor-fraude-senales-etapa8.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de las dos anteriores
-- (refactor-fraude-senales.sql y refactor-fraude-senales-etapa7.sql).
--
-- ETAPA 8, PASO 1 del refactor de fraude (ver refactor-fraude-senales.md):
-- se quitan las llaves viejas de evidencia_caso_fraude y de
-- notificacion_fraude, y id_senal_fraude pasa a ser NOT NULL en las dos.
--
-- NO borra ni convierte en vistas las tablas viejas (anillo_fraude,
-- hallazgo_evento_fraude, alerta_fraude y sus pivotes y catalogos): eso es el
-- paso 3 y el 4, en archivos aparte. Despues de este archivo, lo unico que
-- sigue apuntando a las tablas viejas son sus propios pivotes.
--
-- Requiere las dos migraciones anteriores ya aplicadas. Antes de correrlo, el
-- backend ya no debe escribir en las tablas viejas ni leerlas (etapa 8,
-- paso 2): ya es asi en el codigo.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF EXISTS) y se detiene sin cambiar nada si queda una fila
-- sin senal. NO tiene vuelta atras: las llaves viejas se pierden. En una base
-- real, respaldar antes.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 0. Que no quede nada sin senal
-- ------------------------------------------------------------
-- Las evidencias que en la etapa 7 chocaron con otra de OTRO caso se quedaron
-- con su llave vieja y sin senal (salio un NOTICE). Si hay alguna, hay que
-- resolverla a mano antes: al quitar la llave vieja quedaria sin ninguna.
DO $$
DECLARE
    sin_senal_evidencia integer;
    sin_senal_notificacion integer;
BEGIN
    SELECT count(*) INTO sin_senal_evidencia
      FROM evidencia_caso_fraude WHERE id_senal_fraude IS NULL;
    SELECT count(*) INTO sin_senal_notificacion
      FROM notificacion_fraude WHERE id_senal_fraude IS NULL;
    IF sin_senal_evidencia > 0 OR sin_senal_notificacion > 0 THEN
        RAISE EXCEPTION 'Quedan filas sin senal: % en evidencia_caso_fraude y % en notificacion_fraude. Resolverlas a mano antes de la etapa 8.',
            sin_senal_evidencia, sin_senal_notificacion;
    END IF;
END $$;


-- ------------------------------------------------------------
-- 1. evidencia_caso_fraude
-- ------------------------------------------------------------
-- Al quitar una columna, Postgres quita tambien sus llaves foraneas, sus
-- indices y los CHECK que la usan; se nombran igual para que quede escrito.
ALTER TABLE evidencia_caso_fraude
    DROP CONSTRAINT IF EXISTS evidencia_caso_fraude_alguna_llave_check;

DROP INDEX IF EXISTS idx_evidencia_caso_fraude_anillo;
DROP INDEX IF EXISTS idx_evidencia_caso_fraude_hallazgo_evento;
DROP INDEX IF EXISTS idx_evidencia_caso_fraude_alerta;

ALTER TABLE evidencia_caso_fraude
    DROP COLUMN IF EXISTS id_anillo_fraude,
    DROP COLUMN IF EXISTS id_hallazgo_evento_fraude,
    DROP COLUMN IF EXISTS id_alerta_fraude;

ALTER TABLE evidencia_caso_fraude
    ALTER COLUMN id_senal_fraude SET NOT NULL;

-- Una senal es evidencia de un solo caso a la vez. Ya no hace falta que el
-- indice sea parcial (la columna no admite NULL).
DROP INDEX IF EXISTS idx_evidencia_caso_fraude_senal;
CREATE UNIQUE INDEX idx_evidencia_caso_fraude_senal
    ON evidencia_caso_fraude (id_senal_fraude);

COMMENT ON COLUMN evidencia_caso_fraude.id_senal_fraude IS
    'La senal (senal_fraude) que es evidencia de este caso. Unica llave de la evidencia desde la etapa 8 del refactor de fraude';


-- ------------------------------------------------------------
-- 2. notificacion_fraude
-- ------------------------------------------------------------
ALTER TABLE notificacion_fraude
    DROP CONSTRAINT IF EXISTS notificacion_fraude_alguna_llave_check;
ALTER TABLE notificacion_fraude
    DROP CONSTRAINT IF EXISTS notificacion_fraude_id_alerta_fraude_id_usuario_key;

DROP INDEX IF EXISTS idx_notificacion_fraude_alerta;

ALTER TABLE notificacion_fraude
    DROP COLUMN IF EXISTS id_alerta_fraude;

ALTER TABLE notificacion_fraude
    ALTER COLUMN id_senal_fraude SET NOT NULL;

-- Una notificacion por (senal, cuenta). Tampoco necesita ser parcial.
DROP INDEX IF EXISTS idx_notificacion_fraude_senal_usuario;
CREATE UNIQUE INDEX idx_notificacion_fraude_senal_usuario
    ON notificacion_fraude (id_senal_fraude, id_usuario);

COMMIT;
