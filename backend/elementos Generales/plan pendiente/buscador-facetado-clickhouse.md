# Analitica del buscador facetado en ClickHouse

**Estado (2026-09-26, actualizado la misma noche): CERRADO de este lado,
probado en vivo.** Columnas nuevas aplicadas en la base LOCAL,
`EventosService.registrarBusqueda()`/`registrarClicBusqueda()` las
llenan, `GET /buscador/productos/facetado` y `POST /eventos/busqueda-clic`
las mandan, y las tres rutas de ranking
(`GET /admin/eventos/categorias-mas-buscadas` / `precios-mas-buscados` /
`calificaciones-mas-buscadas`) ya las consultan. Detalle completo y
pruebas en `endpoints-buscador.md` y `endpoints-eventos.md`. Solo queda lo
del compañero, ver el final de este documento.

## Por que

`GET /buscador/productos/facetado` (Entrega 3, ver `endpoints-buscador.md`
y `services/buscador/facetado.service.ts`) deja filtrar por categoria,
rango de precio, calificacion minima y disponibilidad. Hoy, si se registra
la busqueda en ClickHouse, se hace exactamente igual que una busqueda
simple (`EventosService.registrarBusqueda()`, tabla `busqueda_realizada`):
se pierde que facetas se usaron. La idea del usuario: guardar eso, para
poder analizar despues que filtros usa la gente de verdad (por ejemplo,
"la mayoria filtra por categoria, casi nadie por calificacion").

## Decisiones de diseño

- **Se extienden las dos tablas que ya existen** (`busqueda_realizada`,
  `busqueda_clic`), no se crean tablas nuevas -- un facetado sigue siendo
  "una busqueda" o "un clic sobre un resultado", solo con mas detalle.
  Separar en tablas aparte partiria en dos el mismo analisis por
  termino/fecha (`ORDER BY (termino, fecha)` en ambas).
- **`busqueda_clic` recibe las mismas columnas que `busqueda_realizada`**
  (pedido explicito del usuario, "igual clic busqueda"): un clic pasa
  siempre dentro de un resultado de busqueda, facetado o no, y saber que
  facetas estaban activas en ESE momento es tan util como saberlo para la
  busqueda misma -- por ejemplo, "los clics con `categoria` filtrada tienen
  mejor posicion promedio que sin filtrar".
- **Se guarda lo que el cliente ELIGIO, no lo que el backend resolvio.**
  `calificaciones` guarda el arreglo crudo de la query
  (`?calificacion=4-o-mas,3-o-mas` -> `['4-o-mas','3-o-mas']`), no el
  minimo ya calculado que usa `BuscadorFacetadoService.filtroDe()` para
  armar el filtro real de Elasticsearch. Mas simple del lado del backend
  (no hay que hacer el calculo dos veces) y no se pierde informacion si el
  analisis futuro quiere mirarlo distinto.
- **`facetada UInt8`** distingue las dos rutas en la misma tabla: `0` en
  toda fila que venga de `GET /buscador/productos` (la busqueda simple,
  sin facetas) o de antes de este cambio; `1` solo en las que pasaron por
  `GET /buscador/productos/facetado`. Las demas columnas nuevas quedan en
  su default (arreglo vacio o `0`) en las filas `facetada = 0` -- ninguna
  fila vieja hay que reprocesar, el `DEFAULT` ya las deja consistentes.
- **Arreglos, no una fila por faceta elegida.** `categorias`
  (`Array(UInt32)`), `precios`/`calificaciones` (`Array(String)`, guardan
  las claves tal cual: `'250-500'`, `'4-o-mas'`) -- una sola fila por
  busqueda/clic, igual que hoy, en vez de explotar una fila por cada
  filtro elegido.

## Columnas nuevas (identicas en las dos tablas)

| Columna | Tipo | Default | Que guarda |
|---|---|---|---|
| `facetada` | `UInt8` | `0` | `1` si vino de `GET /buscador/productos/facetado`, `0` si de la busqueda simple |
| `categorias` | `Array(UInt32)` | `[]` | los `id_categoria` de `?categoria=7,9` |
| `precios` | `Array(String)` | `[]` | las claves de `?precio=250-500,500-1000` |
| `calificaciones` | `Array(String)` | `[]` | las claves de `?calificacion=4-o-mas` |
| `disponible` | `UInt8` | `0` | `1` si se mando `?disponible=si` |

SQL de referencia, idempotente, en `buscador-facetado-clickhouse.sql` (este
mismo directorio) -- **ya aplicado a mano en la base LOCAL**
(`mesh-clickhouse`, `docker exec -i mesh-clickhouse clickhouse-client
--database mesh_eventos --multiquery < ...`), verificado con
`SHOW CREATE TABLE` y corrido dos veces para confirmar que no falla la
segunda (`ADD COLUMN IF NOT EXISTS`).

## Del lado del backend, TODO HECHO (2026-09-26 en la noche)

1. ~~`EventosService.registrarBusqueda()` -- agregar los cuatro campos
   nuevos a la firma~~. Hecho: `facetada`/`categorias`/`precios`/
   `calificaciones`/`disponible`, todos opcionales con default `false`/
   `[]` -- `BuscadorProductosController` (la busqueda simple) sigue
   llamandola igual que antes, sin tocarla, y queda escrito con `facetada: 0`.
2. ~~`BuscadorFacetadoController` -- conectar a `registrarBusqueda()`~~.
   Hecho: pasa `facetada: true` y las cuatro facetas parseadas con
   `separarPorComas()` (exportada de `BuscadorFacetadoService`, ya no un
   metodo privado) -- no se volvio a parsear nada.
3. ~~`EventosService.registrarClicBusqueda()` y `POST
   /eventos/busqueda-clic` -- agregar los mismos campos~~. Hecho:
   `dto/registrar-clic-busqueda.ts` con los cinco campos opcionales,
   cuatro validadores nuevos en `helpers/validaciones-eventos.ts`
   (`validarFacetadaEvento`, `validarCategoriasEvento`,
   `validarClavesFacetaEvento`, `validarDisponibleEvento`).
4. **Tres rutas nuevas, no estaban en el plan original, agregadas
   despues**: `GET /admin/eventos/categorias-mas-buscadas` /
   `precios-mas-buscados` / `calificaciones-mas-buscadas` -- el ranking de
   que facetas se usan mas, mismo `AdminTendenciasController`/`Service`
   que las seis rutas de `eventos-clickhouse.md`, con `ARRAY JOIN` para
   desenrollar las columnas `Array(...)` antes de agrupar
   (`rankingPorFaceta()`).

**Bug real encontrado y corregido durante las pruebas, sin relacion con
las columnas de ClickHouse**: `nombre` vacio en
`GET /buscador/productos/facetado` (navegar solo por faceta, sin texto)
daba `total: 0` -- un `multi_match` de Elasticsearch con `query: ''` no es
"sin filtro de texto", es "no encuentra nada". Corregido con `match_all`
cuando el texto viene vacio. Detalle y toda la bateria de pruebas en vivo
en `endpoints-buscador.md` y `endpoints-eventos.md`.

## Le queda al compañero (fuera de `backend/`)

- Sumar las mismas `ALTER TABLE ADD COLUMN` (o reescribir el `CREATE TABLE`
  con las columnas ya adentro, como prefiera) a `clickhouse/001_esquema.sql`
  -- hoy esas columnas solo existen en la base LOCAL de este entorno.
