-- ============================================================
-- 033_sin_llaves_viejas_de_fraude.sql
-- ============================================================
-- Etapa 8, paso 1, del refactor de fraude (ver 031). Es
-- refactor-fraude-senales-etapa8.sql hecho migracion: evidencia_caso_fraude y
-- notificacion_fraude pierden sus llaves a las tablas viejas
-- (id_anillo_fraude, id_hallazgo_evento_fraude, id_alerta_fraude) y
-- id_senal_fraude pasa a ser NOT NULL en las dos.
--
-- No tiene vuelta atras: las llaves viejas se pierden. Por eso se detiene sin
-- cambiar nada si queda una evidencia o una notificacion sin senal (la 032
-- avisa con un NOTICE de las que no pudo enlazar). Si pasa, arrancar se corta
-- con el mensaje de abajo y hay que resolverlas a mano.
--
-- Las tablas viejas (anillo_fraude, hallazgo_evento_fraude, alerta_fraude,
-- sus pivotes y sus catalogos) NO se borran: quedan sin escrituras. Borrarlas
-- es refactor-fraude-senales-etapa8-borrado.sql, que esta sin decidir. Antes
-- de hacerlo hay que tener en cuenta que la 016, la 019, la 023 y la 025 las
-- vuelven a crear vacias en cada arranque.
--
-- La 018 y la 026 crean indices y llaves sobre las columnas que aqui se
-- quitan. Desde esta migracion llevan un \if que se salta esa parte cuando la
-- columna ya no existe; sin eso, el arranque siguiente se cortaba en ellas.
-- ============================================================

SELECT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND ((table_name = 'evidencia_caso_fraude' AND column_name = 'id_anillo_fraude')
                    OR (table_name = 'notificacion_fraude'   AND column_name = 'id_alerta_fraude'))
              ) AS fraude_por_pasar
\gset

\if :fraude_por_pasar

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

\endif


-- ------------------------------------------------------------
-- Los comentarios de las dos tablas
-- ------------------------------------------------------------
-- Van fuera del \if, en cada arranque: la 018 y la 026 vuelven a poner los
-- suyos (que hablan de alerta_fraude y de las tres llaves) cada vez que corren.
COMMENT ON TABLE notificacion_fraude IS
    'Una fila por cada cuenta victima de una senal de fraude de login (senal_fraude), con su propio estado de lectura. Se avisa la primera vez que la cuenta aparece en la senal y cuando la senal se reabre. Independiente de la revision del admin';
COMMENT ON TABLE evidencia_caso_fraude IS
    'Enlaza UNA senal (senal_fraude) a su caso, con los puntos que aporta. Una senal es evidencia de un solo caso a la vez. Tipo, clave y metricas se leen con JOIN a la senal';
