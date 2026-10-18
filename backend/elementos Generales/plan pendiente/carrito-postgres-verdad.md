# Plan pendiente — "Redis nunca es la fuente de verdad": carrito y venta relámpago con respaldo en PostgreSQL

> **Estado (2026-10-17): HECHO en `backend/` y probado a fondo en local (más de
> 300 comprobaciones propias, más las suites de `pruebas/`). SQL aplicado a mano
> en la base local. Falta la migración real, sumar el script Lua al de `redis/`,
> los cambios del frontend y actualizar tres pruebas de `pruebas/` (todo de
> otros, ver al final).**
> SQL de referencia: `carrito-postgres-verdad.sql`. Script Lua nuevo:
> `restaurar-venta-relampago.lua`. Rutas: `endpoints/endpoints-carrito.md`.

## La directiva

El profesor: **Redis nunca debe ser la fuente de verdad.** Su modelo:

- Agregar o quitar del carrito se hace en Redis; si Redis responde, se le
  confirma a la persona, y **debajo** se va armando el pedido en PostgreSQL.
- Ver el carrito: responde Redis. Solo si Redis muere, la consulta se vuelve
  lenta y baja a PostgreSQL.
- Lo que siempre es verdad es PostgreSQL. Puede pasar que Redis diga que sí y
  PostgreSQL falle: en el checkout se detiene todo.

Antes de este cambio el carrito vivía **solo** en Redis (Redis era la verdad
del carrito y de las reservas de venta relámpago).

## Decisiones (cerradas con el usuario)

| Tema | Decisión |
|---|---|
| Dónde vive la verdad del carrito | El pedido `pendiente` de la cuenta (uno solo, `uq_pedido_pendiente_usuario`) y sus líneas en `pedido_producto` |
| Cómo se escribe PostgreSQL | Un intento asíncrono (sin hacer esperar a la persona) que copia el carrito entero de Redis, por diferencias. Si falla, el carrito queda **desincronizado** y el frontend lo puede resincronizar |
| Redis caído | Se sigue: todo va directo a PostgreSQL, más lento. Incluida la venta relámpago (sigue vendiendo) |
| Las 24 h de inactividad | Las decide PostgreSQL (`pedido.fecha_ultima_actividad`): eliminación pasiva al leer + un barrido. Si no, el carrito nunca vencería (Redis lo reconstruiría desde PostgreSQL) |
| Reservas de venta relámpago | Tabla aparte, `reserva_venta_relampago` (responsabilidad única: no columnas en `pedido_producto`). El ticket se llama `ticket` |
| Ventas que se abren o cierran solas | Abrir siembra Redis desde PostgreSQL; cerrar devuelve las reservas en la misma transacción; el checkout reserva si una línea relámpago no tiene reserva |

## Cómo quedó

### Las dos copias

- **Redis** `mesh:carrito:<id_usuario>` (HASH): una foto JSON por línea
  (incluye `id_precio_historial`, el precio que se vio, y `reserva_vence`),
  `t:<id_oferta>` el ticket, `_v` la versión de PostgreSQL que conoce, `_d` la
  marca de desincronizado.
- **PostgreSQL** `pedido` pendiente (`version`, `fecha_ultima_actividad`, sin
  dirección hasta pagar), `pedido_producto` (cada línea con su
  `id_precio_historial`), `reserva_venta_relampago`.

### Escribir (PUT / DELETE / vaciar)

1. Se escribe en Redis y se contesta.
2. `CarritoService.programarReplica` copia el carrito entero a PostgreSQL
   (`CarritoPostgresService.escribir`): una copia a la vez por cuenta, y otra
   al terminar si algo cambió mientras corría.
3. La copia compara `pedido.version` con `_v`. Si no coinciden (PostgreSQL tuvo
   cambios que Redis no vio) no pisa nada: marca `_d`. Si PostgreSQL falla,
   también. Si sale bien, guarda la versión nueva y quita `_d`.
4. Solo cambia lo que cambió (no borra y recrea filas): una copia que repite el
   estado no mueve nada, ni el grafo ni las reservas.

El `PUT` sigue leyendo PostgreSQL una vez para tomar la foto (ya lo hacía desde
el 2026-09-23). Una oferta que no existe ahora da **404**.

### Leer (GET)

Redis puro. Si Redis no tiene el carrito, se reconstruye desde PostgreSQL (con
el TTL que le queda según PostgreSQL). Si Redis no responde, se lee PostgreSQL
(`fuente: "postgres"`). El precio que se muestra es siempre el que la persona
vio (el de la línea), no el de ahora.

### Redis caído

Todo va directo a PostgreSQL: `CarritoService.definirEnPostgres`, etc. La cuenta
queda en `afectados`: cuando Redis vuelve, su carrito de Redis se reconstruye
desde PostgreSQL antes de usarse. Se detecta rápido: si el cliente de Redis no
está `ready` ni se intenta (`esRedisInalcanzable`).

### Desincronizado

`GET /carrito` dice `sincronizado: false`, el checkout contesta 409, y
`POST /carrito/sincronizar` decide: misma versión → vuelve a copiar Redis a
PostgreSQL (la escritura que faltó); PostgreSQL más nuevo o choque → Redis se
reconstruye desde PostgreSQL. La siguiente escritura que se copie bien también
lo arregla sola.

### 24 h

`fecha_ultima_actividad` se renueva en cada escritura y, como mucho cada 5 min,
al ver el carrito. El TTL de Redis se pone igual. Un carrito vencido se borra al
leerlo (`CarritoPostgresService.leer` / `escribir`) y, si nadie lo lee,
`CarritoBarridoService` (cada 10 min). Vaciar o quitar la última línea borra el
pedido pendiente: un carrito vacío no existe en ninguna de las dos.

### Checkout

Compra el pedido pendiente en una transacción (`CarritoService.ejecutarCompraCarrito`):
bloquea el pedido y las ofertas (`FOR UPDATE`, en orden de id), compara Redis
con PostgreSQL si Redis está, comprueba disponibilidad, reservas y precio, y
llama a `cambiar_direccion_pedido()` y `comprar_pedido()` (las de la 007). Las
reservas pasan a `confirmada` en la misma transacción. Ya no usa
`comprar_carrito()` (sigue en la base, sin uso). El candado de Redis contra el
doble submit sigue; si Redis no está, el `FOR UPDATE` del pedido hace lo mismo.

### Venta relámpago

- `redimensionar` ahora se usa del script original (`redis/inventario_limitado.lua`):
  la copia provisional de `plan pendiente/redimensionar-reserva.lua` no
  comprobaba que la venta existiera (contestaba AGOTADO y dejaba un hash con
  solo `rechazos`). **Bug real, encontrado en las pruebas.** El archivo
  provisional ya no se carga.
- Si la venta está vigente lo dice PostgreSQL (`es_inventario_limitado` y sin
  pasar `fecha_vencimiento_venta_limitada`), no el `EXISTS` de Redis: si Redis
  la perdió, la oferta ya no se trata como normal.
- La copia vuelve a comprobar las unidades en PostgreSQL (`oferta.stock` menos
  las reservas activas sin vencer de las demás cuentas, con `FOR UPDATE`). Si
  Redis dio de más, PostgreSQL manda: desincronizado + Redis se reconstruye.
- Redis caído: `CarritoPostgresService.aplicarReservas` reserva solo, con el
  mismo control (ticket NULL).
- `InventarioLimitadoService.restaurar` reconstruye Redis desde PostgreSQL
  (script nuevo `restaurar-venta-relampago.lua`): stock libre, cada reserva con
  su ticket y vencimiento, contador desde el ticket más alto de la historia, y
  tickets nuevos para las reservas hechas sin Redis.
  `ReservasVentaRelampagoSyncService` (cada 10 s) lo corre al arrancar, cuando
  Redis vuelve de una caída, cuando Redis no tiene una venta vigente, cuando hay
  reservas sin ticket y cuando otro servicio lo pide (una reserva rechazada, una
  compra o una cancelación de una oferta relámpago). También pasa a `vencida`
  las reservas activas que vencieron.
- Abrir la venta (`activar`) usa `restaurar` en vez de `sembrar`: **arregla el
  choque de tickets** (antes el contador volvía a 0 y un ticket viejo de un
  carrito podía ser el de otra persona en la venta nueva).
- Cerrar (a mano, por una regla, o el worker de vencidas) devuelve las reservas
  activas en la misma transacción que apaga la oferta, y quita el ticket de los
  carritos (la línea se queda, como normal).

### Lo que se quitó

- Seis rutas de `/comprador/pedidos` que armaban un pedido a mano (crear,
  agregar/cambiar/quitar líneas, cambiar dirección, comprar) y sus métodos:
  ninguna pantalla las usaba y pasaban por encima del carrito. Ahora 404. Ver
  `endpoints-compradores.md`.
- El pendiente no se lista, no se ve por id (404) y no se cancela (409) en
  `/comprador/pedidos`.

## Archivos de backend

- Nuevos: `services/carrito/carrito-postgres.service.ts`,
  `services/carrito/carrito-redis.service.ts` (la clave del carrito en Redis:
  leer, escribir, marcar sincronizado/desincronizado, y el candado del
  checkout),
  `services/carrito/carrito-barrido.service.ts`,
  `services/inventario-limitado/reservas-venta-relampago-sync.service.ts`,
  `plan pendiente/restaurar-venta-relampago.lua`.
- Reescrito: `services/carrito/carrito.service.ts` (la orquestación: qué se
  escribe en cada copia y cuándo). La comprobación de unidades de una reserva
  está una sola vez, en `CarritoPostgresService.reservarSiHayUnidades`, que
  usan la escritura del carrito y el checkout.
- Cambiados: `inventario-limitado.service.ts` (restaurar, abrir, cerrar),
  `ventas-limitadas.service.ts` (el worker de vencidas devuelve reservas),
  `compradores/pedidos.service.ts` y su controller (rutas quitadas, pendiente
  oculto, cancelar marca reconciliación), `admin-reportes.service.ts`
  (reservaciones con `LEFT JOIN` a la dirección), `models/carrito.ts`
  (`sincronizado`, `fuente`), `models/reporte.ts`, `helpers/errores.ts`
  (`ErrorConexionRedis`), `helpers/manejar-error-redis.ts`
  (`esRedisInalcanzable`), `carrito.controller.ts` (`POST /carrito/sincronizar`),
  `app.module.ts`.
- Borrados: `dto/agregar-linea-pedido.ts`, `dto/restar-linea-pedido.ts`,
  `dto/crear-pedido.ts`, `dto/cambiar-direccion-pedido.ts`.

## Le toca a otros (no tocar desde backend/)

**Migración real** (después de la de `seguimiento-ofertas.sql`): el contenido de
`carrito-postgres-verdad.sql`.

- OJO con el orden: el `CHECK pedido_direccion_salvo_pendiente` y el índice único
  de pendientes fallan si ya hay datos que no cumplen (hoy no los hay).
- Si `migrations/datos/` siembra pedidos pendientes, cada cuenta puede tener uno
  solo.

**`redis/`** (el compañero de Redis):

- Sumar `restaurar` como una rama más de `inventario_limitado.lua` (hoy vive en
  `plan pendiente/restaurar-venta-relampago.lua`, probado a mano y por el
  backend).
- Borrar `plan pendiente/redimensionar-reserva.lua` (ya no se carga).
- `redis/README.md`: la reconciliación que figuraba como pendiente ya existe
  (`ReservasVentaRelampagoSyncService`).

**Frontend:**

- Si `GET /carrito` trae `sincronizado: false`: un aviso y un botón que llame a
  `POST /carrito/sincronizar` (devuelve el carrito como queda).
- El 409 del checkout con "Tu carrito no quedo guardado del todo…" también va a
  ese botón; el de "El carrito vencio…" pide volver a agregar.
- `PUT /carrito/lineas/:id` con una oferta inexistente ahora da 404.
- Código muerto: el `modo="pedido"` de `Checkout.svelte` y `comprarPedido` /
  `cambiarDireccionPedido` de `lib/pedido.ts` llaman a rutas que ya no existen
  (nunca se ejecutaban).
- `fuente` es informativo (se puede mostrar "modo lento" si es `postgres`).

**Pruebas de `pruebas/` que hay que actualizar** (prueban el diseño viejo):

| Prueba | Qué falla | Por qué | Cómo actualizarla |
|---|---|---|---|
| `carrito.sh` sección 2 | (pasa por casualidad) | Afirma "agregar y quitar NO escriben en PostgreSQL": es justo lo contrario de la directiva. Pasa solo porque mide antes de que termine la copia asíncrona | Afirmar lo contrario: tras unos ms, el pedido pendiente tiene las líneas |
| `carrito.sh` sección 4 | oferta inventada | Ahora 404 | Esperar 404 |
| `carrito.sh` limpieza / sección 1 | `R DEL` de la clave no vacía el carrito | PostgreSQL lo reconstruye | Limpiar con `DELETE /carrito` |
| `carrito_vencimiento.sh` | compra el carrito "vencido" | Solo baja el TTL de Redis; PostgreSQL lo mantiene vivo | Envejecer también `pedido.fecha_ultima_actividad` (`now() - interval '25 hours'`) |
| `falla_checkout.sh` escenario A | compra con Redis parado | Es lo que pide la directiva | Esperar que compre |
| `falla_checkout.sh` "las cuatro cosas" | cuenta filas de `pedido` | El pedido nace al agregar (pendiente); pagar no suma una fila, la pasa a `comprado` | Contar pedidos `comprado`, no filas |

`oferta_limitada.sh` (33/33), `descuentos.sh` (98/98), `reglas_descuento.sh`
(44/44) y `reglas_periodo.sh` (61/61) pasan sin cambios.

**`docs/`**: el carrito ya no vive solo en Redis (`docs/base-de-datos.md`,
`docs/CONSISTENCIA-CHECKOUT.md`, lo que diga de "el carrito salió del modelo
relacional").

## Límites conocidos

- **`SesionGuard` consulta PostgreSQL en cada petición** (cuenta activa): con
  PostgreSQL caído toda ruta con sesión da 503, el carrito incluido. Ya era así;
  no se tocó porque es un control de seguridad de todo el backend.
- `afectados` vive en memoria: si el backend se reinicia con Redis caído, al
  volver Redis puede mostrar un carrito viejo hasta la siguiente escritura o el
  checkout (los dos lo detectan por la versión y lo marcan desincronizado; nunca
  se compra lo que no es verdad).
- Si Redis se cae entre que su script reserva y se guarda el carrito, esa
  reserva de Redis queda huérfana 15 min (aparta unidades de más un rato, nunca
  vende de más).
- La reconstrucción de Redis toma lo que PostgreSQL ya tiene: una reserva que
  Redis dio y todavía no se copió puede perderse de Redis en ese instante; la
  copia la detecta (PostgreSQL no tiene unidades o Redis da de más) y la
  siguiente reconciliación lo corrige.

## Probado en local — 2026-10-17

Arnés propio (scratchpad de Claude, no va al repo), contra el backend en marcha,
con ofertas de prueba del vendedor `vendcarga` y contenedores parados de verdad:

| Bloque | Qué | Resultado |
|---|---|---|
| A, B | Carrito con Redis vivo; copia; versiones; idempotencia; validaciones; el pendiente oculto en `/comprador/pedidos`; rutas viejas 404; restricciones de la base; Redis pierde el carrito y se reconstruye; precio visto | 65/65 |
| C, D, G | 24 h (pasivo, borde 23 h 59 min, checkout, choque al vencer); desincronizado (PostgreSQL rechaza, choque de versión, Redis tocado por fuera, sincronizar en los dos sentidos); checkout (compra, aviso de precio, bloqueantes, errores, doble submit, vacío) | 75/75 |
| E, F | Redis parado (ver, agregar, quitar, comprar con tres compras a la vez: una sola; reconstrucción al volver); PostgreSQL parado (503 limpio, nada a medias, recupera) | 31/31 |
| H | Venta relámpago: abrir, reservar, redimensionar, soltar, 30 cuentas sobre 10 unidades (10 ganan, 20 con 409, 10 reservas en PostgreSQL con tickets distintos), comprar, reserva vencida con y sin unidades, cerrar con reservas vivas, reabrir sin choque de tickets, Redis pierde la venta, Redis caído en plena venta (PostgreSQL reserva y no vende de más), comprar con Redis caído, venta abierta con la línea ya en el carrito, Redis da de más, la venta vence sola | 85/85 |
| Regla | La venta la abre y la cierra sola una regla por periodo (disparador real, cada 15 min), con carritos de antes | 15/15 |
| Barrido | Un carrito con 25 h sin tocar que nadie lee: lo borro `CarritoBarridoService` en su pasada (PostgreSQL y Redis) | OK |
| `pruebas/` | Las suites del equipo | ver la tabla de arriba |
