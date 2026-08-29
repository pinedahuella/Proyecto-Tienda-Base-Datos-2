-- ============================================================
-- propuesta-de-productos.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion real la escribe quien lleva
-- migrations/ (el companero) -- probablemente un archivo nuevo despues de
-- 003_productos.sql. Ver propuesta-de-productos.md en este mismo folder.
--
-- Se aplica al contenedor local `mesh-postgres` para que el companero tenga
-- todo el lado de Postgres a la vista y para poder desarrollar el backend
-- despues.
--
-- Aplicado en local el 2026-08-29.
-- Idempotente (IF NOT EXISTS / ON CONFLICT). Reversible con
-- `.\arrancar.ps1 -Reiniciar`.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. Dos estados nuevos en estado_producto
-- ------------------------------------------------------------
-- estado_producto ya existe (003_productos.sql) con borrador(1), activo(2),
-- inactivo(3). La smallserial esta en 3, asi que estos quedan 4 y 5.
--
-- en_revision -> un vendedor convencional propuso el producto; no circula
--                (la busqueda, la ficha y la compra filtran por 'activo').
-- rechazado   -> un admin o la tienda lo rechazo, con motivo en
--                rechazo_producto.
--
-- OJO: los productos que propone un vendedor viven SOLO en MongoDB
-- (POST /vendedor/productos no escribe en `productos` de Postgres desde el
-- giro multi-vendedor). El estado operativo es el string `estado` del
-- documento. Estas filas son para el ETL/catalogo relacional y la
-- coherencia del esquema; el backend no consulta estado_producto.
INSERT INTO estado_producto (estado_producto_nombre) VALUES
    ('en_revision'),
    ('rechazado')
ON CONFLICT (estado_producto_nombre) DO NOTHING;

COMMENT ON TABLE estado_producto IS
    'Catalogo de estados de una entrada del catalogo: borrador, activo, inactivo, en_revision, rechazado';


-- ------------------------------------------------------------
-- 2. propuesta_producto  --  pivote usuario <-> producto de Mongo
-- ------------------------------------------------------------
-- Une a quien propone un producto con el _id de su documento en Mongo, mas
-- la metadata de la aprobacion. NO significa propiedad: el giro
-- multi-vendedor quito el dueno del producto a proposito. Es atribucion del
-- ciclo de revision -- deja de importar en cuanto el producto es 'activo'
-- (ahi vuelve a ser una entrada compartida). Ver el ADR en
-- propuesta-de-productos.md.
CREATE TABLE IF NOT EXISTS propuesta_producto (
    id_propuesta_producto  bigserial PRIMARY KEY,

    -- Quien propuso. RESTRICT: no se borra un usuario con propuestas.
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    -- El _id del documento en MongoDB. SIN llave foranea: el catalogo se lee
    -- de otra base, igual que oferta.id_producto_mongo y pedido_producto.
    id_producto_mongo  bigint NOT NULL,

    -- La nota que el admin/tienda escribe AL APROBAR (opcional). El motivo
    -- del rechazo NO va aqui: va en rechazo_producto, que admite varias filas.
    comentario_aprobacion  text,

    fecha_propuesta    timestamptz NOT NULL DEFAULT now(),
    fecha_aprobacion   timestamptz,          -- NULL hasta que se aprueba
    id_usuario_aprobo  bigint REFERENCES usuarios(id_usuario)
                       ON DELETE RESTRICT,   -- NULL hasta que se aprueba

    -- Cada documento de Mongo lo propone un unico vendedor: proponer crea un
    -- documento nuevo con su propio _id.
    UNIQUE (id_producto_mongo)
);

COMMENT ON TABLE propuesta_producto IS
    'Quien propuso un producto del catalogo y su aprobacion. Atribucion del ciclo de revision, no propiedad';
COMMENT ON COLUMN propuesta_producto.id_producto_mongo IS
    'Del catalogo en MongoDB. NO es llave foranea: PostgreSQL no puede garantizarla contra otra base';
COMMENT ON COLUMN propuesta_producto.comentario_aprobacion IS
    'Nota opcional de quien aprueba. El motivo del rechazo va en rechazo_producto';
COMMENT ON COLUMN propuesta_producto.fecha_aprobacion IS
    'Cuando se aprobo. NULL = todavia en revision o rechazada';

-- "las propuestas de este vendedor": su panel de propuestas
CREATE INDEX IF NOT EXISTS idx_propuesta_producto_usuario
    ON propuesta_producto(id_usuario);


-- ------------------------------------------------------------
-- 3. rechazo_producto  --  espejo de rechazo_oferta
-- ------------------------------------------------------------
-- Cada vez que un admin/tienda rechaza una propuesta, con el motivo. Tabla
-- de solo insercion: si se rechaza, el vendedor la re-envia y se rechaza de
-- nuevo, quedan varias filas -- cada una con su fecha_rechazo.
--
-- Apunta a la PROPUESTA y no al id de Mongo: asi hay integridad referencial
-- de verdad, igual que rechazo_oferta apunta a oferta.
CREATE TABLE IF NOT EXISTS rechazo_producto (
    id_rechazo_producto  bigserial PRIMARY KEY,

    id_propuesta_producto  bigint NOT NULL
        REFERENCES propuesta_producto(id_propuesta_producto)
        ON DELETE RESTRICT,

    razon_rechazo  text NOT NULL CHECK (length(trim(razon_rechazo)) > 0),

    fecha_rechazo  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE rechazo_producto IS
    'Cada vez que se rechaza una propuesta de producto, con el motivo. Solo insercion';
COMMENT ON COLUMN rechazo_producto.razon_rechazo IS
    'Por que se rechazo. Obligatorio y no vacio';

-- "los rechazos de esta propuesta, del mas reciente al mas viejo"
CREATE INDEX IF NOT EXISTS idx_rechazo_producto_propuesta
    ON rechazo_producto(id_propuesta_producto, fecha_rechazo DESC);

COMMIT;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT id_estado_producto, estado_producto_nombre FROM estado_producto ORDER BY id_estado_producto;
SELECT to_regclass('public.propuesta_producto') AS propuesta_producto,
       to_regclass('public.rechazo_producto')   AS rechazo_producto;
SELECT count(*) AS propuestas FROM propuesta_producto;
SELECT count(*) AS rechazos   FROM rechazo_producto;
