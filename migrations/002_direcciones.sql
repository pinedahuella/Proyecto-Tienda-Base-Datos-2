-- 002_direcciones.sql
-- Direcciones de los usuarios, su catalogo de estados y su historial.
--
-- El orden importa: el catalogo va primero, luego direcciones (que lo
-- referencia junto con usuarios), y al final el historial (que referencia a
-- direcciones).


-- ============================================================
-- estado_direccion
-- ============================================================
CREATE TABLE estado_direccion (
    id_estado_direccion      smallserial PRIMARY KEY,
    estado_direccion_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_direccion IS 'Catalogo de estados de una direccion';


-- ============================================================
-- direcciones
-- ============================================================
-- Una direccion no se borra nunca: el historial la referencia y el borrado
-- esta en RESTRICT. Para quitarla de en medio se le pone el estado
-- inactiva, que es justo para lo que existe el catalogo de arriba.
CREATE TABLE direcciones (
    id_direccion    bigserial PRIMARY KEY,

    -- RESTRICT: no se puede borrar un usuario que todavia tenga direcciones
    id_usuario      bigint NOT NULL REFERENCES usuarios(id_usuario)
                    ON DELETE RESTRICT,

    pais            varchar(100) NOT NULL,
    departamento    varchar(100) NOT NULL,
    ciudad          varchar(100) NOT NULL,
    codigo_postal   varchar(20),
    fecha_creacion  timestamptz  NOT NULL DEFAULT now(),

    id_estado_direccion  smallint NOT NULL REFERENCES estado_direccion(id_estado_direccion)
                         ON DELETE RESTRICT
);

COMMENT ON TABLE direcciones IS 'Direcciones de envio de cada usuario. La version vigente';
COMMENT ON COLUMN direcciones.codigo_postal IS 'Opcional: no todos los paises lo usan';

-- "las direcciones de este usuario" es la consulta que se va a hacer
CREATE INDEX idx_direcciones_usuario ON direcciones(id_usuario);
CREATE INDEX idx_direcciones_estado  ON direcciones(id_estado_direccion);


-- ============================================================
-- direccion_historial
-- ============================================================
-- Solo se inserta, nunca se actualiza ni se borra: cada fila es la version
-- de una direccion que regia desde su fecha_creacion. Se agrega una al
-- crear la direccion y otra cada vez que se edita.
--
-- Por eso no lleva estado: el estado vive en la fila viva, que si cambia.
-- Y la fecha se llama fecha_creacion y no fecha_actualizacion, porque marca
-- desde cuando rige esa version, no cuando se toco por ultima vez.
--
-- Existe para que un pedido pueda recordar a que direccion se envio ese
-- dia, aunque el usuario la edite despues. Pedido apunta aqui, no a
-- direcciones.
CREATE TABLE direccion_historial (
    id_direccion_historial  bigserial PRIMARY KEY,

    id_direccion    bigint NOT NULL REFERENCES direcciones(id_direccion)
                    ON DELETE RESTRICT,

    pais            varchar(100) NOT NULL,
    departamento    varchar(100) NOT NULL,
    ciudad          varchar(100) NOT NULL,
    codigo_postal   varchar(20),
    fecha_creacion  timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE direccion_historial IS 'Cada version por la que ha pasado una direccion';

-- "que decia esta direccion el 3 de marzo": con este indice la base entra
-- directo y lee una fila, sin recorrer el historial completo
CREATE INDEX idx_direccion_historial_direccion
    ON direccion_historial(id_direccion, fecha_creacion DESC);


-- ============================================================
-- Valores de los catalogos
-- ============================================================
-- No son datos de prueba: sin ellos no se puede crear una direccion.

INSERT INTO estado_direccion (estado_direccion_nombre) VALUES
    ('activa'),
    ('inactiva');
