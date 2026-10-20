-- ============================================================
-- 047_catalogo_respaldo.sql
-- ============================================================
-- La copia del catalogo (029) alcanza para que la tienda se vea sin MongoDB.
--
-- La 029 copio a PostgreSQL solo lo que necesita la compra: el nombre del
-- producto y el nombre, el estado y la portada de cada variante. Con eso se
-- compra con Mongo caido, pero el catalogo y la ficha de un producto seguian
-- saliendo de Mongo y con Mongo caido daban 503 (medido el 2026-10-19, ver
-- docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md).
--
-- Para mostrar un producto sin Mongo faltan cuatro datos, y se agregan aqui:
--
--   estado          sin el, el respaldo mostraria borradores, propuestas en
--                   revision y productos dados de baja: lo publico es solo
--                   'activo' (ESTADO_PRODUCTO_VISIBLE)
--   id_categoria    la ficha pinta la categoria y su padre, y el catalogo
--                   filtra por ella. Los nombres salen de `categorias`, que es
--                   de donde Mongo copia las suyas, con los mismos ids
--   descripcion     el texto de la ficha
--   fecha_creacion  la del documento de Mongo
--
-- Lo demas de la tarjeta (precios, stock, vendedores, descuento y notas) ya
-- vive en PostgreSQL (oferta y resena) y el respaldo lo calcula en el momento.
-- Lo que se queda solo en Mongo son las caracteristicas: el respaldo muestra el
-- producto sin ellas (helpers/catalogo-respaldo.ts del backend).
--
-- Mongo sigue mandando. Las columnas las escriben los mismos que ya escribian
-- la copia: el backend al crear, editar o revisar un producto, y el paso 7e de
-- arrancar.ps1 (etl/extraer_catalogo_postgres.js) para lo que entra por fuera.
-- En una base que ya tenia la copia, las columnas nacen vacias y el siguiente
-- arranque las llena. Mientras tanto el respaldo no muestra esos productos
-- (sin estado no puede saber si son publicos).
--
-- Es idempotente (IF NOT EXISTS): arrancar.ps1 lo vuelve a correr en cada
-- arranque.
-- ============================================================

BEGIN;

ALTER TABLE producto_catalogo ADD COLUMN IF NOT EXISTS estado         text        NULL;
ALTER TABLE producto_catalogo ADD COLUMN IF NOT EXISTS id_categoria   bigint      NULL;
ALTER TABLE producto_catalogo ADD COLUMN IF NOT EXISTS descripcion    text        NULL;
ALTER TABLE producto_catalogo ADD COLUMN IF NOT EXISTS fecha_creacion timestamptz NULL;

-- El listado del respaldo filtra siempre por estado y casi siempre por
-- categoria.
CREATE INDEX IF NOT EXISTS idx_producto_catalogo_estado_categoria
    ON producto_catalogo (estado, id_categoria);

COMMENT ON COLUMN producto_catalogo.estado IS
  'Estado del producto en Mongo (activo, inactivo, en_revision, rechazado...). Solo activo es publico. NULL = todavia no copiado.';
COMMENT ON COLUMN producto_catalogo.id_categoria IS
  'categoria.id_categoria del documento de Mongo. Mismo id que categorias.id_categoria.';
COMMENT ON COLUMN producto_catalogo.descripcion IS
  'Descripcion del producto, copiada de Mongo, para la ficha cuando Mongo no responde.';
COMMENT ON COLUMN producto_catalogo.fecha_creacion IS
  'fecha_creacion del documento de Mongo.';

COMMIT;
