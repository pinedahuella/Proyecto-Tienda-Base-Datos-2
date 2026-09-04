# Cambio: `stock_disponible` — el stock real (Redis) de una oferta en venta relámpago, en los GET de ofertas

**Fecha aproximada:** 2026-09-03, noche.
**Alcance:** solo `backend/`. No tocó migraciones, Mongo ni los `.lua` —
lee un contador que ya existe en Redis.

## De dónde salió

Pedido del compañero: agregar `estado(idOferta)` al servicio de inventario
limitado para que llame a la operación `estado` del `.lua` (que ya estaba
escrita), y así "la ficha y el panel puedan preguntarle a Redis cuántas
unidades quedan de verdad".

El problema real: cuando una oferta está en venta relámpago
(`es_inventario_limitado = true`), su `stock` en PostgreSQL **queda
congelado** desde que se abrió la venta — el número real lo lleva el
contador atómico de Redis (`mesh:oferta:<id>`). La ficha del producto y el
panel del vendedor mostraban el `stock` viejo de PG.

## Qué se agregó

### `InventarioLimitadoService.estado(idOferta)`

`src/services/inventario-limitado/inventario-limitado.service.ts`. Llama la
operación `estado` de `redis/inventario_limitado.lua` (solo lectura, **no
cosecha** reservas vencidas) y devuelve un `EstadoVentaLimitada`:
`{ stock, reservado, vendidas, rechazos, ticket, pendientes, ttl_segundos }`,
o `null` si esa oferta no tiene una venta relámpago viva en Redis (el hash
no existe → el `.lua` devuelve `-1` en cada contador).

**No lanza si Redis falla:** sus consumidores son pantallas de solo lectura
que tienen que poder pintarse igual con el `stock` de PostgreSQL. En un
error de Redis deja un `warn` y devuelve `null`.

### El campo `stock_disponible` en tres endpoints

`number | null`. Las unidades que quedan **ahora mismo** según Redis. Solo
se llena cuando `es_inventario_limitado` es `true`; `null` en el resto, si
la venta ya cerró, o si Redis no respondió (ahí el número a mostrar es
`stock`).

- `GET /productos/:id` — cada entrada de `ofertas[]` (`OfertaVendedor`).
- `GET /vendedor/ofertas` — cada oferta propia (`OfertaPropia`).
- `GET /vendedor/ofertas/producto/:id` — cada `mi_oferta` (`OfertaPropiaResumen`).

Detalle en `elementos Generales/endpoints-productos.md` y
`endpoints-vendedores.md`.

## Archivos tocados

- `models/oferta.ts` — `stock_disponible` en `OfertaVendedor` y
  `OfertaPropiaResumen`.
- `services/inventario-limitado/inventario-limitado.service.ts` — interfaz
  `EstadoVentaLimitada` + método `estado()`.
- `services/productos/productos.service.ts` — inyecta
  `InventarioLimitadoService`; `obtenerOfertasReales` llena
  `stock_disponible` por oferta limitada (`Promise.all`, una llamada a
  Redis por oferta en venta relámpago — suelen ser pocas por producto).
- `services/vendedores/ofertas.service.ts` — inyecta
  `InventarioLimitadoService`; helper `stockDisponibleLimitado`; los 4
  armadores de salida (`crear`, `armarOfertaPropia`, `listarPropias`,
  `obtenerConMisOfertas`) llenan el campo. `listarPropias` pasó a
  `Promise.all`; `obtenerConMisOfertas` pide todos los stocks limitados de
  una vez antes de armar las variantes para que ese `map` siga siendo
  síncrono.

Sin cambios de DI en módulos: `AppModule` es plano y ya proveía
`InventarioLimitadoService`.

## Probado

Contra el servidor y las bases reales, oferta 11 en venta relámpago (PG
`stock` 26, Redis `stock` 2):

- Los tres endpoints → `stock_disponible: 2`, `stock: 26`.
- Oferta normal → `stock_disponible: null` en los tres.
- Reservar 1 unidad (Redis 2→1) → la ficha pasa a `stock_disponible: 1` en
  el acto; `devolver` → vuelve a 2.
- Oferta `es_inventario_limitado = true` en PG sin clave en Redis →
  `stock_disponible: null`, sin error ni warning.
- DI resuelve y el servidor arranca (constructor nuevo en `ProductosService`
  y `OfertasVendedorService`).

`npx tsc --noEmit` limpio. eslint: **0 violaciones nuevas** (el repo ya
tenía violaciones de `prettier/prettier` preexistentes en estos archivos;
el conteo por archivo no subió). Base local intacta.
