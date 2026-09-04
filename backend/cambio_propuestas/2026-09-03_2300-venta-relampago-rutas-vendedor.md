# Cambio: las dos rutas para que el vendedor abra/cierre la venta relámpago

**Fecha aproximada:** 2026-09-03, noche.
**Alcance:** solo `backend/`. No tocó migraciones (la 014 ya la subió el
compañero), Mongo ni los `.lua`.

Es el **paso 2** de `elementos Generales/plan pendiente/inventario-limitado.md`
y lo único que bloqueaba el botón del panel del vendedor (el contrato lo
dejó el compañero en el BLOQUE 9 de `docs/BACKEND-PENDIENTE.md`).

## Las dos rutas

- **`POST /vendedor/ofertas/:id/venta-limitada`** — abre la venta relámpago
  de una oferta propia. Cuerpo `{ "duracion_segundos": N }` opcional
  (`0` = sin vencimiento, por defecto; tope 7 días). 201 con
  `{ id_oferta, stock_sembrado }`.
- **`DELETE /vendedor/ofertas/:id/venta-limitada`** — la cierra. 200 sin
  cuerpo.

Detalle completo (cuerpos, todos los códigos de error, ejemplos) en
`elementos Generales/endpoints-vendedores.md`.

## Archivos nuevos

- `src/controllers/vendedores/ventas-limitadas.controller.ts`
- `src/services/vendedores/ventas-limitadas.service.ts`
- `src/dto/abrir-venta-limitada.ts`

Van **aparte** de `OfertasVendedorController` / `OfertasVendedorService` a
propósito: el CRUD de ofertas es PostgreSQL puro y esto es Redis
(`InventarioLimitadoService` + el script Lua). El nuevo servicio solo tiene
la autorización (la oferta tiene que ser tuya) y la validación del cuerpo;
el trabajo real lo hacen `InventarioLimitadoService.activar` / `revertir`,
que ya existían y ya usa `CarritoService`. Comparten el prefijo
`/vendedor/ofertas`, el guard y los roles con el controlador de ofertas.

## Decisiones cerradas (las tres preguntas que estaban abiertas)

- **Quién**: el dueño de la oferta. Ajena o inexistente → 404 genérico. Un
  admin actúa como la cuenta de la tienda (igual que el resto de
  `/vendedor/ofertas`).
- **Cuántas unidades**: siempre el `stock` completo de la oferta en ese
  instante. Sembrar menos dejaría unidades invisibles en PostgreSQL que
  nadie podría comprar mientras la venta esté abierta.
- **Duración**: la elige el vendedor (`duracion_segundos`), 0 por defecto,
  tope 7 días.

## `es_inventario_limitado` en los GET de ofertas

Se agregó el campo a:

- `GET /vendedor/ofertas` (cada oferta propia)
- `GET /vendedor/ofertas/producto/:idProducto` (en cada `mi_oferta`)
- `GET /productos/:id` (público, en cada entrada de `ofertas[]`)

Cambios: `models/oferta.ts` (`OfertaVendedor`, `OfertaPropiaResumen`,
`FilaOfertaPropia`, y el nuevo `VentaLimitadaAbierta`), las 4 consultas de
`OfertasVendedorService` y sus 3 armadores de salida, y `FilaOferta` +
`obtenerOfertasReales` de `ProductosService`.

## Probado

`test-ventas-limitadas.sh` — 45 comprobaciones, 0 fallos, contra el
servidor y las bases reales:

- abrir con duración → 201, PG marcada, Redis sembrado con el stock, TTL de
  la clave ≈ la duración;
- los tres GET traen `es_inventario_limitado` con el valor correcto;
- abrir de nuevo → 409; oferta ajena → 404; inexistente → 404; sin sesión →
  401; rol comprador → 403; oferta pausada → 409; `duracion_segundos`
  negativa / > 7 días / no numérica → 400; ningún intento fallido sembró
  nada en Redis;
- abrir con body `{}` → 201 sin vencimiento; cuerpo vacío → 400 de Fastify;
- cerrar → 200, PG desmarcada, claves de Redis borradas; cerrar de nuevo →
  409; cerrar ajena → 404 sin tocar nada;
- un admin abre y cierra la venta de una oferta de la tienda.

`npx tsc --noEmit` limpio. Base local intacta; los carritos de validación
sembrados a mano siguen enteros.

## Lo que queda del bloque de inventario limitado

Solo la **fase futura** (activación automática por "calor" — detectar un
producto que se está calentando y abrir el modo solo), que nunca fue del
alcance de esta entrega. El bloque queda completo.
