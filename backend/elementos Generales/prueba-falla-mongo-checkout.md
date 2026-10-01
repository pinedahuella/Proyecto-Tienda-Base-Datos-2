# Prueba de falla: MongoDB caido durante el checkout

> **ACTUALIZACION 2026-10-01: la dependencia de este documento se cerro en el
> backend.** El carrito y el checkout (`POST /carrito/comprar` y
> `POST /comprador/pedidos/:id/comprar`) ya no leen Mongo: nombre, estado de
> la variante e imagen salen de `producto_catalogo`/`variante_catalogo` en
> PostgreSQL (la opcion 2 de la seccion 4, extendida a nombres e imagen), y el
> recalculo de Mongo posterior a la compra salio de la peticion (lo hace un
> worker con la cola `evento_producto`). Con Mongo caido la compra deberia
> pasar de 503 a comprar normal. **Falta la prueba en vivo** (el escenario B
> de `pruebas/falla_checkout.sh` esperaba el 503 y hay que actualizarlo; lo
> hace quien lleva las pruebas) y las migraciones reales. Detalle:
> `plan pendiente/catalogo-en-postgres.md` y `plan pendiente/evento-producto.md`.
> Lo de abajo se conserva como el registro de la medicion original.

Complementa `docs/CONSISTENCIA-CHECKOUT.md` (Entrega 3). Esa tabla de
"puntos de falla" no tiene una fila para **"se cae MongoDB en mitad de una
compra"**, y salio como hallazgo al probar. Aqui queda lo medido y el
ajuste que se hizo del lado de `backend/`.

Estado: **el ajuste de timeout esta HECHO y probado**. **PENDIENTE**:
preguntar al profesor como debe manejarse la dependencia de disponibilidad
(ver la seccion 4).

---

## 1. La dependencia

MongoDB **no participa del COMMIT** del checkout. El pedido se crea, se le
meten las lineas y se cobra en **una sola transaccion de PostgreSQL**
(`comprar_carrito()` / `comprar_pedido()`), y ahi Mongo no entra: sus
numeros agregados se recalculan *despues*, best-effort (fila 8 de la tabla
de `CONSISTENCIA-CHECKOUT.md`).

Pero las dos rutas de compra **leen Mongo antes** de llegar a esa
transaccion, para resolver datos que no viven en PostgreSQL — el **nombre**
del producto y de la variante, y el **estado** de la variante
(`activa`/`inactiva`, que no se copia a PostgreSQL):

| Ruta | Donde toca Mongo | Momento |
|---|---|---|
| `POST /carrito/comprar` | `CarritoService.verCarrito()` → `productos.find({_id: {$in: [...]}})` | **antes** de la transaccion |
| `POST /comprador/pedidos/:id/comprar` | `PedidosCompradorService.revisarCambiosAntesDeComprar()` → `ProductosService.obtenerEstadosVariante()` → `productos.find(...)` | **dentro** de la transaccion (con el `cliente` de esa transaccion) |

Si esa lectura a Mongo falla, la compra no se concreta. Es una dependencia
de **disponibilidad** (no de consistencia): sin Mongo no se puede comprar,
aunque Mongo nunca escriba nada del pedido.

---

## 2. Lo que se midio

Prueba en vivo el **7 de septiembre de 2026**: `docker kill mesh-mongo`,
intento de compra por las dos rutas, y `docker start mesh-mongo` para
confirmar la recuperacion. Cuenta `comprador.sur@mesh.com` (id 3), ofertas
de la tienda. Script en el scratchpad (no va al repo); los pedidos de
prueba se crearon reales y se borraron despues.

### Antes del ajuste (driver con sus valores por defecto)

| | `POST /carrito/comprar` | `POST /comprador/pedidos/:id/comprar` |
|---|---|---|
| Respuesta con Mongo muerto | **HTTP 503** `No se pudo conectar con MongoDB` | **HTTP 503** `No se pudo conectar con MongoDB` |
| **Cuanto tardo en fallar** | **~32 s** | **~32 s** |
| Pedido / pago / `stock_movimiento` | ninguno — snapshot identico antes y despues | ninguno |
| Estado del pedido | no se creo | queda `pendiente` (ROLLBACK de la transaccion) |
| Stock de la oferta | intacto | intacto |
| Candado `mesh:checkout:<id>` | liberado (no queda trabado) | n/a |
| Al volver Mongo | compra normal | compra normal |

Los ~32 s son el `serverSelectionTimeoutMS` del driver de MongoDB (30 s por
defecto): con el servidor caido, el driver reintenta la seleccion de
servidor durante todo ese tiempo antes de rendirse. Mientras tanto, la
request HTTP y **una conexion del pool** quedan tomadas. Con una caida real
y varios compradores, eso son muchas conexiones colgadas medio minuto cada
una.

Ademas: un **parpadeo corto de Mongo** (menos que el timeout) **no da
error** — el driver bufferea la operacion y la compra se completa cuando
Mongo vuelve, solo que la request tarda lo que duro el parpadeo.

### Despues del ajuste

`src/database/mongo.ts` ahora crea el `MongoClient` con
`serverSelectionTimeoutMS: 3000` y `connectTimeoutMS: 3000` (mismo criterio
que el limite de 3 s del health-check del grafo, `helpers/limite-tiempo.ts`).

| | `POST /carrito/comprar` con Mongo muerto |
|---|---|
| Respuesta | **HTTP 503** `No se pudo conectar con MongoDB` (igual) |
| **Cuanto tardo en fallar** | **~5 s** medido (antes ~32 s); el timeout es 3 s, el resto es el Redis + PostgreSQL que `verCarrito` hace antes, mas el reintento del driver |
| Pedido / pago / `stock_movimiento` / stock | sin cambios — snapshot identico antes y despues |
| Al volver Mongo | compra normal (probado: pedido creado y cobrado en ~2 s) |

No cambia la semantica: sigue siendo 503, la venta sigue siendo atomica en
PostgreSQL y la consistencia sigue intacta. Lo unico que cambia es que la
dependencia **falla rapido y libera la conexion**, en vez de colgar.

---

## 3. Veredicto de consistencia

**La consistencia no se rompe.** Mongo se lee para resolver nombre y estado
de variante; si esa lectura falla, se corta ahi y nunca se llega a
`comprar_carrito()` / `comprar_pedido()`. No queda pedido a medias, ni
pago, ni movimiento de stock. En la ruta del pedido, la transaccion hace
ROLLBACK y el pedido se queda `pendiente`, reintentable.

Lo que si hay es una **dependencia de disponibilidad no declarada** en el
camino de lectura previo al COMMIT: es la fila que le falta a la tabla de
`docs/CONSISTENCIA-CHECKOUT.md` (seria la #11: "se cae MongoDB durante el
checkout" → 503, todo o nada, sin escritura parcial).

---

## 4. PENDIENTE: consultar al profesor

El ajuste de timeout es solo para que la dependencia falle rapido, no para
resolverla. Queda por decidir **como debe manejarse** que el checkout
dependa de MongoDB para leer el nombre y el estado de la variante. Opciones
sobre la mesa, a confirmar con el profesor:

- **Aceptarlo como "ventana de disponibilidad"** y solo documentarlo (fila
  #11 de la tabla). Es lo que ya se hace con Redis en la confirmacion de
  reservas (fila 5).
- **Copiar el estado de la variante a PostgreSQL** (como ya se copian
  precio y stock a `oferta`), para que `revisarCambiosAntesDeComprar` no
  necesite Mongo. El nombre del producto ya se **congela** en
  `pedido_producto.nombre_producto` al agregar la linea, asi que para la
  ruta del pedido el unico dato vivo que falta de PostgreSQL es el estado
  de la variante.
- **Degradar en vez de fallar**: si Mongo no responde, seguir con el ultimo
  nombre conocido / asumir la variante activa y dejar que
  `comprar_*()` haga su chequeo de stock y estado de oferta igual. Riesgo:
  se podria vender una variante que se desactivo y el backend no se entero.

Este documento se actualiza cuando haya respuesta.
