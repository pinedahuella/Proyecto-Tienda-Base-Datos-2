# Catálogo copiado a PostgreSQL y cola de productos por recalcular: el carrito y el checkout ya no dependen de MongoDB

**Fecha:** 2026-10-01.
**Alcance:** `backend/`. Hay esquema nuevo en PostgreSQL (dos tablas de catálogo
y una cola con triggers) que **en local está aplicado a mano**; la migración
real, la prueba en vivo del checkout y los scripts/ETL le tocan al resto del
equipo (ver "Pendiente fuera de `backend/`").

## Por qué

La fila 11 de `docs/CONSISTENCIA-CHECKOUT.md` y `prueba-falla-mongo-checkout.md`
dejaron declarada una dependencia de disponibilidad: el checkout lee Mongo
antes de cobrar (nombres y estado de la variante) y lo escribe después
(`recalcularCamposCalculados`, con `await`). Con Mongo caído la compra daba 503
y, ya cobrada, la respuesta esperaba ~3 s por producto en serie. Se decidió con
el usuario que **el carrito y el checkout solo necesiten Redis y PostgreSQL**.

## Qué se hizo

### 1. El catálogo que necesita la compra vive también en PostgreSQL

Dos tablas, normalizadas (el nombre depende de la variante, no de la oferta;
una variante tiene varias ofertas en el modelo multi-vendedor):

- `producto_catalogo (id_producto_mongo PK, nombre)`.
- `variante_catalogo (id_producto_mongo, id_producto_variante_mongo, nombre_variante, estado, imagen)`,
  PK = el par. `imagen` es solo la portada.

`oferta` no gana columnas (ya tiene el par). La FK de `oferta` a
`variante_catalogo` está prevista (etapa 2) y **no se aplicó**.
SQL: `plan pendiente/catalogo-en-postgres.sql`; siembra desde Mongo:
`plan pendiente/catalogo-en-postgres-sembrar.cjs`. Local: 102 productos, 202
variantes, 0 ofertas sin su variante.

### 2. Carrito y checkout leen de PostgreSQL

- `carrito.service.ts`: `consultarOfertas()` une `oferta` con las dos tablas
  (LEFT JOIN) y devuelve nombres, estado e imagen. `construirSnapshot()` (el
  `PUT`) y `verCarritoEnVivo()` (el checkout) dejaron de llamar a Mongo; se
  borró `consultarProductos()`.
- `pedidos.service.ts`: `revisarCambiosAntesDeComprar()` lee
  `variante_catalogo.estado` en la misma consulta, en vez de
  `obtenerEstadosVariante()`. Una variante que no esté en la copia cuenta como
  no disponible.

### 3. La copia se mantiene sola al escribir el catálogo

`helpers/catalogo-postgres.ts` (`escribirConCatalogoPostgres`): `BEGIN` en
PostgreSQL, `UPSERT` de la copia, escritura en Mongo, `COMMIT`; con compensación
(se deshace Mongo) si algo falla antes o en el `COMMIT`. Conectado en
`vendedores/productos.service.ts`: `crear()`, `proponer()` (el `INSERT` de la
propuesta va dentro de la misma transacción) y `editar()` cuando cambia
`nombre` o `variantes`. No es una transacción distribuida: queda una ventana de
milisegundos si el proceso muere entre la escritura de Mongo y el `COMMIT`.
Aprobar, rechazar y reenviar propuesta no cambian nombre ni variantes y no
tocan la copia.

### 4. El recálculo de Mongo sale de la petición

- Tabla `evento_producto` (mismo estilo que `evento_grafo`) con **una fila
  pendiente por producto**, y los triggers `trg_oferta_al_producto` (solo
  `precio`, `porcentaje_descuento`, `stock`, `id_estado_oferta`) y
  `trg_resena_al_producto`. SQL: `plan pendiente/evento-producto.sql`.
- `services/productos/evento-producto-sync.service.ts` (`@Interval` 5 s): lee
  los pendientes, llama a `ProductosService.recalcularProductoEstricto()` (la
  versión que lanza el error, nueva) y marca `procesado_en` solo si `fecha` no
  cambió. 5 fallos aparta el producto (un cambio nuevo lo reactiva); con Mongo
  caído corta la corrida sin contar intentos.
- Se quitaron **todas** las llamadas directas a `recalcularCamposCalculados`:
  checkout (carrito y pedidos), cancelar pedido, 5 sitios de `ofertas.service.ts`,
  ventas limitadas y descuentos vencidos, y reseñas. El método queda como base
  del worker.

Se descartó dejar la llamada sin `await`: seguiría metiendo a Mongo en la ruta
de compra, sin reintento, y duplicaría al worker.

## Cómo se probó (en local)

- `pruebas/carrito.sh`: 25 OK, 0 FALLA.
- `PUT /carrito/lineas/:idOferta` + `GET /carrito` con `mesh-mongo` parado:
  respondieron con nombre e imagen.
- Crear y editar un producto: la copia quedó idéntica a Mongo; crear con Mongo
  parado dio 503 sin dejar ninguna fila.
- Triggers: dos cambios al mismo producto dejan una sola fila pendiente; un
  `ROLLBACK` no deja nada.
- Worker: con `stock_total` del producto 83 puesto a 12345 en Mongo, tocar una
  oferta lo dejó en 146 (el real) en ~9 s; con Mongo parado la fila siguió
  pendiente con `intentos = 0` y se procesó al volver Mongo.
- `tsc` y `eslint` sobre todo `src`: limpio.

**No probado:** una compra real de punta a punta con Mongo parado, ni
cancelar/ofertas/reseñas tras quitar sus llamadas (mismo mecanismo ya probado,
pero sin corrida propia).

## Qué se acepta

- La tarjeta del catálogo (precio, stock, nota) puede ir hasta unos segundos
  atrás; la ficha y el cobro siguen en vivo contra PostgreSQL.
- `PedidosCompradorService.agregarLinea` (flujo manual de pedidos, sin uso en
  el frontend) sigue leyendo Mongo; no se tocó.

## Pendiente fuera de `backend/` (no se tocó)

- Migraciones reales: `029` (tablas del catálogo) y `030` (`evento_producto` y
  triggers). **Sin la 030 el worker falla en cada pasada.** Sembrar el catálogo
  después del ETL y antes de las ofertas; decidir cuándo aplicar la FK.
- Pruebas: actualizar el escenario B de `pruebas/falla_checkout.sh` (esperaba
  el 503) y correrlo.
- ETL y scripts: los cambios al catálogo hechos fuera del backend necesitan
  volver a sembrar.
- `docs/CONSISTENCIA-CHECKOUT.md` (fila 11) sigue diciendo que sin Mongo no se
  compra.

## Documentación actualizada

`endpoints/endpoints-carrito.md`, `endpoints-compradores.md`,
`endpoints-vendedores.md`, `endpoints-resenas.md`;
`guias-estudio/guia-estudio-decisiones-multibase.md` (Parte 8 y la tabla de
workers); `prueba-falla-mongo-checkout.md` (aviso de que la dependencia se
cerró); y los dos planes en `plan pendiente/`.
