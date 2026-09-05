# Cambios: 409 en `ajuste_stock` durante venta relámpago + `puede_resenar`/`ya_reseno` en el pedido

**Fecha aproximada:** 2026-09-04, mañana.
**Alcance:** solo `backend/`. Sin migraciones ni cambios de esquema.

Dos pedidos sueltos de José (el compañero), sin relación entre sí.

## 1. `PATCH /vendedor/ofertas/:id` — 409 si `ajuste_stock` llega con la venta relámpago abierta

**El problema.** Con la venta relámpago abierta, el stock real de la
oferta lo lleva Redis (las unidades reservadas se descuentan ahí, no en
`oferta.stock`). Si de todos modos se aceptaba `ajuste_stock` por esta
ruta, la columna de PostgreSQL y el contador de Redis se desincronizaban:
Redis seguía prometiendo unidades que PostgreSQL ya no tenía. Alguien
aparta, espera, paga, y el cobro revienta con un error que no explica
nada.

**El fix.** En `OfertasVendedorService.editar()`
(`services/vendedores/ofertas.service.ts`), justo después de traer
`filaActual` (que ya incluye `es_inventario_limitado`) y antes de abrir la
transacción: si el cuerpo trae `ajuste_stock` y la oferta está en venta
relámpago, `ErrorConflicto` (409) — nada se escribe, ni siquiera si el
cuerpo también traía `precio` y/o `estado` en la misma petición. `precio`
y `estado` siguen editables sin ninguna restricción nueva.

Archivo tocado: `src/services/vendedores/ofertas.service.ts` (4 líneas +
comentario).

**Probado en vivo:**

| Caso | Resultado |
|---|---|
| Venta relámpago abierta, `ajuste_stock` solo | `409` |
| Venta relámpago abierta, `ajuste_stock` + `precio` juntos | `409`, precio **no** se tocó (verificado en la fila) |
| Venta relámpago abierta, `precio` solo | `200` (sigue editable) |
| Venta relámpago abierta, `estado` solo | `200` (sigue editable) |
| Venta relámpago cerrada, el mismo `ajuste_stock` | `200` normal |

Documentado en `endpoints-vendedores.md`.

## 2. `GET /comprador/pedidos/:id` — `puede_resenar`/`ya_reseno` por línea

**El pedido.** "Son dos campos en su consulta de `pedidos.service.ts`, no
una ruta nueva" — que la pantalla del pedido pueda ofrecer el botón
"Reseñar" directo, sin que el frontend le pegue aparte a
`GET /resenas/productos/:id/comprado` y `.../resenado` por cada producto
de cada línea.

**El fix.** En `PedidosCompradorService.obtener()`
(`services/compradores/pedidos.service.ts`), la consulta que ya trae las
líneas del pedido (`resultadoDetalles`) suma dos columnas calculadas con
subconsultas, sin cambiar la forma del resto de la respuesta ni el flujo:

- `id_resena` — el id de la reseña si ya existe una fila en `resena` para
  el trío exacto `(id_usuario, id_usuario_vendedor, id_producto_mongo)` de
  esa línea (el mismo trío que protege el `UNIQUE` de `resena`), o `null`
  si no. Más preciso que `resenoProducto()` (que ignora el vendedor): el
  mismo producto comprado a dos vendedores puede reseñarse dos veces, una
  por vendedor.
- `puede_resenar` — `true` solo si las cuatro se cumplen a la vez: el
  pedido está pagado (`pago.estado_pago = 'pagado'`) y no está `cancelado`
  (misma regla que `ResenasService.exigirCompraPagada`, con los mismos
  JOINs, no una versión reescrita), la línea todavía no tiene
  `id_resena`, y el vendedor de la línea no es la propia cuenta.

Archivos tocados: `src/services/compradores/pedidos.service.ts` (la
consulta + un parámetro nuevo, `idUsuario`) y `src/models/pedido-producto.ts`
(`id_resena: string | null` y `puede_resenar: boolean` en `DetallePedido`).

**Corrección sobre la primera versión, el mismo día.** La primera versión
de este cambio usaba `ya_reseno` (booleano) en vez de `id_resena`, y
`puede_resenar` no descartaba el caso de reseñarse a uno mismo. Se detectó
al revisar `docs/BACKEND-PENDIENTE.md` (bloque 5) — el documento que fija
el contrato exacto contra el que el frontend ya está escrito ("Las
pantallas ya están escritas contra estas firmas: si las respetás,
funcionan sin tocar el frontend") — y que trae las dos trampas que la
primera versión no cubría:

1. **El nombre y la forma del campo importan, no solo el significado.**
   El frontend espera `id_resena` (el id o `null`), no un booleano
   `ya_reseno` — aunque comuniquen casi lo mismo, el frontend ya escrito
   no iba a funcionar contra el nombre equivocado.
2. **Nadie se reseña a sí mismo.** La tabla `resena` tiene
   `CHECK (id_usuario <> id_usuario_vendedor)`; sin excluir ese caso de
   `puede_resenar`, el botón podría ofrecerse para una línea donde el
   comprador es también el vendedor (raro, pero posible si algún día
   existiera esa compra) y el `POST /resenas` reventaría con un error que
   el botón nunca prometió.

Se corrigió antes de que nadie lo consumiera — no llegó a commitearse ni
se avisó al equipo con la forma vieja.

**Probado en vivo** contra un pedido pagado real con dos líneas del mismo
producto vendidas por dos vendedores distintos:

- Las dos líneas nacen `id_resena: null, puede_resenar: true`.
- Se publicó una reseña real para una de las dos (`POST /resenas`, id
  117): esa línea pasó a `id_resena: 117, puede_resenar: false` — el id
  real, no un booleano inventado —, la otra (mismo producto, otro
  vendedor) se quedó en `id_resena: null, puede_resenar: true` — confirma
  que compara el trío completo, no solo el producto.
- Simulando a mano el pedido `cancelado`, y aparte el pago en `pendiente`:
  las dos líneas cayeron a `puede_resenar: false` en los dos casos (con
  `id_resena` sin cambiar).
- Datos de prueba limpiados al terminar (la reseña de prueba borrada, la
  oferta devuelta a su estado original).

Documentado en `endpoints-compradores.md`.

## Verificación general

`npx tsc --noEmit` limpio. `eslint` no agregó violaciones nuevas en
ninguno de los tres archivos tocados (mismo conteo de
`prettier/prettier` preexistentes que en `HEAD`, ver memoria
`formato-y-finales-de-linea` — el repo no está limpio de lint y no se
corrió ningún formateador sobre código ajeno). Finales de línea CRLF
normalizados tras editar.

## Lo que no se tocó en esta ronda

**Apagar `es_inventario_limitado` cuando la venta relámpago vence sola**
(por TTL de Redis, no por el `DELETE .../venta-limitada` manual) — ya se
hizo, aparte:
`cambio_propuestas/2026-09-04_0900-apagar-venta-relampago-vencida.md`.

**El numerador del id de producto** sigue sin código, solo la propuesta
de abajo — necesita que el usuario la hable con José antes de tocar nada,
porque el mecanismo completo toca `mongo/lote/generar_lote_mongo.js` y
`migrations/lote/generar_lote.sql`, fuera de `backend/`.

### Propuesta: un contador atómico, doble (producto/variante)

**Lo que de verdad se cruza no son dos generadores de Mongo entre sí** —
releyendo `mongo/lote/generar_lote_mongo.js` (comentario de su propia
cabecera) el cruce real es otro: **el `bigserial` de
`productos.id_producto` en PostgreSQL** (que sigue vivo y lo usa
`migrations/lote/generar_lote.sql` para crear el catálogo "curado" que
después sube el ETL) **contra los ids que Mongo reparte por su cuenta**
(el backend en vivo, `siguienteIdProducto()`/`siguienteIdVariante()`
calculando `max(_id) + 1`, y el generador de Mongo,
`generar_lote_mongo.js`, que ya se defiende leyendo el máximo de las DOS
bases en el instante en que corre). El bigserial de PostgreSQL es el que
avanza SIN saber nunca qué ids ya está usando Mongo — y cuando alcanza un
número que Mongo ya usó para un producto nacido ahí directamente, el ETL
(`etl/cargar.js`) hace un `replaceOne` por `_id` sobre `db.productos` sin
ningún barrido ni aviso: **machaca ese producto entero**, tal cual lo dice
el comentario de `generar_lote_mongo.js` línea 44-48.

**La propuesta, en dos piezas:**

1. **Un contador atómico en Mongo**, dos documentos (`producto` y
   `variante`) en una colección nueva (p. ej. `contadores`), incrementados
   con `findOneAndUpdate({_id: 'producto'}, {$inc: {valor: 1}}, {returnDocument: 'after'})`.
   El backend en vivo deja de "adivinar" con `max(_id) + 1` (un `sort` +
   `limit(1)` que además se degrada al crecer la colección) y pide su
   próximo id ahí — atómico de verdad, sin ventana de carrera entre dos
   peticiones simultáneas del panel.
2. **Ese mismo id, empujado también hacia PostgreSQL.** Cada vez que el
   backend reserva un id nuevo por el contador, además corre
   `SELECT setval('productos_id_producto_seq', GREATEST(id_reservado, (SELECT last_value FROM productos_id_producto_seq)))`
   (una sola sentencia, sin transacción especial). Así el `bigserial` de
   PostgreSQL queda empujado por delante de cualquier id que Mongo ya
   repartió, y nunca puede volver a entregar ese número — que es
   justamente lo que hoy nadie garantiza.

Con las dos piezas, el generador de Mongo (`generar_lote_mongo.js`) casi
no necesita cambiar: seguiría leyendo el máximo de Mongo en vivo (ya lo
hace) y ya no haría falta que le pasen `LOTE_MAX_PG_PRODUCTO` a mano desde
`arrancar.ps1` — podría simplemente reservar su lote completo del mismo
contador atómico (`$inc` por la cantidad del lote de una sola vez), que es
más simple que lo de hoy y cierra la ventana del todo, no solo la reduce.

**Por qué no queda perfecto sin hablarlo con José:** la pieza 2 (empujar
el `setval` de PostgreSQL) asume que `productos.id_producto` sigue siendo
el único lugar en PostgreSQL que reparte esos ids — si `generar_lote.sql`
tiene algún otro camino para crearlos, o si el equipo prefiere que sea
PostgreSQL el que empuje hacia Mongo en vez de al revés, cambia el diseño.
Y aunque el `generar_lote_mongo.js` ya no tendría que cambiar de fondo,
sigue siendo su archivo — cualquier ajuste ahí (aunque sea "ya no hace
falta este parámetro") lo decide y lo aplica él.

**Lo que le toca a cada lado, si se aprueba:**

- **Backend (nuestro):** la colección `contadores`, el cambio en
  `siguienteIdProducto()`/`siguienteIdVariante()` de `productos.service.ts`
  para usarla, y el `setval` hacia PostgreSQL tras reservar. Sin
  migración: la colección la crea el primer `findOneAndUpdate` con
  `upsert: true`, y hay que sembrarla una sola vez con el máximo actual de
  las dos bases (mismo cálculo que ya hace `generar_lote_mongo.js` hoy)
  para no chocar con lo que ya existe al momento de encender esto.
- **José (fuera de `backend/`):** decidir si `generar_lote_mongo.js` pasa
  a reservar del contador o se queda igual (con la pieza 2 puesta, su
  forma actual ya no puede chocar con PostgreSQL, así que cambiarlo es
  simplificación, no urgencia), y confirmar que `productos.id_producto`
  sigue siendo la única fuente de ids nuevos del lado de PostgreSQL.
