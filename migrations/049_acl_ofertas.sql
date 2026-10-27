-- ============================================================
-- 049_acl_ofertas.sql
-- ============================================================
-- El ACL de la aplicacion, por oferta (2026-10-26). El dueno de una oferta le
-- da a otra cuenta permiso para verla, editar su precio y su existencia, o
-- ponerle y quitarle descuento, sin compartir su contrasena.
--
-- Es un ACL en el sentido clasico: una lista pegada a cada objeto (la oferta)
-- con entradas de sujeto (la cuenta) y operacion (el permiso). Lo que no esta
-- en la lista se niega. Las bases ya tienen su control de acceso por SERVICIO
-- (docs/SEGURIDAD.md: mesh_backend, mesh_lectura, los usuarios de ACL de
-- Redis); este es por PERSONA, y vive en la aplicacion porque PostgreSQL no
-- sabe que persona esta detras de cada peticion: todas llegan como
-- mesh_backend.
--
-- Lo hace cumplir el backend:
--   - PermisoOfertaGuard, antes de cada ruta de /compartidas/ofertas, busca
--     una entrada vigente de esa cuenta, esa oferta y ese permiso. Sin ella
--     contesta 404, igual que una oferta ajena.
--   - Las rutas de lo propio (/vendedor/ofertas) no cambian.
--   - Solo el dueno reparte permisos (/vendedor/ofertas/:id/permisos).
--
--   tipo_permiso_oferta       ver, editar, descuento
--   permiso_oferta            una fila por (oferta, cuenta, permiso)
--   auditoria_permiso_oferta  quien hizo que, por la via compartida o al
--                             repartir permisos, incluidos los intentos negados
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- ============================================================
-- tipo_permiso_oferta
-- ============================================================
CREATE TABLE IF NOT EXISTS tipo_permiso_oferta (
    id_tipo_permiso_oferta      smallserial PRIMARY KEY,
    tipo_permiso_oferta_nombre  varchar(20) NOT NULL UNIQUE,
    descripcion                 text NOT NULL
);

COMMENT ON TABLE tipo_permiso_oferta IS
    'Catalogo de las operaciones del ACL de ofertas. ver: mirar la oferta. editar: cambiar precio y existencia (no el estado). descuento: poner y quitar el descuento. Cualquier entrada vigente deja ver la oferta';

-- WHERE NOT EXISTS y no ON CONFLICT: este archivo corre en cada arranque y un
-- ON CONFLICT gastaria un numero de la secuencia cada vez.
INSERT INTO tipo_permiso_oferta (tipo_permiso_oferta_nombre, descripcion)
SELECT v.nombre, v.descripcion
  FROM (VALUES
          ('ver',       'Ver la oferta, su precio, su descuento y su existencia'),
          ('editar',    'Cambiar el precio y ajustar la existencia'),
          ('descuento', 'Poner y quitar el descuento')
       ) AS v(nombre, descripcion)
 WHERE NOT EXISTS (SELECT 1 FROM tipo_permiso_oferta t
                    WHERE t.tipo_permiso_oferta_nombre = v.nombre);


-- ============================================================
-- permiso_oferta
-- ============================================================
CREATE TABLE IF NOT EXISTS permiso_oferta (
    id_permiso_oferta  bigserial PRIMARY KEY,

    -- La oferta compartida. CASCADE: sin oferta no hay nada que compartir.
    id_oferta  bigint NOT NULL REFERENCES oferta(id_oferta) ON DELETE CASCADE,

    -- La cuenta que recibe el permiso. CASCADE: los quitar.sql de las semillas
    -- borran cuentas de prueba, y un permiso no debe impedirlo.
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario) ON DELETE CASCADE,

    id_tipo_permiso_oferta  smallint NOT NULL
        REFERENCES tipo_permiso_oferta(id_tipo_permiso_oferta) ON DELETE RESTRICT,

    -- Quien lo dio: el dueno, o un admin en nombre de la tienda.
    id_usuario_otorgo  bigint NOT NULL REFERENCES usuarios(id_usuario) ON DELETE CASCADE,

    fecha_otorgado  timestamptz NOT NULL DEFAULT now(),

    -- NULL = no vence. Con fecha, deja de valer en ese instante sin que nadie
    -- tenga que borrar la fila.
    fecha_vencimiento  timestamptz,

    CONSTRAINT permiso_oferta_vence_despues CHECK (
        fecha_vencimiento IS NULL OR fecha_vencimiento > fecha_otorgado
    ),
    -- Nadie se da permisos a si mismo.
    CONSTRAINT permiso_oferta_no_a_si_mismo CHECK (id_usuario <> id_usuario_otorgo),
    -- Una entrada por (oferta, cuenta, permiso): volver a darlo la actualiza.
    CONSTRAINT permiso_oferta_unico UNIQUE (id_oferta, id_usuario, id_tipo_permiso_oferta)
);

COMMENT ON TABLE permiso_oferta IS
    'El ACL de la aplicacion: que cuenta puede hacer que con que oferta, ademas de su dueno. Lo revisa PermisoOfertaGuard antes de cada ruta de /compartidas/ofertas. Lo que no esta aqui se niega';
COMMENT ON COLUMN permiso_oferta.fecha_vencimiento IS
    'NULL = no vence. Una entrada vencida se queda en la tabla pero ya no da permiso';

-- La pregunta del guard: esta cuenta, esta oferta, este permiso.
-- (permiso_oferta_unico ya la cubre por su orden de columnas.)
-- La pregunta de la lista de compartidas conmigo: todo lo de esta cuenta.
CREATE INDEX IF NOT EXISTS idx_permiso_oferta_usuario
    ON permiso_oferta (id_usuario);


-- ============================================================
-- auditoria_permiso_oferta
-- ============================================================
CREATE TABLE IF NOT EXISTS auditoria_permiso_oferta (
    id_auditoria_permiso_oferta  bigserial PRIMARY KEY,
    fecha  timestamptz NOT NULL DEFAULT now(),

    -- SIN llaves foraneas a proposito: es un registro, y tiene que sobrevivir
    -- a la oferta, al permiso y a las cuentas de las que habla. Un intento
    -- negado puede nombrar una oferta que no existe.
    id_oferta           bigint NOT NULL,
    id_usuario_actor    bigint NOT NULL,
    id_usuario_dueno    bigint,
    id_usuario_receptor bigint,

    -- Mirar una oferta compartida no se anota: solo lo que cambia algo, y lo
    -- que se nego.
    accion  varchar(20) NOT NULL CHECK (accion IN (
        'otorgar', 'revocar', 'editar',
        'poner_descuento', 'quitar_descuento', 'negado'
    )),

    -- El permiso que se dio, se quito o se pidio.
    permiso  varchar(20),

    -- Lo que cambio (el cuerpo de la peticion) o por que se nego.
    detalle  jsonb NOT NULL DEFAULT '{}'::jsonb
);

COMMENT ON TABLE auditoria_permiso_oferta IS
    'Registro del ACL de ofertas: cada permiso dado o quitado, cada accion hecha por la via compartida (a nombre del dueno, pero con quien la hizo de verdad) y cada intento negado. Sin FK a proposito';

CREATE INDEX IF NOT EXISTS idx_auditoria_permiso_oferta_oferta
    ON auditoria_permiso_oferta (id_oferta, fecha DESC);

COMMIT;
