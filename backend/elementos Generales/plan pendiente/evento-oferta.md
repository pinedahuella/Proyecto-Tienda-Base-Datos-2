# Plan pendiente — Buscador de ofertas en Elasticsearch (`evento_oferta` → `mesh_ofertas`)

> **Estado (2026-10-17): cola, triggers, worker y ruta HECHOS y probados en
> local (prueba ligera), con el backend corriendo. Falta la migración real y el
> índice en `elastic/` (le tocan a quien lleva `migrations/` y `elastic/`), y la
> prueba a fondo.** Sin la migración el worker no hace nada útil (no existe
> `evento_oferta`). Sin el índice `mesh_ofertas` el worker se salta las
> corridas y deja todo pendiente; la ruta responde 500.

## El problema

El profesor pidió darle más uso a Elasticsearch. Hoy no se puede buscar una
oferta por texto: `GET /vendedor/ofertas/paginado` solo filtra por estado, y el
buscador de Elasticsearch (`mesh_productos`) es de productos, no de ofertas.
Una tienda con 2000 ofertas no tiene cómo encontrar "la laptop de 16 GB" entre
las suyas, ni ver qué vendedores tienen agotada una oferta.

## Decisión: índice propio, alimentado por una cola propia

Un documento por oferta en `mesh_ofertas`, sincronizado desde PostgreSQL con el
mismo patrón outbox que `evento_producto` y `evento_comentario` (tabla de cola
+ triggers AFTER en la misma transacción + worker `@Interval`).

No se colgó de `evento_producto`:

- Guarda el **producto**, no la oferta, y su worker recalcula campos en MongoDB.
  Si Mongo se cae, se frenaría también el índice de ofertas.
- El documento de una oferta lleva nombres que viven en otras tablas (producto,
  variante, vendedor), y ninguna de ellas tenía un trigger.

SQL de referencia, aplicado en local: `evento-oferta.sql` (este folder).
Mapping de referencia: `ofertas-indice.json` (este folder).

## El documento (los campos mínimos)

| Campo | De dónde sale | Para qué |
|---|---|---|
| `id_oferta`, `id_producto`, `id_producto_variante` | `oferta` | Llevar al producto y a la oferta |
| `nombre_producto` | `producto_catalogo.nombre` | Texto difuso (el de más peso) |
| `nombre_variante`, `estado_variante` | `variante_catalogo` | Texto; ocultar variantes inactivas |
| `id_vendedor`, `vendedor_usuario`, `vendedor_nombre`, `estado_vendedor` | `usuarios`, `estado_usuario` | Filtrar por vendedor, buscarlo por nombre; ocultar suspendidos |
| `precio`, `porcentaje_descuento`, `precio_final` | `oferta` (`precio_final` calculado igual que `expresionPrecioFinal`) | Rango, orden por precio, "con descuento" |
| `stock` | `oferta` | "Agotadas" / "con stock" |
| `estado` | `estado_oferta` | Filtrar por estado |

No van las fechas, la aprobación, `es_inventario_limitado` ni los vencimientos:
el índice sirve para **encontrar**; lo demás se lee de PostgreSQL. El mapping es
`dynamic: strict`: un campo de más en el worker hace fallar la oferta (y se ve
en `evento_oferta.ultimo_error`) en vez de crear un campo adivinado.

## Los cuatro triggers

| Tabla | Cuándo | Qué encola |
|---|---|---|
| `oferta` | `INSERT`, `DELETE`, `UPDATE OF precio, porcentaje_descuento, stock, id_estado_oferta` | esa oferta |
| `producto_catalogo` | `INSERT`, `UPDATE OF nombre` (si cambió de verdad) | todas las ofertas del producto |
| `variante_catalogo` | `INSERT`, `UPDATE OF nombre_variante, estado` (si cambió) | todas las ofertas del par producto + variante |
| `usuarios` | `UPDATE OF usuario, nombre, apellido, id_estado_usuario` (si cambió) | todas las ofertas del vendedor |

El `INSERT` de catálogo cubre una oferta que se indexó antes de que existiera su
fila de catálogo (quedaría sin nombre). `usuarios` no lleva `INSERT` ni `DELETE`:
uno nuevo no tiene ofertas y uno con ofertas no se puede borrar
(`ON DELETE RESTRICT`).

El SQL termina encolando **todas** las ofertas que ya existen, para que el
primer paso del worker llene el índice entero.

## Backend (HECHO)

- `services/vendedores/evento-oferta-sync.service.ts` — el worker (5 s, hasta
  500 por corrida, un solo `bulk`). Existe → `index`; no existe → `delete` (un
  404 al borrar cuenta como hecho). Marca procesado solo si `fecha` no cambió;
  una oferta que falla suma `intentos` (se aparta a los 5). Si el índice no
  existe, avisa una vez y no toca la cola.
- `services/vendedores/buscar-ofertas.service.ts` +
  `controllers/vendedores/buscar-ofertas.controller.ts` —
  `GET /vendedor/ofertas/buscar`, documentada en
  `endpoints/endpoints-vendedores.md`.
- `dto/buscar-ofertas.ts`, validadores nuevos al final de
  `helpers/validaciones-oferta.ts`.
- Variable `ELASTIC_INDICE_OFERTAS` (por defecto `mesh_ofertas`) en `.env.example`.

## Le toca a otros (no tocar desde backend/)

- **Migración real** (`migrations/040_evento_oferta.sql` o el número que siga):
  el contenido de `evento-oferta.sql`, sin el encabezado de "solo referencia".
- **`elastic/`**: el mapping de `ofertas-indice.json` como `004_ofertas.json`, y
  crear el índice al arrancar (hoy se creó a mano con
  `curl -X PUT localhost:9200/mesh_ofertas --data-binary @ofertas-indice.json`).
  Como la carga inicial la hace el worker desde la cola, no hace falta ETL.
- **`arrancar.ps1 -Reiniciar`**: hoy borra lo aplicado a mano (tabla y triggers);
  el índice de Elasticsearch se queda.
- `docs/` si se quiere mencionar el buscador de ofertas.

## Probado en local (ligero) — 2026-10-17

Ver la tabla en `endpoints/endpoints-vendedores.md`. Resumen: 5531 ofertas
indexadas en unos 55 s sin errores; un cambio de stock llegó al documento en
menos de 7 s; vendedor, tienda y admin ven lo que les toca.

**Falta la prueba a fondo:** renombrar un producto, una variante y un vendedor;
suspender un vendedor; borrar una oferta; Elasticsearch caído y vuelto a subir.
