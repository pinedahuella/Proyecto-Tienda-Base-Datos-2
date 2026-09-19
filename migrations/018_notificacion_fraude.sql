-- ============================================================
-- 018_notificacion_fraude.sql
-- ============================================================
-- Segundo pedido del profesor sobre el modulo de fraude de login: que las
-- alertas no solo las vea el admin, sino tambien cada usuario cuya cuenta
-- esta involucrada, "por si cualquiera desea tomar accion".
--
-- DE DONDE SALE
-- ============================================================
-- El backend ya la usa (FraudeLoginService.listarAlertasPaginadoUsuario /
-- marcarLeida, PerfilController). La definicion es la del SQL de referencia
-- del companero, en
-- `backend/elementos Generales/plan pendiente/notificacion-fraude-usuario.sql`,
-- copiada tal cual.
--
--
-- POR QUE UNA TABLA Y NO UNA COLUMNA EN alerta_fraude
-- ============================================================
-- multi_cuenta_ip / multi_cuenta_ip_lenta le tocan a VARIAS cuentas a la
-- vez (todos los identificadores reales que una misma IP probo), no a una
-- sola. Una columna en alerta_fraude no puede apuntar a varias cuentas.
-- Una tabla (una alerta, N filas de afectados) si.
--
--
-- POR QUE ES INDEPENDIENTE DE fecha_actualizacion DE alerta_fraude
-- ============================================================
-- alerta_fraude.fecha_actualizacion es la actividad de revision del ADMIN
-- (ordena su listado). Si marcar-leida por un usuario tambien la tocara, la
-- fila "saltaria" en el listado del admin cada vez que un afectado entra a
-- mirar su alerta, un efecto colateral sin sentido. Por eso la lectura de
-- cada usuario vive aparte, en su propia fila y su propia columna.
-- ============================================================


CREATE TABLE IF NOT EXISTS notificacion_fraude (
    id_notificacion   bigserial PRIMARY KEY,

    id_alerta_fraude  bigint NOT NULL
                      REFERENCES alerta_fraude(id_alerta_fraude)
                      ON DELETE RESTRICT,

    id_usuario        bigint NOT NULL
                      REFERENCES usuarios(id_usuario)
                      ON DELETE RESTRICT,

    fecha_creacion    timestamptz NOT NULL DEFAULT now(),

    -- NULL = no leida. La marca SET fecha_lectura = COALESCE(fecha_lectura,
    -- now()) del backend, idempotente.
    fecha_lectura     timestamptz,

    UNIQUE (id_alerta_fraude, id_usuario)
);

COMMENT ON TABLE notificacion_fraude IS
    'Una fila por cada cuenta a la que le corresponde ver una alerta de alerta_fraude, con su propio estado de lectura. Independiente de la revision del admin (alerta_fraude.id_estado_alerta_fraude/fecha_revision): un usuario puede leer su alerta antes o despues de que el admin la revise.';
COMMENT ON COLUMN notificacion_fraude.fecha_lectura IS
    'NULL = no leida por esta cuenta. La marca PATCH /perfil/alertas-fraude/:id, sin tocar alerta_fraude.fecha_actualizacion (esa es del admin, no de este usuario)';

-- GET /perfil/alertas-fraude: las de una cuenta, mas recientes primero
-- (se ordena por alerta_fraude.fecha_creacion via join, este indice cubre
-- el filtro por cuenta).
CREATE INDEX IF NOT EXISTS idx_notificacion_fraude_usuario
    ON notificacion_fraude (id_usuario);

-- GET /admin/fraude/alertas-login: por cada alerta, quienes son sus
-- afectados y si ya la leyeron.
CREATE INDEX IF NOT EXISTS idx_notificacion_fraude_alerta
    ON notificacion_fraude (id_alerta_fraude);


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT to_regclass('public.notificacion_fraude') AS tabla_notificacion_fraude;
