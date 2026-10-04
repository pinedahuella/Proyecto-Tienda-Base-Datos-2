-- ============================================================
-- 036_sin_producto_vector.sql
-- ============================================================
-- Se retira la recomendacion semantica de PostgreSQL. Desde fa3281c de Jose
-- David el vector de cada producto vive en el documento de mesh_productos de
-- Elasticsearch (campo `vector`, dense_vector de 768 con similitud coseno), y
-- SimilaresService le pide los parecidos a Elasticsearch con kNN. Ni el
-- backend ni etl/cargar_vectores.ps1 vuelven a leer ni escribir
-- producto_vector, y productos_similares() no la llama nadie. El por que esta
-- en backend/cambio_propuestas/2026-10-02_2010-vectores-a-elasticsearch.md y
-- en el ADR-10 de docs/ARQUITECTURA.md.
--
--
-- LA 024 Y LA 027 SE QUEDAN COMO ESTAN
-- ============================================================
-- Una migracion corrida no se edita (migrations/README.md). Como el esquema se
-- reejecuta en cada arranque, la 024 vuelve a crear producto_vector VACIA y la
-- 027 vuelve a crear la funcion, y esta las quita otra vez justo despues. Es
-- un CREATE y un DROP de una tabla sin filas, un par de milisegundos, y deja
-- todas las bases iguales: la nueva, la que tenia los 3105 vectores y la de
-- quien ya las habia borrado a mano.
--
-- La extension `vector` NO se quita: la 024 la vuelve a pedir en cada
-- arranque, y la imagen pgvector/pgvector:pg18 del compose la trae igual.
-- Cambiar la imagen toca el volumen de datos y no hace falta para nada.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

DROP FUNCTION IF EXISTS productos_similares(bigint, int);
DROP TABLE IF EXISTS producto_vector;

DO $verificar$
BEGIN
    IF to_regclass('public.producto_vector') IS NOT NULL THEN
        RAISE EXCEPTION 'producto_vector sigue existiendo';
    END IF;
    IF to_regprocedure('productos_similares(bigint, integer)') IS NOT NULL THEN
        RAISE EXCEPTION 'productos_similares() sigue existiendo';
    END IF;
END
$verificar$;
