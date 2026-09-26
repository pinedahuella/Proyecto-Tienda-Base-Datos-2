-- ============================================================
-- buscador-facetado-clickhouse.sql (REFERENCIA, no se aplica sola)
-- ============================================================
-- Columnas nuevas en `busqueda_realizada` y `busqueda_clic` para saber que
-- facetas se usaron en una busqueda, o estaban activas cuando alguien hizo
-- clic en un resultado (Entrega 3, GET /buscador/productos/facetado).
--
-- NO son tablas nuevas: se extienden las dos que ya existen, porque un
-- facetado sigue siendo "una busqueda" o "un clic" -- separar en tablas
-- aparte partiria el mismo analisis por termino/fecha en dos.
--
-- Van con DEFAULT (0 o arreglo vacio) para que las filas que YA existen
-- (buscadas antes de este cambio, y las que siga escribiendo
-- GET /buscador/productos, que no es facetado) queden consistentes sin
-- reprocesarlas: `facetada = 0` en todas esas, como si nunca hubiera
-- elegido ninguna faceta -- que es exactamente lo que paso.
--
-- Se guarda lo que el CLIENTE eligio (los mismos valores crudos de
-- `?categoria=7,9&precio=250-500&...`), no lo que el backend resolvio
-- (por ejemplo, `calificacion` guarda el arreglo elegido, no el minimo ya
-- calculado) -- mas simple, y no se pierde informacion si mas adelante se
-- analiza distinto.
--
-- Idempotente: `ADD COLUMN IF NOT EXISTS` no falla si ya se aplico antes.
-- Aplicado a mano en la base LOCAL para desarrollar el backend en paralelo
-- (`docker exec -i mesh-clickhouse clickhouse-client --database
-- mesh_eventos --multiquery < ...`). Le queda al compañero sumar estas
-- mismas columnas a `clickhouse/001_esquema.sql` (el real, que se re-aplica
-- solo en cada arranque).
-- ============================================================

ALTER TABLE busqueda_realizada
    ADD COLUMN IF NOT EXISTS facetada     UInt8         DEFAULT 0,
    ADD COLUMN IF NOT EXISTS categorias   Array(UInt32) DEFAULT [],
    ADD COLUMN IF NOT EXISTS precios      Array(String) DEFAULT [],
    ADD COLUMN IF NOT EXISTS calificaciones Array(String) DEFAULT [],
    ADD COLUMN IF NOT EXISTS disponible   UInt8         DEFAULT 0;

ALTER TABLE busqueda_clic
    ADD COLUMN IF NOT EXISTS facetada     UInt8         DEFAULT 0,
    ADD COLUMN IF NOT EXISTS categorias   Array(UInt32) DEFAULT [],
    ADD COLUMN IF NOT EXISTS precios      Array(String) DEFAULT [],
    ADD COLUMN IF NOT EXISTS calificaciones Array(String) DEFAULT [],
    ADD COLUMN IF NOT EXISTS disponible   UInt8         DEFAULT 0;
