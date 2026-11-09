-- ============================================================
-- 055_vector_caracteristicas.sql
-- ============================================================
-- Parecidos a este por mas campos (2026-11-08). Hasta hoy el vector de cada
-- producto salia de un solo texto, "nombre. Categoria X. descripcion". El
-- profesor pidio la similitud por mas campos, y cada producto ya guarda en
-- MongoDB sus caracteristicas (marca, potencia, memoria, talla, color...).
--
-- Van en un vector APARTE y no dentro del mismo texto, por dos razones:
--   - Cada parte pesa lo que se decide al ordenar. El de nombre, categoria y
--     descripcion manda, y el de caracteristicas suma (similares.service.ts).
--   - Si un producto no tiene caracteristicas, o su vector todavia no se
--     calculo, el general sigue igual y esa parte simplemente no cuenta.
--
-- Lo calcula el mismo worker que el general (VectoresSyncService), con la
-- bandera pendiente_vector de MongoDB, y solo llama a Ollama si cambio la
-- huella del texto. Si MongoDB no contesta, los dos vectores se quedan como
-- estaban hasta que vuelva: los parecidos se siguen calculando en PostgreSQL.
--
--   vector_caracteristicas   el vector del texto de caracteristicas, o NULL si
--                            el producto no tiene ninguna
--   caracteristicas_hash     md5 de ese texto. NULL quiere decir que todavia no
--                            se calculo; el md5 del texto vacio, que se calculo
--                            y no tiene caracteristicas
--
-- No lleva indice: el indice HNSW del vector general trae los candidatos, y
-- este solo se compara contra esos pocos, por su id.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

ALTER TABLE vector_producto
    ADD COLUMN IF NOT EXISTS vector_caracteristicas vector(768) NULL,
    ADD COLUMN IF NOT EXISTS caracteristicas_hash   char(32)    NULL;

COMMENT ON COLUMN vector_producto.vector_caracteristicas IS
    'El vector de Ollama del texto de caracteristicas del producto y de sus variantes, ordenadas por nombre ("Marca Aurora. Memoria RAM 16 GB, 32 GB..."). NULL si no tiene ninguna. Suma al puntaje de Parecidos a este, el general manda';
COMMENT ON COLUMN vector_producto.caracteristicas_hash IS
    'md5 del texto de caracteristicas con que se calculo. NULL si todavia no se calculo; el md5 del texto vacio si no tiene caracteristicas';

COMMIT;
