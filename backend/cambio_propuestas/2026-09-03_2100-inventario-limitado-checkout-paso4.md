# Cambio: el checkout del carrito cierra las reservas de inventario limitado

**Fecha aproximada:** 2026-09-03, noche.
**Alcance:** solo `backend/` — `src/services/carrito/carrito.service.ts`,
`src/controllers/carrito/carrito.controller.ts`. No tocó Postgres, Mongo,
Redis (los scripts `.lua`) ni ninguna migración: es lógica del backend
sobre piezas que ya existían (`InventarioLimitadoService.confirmar` /
`devolver`, que ya estaban escritas y probadas por separado).

Cubre tres cosas: (1) el **paso 4** — conectar `confirmar`/`devolver` al
checkout; (2) un bug del `t:` huérfano encontrado al probar; (3) el
**candado de checkout** contra el doble submit, que salió de la misma
batería de estrés.

## Qué es esto

Es el **paso 4** de `elementos Generales/plan pendiente/inventario-limitado.md`.
Antes de este cambio, comprar una línea de venta relámpago la pasaba por
`comprar_carrito()` de PostgreSQL como cualquier otra, pero el ticket de la
reserva en Redis se quedaba "reservado" sin confirmar — se liberaba solo
cuando vencía (hasta 15 min). No era una sobreventa (PostgreSQL con su
`FOR UPDATE` es el libro real), solo una desprolijidad: Redis creía que
esas unidades seguían apartadas.

## Qué cambió

En `POST /carrito/comprar`, después de leer el carrito y antes de vaciarlo:

1. Se leen las líneas que traen una reserva viva (campo `t:<id_oferta>` del
   hash del carrito) con su número de ticket — **antes** del pago, porque
   el `vaciar()` del final borra el hash.
2. **`comprar_carrito()` devolvió bien** → por cada una de esas líneas se
   llama `confirmar` (op de `redis/inventario_limitado.lua`): la reserva
   pasa de *reservada* a *vendida*. Es *best-effort*: la venta ya está
   cerrada en PostgreSQL, así que un fallo de Redis aquí **no** deshace la
   compra, solo se registra en el log.
3. **`comprar_carrito()` tiró error** (oferta pausada/agotada entre ver y
   pagar, o error de conexión) → se llama `devolver` por cada reserva antes
   de propagar el 409/503. Las unidades vuelven al contador de Redis en el
   acto. El carrito **no** se vacía; en el siguiente `GET /carrito` esas
   líneas salen `reserva_vencida` y hay que volver a agregarlas
   (re-reservar) para reintentar.
4. El chequeo de precio (`comprado: false`) **no** dispara `devolver` — la
   reserva sigue viva mientras el cliente confirma y reintenta.

También:

- **`DELETE /carrito`** ahora suelta (`devolver`) las reservas de
  inventario limitado antes del `DEL`. El `vaciar()` que corre tras una
  compra correcta **no** lo hace (esas reservas ya se confirmaron). Lo
  decide un parámetro interno nuevo, `soltarReservas`, de
  `CarritoService.vaciar()`.
- La rama del interruptor `QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR` (hoy en
  `false`) también suelta la reserva de una línea limitada que quede
  bloqueante antes de quitarla del carrito.

Con esto, `endpoints-carrito.md` ya no tiene la "limitación conocida"
anotada en `DELETE /carrito`.

## Probado

74 comprobaciones contra el servidor y las bases reales (grupos A–G:
compra con confirmación, redimensionar + confirmar, fallo → devolver +
reintento, `DELETE /carrito`, `DELETE /carrito/lineas`, regresión de
carrito normal, e interruptor en `true`), 0 fallos.

**Batería de estrés extra** del ciclo de vida de la reserva (a raíz de la
observación de que la liberación tiene muchos puntos de fallo):
`test-reserva-stress.sh` (62/62) + `test-reserva-concurrencia.sh` +
`test-m2-postgres-down.sh` — idempotencia de cada liberación, rechazo de
PostgreSQL, best-effort de `confirmar`/`devolver`, venta cerrada con ticket
colgado, caídas de Redis y PostgreSQL, y concurrencia (`DELETE` línea ‖
checkout, doble `PUT`). El ciclo aguanta: toda liberación es idempotente,
ningún camino sobre-libera, los fallos se registran, y `comprar_carrito()`
(el libro real) nunca queda a medias.

- **Bug corregido en el camino:** el `PUT` normal no limpiaba un campo
  `t:<id_oferta>` huérfano cuando la venta relámpago ya había cerrado, así
  que la línea seguía reportándose como limitada. Ahora hace `HDEL` de ese
  campo siempre.
- **Doble compra por doble submit — CORREGIDO** (`test-candado-checkout.sh`,
  0/22 dobles tras el cambio). `comprarCarrito` toma un candado corto en
  Redis, `mesh:checkout:<id_usuario>` (`SET EX 30 NX`); si la cuenta ya
  tiene una compra en curso, corta con 409 sin leer el carrito. Es por
  cuenta (dos personas distintas no se estorban) y se auto-libera a los
  30 s si el proceso muere. El otro camino de compra,
  `POST /comprador/pedidos/:id/comprar`, se comprobó y ya era seguro (el
  `pedido` ya existe y `comprar_pedido()` revalida su estado bajo
  `FOR UPDATE`).
- **Hallazgo pre-existente, sin tocar** (para el equipo): PostgreSQL caído
  → 500 en vez de 503 en rutas con sesión (el `SesionGuard.estaActivo` no
  traduce el error de conexión a `ErrorConexion`). Afecta a toda ruta
  autenticada, no solo al carrito.

`npx tsc --noEmit` limpio, log del servidor sin warnings de
`confirmar`/`devolver`. Base local devuelta a su estado inicial. Detalle en
`endpoints-carrito.md`, secciones "Paso 4 — `confirmar` / `devolver`
conectados al checkout" y "Batería de estrés del ciclo de vida de la
reserva".

## Lo que sigue del bloque de inventario limitado

Solo el **paso 2**: una ruta HTTP para que el vendedor abra la venta
relámpago de una oferta suya. `InventarioLimitadoService.activar` /
`revertir` ya hacen el trabajo, pero falta decidir quién puede llamarla
(¿el dueño de la oferta? ¿solo tienda/admin?), si el vendedor elige cuántas
unidades sembrar y la duración de la venta. Ver el plan.
