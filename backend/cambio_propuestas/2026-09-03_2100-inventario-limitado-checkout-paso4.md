# Cambio: el checkout del carrito cierra las reservas de inventario limitado

**Fecha aproximada:** 2026-09-03, noche.
**Alcance:** solo `backend/` — `src/services/carrito/carrito.service.ts`,
`src/controllers/carrito/carrito.controller.ts`. No tocó Postgres, Mongo,
Redis (los scripts `.lua`) ni ninguna migración: es lógica del backend
sobre piezas que ya existían (`InventarioLimitadoService.confirmar` /
`devolver`, que ya estaban escritas y probadas por separado).

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
carrito normal, e interruptor en `true`), 0 fallos. `npx tsc --noEmit`
limpio, log del servidor sin warnings de `confirmar`/`devolver`. Base
local devuelta a su estado inicial. Detalle en `endpoints-carrito.md`,
sección "Paso 4 — `confirmar` / `devolver` conectados al checkout".

## Lo que sigue del bloque de inventario limitado

Solo el **paso 2**: una ruta HTTP para que el vendedor abra la venta
relámpago de una oferta suya. `InventarioLimitadoService.activar` /
`revertir` ya hacen el trabajo, pero falta decidir quién puede llamarla
(¿el dueño de la oferta? ¿solo tienda/admin?), si el vendedor elige cuántas
unidades sembrar y la duración de la venta. Ver el plan.
