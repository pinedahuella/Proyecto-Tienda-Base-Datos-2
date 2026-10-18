# Búsquedas sin resultados, con las formas de escribir lo mismo juntas

**Fecha:** 2026-10-16 (noche).
**Alcance:** `backend/`. La columna nueva de ClickHouse está aplicada en local
(`plan pendiente/busquedas-sin-resultados.sql`); en el esquema real
(`clickhouse/001_esquema.sql`) la agrega el compañero.

## Qué se hizo

- `busqueda_realizada.termino_normalizado`: columna `MATERIALIZED` (minúsculas,
  sin tildes, sin espacios de más). El término original no se toca.
- `GET /admin/eventos/busquedas-sin-resultados`: lo más buscado con 0
  resultados y sin filtros, agrupado por el término normalizado y por errores de
  tecleo (`editDistanceUTF8`), en sesiones distintas. En vivo contra ClickHouse,
  sin Redis (ruta de admin).

Se descartó guardar las búsquedas en Elasticsearch: su análisis une formas de
escribir, no significados, no agrupa términos entre sí, y contar eventos es
trabajo de ClickHouse.

## Relación con lo que ya había

`GET /admin/eventos/busquedas-sin-respuesta` (T3, 2026-09-25) ya marcaba
`no_tenemos` con una normalización mínima (minúsculas y espacios en las puntas).
La ruta nueva es la versión completa de esa parte; T3 no se tocó.

## Pruebas

Búsquedas fantasma en ClickHouse (variantes, errores de tecleo, sesiones
repetidas, palabras cortas, con resultados, con filtros, viejas, de otro lote) y
una prueba por HTTP con búsquedas reales. Detalle en
`elementos Generales/endpoints/endpoints-eventos.md`. Fantasmas borrados.
`tsc` y eslint limpios.
