-- ============================================================
-- 048_buscador_respaldo.sql
-- ============================================================
-- El buscador puede salir de PostgreSQL cuando Elasticsearch no responde.
--
-- El buscador de productos vive en Elasticsearch (mesh_productos): tolera
-- errores de tecleo ("labtop" encuentra "laptop"), no distingue tildes y arma
-- los filtros de la pagina /buscar. Con Elasticsearch caido el buscador daba
-- 503 a los 22 segundos (medido el 2026-10-19, docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md)
-- y el profesor pidio que la tienda siga respondiendo con las bases que
-- quedan.
--
-- La copia del catalogo en PostgreSQL (029 y 047) ya tiene el nombre, la
-- descripcion, el estado, la categoria y las variantes de cada producto, y los
-- precios, el stock y las notas ya viven aqui (oferta y resena). Lo que faltaba
-- era buscar texto parecido, y eso lo dan dos extensiones que trae la imagen de
-- PostgreSQL:
--
--   unaccent       quita las tildes: "audifonos" encuentra "Audifonos".
--   fuzzystrmatch  la distancia de Levenshtein: cuantas letras hay que
--                  cambiar para pasar de una palabra a otra. "labtop" esta a
--                  1 de "laptop".
--   pg_trgm        indices por trigramas (pedazos de tres letras) para que
--                  comparar nombres no recorra la tabla entera.
--
-- mesh_normalizar() es la forma en que se compara todo: sin tildes y en
-- minusculas, como el analizador espanol_llano del indice de Elasticsearch
-- (lowercase y asciifolding). Va en una funcion IMMUTABLE porque unaccent() no
-- lo es (depende del diccionario que este cargado) y un indice solo acepta
-- funciones inmutables; fijando el diccionario por nombre, el resultado ya no
-- cambia.
--
-- mesh_coincide(palabra, texto) dice cuanto se parece una palabra buscada a la
-- mas parecida de un texto, con la misma tolerancia que `fuzziness: AUTO` de
-- Elasticsearch: palabras de 1 o 2 letras tienen que ser iguales, de 3 a 5
-- aceptan 1 letra distinta y de 6 o mas, 2. Devuelve 1 si es igual, 0.8 con una
-- letra distinta, 0.6 con dos y 0 si no se parece. "asdffff" no se parece a
-- ninguna palabra del catalogo.
--
-- Lo usa backend/src/helpers/buscador-respaldo.ts. Es idempotente: arrancar.ps1
-- lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE OR REPLACE FUNCTION mesh_normalizar(texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
STRICT
AS $$
    SELECT lower(public.unaccent('public.unaccent'::regdictionary, texto));
$$;

COMMENT ON FUNCTION mesh_normalizar(text) IS
  'Texto sin tildes y en minusculas, para buscar en la copia del catalogo cuando Elasticsearch no responde (048).';

-- `palabra` y `texto` ya normalizados. Las palabras del texto se parten como el
-- tokenizador standard: por todo lo que no sea letra o numero.
CREATE OR REPLACE FUNCTION mesh_coincide(palabra text, texto text)
RETURNS real
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
STRICT
AS $$
    WITH tope AS (
        SELECT CASE WHEN length(palabra) <= 2 THEN 0
                    WHEN length(palabra) <= 5 THEN 1
                    ELSE 2 END AS n
    )
    SELECT COALESCE(MAX(CASE d WHEN 0 THEN 1.0 WHEN 1 THEN 0.8 ELSE 0.6 END), 0)::real
      FROM (
        -- levenshtein_less_equal deja de contar al pasar el tope, y una palabra
        -- cuyo largo ya difiere en mas del tope ni se mide.
        SELECT public.levenshtein_less_equal(palabra, p, tope.n) AS d, tope.n
          FROM regexp_split_to_table(texto, '[^[:alnum:]]+') AS p, tope
         WHERE p <> '' AND abs(length(p) - length(palabra)) <= tope.n
      ) medidas
     WHERE d <= n;
$$;

COMMENT ON FUNCTION mesh_coincide(text, text) IS
  'Cuanto se parece una palabra a la mas parecida de un texto, con la tolerancia de fuzziness AUTO de Elasticsearch: 1 igual, 0.8 y 0.6 con una o dos letras distintas, 0 nada (048).';

-- Por trigramas sobre lo que se busca: el nombre y las variantes. La
-- descripcion se compara tambien, pero sin indice: es texto largo y con mil
-- productos el recorrido entero tarda milesimas.
CREATE INDEX IF NOT EXISTS idx_producto_catalogo_nombre_trgm
    ON producto_catalogo USING gin (mesh_normalizar(nombre) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_variante_catalogo_nombre_trgm
    ON variante_catalogo USING gin (mesh_normalizar(nombre_variante) gin_trgm_ops);

COMMIT;
