-- ============================================================
-- busquedas-sin-resultados.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- ClickHouse (mesh_eventos), no PostgreSQL. Esto NO es el esquema real: el
-- real es clickhouse/001_esquema.sql, que lleva el companero. Agregarle estas
-- dos sentencias al final, junto a los demas ALTER de busqueda_realizada.
--
-- Para GET /admin/tendencias/busquedas-sin-resultados: lo mas buscado que no
-- encontro nada, agrupando las formas de escribir lo mismo.
--
-- `termino` se queda tal como lo escribio la persona. `termino_normalizado`
-- es la version para agrupar: minusculas, sin tildes ni dieresis (la n con
-- virgulilla queda n, como el analizador del buscador) y sin espacios de mas.
-- Es MATERIALIZED: ClickHouse la calcula sola en cada INSERT, asi que el
-- backend sigue mandando solo `termino` y la regla vive en un solo lugar
-- (nadie que inserte puede normalizar distinto). No sale en un SELECT * ;
-- hay que nombrarla.
--
-- Aplicado en local con el cliente HTTP de ClickHouse. Es idempotente
-- (IF NOT EXISTS); MATERIALIZE COLUMN llena las filas que ya existian.
-- ============================================================

ALTER TABLE busqueda_realizada
    ADD COLUMN IF NOT EXISTS termino_normalizado String
    MATERIALIZED replaceRegexpAll(
        trimBoth(replaceRegexpAll(lowerUTF8(normalizeUTF8NFD(termino)), '\\p{Mn}', '')),
        '\\s+', ' ');

ALTER TABLE busqueda_realizada
    MATERIALIZE COLUMN termino_normalizado
    SETTINGS mutations_sync = 2;
