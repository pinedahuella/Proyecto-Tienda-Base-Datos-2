-- ============================================================
-- 027 -- productos_similares() escrita para que el indice HNSW se pueda usar
-- ============================================================
--
-- La 024 compara el vector de cada producto contra el del producto base con un
-- JOIN (`FROM producto_vector v, base`). Asi escrita, el `ORDER BY v.vector <=>
-- base.vector` tiene del lado derecho una columna de otra tabla, no un valor
-- fijo, y un indice HNSW solo sirve para ordenar por distancia a UN vector
-- conocido. Resultado, medido el 2026-09-26: la funcion recorria las 3105 filas
-- (Seq Scan, unos 22 ms) en todas las llamadas, y el indice
-- idx_producto_vector_hnsw no se usaba nunca, con 3105 productos o con un
-- millon.
--
-- Aqui el vector base se lee primero a una variable y la consulta ordena por
-- distancia a ese valor, asi el indice se puede usar. Pero con eso solo, el
-- planificador seguia eligiendo recorrer la tabla: estima que pedir 200
-- candidatos a 3105 filas sale mas barato comparando contra todas. Se midio y
-- la estimacion esta mal. Sobre los 3103 productos activos, el 2026-09-26:
--
--                      tiempo total   por producto   los 6 iguales al exacto
--   recorrer todo        100 s          32 ms          (es el exacto)
--   indice HNSW          11,7 s         3,8 ms         3099 de 3103, 99,98 %
--
-- Ninguno devolvio menos de 6, y en los 4 distintos cambia un solo producto
-- de los seis. Por eso la funcion lleva `enable_seqscan = off`: solo vale
-- mientras corre, no toca ninguna otra consulta, y no prohibe recorrer la
-- tabla, solo lo encarece para que el planificador prefiera el indice.
--
-- hnsw.iterative_scan = relaxed_order (pgvector 0.8): si los filtros de
-- activo y de grupo descartan candidatos, el indice sigue buscando en vez de
-- devolver menos de los pedidos.
--
-- Mismo nombre, mismos parametros y la misma forma de resultado que la 024,
-- asi que el backend (SimilaresService) no cambia. La 024 no se edita porque
-- ya corrio.

CREATE OR REPLACE FUNCTION productos_similares(p_id_producto bigint, p_limite int DEFAULT 6)
RETURNS TABLE (id_producto bigint, similitud double precision)
LANGUAGE plpgsql
STABLE
SET hnsw.ef_search = 200
SET hnsw.iterative_scan = 'relaxed_order'
SET enable_seqscan = off
AS $fn$
DECLARE
    v_base  vector;
    v_grupo text;
BEGIN
    SELECT pv.vector, pv.grupo INTO v_base, v_grupo
      FROM producto_vector pv
     WHERE pv.id_producto = p_id_producto;

    IF v_base IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH cercanos AS (
        SELECT v.id_producto, v.grupo, v.vector <=> v_base AS distancia
          FROM producto_vector v
         WHERE v.id_producto <> p_id_producto
           AND v.activo
           AND v.grupo IS DISTINCT FROM v_grupo
         ORDER BY v.vector <=> v_base
         LIMIT 200
    ), uno_por_grupo AS (
        SELECT DISTINCT ON (COALESCE(c.grupo, c.id_producto::text)) c.id_producto, c.distancia
          FROM cercanos c
         ORDER BY COALESCE(c.grupo, c.id_producto::text), c.distancia
    )
    SELECT u.id_producto, 1 - u.distancia
      FROM uno_por_grupo u
     ORDER BY u.distancia
     LIMIT GREATEST(1, LEAST(p_limite, 24));
END;
$fn$;

COMMENT ON FUNCTION productos_similares(bigint, int) IS
    'Los productos activos mas parecidos por contenido. Vacio si el producto no tiene vector. Usa el indice HNSW (027)';
