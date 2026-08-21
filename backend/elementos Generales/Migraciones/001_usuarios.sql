-- 001_usuarios.sql
-- Usuarios, sus catalogos y los logs de acceso.
--
-- El orden importa: los catalogos van primero porque las demas tablas los
-- referencian.


-- ============================================================
-- rol_usuario
-- ============================================================
CREATE TABLE rol_usuario (
    id_rol_usuario      smallserial PRIMARY KEY,
    rol_usuario_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE rol_usuario IS 'Catalogo de roles: comprador, vendedor, admin';


-- ============================================================
-- estado_usuario
-- ============================================================
CREATE TABLE estado_usuario (
    id_estado_usuario      smallserial PRIMARY KEY,
    estado_usuario_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_usuario IS 'Catalogo de estados de una cuenta';


-- ============================================================
-- usuarios
-- ============================================================
CREATE TABLE usuarios (
    id_usuario          bigserial PRIMARY KEY,
    correo_electronico  varchar(255) NOT NULL UNIQUE,
    usuario             varchar(50)  NOT NULL UNIQUE,
    nombre              varchar(100) NOT NULL,
    apellido            varchar(100),
    contrasena_hash     varchar(255) NOT NULL,
    fecha_nacimiento    date,
    fecha_creacion      timestamptz  NOT NULL DEFAULT now(),

    -- RESTRICT: no se puede borrar un rol o un estado que alguien este usando
    id_rol_usuario     smallint NOT NULL REFERENCES rol_usuario(id_rol_usuario)
                       ON DELETE RESTRICT,
    id_estado_usuario  smallint NOT NULL REFERENCES estado_usuario(id_estado_usuario)
                       ON DELETE RESTRICT
);

COMMENT ON TABLE usuarios IS 'Cuentas del sistema. Compradores, vendedores y administradores';
COMMENT ON COLUMN usuarios.contrasena_hash IS 'Nunca la contrasena en texto plano';

CREATE INDEX idx_usuarios_rol    ON usuarios(id_rol_usuario);
CREATE INDEX idx_usuarios_estado ON usuarios(id_estado_usuario);


-- ============================================================
-- tipo_login
-- ============================================================
CREATE TABLE tipo_login (
    id_tipo_login      smallserial PRIMARY KEY,
    tipo_login_nombre  varchar(20) NOT NULL UNIQUE
);

COMMENT ON TABLE tipo_login IS 'Distingue una entrada de una salida: login o logout';


-- ============================================================
-- log_login
-- ============================================================
-- Solo se inserta, nunca se actualiza ni se borra. Es un registro historico:
-- por eso no lleva estado.
CREATE TABLE log_login (
    id_log_login   bigserial PRIMARY KEY,
    id_usuario     bigint   NOT NULL REFERENCES usuarios(id_usuario) ON DELETE RESTRICT,
    id_tipo_login  smallint NOT NULL REFERENCES tipo_login(id_tipo_login) ON DELETE RESTRICT,
    ip_origen      inet,
    fecha_login    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE log_login IS 'Cada entrada y salida de un usuario';
COMMENT ON COLUMN log_login.ip_origen IS 'Tipo inet: valida la IP y acepta IPv4 e IPv6';

-- "los ultimos accesos de este usuario" es la consulta que se va a hacer
CREATE INDEX idx_log_login_usuario ON log_login(id_usuario, fecha_login DESC);


-- ============================================================
-- log_registro
-- ============================================================
CREATE TABLE log_registro (
    id_log_registro  bigserial PRIMARY KEY,
    id_usuario       bigint NOT NULL REFERENCES usuarios(id_usuario) ON DELETE RESTRICT,
    ip_origen        inet,
    fecha_registro   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE log_registro IS 'Desde donde se creo cada cuenta';

CREATE INDEX idx_log_registro_usuario ON log_registro(id_usuario);


-- ============================================================
-- Valores de los catalogos
-- ============================================================
-- No son datos de prueba: sin ellos no se puede crear un usuario.

INSERT INTO rol_usuario (rol_usuario_nombre) VALUES
    ('comprador'),
    ('vendedor'),
    ('admin');

INSERT INTO estado_usuario (estado_usuario_nombre) VALUES
    ('activo'),
    ('inactivo'),
    ('suspendido');

INSERT INTO tipo_login (tipo_login_nombre) VALUES
    ('login'),
    ('logout');
