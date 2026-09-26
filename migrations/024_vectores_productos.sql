-- ============================================================
-- 024_vectores_productos.sql
-- ============================================================
-- La recomendacion por similitud de contenido de la Entrega final. Cada
-- producto guarda un vector que representa el significado de su nombre, su
-- categoria y su descripcion, y dos productos son parecidos si sus vectores
-- apuntan hacia el mismo lado.
--
--
-- POR QUE AQUI Y NO EN UN COMPONENTE APARTE
-- ============================================================
-- El enunciado deja elegir entre una extension de la base relacional o un
-- componente vectorial dedicado. Se eligio pgvector sobre el PostgreSQL que
-- ya corre, que ademas viene en la imagen desde la Entrega 1
-- (`pgvector/pgvector:pg18` en docker-compose.yml). Con unos miles de
-- productos un indice HNSW contesta en milisegundos, y una base mas solo para
-- esto seria otro contenedor, otra copia de los ids y otro ETL que se puede
-- quedar atras.
--
--
-- SIN LLAVE FORANEA, A PROPOSITO
-- ============================================================
-- El producto vive en MongoDB, y hay productos que existen SOLO ahi (los que
-- publica un vendedor desde el panel). `id_producto` es el `_id` de Mongo, el
-- mismo trato que `pedido_producto` en la Entrega 1. Una FK a `productos`
-- dejaria fuera justo esos.
--
--
-- QUIEN LA LLENA
-- ============================================================
-- `etl/cargar_vectores.ps1`, que corre dentro de `arrancar.ps1`. Lee los
-- productos de Mongo, le pide los vectores a Ollama con el modelo
-- `paraphrase-multilingual` (768 dimensiones, entiende espanol) y los escribe
-- aqui. Solo calcula los que faltan o cuyo texto cambio, por eso guarda el
-- hash del texto.
--
--
-- COMO SE CONSULTA
-- ============================================================
-- `productos_similares(id, limite)` devuelve los mas parecidos a un producto,
-- solo activos y sin el propio. Es lo unico que tiene que llamar la ruta del
-- backend.
--
--
-- LAS COPIAS NO CUENTAN COMO PARECIDOS
-- ============================================================
-- El generador de productos (`-Productos N` de arrancar.ps1) copia un producto
-- del catalogo con otro sufijo en el nombre y la MISMA descripcion. Sin
-- cuidarlo, los seis parecidos del Telefono Ceibo Lite eran seis copias del
-- Telefono Ceibo Lite. `grupo` es el md5 de la categoria y la descripcion, sin
-- el nombre, y la funcion quita el grupo del propio producto y devuelve uno
-- solo por grupo. Se agrego el mismo 2026-09-25 con ADD COLUMN IF NOT EXISTS,
-- asi que una base que ya tenia la tabla la recibe en el siguiente arranque.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS producto_vector (
    id_producto    bigint PRIMARY KEY,
    modelo         varchar(80)  NOT NULL,
    texto_hash     char(32)     NOT NULL,
    activo         boolean      NOT NULL DEFAULT true,
    vector         vector(768)  NOT NULL,
    fecha_calculo  timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE producto_vector IS 'Vector de contenido de cada producto del catalogo, para la recomendacion semantica';
COMMENT ON COLUMN producto_vector.id_producto IS 'El _id del producto en MongoDB. Sin FK, hay productos que solo existen en Mongo';
COMMENT ON COLUMN producto_vector.texto_hash IS 'md5 del texto con que se calculo el vector. Si cambia, el ETL lo recalcula';
COMMENT ON COLUMN producto_vector.activo IS 'Copia del estado en Mongo. Solo los activos se recomiendan';

ALTER TABLE producto_vector ADD COLUMN IF NOT EXISTS grupo char(32);
COMMENT ON COLUMN producto_vector.grupo IS 'md5 de categoria y descripcion, sin el nombre. Las copias del mismo producto comparten grupo y no se recomiendan entre si';

-- Distancia coseno, la que usa el modelo. HNSW no necesita entrenarse con los
-- datos ya cargados, a diferencia de IVFFlat, asi que se puede crear vacio.
CREATE INDEX IF NOT EXISTS idx_producto_vector_hnsw
    ON producto_vector USING hnsw (vector vector_cosine_ops);


-- Primero los 200 mas cercanos por el indice, despues uno por grupo. El
-- indice HNSW por defecto solo mira 40 candidatos (hnsw.ef_search), y con los
-- filtros de activo y de grupo podian quedar menos de los pedidos, por eso la
-- funcion lo sube a 200 solo mientras corre.
CREATE OR REPLACE FUNCTION productos_similares(p_id_producto bigint, p_limite int DEFAULT 6)
RETURNS TABLE (id_producto bigint, similitud double precision)
LANGUAGE sql
STABLE
SET hnsw.ef_search = 200
AS $fn$
    WITH base AS (
        SELECT vector, grupo FROM producto_vector WHERE id_producto = p_id_producto
    ), cercanos AS (
        SELECT v.id_producto, v.grupo, v.vector <=> base.vector AS distancia
          FROM producto_vector v, base
         WHERE v.id_producto <> p_id_producto
           AND v.activo
           AND v.grupo IS DISTINCT FROM base.grupo
         ORDER BY v.vector <=> base.vector
         LIMIT 200
    ), uno_por_grupo AS (
        SELECT DISTINCT ON (COALESCE(grupo, id_producto::text)) id_producto, distancia
          FROM cercanos
         ORDER BY COALESCE(grupo, id_producto::text), distancia
    )
    SELECT id_producto, 1 - distancia
      FROM uno_por_grupo
     ORDER BY distancia
     LIMIT GREATEST(1, LEAST(p_limite, 24));
$fn$;

COMMENT ON FUNCTION productos_similares(bigint, int) IS
    'Los productos activos mas parecidos por contenido. Vacio si el producto no tiene vector';
