# Plan pendiente — Venta de inventario limitado (Redis)

> **Estado (2026-09-03, noche): pasos 1, 3, 4 y 5 cerrados y probados en
> vivo. Falta solo el 2 (ruta para que el vendedor abra la venta), que
> necesita decisiones de autorización antes de construirse.** Ver el
> detalle de cada uno más abajo, y la evidencia completa en
> `endpoints-carrito.md` (secciones "Inventario limitado en PUT / DELETE /
> GET del carrito" y "Paso 4 — `confirmar` / `devolver` conectados al
> checkout").

## El problema

Es el punto de la Entrega 2 que pide "venta de unidades limitadas bajo
alta concurrencia, sin sobreventa, con operaciones atómicas del almacén
clave-valor y **sin bloqueos a nivel de aplicación**". El compañero ya
resolvió la parte de Redis — `redis/inventario_limitado.lua` (comprobar y
descontar en un solo paso, con reservas que vencen solas) y
`redis/prueba_concurrencia.sh` (1000 solicitudes con 50 clientes reales a
la vez sobre 100 unidades venden exactamente 100) — documentado en
`redis/README.md`, sección 2-3. Lo que falta es enchufarlo al backend
(sección 5 de ese README, puntos 8, 9 y 11).

`comprar_pedido()`/`comprar_carrito()` (con su `SELECT ... FOR UPDATE`
sobre `oferta`) **no se tocan** — siguen siendo el libro contable final.
Lo que cambia es que, para una oferta en modo venta relámpago, PostgreSQL
ya no recibe 1000 personas peleando por 100 unidades: recibe (como mucho)
100 compras que ya ganaron la pelea en Redis.

## Decisión de diseño: es el vendedor quien lo activa, a mano

Se conversó la idea de detectar automáticamente "productos que se están
calentando" (muchas vistas/agregados en poco tiempo) y activar el modo
solo. **No se descarta**, pero queda como una fase futura, aparte — la
base (que el vendedor lo prenda a mano, para UNA oferta puntual) tiene que
funcionar primero. Ver la sección "Fase futura" más abajo.

---

## Paso 1 — CERRADO: marcar qué ofertas son de inventario limitado

Hoy `oferta` no tiene ninguna columna para decir esto. Se agrega una sola
columna booleana:

```sql
ALTER TABLE oferta
  ADD COLUMN es_inventario_limitado boolean NOT NULL DEFAULT false;
```

- `false` por default: ninguna oferta existente cambia de comportamiento
  al aplicar esto.
- Es el vendedor quien la prende (paso 2, todavía sin construir) — nunca
  se marca sola.
- No hace falta guardar en Postgres cuántas unidades se sembraron, ni
  cuándo cierra la venta: eso vive en Redis mientras la venta está
  abierta (el propio HASH `mesh:oferta:<id_oferta>` y su `EXPIRE`). La
  columna de Postgres solo dice "esta oferta opera bajo ese mecanismo",
  no el detalle de la venta en curso.

**Aplicado en la base local el 2026-09-03** con `inventario-limitado.sql`
(mismo folder) — ver ese archivo para el comando exacto. Reversible con
`.\arrancar.ps1 -Reiniciar`.

---

## Pieza base: `InventarioLimitadoService`

`src/services/inventario-limitado/inventario-limitado.service.ts`. Sin
controlador ni ruta HTTP propia todavía (algunos de sus métodos ya los
usa `CarritoService`, ver el paso 3 abajo; `activar`/`revertir` se siguen
disparando a mano, ver el paso 2). Métodos, todos probados en vivo:

- `activar(idOferta, ttlSegundos)` / `revertir(idOferta)` — paso 2, sin
  ruta HTTP todavía (se dispara a mano).
- `existeVentaLimitada(idOferta)` — `EXISTS` en Redis, sin tocar
  Postgres. Es lo que usa `CarritoService` para decidir si una línea del
  carrito pasa por el camino especial o el normal.
- `reservar` / `confirmar` / `devolver` — las tres operaciones de
  `redis/inventario_limitado.lua`, tal cual.
- `redimensionar` — la operación provisional (ver más abajo).
- `ticketVigente(idOferta, ticket)` — si una reserva sigue viva, sin
  gastar la operación completa `estado`.

Carga los dos scripts Lua (`redis/inventario_limitado.lua` y el
`redimensionar-reserva.lua` provisional) con `redis.defineCommand` de
ioredis al importar el módulo — eso YA resuelve el paso 5 del plan
original ("`SCRIPT LOAD`/`EVALSHA`/reintento en `NOSCRIPT`"): es lo que
hace `defineCommand` internamente, sin escribirlo a mano.

## Pieza nueva — `redimensionar` (provisional, escrita y probada el
2026-09-03)

`redis/inventario_limitado.lua` (el archivo real, del compañero) no trae
una forma de cambiar la cantidad de una reserva existente. Hacerlo como
dos llamadas separadas (`devolver` + `reservar`) deja un hueco real entre
las dos donde otro comprador se puede llevar el stock recién soltado, y
además obligaría a pedir la cantidad NUEVA completa como si fueran
unidades ajenas, sin contar las que la persona ya tenía apartadas.
`redimensionar-reserva.lua` (mismo folder) es un script **aparte**,
provisional, que hace las dos cosas en un solo paso atómico: acredita lo
viejo (si el ticket es del mismo usuario) y pide lo nuevo, comparando
contra el stock + lo que se libera, no contra el stock a secas. Detalle
completo y evidencia de prueba en
`cambio_propuestas/2026-09-03_1700-redimensionar-reserva-lua.md`. Es
provisional: el día que el compañero la revise y decida sumarla a su
archivo real, este `.lua` se borra y el backend apunta al de él.

## Paso 2 — el vendedor abre la venta relámpago de una oferta suya (PENDIENTE)

`activar`/`revertir` del servicio ya hacen el trabajo, pero **no hay ruta
HTTP** todavía — no está decidido:
- Quién puede llamarla (¿el dueño de la oferta? ¿solo tienda/admin, como
  la aprobación de ofertas?).
- Si el vendedor puede elegir CUÁNTAS unidades sembrar (hoy `activar`
  siempre usa el `stock` completo de Postgres en ese instante) o solo un
  subconjunto.
- Si puede elegir la duración de la venta (`ttlSegundos`) o queda fija.

## Paso 3 — el comprador reserva antes de pagar (CERRADO, integrado al carrito)

Decisión tomada con el usuario: **no** es un flujo de compra separado del
carrito (se consideró y se descartó — ver la discusión de "dos caminos
para pagar" más abajo). Es el mismo carrito de siempre
(`mesh:carrito:<id_usuario>`), con una excepción puntual para las líneas
de inventario limitado:

- `PUT /carrito/lineas/:idOferta` — si la oferta está en modo limitado
  (`existeVentaLimitada`, una consulta a Redis, no a Postgres), reserva o
  redimensiona de verdad (única excepción a "agregar nunca reserva
  nada"). El ticket se guarda como un campo COMPAÑERO en el mismo hash
  del carrito (`t:<id_oferta>`, junto al `<id_oferta>: cantidad` de
  siempre) — no hace falta que el cliente se acuerde de ningún ticket, es
  todo estado del lado del servidor.
- `DELETE /carrito/lineas/:idOferta` — si la línea tenía ticket, lo
  suelta con `devolver` antes de quitarla.
- `GET /carrito` — marca `es_inventario_limitado` por línea, y si la
  reserva venció sola, la línea sale `disponible: false, motivo:
  "reserva_vencida"` (el `stock_disponible` de Postgres queda congelado
  desde que se abrió la venta, así que no sirve para esto).

Detalle completo, con ejemplos de petición/respuesta y la evidencia de
prueba, en `endpoints-carrito.md`.

### Por qué no quedó como un flujo aparte

Se discutió primero mantenerlo separado del carrito (más simple de
construir), pero no es como funcionan los sistemas reales (el ejemplo
que se usó fue "Lightning Deals" de Amazon): es UN carrito y UN checkout,
donde una línea puntual trae un reloj más corto que las demás, no dos
experiencias de compra distintas conviviendo. Se corrigió el diseño para
seguir ese patrón.

## Paso 4 — conectar el resultado del pago (CERRADO, 2026-09-03)

Después de `comprar_carrito()`: si salió bien, `confirmar` el ticket de
cada línea de inventario limitado; si `comprar_carrito()` tiró error,
`devolver`. Hecho en `CarritoService.comprarCarrito()`:

- Las líneas con reserva se leen del hash del carrito (`t:<id_oferta>`)
  **antes** del pago — el `vaciar()` del final borra el hash.
- Éxito → `confirmarReservas()`: recorre esas líneas y llama `confirmar`.
  Es *best-effort* (no relanza): la venta ya está cerrada en PostgreSQL,
  que es el libro real; una reserva sin confirmar vence sola y `cosechar`
  devuelve su unidad — desajuste chico y acotado entre los dos contadores,
  no una sobreventa. Mismo criterio que el recálculo de Mongo.
- Fallo de `comprar_carrito()` → `devolverReservas()` antes de propagar el
  409/503. El carrito **no** se vacía; en el siguiente `GET /carrito` la
  línea sale `reserva_vencida` y hay que re-agregarla (re-reservar) para
  reintentar. El chequeo de precio (`comprado: false`) **no** dispara
  `devolver` — la reserva sigue viva mientras el cliente confirma.
- `confirmar`/`devolver` reciben el `id_usuario` de la sesión (nunca se
  confía en que el ticket sea secreto — ver `redis/inventario_limitado.lua`,
  `TICKET_AJENO`).

**`vaciar()` ya no tiene la limitación anotada:** ahora recibe
`soltarReservas` (`DELETE /carrito` lo pasa en `true` → suelta las reservas
antes del `DEL`; el vaciado post-compra lo deja en `false` → ya están
confirmadas). Y `quitarLineasDelCarrito` (rama del interruptor
`QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR`) también suelta la reserva de una
línea limitada que quede bloqueante antes de quitarla.

Evidencia: `endpoints-carrito.md`, sección "Paso 4" — 74 comprobaciones,
0 fallos, base local intacta.

**Fuera de nuestro alcance, o de otra persona:**
- El frontend tiene que tratar `AGOTADO` como respuesta normal, no error
  (punto 11 del README) — no es trabajo de backend.
- La reconciliación real (comparar tickets confirmados contra
  `stock_movimiento` y resembrar) — anotada como no hecha en
  `redis/README.md`, punto 10. Fuera de alcance por ahora.

## Fase futura (no en esta ronda): activación automática por "calor"

Idea del profesor: en vez de (o además de) que el vendedor lo prenda a
mano, detectar automáticamente que un producto está recibiendo mucha
actividad en poco tiempo y activar el modo solo. Se descartó usar el
detector de "hot keys" nativo de Redis (`redis-cli --hotkeys`) porque
depende de una política de desalojo LFU, y el proyecto usa
`maxmemory-policy noeviction` a propósito (para que el carrito y el
inventario limitado nunca se desalojen solos — `redis/README.md`, sección
4). La alternativa, si se retoma, sería un contador de actividad propio
por oferta (`INCR` con `EXPIRE` corto) que dispare `sembrar`
automáticamente al cruzar un umbral. Necesita su propio diseño (qué
cuenta como señal, qué umbral, qué pasa si se dispara dos veces) — se
deja anotado, no se empieza hasta que el paso 2-5 esté funcionando.
