-- ============================================================
-- notificacion-fraude-usuario.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada despues de la ultima migracion real
-- existente y en migrations/README.md -- mismo workflow de siempre (ver
-- fraude-login-eventos.sql, mismo folder, para el precedente).
--
-- REVISION (2026-09-15, segunda ronda): la primera version de este archivo
-- agregaba una columna (`alerta_fraude.fecha_lectura_usuario`) pensando en
-- que cada alerta tiene UN usuario afectado. Es falso para
-- `multi_cuenta_ip`/`multi_cuenta_ip_lenta`: esas dos senales involucran a
-- VARIAS cuentas a la vez (todas las que esa IP probo), y una columna no
-- puede apuntar a mas de una. El detalle completo de por que se corrigio
-- esta en notificacion-fraude-usuario.md (mismo folder) y en
-- `cambio_propuestas/2026-09-15_1700-notificacion-fraude-multiusuario.md`.
-- Como la migracion real NUNCA se mando (esto seguia siendo solo local),
-- este archivo se REEMPLAZA en el lugar en vez de apilar una migracion
-- que corrige a la anterior -- no hay nada que revertir del lado del
-- companero.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS / IF EXISTS) y reversible: un
-- `.\arrancar.ps1 -Reiniciar` reconstruye la base desde las migraciones
-- reales y lo borra todo.
-- ============================================================


BEGIN;

-- La columna de la primera version de este archivo, si llego a aplicarse
-- en algun entorno local antes de esta correccion.
ALTER TABLE alerta_fraude
    DROP COLUMN IF EXISTS fecha_lectura_usuario;

-- ------------------------------------------------------------
-- notificacion_fraude: una fila por cada CUENTA a la que le corresponde
-- ver una alerta -- una alerta, N afectados. Ver el comentario de
-- `registrarAlertaFraude()` (`backend/src/helpers/registrar-alerta-fraude.ts`)
-- para como se decide quien termina aqui.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notificacion_fraude (
    id_notificacion   bigserial PRIMARY KEY,

    id_alerta_fraude  bigint NOT NULL
                      REFERENCES alerta_fraude(id_alerta_fraude)
                      ON DELETE RESTRICT,

    id_usuario        bigint NOT NULL
                      REFERENCES usuarios(id_usuario)
                      ON DELETE RESTRICT,

    fecha_creacion    timestamptz NOT NULL DEFAULT now(),

    -- NULL = no leida. Independiente de alerta_fraude.id_estado_alerta_fraude
    -- / fecha_revision (esas son la investigacion del admin, no la lectura
    -- del usuario) -- marcarla no toca esas columnas ni fecha_actualizacion.
    fecha_lectura     timestamptz,

    -- Una alerta no notifica dos veces a la misma cuenta -- ver el
    -- ON CONFLICT DO NOTHING de registrarAlertaFraude().
    UNIQUE (id_alerta_fraude, id_usuario)
);

COMMENT ON TABLE notificacion_fraude IS
    'Una fila por cada cuenta a la que le corresponde ver una alerta_fraude -- una alerta, N afectados (multi_cuenta_ip/multi_cuenta_ip_lenta le llegan a cada cuenta que esa IP probo, no solo a una). fecha_lectura NULL = no leida.';
COMMENT ON COLUMN notificacion_fraude.fecha_lectura IS
    'Cuando esta cuenta marco la alerta como leida via PATCH /perfil/alertas-fraude/:id. NULL = no leida.';

-- El listado del usuario (`GET /perfil/alertas-fraude`): sus notificaciones,
-- mas recientes primero.
CREATE INDEX IF NOT EXISTS idx_notificacion_fraude_usuario
    ON notificacion_fraude (id_usuario, fecha_creacion DESC);

COMMIT;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT column_name
FROM information_schema.columns
WHERE table_name = 'alerta_fraude' AND column_name = 'fecha_lectura_usuario';
-- (0 filas esperadas: la columna ya no existe)

SELECT to_regclass('public.notificacion_fraude') AS tabla_notificacion_fraude;
