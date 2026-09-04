# Plan pendiente — Venta de inventario limitado (Redis)

> **Estado (2026-09-03, noche): los pasos 1, 2, 3, 4 y 5 estan CERRADOS y
> probados en vivo. El bloque de inventario limitado esta completo salvo
> la "fase futura" (activacion automatica por calor, mas abajo), que no
> era del alcance.** Evidencia: `endpoints-carrito.md` (secciones
> "Inventario limitado en PUT / DELETE / GET del carrito", "Paso 4" y
> "Bateria de estres...") y `endpoints-vendedores.md` (seccion "venta
> relampago del vendedor").

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
- Es el vendedor quien la prende (paso 2,
  `POST /vendedor/ofertas/:id/venta-limitada`) — nunca se marca sola.
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

`src/services/inventario-limitado/inventario-limitado.service.ts`. Es la
capa de mecanismo (Redis + el `.lua`); no tiene controlador propio. La usan
`CarritoService` (paso 3/4) y `VentasLimitadasService` (paso 2). Métodos,
todos probados en vivo:

- `activar(idOferta, ttlSegundos)` / `revertir(idOferta)` — el trabajo real
  del paso 2; la ruta HTTP y la autorización viven en
  `VentasLimitadasService`.
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

## Paso 2 — el vendedor abre la venta relámpago de una oferta suya (CERRADO, 2026-09-03)

Dos rutas, en su propio controlador/servicio
(`VentasLimitadasController` / `VentasLimitadasService`, bajo el prefijo
`/vendedor/ofertas`), siguiendo el contrato que dejó el compañero en el
BLOQUE 9 de `docs/BACKEND-PENDIENTE.md`:

- **`POST /vendedor/ofertas/:id/venta-limitada`** — abre la venta. Cuerpo
  `{ "duracion_segundos": N }` opcional (0 = sin vencimiento; tope 7 días).
  201 con `{ id_oferta, stock_sembrado }`. Por dentro: `activar()`.
- **`DELETE /vendedor/ofertas/:id/venta-limitada`** — la cierra
  (`revertir()`). 200 sin cuerpo.

Decisiones cerradas (de las tres preguntas que estaban abiertas):

- **Quién**: el dueño de la oferta. Una oferta ajena o inexistente → el
  404 genérico de siempre. Un admin actúa como la cuenta de la tienda
  (igual que el resto de `/vendedor/ofertas`).
- **Cuántas unidades**: siempre el `stock` completo de la oferta en ese
  instante — no se sembró un subconjunto. Sembrar menos que el stock real
  dejaría unidades "invisibles" en PostgreSQL que nadie podría comprar por
  ningún camino mientras la venta esté abierta; y el caso de uso
  ("liquido estas 100 unidades ya") es justo poner todo.
- **Duración**: la elige el vendedor (`duracion_segundos`), con `0` = sin
  vencimiento por defecto y un tope de 7 días.

`activar()` sigue lanzando los dos 409 que el panel distingue (la oferta
no está `activa`; ya está en venta relámpago). `cerrar()` añade un tercer
409: la oferta no estaba en venta relámpago.

Evidencia: `test-ventas-limitadas.sh`, 45/45; detalle en
`endpoints-vendedores.md`, sección "Pruebas — venta relámpago del
vendedor". `GET /vendedor/ofertas`, `GET /vendedor/ofertas/producto/:id`
(`mi_oferta`) y `GET /productos/:id` (`ofertas[]`, público) ahora traen
`es_inventario_limitado`.

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

**Bug encontrado en la batería de estrés y corregido:** si la venta
relámpago se cerraba (`revertir`) con la línea todavía en el carrito y el
comprador luego cambiaba la cantidad de esa línea, el `PUT` por la vía
normal **no limpiaba el campo `t:<id_oferta>` huérfano**. Resultado: la
línea seguía saliendo como `es_inventario_limitado` en `GET /carrito` y el
checkout intentaba `confirmar` un ticket que ya no existía. Arreglo: la
rama normal de `definirCantidad` hace `HDEL` del campo `t:` siempre (es un
no-op si no está).

**Candado de checkout (mismo día, salió de la batería de estrés):** la
prueba destapó que dos `POST /carrito/comprar` idénticos y concurrentes
creaban **dos pedidos** (cobrando dos veces) — no es de inventario
limitado, afecta a cualquier carrito. Corregido con
`CarritoService.conCandadoCheckout`: candado corto en Redis
`mesh:checkout:<id_usuario>` (`SET EX 30 NX`), 409 para el segundo. El otro
camino de compra (`POST /comprador/pedidos/:id/comprar`) ya era seguro.
Detalle en `endpoints-carrito.md` § "Candado de checkout".

Evidencia: `endpoints-carrito.md`, secciones "Paso 4", "Batería de estrés
del ciclo de vida de la reserva" y `test-candado-checkout.sh` — 74 + 62 +
22 comprobaciones + concurrencia, 0 fallos de regresión, base local
intacta. Un hallazgo **pre-existente** anotado y sin tocar (500 en vez de
503 con PostgreSQL caído, es del `SesionGuard`).

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
