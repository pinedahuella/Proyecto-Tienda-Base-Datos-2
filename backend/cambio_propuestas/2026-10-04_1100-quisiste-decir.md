# "Tal vez quisiste decir" en el buscador

**Fecha:** 2026-10-04.
**Alcance:** `backend/`. Sin esquema nuevo, sin tocar el mapeo ni el ETL.

## Por qué

El buscador ya tolera errores de tecleo (`fuzziness: AUTO`) y autocompleta, pero
si la persona escribe "audifonso" encuentra resultados sin decirle que se
equivocó. Faltaba el "¿Quisiste decir **audífonos**?".

## Qué se hizo

- `helpers/correccion-busqueda.ts` (`pedirCorreccion`, `textoCorregido`): arma el
  bloque `suggest` (*term suggester* sobre `nombre`, `suggest_mode: missing`,
  palabras de 3 letras o más) y reemplaza solo las palabras mal escritas por la
  mejor sugerencia. Viaja dentro de la misma consulta a Elasticsearch.
- `GET /buscador/productos` y `GET /buscador/productos/facetado` devuelven
  `quisiste_decir` (texto corregido o `null`). La búsqueda sigue usando lo que la
  persona escribió.
- **Cambio de forma en `GET /buscador/productos`:** el `payload` era la lista de
  resultados y ahora es `{ resultados, quisiste_decir }`. `/facetado` ya devolvía
  un objeto, solo gana el campo. `/admin` no cambia (sigue siendo la lista sola).
- `BuscadorProductosService.buscar()` devuelve `RespuestaBusquedaProductos`
  (`dto/buscar-productos.ts`); `buscarAdmin()` sigue devolviendo la lista.
- Documentado en `elementos Generales/endpoints/endpoints-buscador.md`.

## Probado en vivo (índice local, 102 productos)

| Texto | `quisiste_decir` |
|---|---|
| `labtop` | `laptop` |
| `audifonso` | `audifonos` |
| `telefno movil` | `telefono movil` |
| `telefno Cuarzo` | `telefono Cuarzo` |
| `laptop`, `teléfono` | `null` |
| `televisro`, `xyzqwk` | `null` (no se parecen a nada del catálogo) |

`/facetado`: `telefno` da `telefono`, `telefono` y vacío dan `null`. `/admin` sin
sesión sigue dando 401 y `nombre` vacío sigue dando 400.

## Límites aceptados

- El índice guarda todos los estados: la palabra sugerida puede venir de un
  producto que no está activo. Evitarlo pide un campo aparte en el mapeo.
- Una palabra bien escrita que solo está en una descripción y se parece a una de
  un nombre podría recibir una sugerencia. Es un "tal vez", no cambia la búsqueda.
- La palabra corregida sale en minúsculas y sin tilde (así está en el índice).

## Pendiente de otros (no tocar, ver `solo-backend`)

- **Frontend, `frontend/src/lib/buscador.ts` (`buscarProductos`):** lee el
  `payload` de `/buscador/productos` como lista (`Array.isArray(...) ? ... : []`).
  Con la forma nueva la búsqueda de la cabecera mostraría **cero resultados** sin
  dar error. Hay que leer `payload.resultados` en la ruta pública (la de admin
  sigue igual) y, si se quiere, pintar `payload.quisiste_decir`. También
  `docs/frontend.md`, que describe esa llamada.
- `pruebas/busqueda.sh` (línea 136, `busca_backend`) recorre `d.get('payload')`
  como lista; con la ruta pública ahora recorrería las llaves del objeto. Debe
  leer `payload.resultados` cuando la ruta es `/buscador/productos` (la de
  `/admin` sigue igual).
