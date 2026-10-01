-- ============================================================
-- 029_catalogo_en_postgres.sql
-- ============================================================
-- Comprar sin MongoDB, la copia del catalogo. Es el catalogo-en-postgres.sql de
-- Jose David (6f89237), hecho migracion; el plan con lo que hace el backend
-- esta en backend/elementos Generales/plan pendiente/catalogo-en-postgres.md.
--
-- El checkout leia de MongoDB el nombre del producto, el de la variante y el
-- estado de la variante, y con Mongo caido la compra daba 503 aunque Mongo no
-- participe del COMMIT (fila 11 de docs/CONSISTENCIA-CHECKOUT.md). Se copia a
-- PostgreSQL SOLO lo que la compra necesita, normalizado:
--
--   producto_catalogo   un renglon por producto     (el nombre)
--   variante_catalogo   un renglon por variante     (nombre, estado e imagen de portada)
--
-- y NO como columnas de `oferta`: el nombre es de la variante, no de la oferta,
-- y una variante puede tener muchas ofertas (multi-vendedor). En `oferta` se
-- repetiria N veces y un renombre tocaria N filas.
--
-- Mongo SIGUE siendo la fuente del catalogo. Estas dos tablas son una copia:
-- la escribe el backend al crear y editar un producto, y el paso 7e de
-- arrancar.ps1 la pone al dia entera desde MongoDB (etl/extraer_catalogo_postgres.js).
--
-- La llave foranea oferta -> variante_catalogo (su etapa 2) NO va todavia: pide
-- que migrations/datos/ y el ETL inserten el catalogo antes que las ofertas.
--
-- Es idempotente (IF NOT EXISTS): arrancar.ps1 lo vuelve a correr en cada
-- arranque.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS producto_catalogo (
    -- El _id del producto en Mongo. SIN autoincremento: el id lo reparte el
    -- catalogo, aqui solo se copia.
    id_producto_mongo   bigint PRIMARY KEY,
    nombre              text   NOT NULL CHECK (btrim(nombre) <> ''),
    fecha_actualizacion timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS variante_catalogo (
    id_producto_mongo          bigint NOT NULL
                               REFERENCES producto_catalogo(id_producto_mongo)
                               ON DELETE CASCADE,
    id_producto_variante_mongo bigint NOT NULL,
    nombre_variante            text   NOT NULL CHECK (btrim(nombre_variante) <> ''),
    -- 'activa' / 'inactiva', tal cual esta en Mongo (variantes.estado).
    estado                     text   NOT NULL CHECK (estado IN ('activa', 'inactiva')),
    -- Solo la PORTADA (variantes.imagenes[0] de Mongo), una sola: es lo que
    -- pinta la linea del carrito. NULL = la variante no tiene imagen. Es una
    -- URL/ruta tal cual esta en Mongo, no el archivo.
    imagen                     text   NULL,
    fecha_actualizacion        timestamptz NOT NULL DEFAULT now(),

    -- El PAR identifica la variante, no el id solo: en Mongo las variantes
    -- van embebidas y dos productos pueden repetir el id de variante (ver
    -- el comentario de oferta en 005_ofertas.sql).
    PRIMARY KEY (id_producto_mongo, id_producto_variante_mongo)
);

COMMENT ON TABLE producto_catalogo IS
  'Copia del nombre del producto del catalogo de MongoDB, para que el checkout no dependa de Mongo. Mongo manda; la mantiene el backend.';
COMMENT ON COLUMN producto_catalogo.id_producto_mongo IS
  'El _id del producto en MongoDB. No se autogenera aqui.';
COMMENT ON TABLE variante_catalogo IS
  'Copia del nombre y del estado de cada variante de MongoDB. oferta apunta aqui por el par (id_producto_mongo, id_producto_variante_mongo).';
-- Si la tabla ya existia sin la columna (aplicada antes de agregar la imagen)
ALTER TABLE variante_catalogo ADD COLUMN IF NOT EXISTS imagen text NULL;

COMMENT ON COLUMN variante_catalogo.imagen IS
  'Portada de la variante (primera de variantes.imagenes en Mongo). Para que construirSnapshot() arme la linea del carrito de Redis sin ir a Mongo.';
COMMENT ON COLUMN variante_catalogo.estado IS
  'activa / inactiva, como en Mongo. Una variante inactiva no se puede comprar.';

COMMIT;
