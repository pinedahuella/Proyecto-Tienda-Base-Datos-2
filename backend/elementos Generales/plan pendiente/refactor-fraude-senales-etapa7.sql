-- ============================================================
-- refactor-fraude-senales-etapa7.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de la de las senales
-- (refactor-fraude-senales.sql, etapas 1 a 5) -- mismo workflow de siempre.
--
-- ETAPA 7, PARTE 1 del refactor de fraude (ver refactor-fraude-senales.md):
-- evidencia_caso_fraude gana una llave a senal_fraude. ADITIVO: las tres
-- llaves viejas (id_anillo_fraude, id_hallazgo_evento_fraude,
-- id_alerta_fraude) NO se quitan aqui; se quitan en la etapa 8, cuando ya
-- nada las lea. Mientras tanto la evidencia nueva solo trae id_senal_fraude.
--
-- Requiere las tablas de refactor-fraude-senales.sql ya aplicadas.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS / solo rellena lo que esta en NULL).
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. La columna nueva
-- ------------------------------------------------------------
-- ON DELETE CASCADE como las tres viejas: si la senal desaparece, la evidencia
-- que la apuntaba desaparece con ella.
ALTER TABLE evidencia_caso_fraude
    ADD COLUMN IF NOT EXISTS id_senal_fraude bigint
        REFERENCES senal_fraude(id_senal_fraude) ON DELETE CASCADE;

COMMENT ON COLUMN evidencia_caso_fraude.id_senal_fraude IS
    'La senal (senal_fraude) que es evidencia de este caso. Reemplaza a las tres llaves viejas (id_anillo_fraude, id_hallazgo_evento_fraude, id_alerta_fraude), que se quitan en la etapa 8 del refactor de fraude';


-- ------------------------------------------------------------
-- 2. El CHECK
-- ------------------------------------------------------------
-- Hoy exige EXACTAMENTE una de las tres llaves viejas, y la evidencia nueva
-- trae solo id_senal_fraude. Se cambia por "al menos una de las cuatro". La
-- etapa 8 lo reemplaza por id_senal_fraude NOT NULL.
ALTER TABLE evidencia_caso_fraude
    DROP CONSTRAINT IF EXISTS evidencia_caso_fraude_check;
ALTER TABLE evidencia_caso_fraude
    DROP CONSTRAINT IF EXISTS evidencia_caso_fraude_alguna_llave_check;
ALTER TABLE evidencia_caso_fraude
    ADD CONSTRAINT evidencia_caso_fraude_alguna_llave_check
    CHECK (num_nonnulls(id_anillo_fraude, id_hallazgo_evento_fraude,
                        id_alerta_fraude, id_senal_fraude) >= 1);


-- ------------------------------------------------------------
-- 3. Rellenar la evidencia que ya existe
-- ------------------------------------------------------------
-- Cada evidencia vieja apunta a UNA fila de su tabla; la senal equivalente es
-- la de ese mismo (tipo, clave). En hallazgos y alertas hay una fila por dia o
-- por ventana, asi que varias filas viejas pueden dar la misma senal.
--   - Si chocan DENTRO del mismo caso, eran el mismo hecho contado dos veces:
--     se conserva la de ultima_evidencia mas reciente y la otra se BORRA (el
--     puntaje del caso se recalcula en la siguiente corrida del agrupador).
--   - Si chocan en casos DISTINTOS (una senal no puede ser evidencia de dos
--     casos), la perdedora se queda con su llave vieja, sin id_senal_fraude, y
--     se avisa por NOTICE para revisarla a mano antes de la etapa 8.
CREATE TEMP TABLE candidatas_evidencia_senal ON COMMIT DROP AS
SELECT e.id_evidencia_caso_fraude, s.id_senal_fraude
  FROM evidencia_caso_fraude e
  JOIN anillo_fraude a ON a.id_anillo_fraude = e.id_anillo_fraude
  JOIN tipo_anillo_fraude t ON t.id_tipo_anillo_fraude = a.id_tipo_anillo_fraude
  JOIN tipo_senal_fraude ts ON ts.tipo_senal_fraude_nombre = t.tipo_anillo_fraude_nombre
  JOIN senal_fraude s ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude
                     AND s.clave = a.clave
 WHERE e.id_senal_fraude IS NULL
UNION ALL
SELECT e.id_evidencia_caso_fraude, s.id_senal_fraude
  FROM evidencia_caso_fraude e
  JOIN hallazgo_evento_fraude h ON h.id_hallazgo_evento_fraude = e.id_hallazgo_evento_fraude
  JOIN tipo_hallazgo_evento t ON t.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
  JOIN tipo_senal_fraude ts ON ts.tipo_senal_fraude_nombre = t.tipo_hallazgo_evento_nombre
  JOIN senal_fraude s ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude
                     AND s.clave = h.clave
 WHERE e.id_senal_fraude IS NULL
UNION ALL
SELECT e.id_evidencia_caso_fraude, s.id_senal_fraude
  FROM evidencia_caso_fraude e
  JOIN alerta_fraude al ON al.id_alerta_fraude = e.id_alerta_fraude
  JOIN tipo_alerta_fraude t ON t.id_tipo_alerta_fraude = al.id_tipo_alerta_fraude
  JOIN tipo_senal_fraude ts ON ts.tipo_senal_fraude_nombre = t.tipo_alerta_fraude_nombre
  JOIN senal_fraude s ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude
                     AND s.clave = al.clave
 WHERE e.id_senal_fraude IS NULL;

-- Una ganadora por senal: la de ultima_evidencia mas reciente.
WITH elegidas AS (
    SELECT DISTINCT ON (c.id_senal_fraude)
           c.id_evidencia_caso_fraude, c.id_senal_fraude
      FROM candidatas_evidencia_senal c
      JOIN evidencia_caso_fraude e USING (id_evidencia_caso_fraude)
     ORDER BY c.id_senal_fraude, e.ultima_evidencia DESC, c.id_evidencia_caso_fraude
)
UPDATE evidencia_caso_fraude e
   SET id_senal_fraude = el.id_senal_fraude
  FROM elegidas el
 WHERE e.id_evidencia_caso_fraude = el.id_evidencia_caso_fraude
   AND NOT EXISTS (SELECT 1 FROM evidencia_caso_fraude otra
                    WHERE otra.id_senal_fraude = el.id_senal_fraude);

-- Las perdedoras del MISMO caso que la ganadora: el mismo hecho contado dos
-- veces. Se borran (evidencia_caso_fraude_cuenta se va en cascada).
DELETE FROM evidencia_caso_fraude e
 USING candidatas_evidencia_senal c
 WHERE e.id_evidencia_caso_fraude = c.id_evidencia_caso_fraude
   AND e.id_senal_fraude IS NULL
   AND EXISTS (SELECT 1 FROM evidencia_caso_fraude otra
                WHERE otra.id_senal_fraude = c.id_senal_fraude
                  AND otra.id_caso_fraude = e.id_caso_fraude);

DO $aviso$
DECLARE
    v_sin_senal integer;
BEGIN
    SELECT count(*) INTO v_sin_senal
      FROM evidencia_caso_fraude WHERE id_senal_fraude IS NULL;
    IF v_sin_senal > 0 THEN
        RAISE NOTICE 'ATENCION: % evidencia(s) quedaron sin id_senal_fraude (su senal no existe, o chocaba con la evidencia de OTRO caso). Siguen con su llave vieja; revisarlas antes de la etapa 8', v_sin_senal;
    END IF;
END
$aviso$;


-- ------------------------------------------------------------
-- 4. Una senal no puede ser evidencia de mas de un caso a la vez
-- ------------------------------------------------------------
-- Igual que los tres indices viejos: si no, el mismo hecho se contaria dos
-- veces en dos puntajes distintos. Parcial, porque mientras dure la
-- transicion hay evidencia vieja con id_senal_fraude en NULL.
CREATE UNIQUE INDEX IF NOT EXISTS idx_evidencia_caso_fraude_senal
    ON evidencia_caso_fraude (id_senal_fraude) WHERE id_senal_fraude IS NOT NULL;


-- ============================================================
-- PARTE 3: notificacion_fraude apunta a la senal
-- ============================================================
-- Hoy una notificacion cuelga de UNA alerta por ventana (minuto u hora), asi
-- que cada ventana nueva avisa otra vez al usuario. La senal es una por
-- (tipo, clave): una notificacion por (senal, cuenta), con su propio estado de
-- lectura. Se avisa cuando la cuenta aparece por primera vez en la senal y
-- cuando la senal se reabre (la lectura vuelve a NULL); no en cada ventana.
--
-- ADITIVO, igual que la evidencia: id_alerta_fraude NO se quita aqui (se quita
-- en la etapa 8) pero pasa a ser opcional, porque la notificacion nueva solo
-- trae id_senal_fraude.

-- ------------------------------------------------------------
-- 5. La columna nueva y sus reglas
-- ------------------------------------------------------------
ALTER TABLE notificacion_fraude
    ADD COLUMN IF NOT EXISTS id_senal_fraude bigint
        REFERENCES senal_fraude(id_senal_fraude) ON DELETE CASCADE;

ALTER TABLE notificacion_fraude
    ALTER COLUMN id_alerta_fraude DROP NOT NULL;

ALTER TABLE notificacion_fraude
    DROP CONSTRAINT IF EXISTS notificacion_fraude_alguna_llave_check;
ALTER TABLE notificacion_fraude
    ADD CONSTRAINT notificacion_fraude_alguna_llave_check
    CHECK (id_alerta_fraude IS NOT NULL OR id_senal_fraude IS NOT NULL);

COMMENT ON COLUMN notificacion_fraude.id_senal_fraude IS
    'La senal (senal_fraude) de la que se avisa a esta cuenta. Reemplaza a id_alerta_fraude, que se quita en la etapa 8 del refactor de fraude. Una fila por (senal, cuenta)';

-- Una notificacion por (senal, cuenta). Parcial: mientras dure la transicion
-- hay notificaciones viejas con id_senal_fraude en NULL.
CREATE UNIQUE INDEX IF NOT EXISTS idx_notificacion_fraude_senal_usuario
    ON notificacion_fraude (id_senal_fraude, id_usuario)
 WHERE id_senal_fraude IS NOT NULL;

-- GET /admin/fraude/alertas-login: por cada senal, sus afectados y si leyeron.
CREATE INDEX IF NOT EXISTS idx_notificacion_fraude_senal
    ON notificacion_fraude (id_senal_fraude);


-- ------------------------------------------------------------
-- 6. Pasar las notificaciones que ya existen
-- ------------------------------------------------------------
-- Cada notificacion vieja cuelga de una alerta; la senal equivalente es la de
-- ese mismo (tipo, clave). Varias alertas (ventanas) de la misma senal dan
-- varias notificaciones para la misma cuenta, asi que por cada (senal, cuenta)
-- se conserva UNA (la mas vieja, id_notificacion menor) y se borran las demas:
--   - fecha_lectura: queda leida solo si leyo TODAS las de esa senal (con la
--     fecha de la ultima lectura); si alguna sigue sin leer, sin leer.
--   - fecha_creacion: la de la primera vez que se le aviso.
CREATE TEMP TABLE notificaciones_por_senal ON COMMIT DROP AS
SELECT nf.id_notificacion, s.id_senal_fraude, nf.id_usuario,
       nf.fecha_creacion, nf.fecha_lectura
  FROM notificacion_fraude nf
  JOIN alerta_fraude al ON al.id_alerta_fraude = nf.id_alerta_fraude
  JOIN tipo_alerta_fraude ta ON ta.id_tipo_alerta_fraude = al.id_tipo_alerta_fraude
  JOIN tipo_senal_fraude ts ON ts.tipo_senal_fraude_nombre = ta.tipo_alerta_fraude_nombre
  JOIN senal_fraude s ON s.id_tipo_senal_fraude = ts.id_tipo_senal_fraude
                     AND s.clave = al.clave
 WHERE nf.id_senal_fraude IS NULL;

CREATE TEMP TABLE notificaciones_unificadas ON COMMIT DROP AS
SELECT min(id_notificacion)                                   AS id_conservada,
       id_senal_fraude, id_usuario,
       min(fecha_creacion)                                    AS fecha_creacion,
       CASE WHEN bool_or(fecha_lectura IS NULL) THEN NULL
            ELSE max(fecha_lectura) END                       AS fecha_lectura
  FROM notificaciones_por_senal
 GROUP BY id_senal_fraude, id_usuario;

-- Las sobrantes primero, para no chocar con el indice unico al enlazar.
DELETE FROM notificacion_fraude nf
 USING notificaciones_por_senal p
  JOIN notificaciones_unificadas u
    ON u.id_senal_fraude = p.id_senal_fraude AND u.id_usuario = p.id_usuario
 WHERE nf.id_notificacion = p.id_notificacion
   AND p.id_notificacion <> u.id_conservada;

UPDATE notificacion_fraude nf
   SET id_senal_fraude = u.id_senal_fraude,
       fecha_creacion  = u.fecha_creacion,
       fecha_lectura   = u.fecha_lectura
  FROM notificaciones_unificadas u
 WHERE nf.id_notificacion = u.id_conservada
   AND nf.id_senal_fraude IS NULL;

-- Las cuentas victima de una senal de login que no tengan notificacion (no
-- deberia haber, salen de las mismas notificaciones): se crean sin leer.
INSERT INTO notificacion_fraude (id_senal_fraude, id_usuario)
SELECT sc.id_senal_fraude, sc.id_usuario
  FROM senal_fraude_cuenta sc
  JOIN rol_cuenta_senal rol ON rol.id_rol_cuenta_senal = sc.id_rol_cuenta_senal
  JOIN senal_fraude s ON s.id_senal_fraude = sc.id_senal_fraude
  JOIN tipo_senal_fraude t ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
  JOIN familia_senal_fraude f ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
 WHERE rol.rol_cuenta_senal_nombre = 'victima'
   AND f.familia_senal_fraude_nombre = 'login'
ON CONFLICT (id_senal_fraude, id_usuario) WHERE id_senal_fraude IS NOT NULL
DO NOTHING;

COMMIT;
