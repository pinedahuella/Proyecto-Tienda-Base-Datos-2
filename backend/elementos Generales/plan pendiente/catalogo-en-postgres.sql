-- ============================================================
-- catalogo-en-postgres.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada despues de la ultima migracion real
-- existente (hoy 028_vencimiento_oferta.sql, asi que esta seria la 029) --
-- mismo workflow de siempre (ver vencimiento-automatico-oferta.sql, mismo
-- folder, para el precedente). El plan completo esta en
-- catalogo-en-postgres.md.
--
-- Que resuelve: el checkout lee de MongoDB el nombre del producto, el de la
-- variante y el estado de la variante, y con Mongo caido la compra da 503
-- aunque Mongo no participe del COMMIT (fila 11 de
-- docs/CONSISTENCIA-CHECKOUT.md). Se copia a PostgreSQL SOLO lo que la
-- compra necesita, normalizado:
--
--   producto_catalogo   un renglon por producto     (el nombre)
--   variante_catalogo   un renglon por variante     (nombre, estado e imagen de portada)
--
-- y NO como columnas de `oferta`: el nombre depende de la variante, no de la
-- oferta, y una variante puede tener muchas ofertas (multi-vendedor). En
-- `oferta` se repetiria N veces y un renombre tendria que tocar N filas.
--
-- Mongo SIGUE siendo la fuente del catalogo. Estas dos tablas son una copia
-- que mantiene el backend (ver el .md); solo la portada de la variante se copia
-- (para el carrito de Redis); el resto de imagenes y todo lo demas se quedan
-- en Mongo.
--
-- Etapa 1 (este archivo): las dos tablas. Se siembran desde Mongo con
-- catalogo-en-postgres-sembrar.cjs.
-- Etapa 2 (al final, comentada): la llave foranea oferta -> variante_catalogo.
-- NO se aplica hasta que el backend sincronice al crear/editar productos;
-- si no, crear una oferta sobre un producto recien creado la rechazaria.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS) y reversible: un `.\arrancar.ps1 -Reiniciar`
-- reconstruye la base desde las migraciones reales y borra esto.
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

-- ============================================================
-- ETAPA 2 -- NO aplicar todavia (ver el encabezado)
-- ============================================================
-- Devuelve a PostgreSQL la integridad que 005_ofertas.sql daba por perdida:
-- una oferta sobre una variante que no existe en el catalogo.
--
-- Requisitos antes de correrla:
--   1. variante_catalogo sembrada (cada par de oferta existe).
--   2. El backend sincroniza producto_catalogo/variante_catalogo al crear y
--      editar productos, ANTES de que un vendedor pueda ofertar.
--   3. etl/ y migrations/datos/ insertan el catalogo antes que las ofertas.
--
-- ALTER TABLE oferta
--   ADD CONSTRAINT fk_oferta_variante_catalogo
--   FOREIGN KEY (id_producto_mongo, id_producto_variante_mongo)
--   REFERENCES variante_catalogo (id_producto_mongo, id_producto_variante_mongo)
--   ON DELETE RESTRICT;
