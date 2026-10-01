# Endpoints del carrito

El carrito de compra de la Entrega 2. **Vive solo en Redis** — reemplaza al
carrito viejo, que era una fila de `pedido` en estado `pendiente` en
PostgreSQL con el `id_pedido` en `localStorage`.

> **Estado (2026-08-29): las cinco rutas del carrito están hechas y
> probadas** — `GET /carrito`, `PUT /carrito/lineas/:idOferta`,
> `DELETE /carrito/lineas/:idOferta`, `DELETE /carrito` (43 comprobaciones)
> y `POST /carrito/comprar` (29 comprobaciones), 0 fallos — ver "Pruebas".
>
> **2026-09-03:** chequeo de precio al pagar + reconocimiento de ofertas de
> inventario limitado en `PUT`/`DELETE`/`GET` + **paso 4**:
> `POST /carrito/comprar` y `DELETE /carrito` conectan `confirmar`/`devolver`
> de la venta relámpago. Ver las secciones de "Pruebas" con fecha 2026-09-03.
>
> **2026-10-01 — El carrito y el checkout ya no leen MongoDB.** El nombre del
> producto, el nombre y el estado de la variante y la imagen de portada salen
> de la copia del catálogo en PostgreSQL (`producto_catalogo` y
> `variante_catalogo`, unidas a `oferta` por el par `id_producto_mongo` +
> `id_producto_variante_mongo`). Mongo sigue siendo la fuente del catálogo; la
> copia la mantiene el backend al crear, proponer y editar productos. Efectos
> en esta API: (1) `PUT /carrito/lineas/:idOferta` y `POST /carrito/comprar`
> ya no devuelven 503 por MongoDB; (2) una variante que todavía no esté en la
> copia sale como `"(producto no encontrado)"` / `"(variante no encontrada)"`
> y su `disponible` no se ve afectado por el estado, pero al pagar un pedido
> manual cuenta como no disponible; (3) los campos calculados de Mongo ya no
> se recalculan en la petición: los recalcula un worker aparte (ver abajo).
> Decisiones y plan: `plan pendiente/catalogo-en-postgres.md` y
> `plan pendiente/evento-producto.md`.
>
> **2026-09-23 — REDISEÑO pedido por el profesor: "el carrito debe resistir
> por sí solo".** `GET /carrito` ya no consulta PostgreSQL ni MongoDB — lee
> una FOTO (nombre, precio, imagen, vendedor, stock, disponibilidad) que se
> guarda en el propio HASH de Redis. A cambio, `PUT /carrito/lineas/:idOferta`
> pasó a consultar esas dos bases (antes no lo hacía) para tomar esa foto.
> El checkout sigue verificando en vivo antes de cobrar, pero el chequeo de
> precio dejó de depender de que el frontend mande nada: ahora compara la
> foto guardada contra el precio real, los dos del lado del servidor — se
> quitó `lineas_precio_visto` del cuerpo de `POST /carrito/comprar`. Ver "El
> modelo" (reescrito) y "Pruebas — rediseño 2026-09-23".
>
> **Hallazgo pendiente, sin resolver todavía:** aunque `GET /carrito` ya no
> toca Postgres/Mongo, la petición completa SÍ sigue dependiendo de Postgres
> — `SesionGuard` (protege TODAS las rutas con sesión, no solo el carrito)
> consulta `usuarios` en cada petición para confirmar que la cuenta sigue
> activa. Con Postgres caído, `GET /carrito` todavía responde 503 antes de
> llegar a `CarritoService`. No se tocó porque es un cambio que afecta a
> cualquier ruta autenticada del backend, no solo al carrito — pendiente de
> decidir cómo (cachear "cuenta activa" en Redis con un TTL, o algo
> similar).

Código: `src/controllers/carrito/carrito.controller.ts` +
`src/services/carrito/carrito.service.ts`. Cliente Redis:
`src/database/redis.ts`.

---

## El modelo

Una sola clave por cuenta, un **HASH**:

```
mesh:carrito:<id_usuario>   HASH   { <id_oferta>: <linea en JSON>, ... }
```

Cada campo guarda la cantidad **junto con una foto** de nombre, precio,
imagen, vendedor, stock y disponibilidad (`LineaCarritoRedis`), tomada de
PostgreSQL/Mongo la última vez que se agregó o se cambió la cantidad de esa
línea. Es a propósito, pedido explícito del profesor (2026-09-23): el
carrito tiene que "resistir por sí solo" — que **verlo** nunca dependa de
que Postgres o Mongo estén arriba. A cambio, lo que se ve puede estar
desactualizado hasta por las 24 h que dura el carrito (el nombre pudo
cambiar, el precio también) — el checkout es la única excepción, paga
siempre con datos en vivo, nunca con esta foto.

### Qué toca cada base

| Ruta | Redis | PostgreSQL / Mongo |
|---|---|---|
| `PUT /carrito/lineas/:idOferta` | `HSET` + `EXPIRE` | **SÍ, una vez**: 1 consulta a PostgreSQL (`oferta` unida a la copia del catálogo), solo para ESA línea, para armar la foto que se guarda. **Ya no toca Mongo** (2026-10-01) |
| `DELETE /carrito/lineas/:idOferta` | `HDEL` + `EXPIRE` | **nada** |
| `DELETE /carrito` | `DEL` | **nada** |
| `GET /carrito` | `HGETALL` + `EXPIRE` | **nada** — lee las fotos ya guardadas |
| `POST /carrito/comprar` | `HGETALL` (x2: fotos guardadas + tickets), `DEL` al final (y `HDEL` de las líneas bloqueantes si el bloqueo fue por disponibilidad y el interruptor `QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR` está en `true`) | 1 consulta EN VIVO a `oferta` + 1 a `productos` (Mongo, en lote) + `resolverDireccionHistorial` + `comprar_carrito()` (una transacción) + recálculo de campos calculados en Mongo |

Quitar una línea / vaciar sigue siendo **Redis puro**. El stock no se
comprueba al agregar — nunca fue una reserva — se comprueba (con datos en
vivo) al pintar el carrito y de forma bloqueante al pagar.

### Cómo nace y cómo muere

**No hay ruta para crear un carrito.** El primer `HSET` sobre una clave que
no existe la crea sola: el carrito nace con el primer producto. Muere solo:

- **TTL:** 24 h sin tocarlo → Redis borra la clave. No hay nada que
  liberar (agregar nunca reservó stock). El TTL se re-pone entero en cada
  toque, incluido `GET /carrito` (mirar cuenta como actividad).
- **checkout:** tras `comprar_carrito()` → `DEL`.
- **vaciar:** `DELETE /carrito` → `DEL`.

Un carrito sin líneas **no existe como clave**. "Carrito vacío" = "no hay
clave" = `GET /carrito` devuelve `{ lineas: [], total: "0.00", ... }`.

### De quién es

Todas las rutas piden sesión (`SesionGuard`, sin `@Roles` — cualquiera con
sesión tiene carrito, igual que comprar). El `id_usuario` sale del token →
la clave es `mesh:carrito:<id_usuario>`. **No hay id de carrito** que pasar
ni guardar en `localStorage`. Dos dispositivos de la misma cuenta comparten
el carrito sin hacer nada.

---

## El inventario limitado (venta relámpago) — construcción en curso

> **Estado (2026-09-03): PUT / DELETE / GET del carrito reconocen una oferta
> de inventario limitado, y `POST /carrito/comprar` ya conecta
> `confirmar`/`devolver` (paso 4) — todo probado en vivo. Lo único que
> falta es una ruta para que el vendedor abra la venta (paso 2). Detalle
> completo del diseño y lo pendiente en
> `elementos Generales/plan pendiente/inventario-limitado.md`.**

Una oferta puntual puede operar en modo "venta relámpago": el stock no lo
decide PostgreSQL con `FOR UPDATE` sino un script Lua de Redis
(`redis/inventario_limitado.lua`, del compañero, más
`redimensionar-reserva.lua`, provisional — ver el plan) que reserva y
descuenta en un solo paso atómico, sin bloqueos de aplicación. El backend
sabe si una oferta está en este modo con una sola consulta a Redis
(`EXISTS mesh:oferta:<id_oferta>`) — **no toca PostgreSQL** para
averiguarlo, así que el `PUT`/`DELETE` normales siguen sin costar una
consulta extra cuando la oferta es normal (el caso de siempre).

**La diferencia real para el comprador:** agregar una oferta de este tipo
al carrito **sí reserva de verdad** las unidades (a diferencia de una
oferta normal, donde agregar nunca reserva nada — es solo intención). Esa
reserva vence sola a los 15 minutos si nadie la confirma
(`TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS`, `helpers/constantes.ts`).

---

## GET /carrito

El carrito completo, cada línea con nombre, precio, stock, subtotal,
vendedor y disponibilidad **tal como quedaron guardados en Redis** — no en
vivo (ver "El modelo"). Renueva el TTL. **No toca PostgreSQL ni Mongo.**

```
GET /carrito
```

### 200

```json
{
  "ok": true,
  "mensaje": "Carrito obtenido",
  "payload": {
    "lineas": [
      {
        "id_oferta": 3,
        "cantidad": 10,
        "id_producto": 1,
        "id_producto_variante": 13,
        "nombre_producto": "Laptop Ambar Campus 14",
        "nombre_variante": "16 GB / 512 GB",
        "imagen": "https://.../laptop.png",
        "precio": "5840.00",
        "porcentaje_descuento": null,
        "subtotal": "58400.00",
        "vendedor": { "usuario": "ventas_norte", "nombre": "Carlos Ramirez" },
        "stock_disponible": 24,
        "disponible": true,
        "motivo": null,
        "es_inventario_limitado": false
      },
      {
        "id_oferta": 15,
        "cantidad": 3,
        "...": "...",
        "precio": "10958.00",
        "subtotal": "32874.00",
        "stock_disponible": 1,
        "disponible": false,
        "motivo": "stock_insuficiente",
        "es_inventario_limitado": false
      }
    ],
    "total": "103957.00",
    "total_lineas": 5,
    "total_items": 16
  }
}
```

- **`precio`** es el que quedó GUARDADO cuando esta línea se agregó o se le
  cambió la cantidad por última vez — no necesariamente el de la oferta
  ahora mismo (ver "El modelo"). Ya viene con el descuento aplicado si la
  oferta tenía uno en ese momento (2026-09-23, ver
  `plan pendiente/descuentos-oferta.md`); `porcentaje_descuento` es solo
  informativo (para un badge), `precio` ya lo tiene aplicado. `subtotal` =
  `precio` × `cantidad`.
- **`total`** = suma de todos los subtotales. `total_lineas` = ofertas
  distintas; `total_items` = suma de cantidades.
- **`disponible`** — `true` si la línea se puede comprar tal cual. Si no,
  **`motivo`** dice por qué:

  | `motivo` | Significa |
  |---|---|
  | `oferta_no_disponible` | la oferta está pausada / retirada / pendiente / rechazada |
  | `agotado` | stock 0 |
  | `stock_insuficiente` | hay stock, pero menos que la cantidad pedida |
  | `oferta_no_existe` | el `id_oferta` del carrito no existe (un `PUT` con un id inventado). La línea sale con nombres `"(oferta no encontrada)"` y precio `0.00`, para que el frontend la muestre y ofrezca quitarla en vez de que desaparezca sin avisar |
  | `reserva_vencida` | era una oferta de inventario limitado y la reserva que la respaldaba venció sin que nadie la confirmara ni la redimensionara a tiempo |

- **`es_inventario_limitado`** — `true` si esta oferta opera bajo el
  mecanismo de venta relámpago (ver la sección de arriba). Para estas
  líneas, `stock_disponible` sigue siendo el de PostgreSQL (que queda
  **congelado** desde que se abrió la venta — no se mueve con cada
  reserva de Redis); la disponibilidad real de la línea es si la reserva
  sigue viva, no ese número — por eso `reserva_vencida` puede salir aunque
  `stock_disponible` todavía se vea positivo.
- Un producto o variante que no aparezca en la copia del catálogo en
  PostgreSQL (`variante_catalogo`; no debería: se siembra y se mantiene al
  crear/editar productos) sale con `"(producto no encontrado)"` / `"(variante no
  encontrada)"`, sin romper el resto del carrito.

### 401 / 503 / 500

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo obtener el carrito", "payload": null }
```

---

## PUT /carrito/lineas/:idOferta

Fija la cantidad **absoluta** de una oferta en el carrito (no un `+1` /
`-1`). Si la línea no estaba, se agrega; si estaba, se **reemplaza** la
cantidad. Si el carrito no existía, nace acá. Renueva el TTL.

```
PUT /carrito/lineas/3
```

```json
{ "cantidad": 10 }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `cantidad` | Sí | Entero de **1 a 1000**. Para quitar la línea → `DELETE /carrito/lineas/:idOferta`, no `cantidad: 0`. El límite real es el stock, que **no se comprueba acá para una oferta normal** (se ve en `GET /carrito` y bloquea al pagar); el 1000 es solo un tope de sanidad |

`:idOferta` tiene que ser un entero. **No se valida que exista para
rechazar el `PUT`** — pero sí se consulta (para armar la foto): un id
inventado se guarda igual, con nombres de relleno `"(oferta no
encontrada)"` y `motivo: "oferta_no_existe"` ya congelados en la foto, y
`comprar_carrito()` lo rechaza al pagar de todos modos. Este `PUT` es la
**única** escritura del carrito que toca Postgres (una consulta, solo por
esta línea; desde el 2026-10-01 ya no toca Mongo) — el resto de las rutas de escritura siguen
siendo Redis puro.

### Si la oferta es de inventario limitado (venta relámpago)

Única excepción a "agregar nunca reserva nada" (ver la sección de arriba).
El backend comprueba con Redis (`EXISTS`, sin tocar Postgres) si
`:idOferta` está en este modo:

- Si la línea **no tenía** reserva todavía, pide `cantidad` unidades de
  una.
- Si la línea **ya tenía** una reserva (un `PUT` anterior sobre la misma
  oferta), la REDIMENSIONA: suelta la vieja y pide la nueva en un solo
  paso atómico — solo hace falta la **diferencia** de unidades libres, no
  la cantidad nueva completa (ver
  `plan pendiente/redimensionar-reserva.lua`).
- Si no alcanza, **409 de una vez**, antes de tocar el carrito — a
  diferencia de una oferta normal, que siempre se deja agregar.

### 200

```json
{
  "ok": true,
  "mensaje": "Cantidad actualizada",
  "payload": {
    "id_oferta": 3,
    "cantidad": 10,
    "es_inventario_limitado": false,
    "total_lineas": 2,
    "total_items": 11
  }
}
```

Un **resumen ligero** (calculado solo con Redis), para que el frontend
actualice el contador sin esperar el enriquecido. Para la vista completa
→ `GET /carrito`.

### 400 / 401

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "La cantidad debe ser un numero entero entre 1 y 1000", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
```

### 409 — solo para una oferta de inventario limitado

```json
{ "ok": false, "mensaje": "No hay suficiente stock en la venta relampago de la oferta 22: pediste 5 y hay 3 disponibles (contando lo que ya tenias reservado)", "payload": null }
```

No se toca nada del carrito cuando esto pasa: si ya tenía una reserva
previa, sigue intacta.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
{ "ok": false, "mensaje": "No se pudo actualizar el carrito", "payload": null }
```

El de PostgreSQL es nuevo desde el rediseño (2026-09-23): antes `PUT` no
tocaba ni Postgres ni Mongo. El de MongoDB **ya no puede salir de esta ruta**
desde el 2026-10-01 (el catálogo se lee de PostgreSQL); queda en la lista
solo por historia.

---

## DELETE /carrito/lineas/:idOferta

Quita una oferta del carrito. **Idempotente**: si la línea no estaba,
responde 200 igual. Si era la última línea, Redis borra la clave sola (un
HASH sin campos deja de existir). Renueva el TTL si quedan líneas.

**Si la línea era de inventario limitado** (tenía una reserva viva), la
suelta con `devolver` **antes** de quitarla del carrito — la unidad queda
disponible de inmediato para el siguiente comprador, en vez de esperar a
que la reserva venza sola a los 15 minutos.

```
DELETE /carrito/lineas/3
```

### 200

```json
{
  "ok": true,
  "mensaje": "Producto quitado del carrito",
  "payload": { "total_lineas": 1, "total_items": 1 }
}
```

### 400 / 401 / 503 / 500

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
{ "ok": false, "mensaje": "No se pudo quitar el producto del carrito", "payload": null }
```

---

## DELETE /carrito

Vacía el carrito entero: un `DEL` de la clave. **Idempotente**. Se llama
también (internamente) tras un checkout correcto.

**Vaciado manual y reservas de inventario limitado (2026-09-03, paso 4):**
si el carrito tenía líneas de inventario limitado con reserva viva, este
vaciado **manual** las suelta (`devolver`) antes del `DEL` — sus unidades
vuelven al contador de Redis en el acto, no cuando vence el TTL. El vaciado
que hace `POST /carrito/comprar` tras una compra correcta **no** las suelta:
ahí ya se confirmaron (`confirmar`) una por una, devolverlas soltaría
unidades recién vendidas. Lo decide el parámetro interno `soltarReservas`
de `CarritoService.vaciar()` (el controlador de esta ruta lo pasa en `true`).

```
DELETE /carrito
```

### 200

```json
{ "ok": true, "mensaje": "Carrito vaciado", "payload": null }
```

### 401 / 503 / 500

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
{ "ok": false, "mensaje": "No se pudo vaciar el carrito", "payload": null }
```

---

## POST /carrito/comprar

El **checkout**. Lee el carrito, comprueba que todo se pueda comprar, y lo
compra llamando a **`comprar_carrito()`**
(`migrations/012_comprar_carrito.sql`), que crea el pedido, le mete todas
las líneas y lo compra en **una sola transacción** — un fallo no deja ni
pedido ni líneas a medias. Si sale bien: `DEL` del carrito. Los campos calculados de Mongo de cada
producto tocado **ya no se recalculan en esta petición** (2026-10-01): los
triggers de `oferta` anotan el producto en `evento_producto` dentro de la
misma transacción de la compra y `EventoProductoSyncService` lo recalcula
cada 5 s. La tarjeta del catálogo puede tardar unos segundos en reflejar el
stock nuevo; la ficha y el cobro siguen en vivo contra PostgreSQL. Con Mongo
caído la compra responde igual de rápido: ya no depende de él.

```
POST /carrito/comprar
```

```json
{
  "id_direccion": 2,
  "metodo_pago": "efectivo contra entrega"
}
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `id_direccion` | Sí | El id normal (el que da `GET /direccion-usuario`), number o string. El backend resuelve su versión vigente en `direccion_historial` y exige que sea **de la cuenta** |
| `metodo_pago` | Sí | `"tarjeta"`, `"transferencia"` o `"efectivo contra entrega"` |
| `tarjeta` | Solo si `metodo_pago` es `"tarjeta"` | `{ numero, vencimiento (MM/AA), cvv, titular }` — se valida y "cobra" el mock (`helpers/validaciones-tarjeta.ts`) |
| `confirmar_cambios` | No | `true` para seguir con la compra al precio de **hoy** aunque el chequeo de precio haya marcado una diferencia |

> **Cambio (2026-09-23): ya no existe `lineas_precio_visto`.** El cliente
> nunca manda nada sobre precios — no hace falta, ni sería seguro: el
> carrito de Redis YA guarda el precio que le mostró el último
> `GET /carrito` (la foto de cada línea), así que el backend compara esa
> foto contra el precio real él solo, sin depender de lo que diga el
> cliente. Si el frontend todavía manda `lineas_precio_visto` de una
> versión vieja, el backend simplemente lo ignora (no hay validación que lo
> rechace, pero tampoco hace nada con él) — es seguro dejar de mandarlo
> cuando se actualice el frontend.

**El precio que se cobra es siempre el del momento de pagar** (el mismo que
devuelve `comprar_carrito()`), nunca la foto de Redis — esa foto es solo
para *detectar* el cambio, no para fijar el precio.

### El chequeo de precio (sin `confirmar_cambios`)

Es enteramente del lado del servidor, en dos pasos:

1. Lee la foto de cada línea guardada en el HASH de Redis (el `precio` que
   `GET /carrito` le mostró al cliente la última vez).
2. La compara contra el precio real de esa oferta, consultado en vivo a
   Postgres (`verCarritoEnVivo`).

- Si **todos coinciden**: sigue con la compra normal, sin pedir nada más.
- Si **alguno no coincide** y `confirmar_cambios` no vino en `true`: no se
  compra nada — la respuesta sale con `comprado: false` y la lista de
  `avisos`, para que el frontend le muestre al usuario (un popup o
  similar) qué cambió antes de seguir.
- Si el cliente reenvía la **misma petición** con `confirmar_cambios: true`:
  la compra sigue al precio de hoy (el de `avisos[].precio_actual`).

**Esto es independiente del bloqueo por disponibilidad** (agotado, oferta
pausada, etc. — ver 409 abajo): eso siempre rechaza la compra, con o sin
`confirmar_cambios`. El aviso de precio solo aplica cuando todas las líneas
sí se pueden comprar y lo único que cambió es cuánto cuestan.

### Líneas de inventario limitado (paso 4, 2026-09-03)

Si el carrito trae líneas de venta relámpago con reserva viva (campo
`t:<id_oferta>` en el hash), el checkout las cierra en Redis además de en
PostgreSQL — el cliente no manda nada distinto, es todo del lado del
servidor:

- **La compra sale bien** (`comprar_carrito()` devolvió): cada reserva pasa
  de *reservada* a *vendida* (`confirmar`, op de
  `redis/inventario_limitado.lua`). Es *best-effort*: la venta ya está
  cerrada en PostgreSQL (el libro contable, con su `FOR UPDATE`), así que
  un fallo de Redis aquí **no** deshace la compra — se registra y sigue. Una
  reserva que quede sin confirmar vence sola a los 15 min y su unidad
  vuelve al contador de Redis (un desajuste chico y acotado entre los dos
  contadores, no una sobreventa).
- **`comprar_carrito()` falla** (oferta pausada/agotada entre ver y pagar,
  o error de conexión): las reservas se sueltan (`devolver`) — sus unidades
  vuelven al contador de Redis en el acto, sin esperar el TTL. El carrito
  **no** se vacía; en el siguiente `GET /carrito` esas líneas salen
  `disponible: false, motivo: "reserva_vencida"` y hay que volver a
  agregarlas (re-reservar) antes de reintentar.
- **El chequeo de precio devuelve `comprado: false`**: no se toca nada —
  las reservas siguen vivas, el cliente confirma y reintenta dentro del
  TTL.

### 201 — compra completada

```json
{
  "ok": true,
  "mensaje": "Compra realizada correctamente",
  "payload": {
    "comprado": true,
    "id_pedido": 3,
    "total": "12950.00",
    "stock": [
      { "id_oferta": 7, "id_usuario": 2, "id_producto": 1, "id_producto_variante": 12, "stock": 32 },
      { "id_oferta": 11, "id_usuario": 2, "id_producto": 2, "id_producto_variante": 11, "stock": 25 }
    ]
  }
}
```

`stock` es el saldo resultante de cada oferta tocada — lo que ya se puso al
día en Mongo. Con `id_pedido` se abre el detalle de la compra
(`GET /comprador/pedidos/:id`).

### 201 — hay que confirmar un cambio de precio

```json
{
  "ok": true,
  "mensaje": "Hay cambios que revisar antes de comprar",
  "payload": {
    "comprado": false,
    "avisos": [
      {
        "id_oferta": 11,
        "nombre_producto": "Laptop Ambar Campus 14",
        "nombre_variante": "16 GB / 512 GB",
        "precio_visto": "10958.00",
        "precio_actual": "11400.00"
      }
    ]
  }
}
```

No se tocó nada — ni Redis, ni Postgres, ni Mongo. Es seguro reenviar la
misma petición con `confirmar_cambios: true` para comprar al precio nuevo.

### 400 / 401

```json
{ "ok": false, "mensaje": "El metodo_pago es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El id_direccion es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El numero de tarjeta no es valido", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
```

### 402

```json
{ "ok": false, "mensaje": "La tarjeta esta vencida", "payload": null }
```

Datos de tarjeta bien formados pero el cobro (mock) se rechaza. No se toca
nada del pedido.

### 404

```json
{ "ok": false, "mensaje": "No existe una direccion con ese id", "payload": null }
```

`id_direccion` no existe, o es de otra cuenta (mismo mensaje).

### 409

```json
{ "ok": false, "mensaje": "El carrito esta vacio", "payload": null }
{ "ok": false, "mensaje": "\"64 GB / 2 TB\" ya no esta disponible; \"Cable 3 m\" no tiene stock suficiente", "payload": null }
{ "ok": false, "mensaje": "Ya tienes una compra en curso, espera un momento antes de reintentar", "payload": null }
```

**Candado de checkout (2026-09-03).** Al entrar, `comprarCarrito` toma un
candado corto en Redis, `mesh:checkout:<id_usuario>` (`SET ... EX 30 NX`).
Si la misma cuenta ya tiene una compra en curso, corta con el 409 de
arriba **sin leer el carrito ni tocar nada**. Cierra el hueco del doble
submit: dos `POST /carrito/comprar` idénticos y concurrentes leían los dos
el carrito lleno antes de que ninguno lo vaciara y creaban **dos pedidos**
(cobrando dos veces). `SET NX` es atómico, así que solo una petición entra;
el candado se suelta al terminar (éxito o error) y, si el proceso muere a
mitad, el `EX 30` lo limpia. Es **por cuenta** — dos personas distintas
compran a la vez sin estorbarse.

El carrito está vacío, o alguna línea no se puede comprar. El chequeo
previo (con `GET /carrito`) arma la **lista** de todos los problemas; si
algo cambia entre ese chequeo y `comprar_carrito()`, la propia función lo
rechaza dentro de su transacción y no queda nada escrito. **Nada de esto se
puede saltar con `confirmar_cambios`** — solo aplica al aviso de precio.

Motivos de bloqueo: oferta pausada/retirada (`ya no esta disponible`),
variante desactivada en el catálogo (`ya no esta disponible en el
catalogo`), stock 0 (`esta agotada`), stock insuficiente (`no tiene stock
suficiente`), id de oferta inexistente (`ya no existe`).

**Interruptor `QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR`**
(`helpers/constantes.ts`, hoy en `false`): la compra se rechaza igual en
ambos casos; lo único que cambia es si, además, esas líneas se borran del
carrito en Redis antes de responder (`true`) o si el carrito queda intacto
para que el cliente decida (`false`). No es algo que la petición pueda
pedir — es una constante del código, hay que tocarla y redesplegar para
cambiar el comportamiento.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
{ "ok": false, "mensaje": "No se pudo completar la compra", "payload": null }
```

---

## Pruebas — contra las bases reales (2026-08-29)

Scripts fuera del repo. Las cuatro primeras rutas **no escriben en
PostgreSQL ni en Mongo** (teardown = borrar la clave de Redis). El checkout
sí: crea un pedido real; el teardown lo borra y restaura el stock exacto.

### `GET` / `PUT` / `DELETE` del carrito — 43/43

**`PUT /carrito/lineas/:idOferta`:**

| Caso | Resultado |
|---|---|
| Fijar cantidad 2 de la oferta 3 | 200; `HGET` = 2; TTL ≈ 86400 s |
| Agregar una segunda oferta | `total_lineas: 2`, `total_items: 3` |
| Re-fijar la oferta 3 a 10 | `HGET` = 10 (absoluto, **no** suma) |
| `cantidad` 0 / -1 / 1001 / no numérica / ausente | 400 |
| `:idOferta` no numérico | 400 |
| Sin sesión | 401 |
| `PUT` sobre oferta con stock bajo, oferta pausada, u oferta inexistente | **200** — no se valida nada al agregar |

**`GET /carrito`:**

| Caso | Resultado |
|---|---|
| Carrito con 5 líneas | `subtotal` = `precio` × `cantidad`; `total` = suma de subtotales; `total_items` = suma de cantidades |
| Oferta activa con stock suficiente | `disponible: true`, `motivo: null` |
| Piden 3, stock 1 | `disponible: false`, `motivo: "stock_insuficiente"` |
| Oferta pausada | `motivo: "oferta_no_disponible"` |
| `id_oferta` inexistente | `motivo: "oferta_no_existe"`, nombres `"(oferta no encontrada)"` |
| Trae `nombre_producto` (Mongo) y `vendedor` (Postgres) | sí |
| Carrito vacío | `{ lineas: [], total: "0.00", total_lineas: 0, total_items: 0 }` |
| Sin sesión | 401 |

**`DELETE /carrito/lineas/:idOferta`:**

| Caso | Resultado |
|---|---|
| Quitar una línea | 200; `HEXISTS` = 0 |
| Quitar otra vez (ya no estaba) | 200 — idempotente |
| Quitar todas las líneas | la clave del carrito **desaparece sola** |
| `:idOferta` no numérico / sin sesión | 400 / 401 |

### `POST /carrito/comprar` — 29/29

| Caso | Resultado |
|---|---|
| **Happy path**: comprar oferta 7 ×2 + oferta 11 ×1 | 201; `total: "12950.00"`; pedido creado en estado `comprado`, pago `pagado`, 2 líneas, `monto` = 12950.00; stock de las ofertas baja 2 y 1; 2 movimientos de kardex (`venta`); **el carrito de Redis se vacía** |
| Carrito vacío | 409 "El carrito esta vacio" |
| Comprar otra vez (carrito ya vacío tras la compra) | 409 |
| Línea con oferta **pausada** | 409 "... ya no esta disponible" |
| Línea con **stock insuficiente** (piden 3, stock 1) | 409 "... no tiene stock suficiente" |
| Línea con `id_oferta` **inexistente** | 409 "... ya no existe" |
| `id_direccion` ausente / inválida | 400 |
| `id_direccion` inexistente o de otra cuenta | 404 |
| `metodo_pago` ausente | 400 |
| `metodo_pago: "tarjeta"` con tarjeta inválida | 400 |
| Sin sesión | 401 |

Teardown verificado: pedidos vuelve a 2, el stock de las ofertas a su valor
original, y los campos calculados de Mongo (`stock_tienda` / `stock_total`
/ `total_ofertas`) quedan iguales a la suma real en PostgreSQL.

Regresión: reseñas 29/29, votos 40/40, bug 1 36/36 — verdes.

### `POST /carrito/comprar` — chequeo de precio (`lineas_precio_visto`) y switch de stock (2026-09-03) — 12/12

Contra el servidor y las bases reales (`compradora_norte`, id 7). Dos
compras reales de prueba (pedidos 6 y 7): teardown verificado — `pedido`
vuelve a 2 filas, el stock de cada oferta tocada vuelve a su valor
original, y los campos calculados de Mongo (`stock_total`) se
resincronizaron a mano tras el `UPDATE` directo de teardown (un `UPDATE`
por SQL no dispara `recalcularCamposCalculados`, solo lo hace el flujo de
la app — esperado, no es un bug).

| Caso | Resultado |
|---|---|
| Un precio discrepa (`precio_visto` viejo), el otro coincide, sin `confirmar_cambios` | 201, `comprado: false`, `avisos` trae **solo** la línea que discrepa; el carrito queda con sus 2 líneas intactas; `pedido` sigue en 2 filas |
| Misma petición + `confirmar_cambios: true` | 201, `comprado: true`; se cobra el **precio actual** (3734.00), no el `precio_visto` viejo (3700.00) — verificado contra `precio_historial`; carrito queda vacío |
| `stock_insuficiente` (piden 2, stock 1), interruptor en `false` (default) | 409; la línea **sigue** en el carrito después |
| Oferta pausada, interruptor en `false` | 409; la línea **sigue** en el carrito después |
| Bloqueante (oferta pausada) + línea válida con `precio_visto` erróneo, interruptor en `false` | 409 (el bloqueo gana) — **no** `comprado: false`; ambas líneas siguen en el carrito |
| Mismo caso anterior, con el interruptor en `true` | 409 igual; pero la línea bloqueante **desaparece** del carrito, la línea válida queda |
| `precio_visto: "3734.0"` vs. actual `"3734.00"` | `comprado: false` — la comparación es **texto exacto**, formatos distintos cuentan como cambio, tal como está documentado |
| `lineas_precio_visto` con un `id_oferta` que no está en el carrito (`9999`) + el resto coincide | se ignora sin romper nada; compra normal completada |
| Sin `lineas_precio_visto` (regresión) | compra normal, igual que antes del cambio |
| Carrito vacío / `id_oferta` inventado / `metodo_pago` ausente / `id_direccion` ausente | 409 / 409 (`"ya no existe"`) / 400 / 400 — sin cambios |

Interruptor probado en ambos valores (`false` y `true`, en `helpers/constantes.ts`, con `nest --watch` recargando solo) y devuelto a `false` al terminar.

### Inventario limitado en `PUT` / `DELETE` / `GET` del carrito (2026-09-03)

Contra el servidor y las bases reales. Ofertas de prueba activadas con
`InventarioLimitadoService.activar()` (disparado a mano, sin ruta HTTP
todavía) y revertidas al terminar (`revertir()` + `UPDATE oferta SET
stock = ...` para restaurar el número original).

| Caso | Resultado |
|---|---|
| `PUT` sobre oferta limitada (sembrada con 3), pide 2 | 200, `es_inventario_limitado: true`; Redis: `stock 1, reservado 2` |
| `PUT` de nuevo, pide 5 (más que el efectivo = 3) | 409 con el mensaje de stock, **nada se toca** — Redis sigue con la reserva de 2 intacta |
| `PUT` de nuevo, pide 3 (exacto) | 200 — redimensiona: solo pidió 1 más, no 3; ticket viejo reemplazado por uno nuevo |
| `GET /carrito` con esa línea | `es_inventario_limitado: true`, `disponible: true` |
| Se agrega también una oferta **normal** al mismo carrito | `es_inventario_limitado: false`, comportamiento sin cambios — regresión OK |
| `DELETE` de la línea limitada | 200; Redis: la reserva se soltó (`stock` vuelve a 3, `reservado` a 0); el campo ticket del carrito desaparece |
| Reserva simulada como vencida (se borran sus campos en Redis, como haría `cosechar`) | `GET /carrito` → `disponible: false, motivo: "reserva_vencida"`, aunque `stock_disponible` (de Postgres, congelado) siga positivo |
| `POST /carrito/comprar` con esa línea vencida | 409 "... era una venta relampago y la reserva ya vencio" — el bloqueo de siempre, sin cambios en esa lógica |
| Regresión: `GET` vacío → `PUT` normal → `GET` → `DELETE` → `GET` vacío | idéntico al comportamiento de antes de este cambio |

`npx tsc --noEmit` limpio en cada paso.

### Paso 4 — `confirmar` / `devolver` conectados al checkout (2026-09-03)

Contra el servidor y las bases reales (`test-paso4.sh` + `test-paso4-flagG.sh`
en el scratchpad — no van al repo). Venta relámpago sembrada a mano
(`HSET mesh:oferta:<id> stock N reservado 0 ...`, que es lo que hace la op
`sembrar`); tras cada caso: pedido de prueba borrado, `stock` de la oferta
restaurado, `es_inventario_limitado` a `false`, Redis limpio. Base local
devuelta a su estado inicial (2 pedidos, stock original).

| Grupo | Caso | Resultado |
|---|---|---|
| A | Comprar carrito con 1 línea limitada (reserva de 2) + 1 normal | 201; Redis oferta: `vendidas 2`, `reservado 0`, `stock` intacto (confirmar no toca stock), `r:<ticket>`/`u:<ticket>` borrados, ZSET vacío; carrito vaciado; PG: stock de las 2 ofertas bajó, pedido con 2 líneas |
| B | `PUT` x2 → `PUT` x3 (redimensiona) → comprar | 201; se confirma el **ticket nuevo** (`vendidas 3`, `reservado 0`); el ticket viejo ya estaba liberado por el redimensionar |
| C | Comprar con `metodo_pago` inválido (falla dentro de `comprar_carrito()`) | 409; Redis: `stock` devuelto (`reservado 0`, `vendidas 0`), `r:`/`u:` borrados; **el carrito NO se vacía**; `GET /carrito` marca la línea `reserva_vencida`; re-`PUT` vuelve a reservar y el reintento compra bien (201, `vendidas 2`) |
| D | `DELETE /carrito` con línea limitada + línea normal | 200; Redis: reserva soltada (`stock` restaurado, `reservado 0`); carrito borrado |
| E | `DELETE /carrito/lineas/:id` de la línea limitada (regresión) | 200; reserva soltada; campo `t:<id>` del carrito borrado |
| F | Carrito 100% normal (regresión, sin ninguna oferta sembrada) | 201; `total` correcto; carrito vaciado; ninguna clave `mesh:oferta:*` en Redis |
| G | Interruptor `QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR` en `true`: línea limitada con reserva viva que además queda bloqueante (vendedor pausó la oferta) | 409; la línea y su campo `t:<id>` se quitan del carrito **y su reserva se suelta antes** (`stock` restaurado, `reservado 0`) — antes del paso 4 quedaba una reserva colgada 15 min |

**74 comprobaciones (60 + 14), 0 fallos.** `npx tsc --noEmit` limpio; log
del servidor sin warnings ni errores de `confirmar`/`devolver`. Interruptor
`QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR` probado en `true` (grupo G) y
devuelto a `false` al terminar.

### Batería de estrés del ciclo de vida de la reserva (2026-09-03)

A raíz de la observación de que la liberación de la reserva tiene muchos
puntos posibles de fallo (por tiempo, por rechazo de PostgreSQL, por caída
de infraestructura, best-effort de `confirmar`/`devolver`, concurrencia),
se corrió una batería extra: `test-reserva-stress.sh` (62/62) +
`test-reserva-concurrencia.sh` (L1/L3 limpios) + `test-m2-postgres-down.sh`.

| Grupo | Qué prueba | Resultado |
|---|---|---|
| **I — idempotencia** | `DELETE /carrito/lineas` dos veces; `DELETE /carrito` con reserva ya cosechada; `DELETE` de línea con reserva vencida; `DELETE /carrito` tras compra ya confirmada | Ninguna liberación se aplica dos veces: `devolver` sobre un ticket muerto contesta `SIN_TICKET` sin efecto. El `stock` de Redis nunca "sube de más". |
| **J — PostgreSQL rechaza** | `comprar_carrito()` falla por `metodo_pago` inválido; oferta retirada por el vendedor (bloqueante) | Fallo dentro de `comprar_carrito()` → `devolver` + carrito intacto + `reserva_vencida` en el siguiente `GET` + reintento OK. Bloqueante en la precomprobación (con el interruptor en `false`) → 409 y la reserva queda hasta su TTL o hasta un `DELETE` manual (esperado). |
| **K — `confirmar` best-effort** | reserva muerta antes de pagar; `confirmar` rechazado (`TICKET_AJENO`) con la compra en curso | Una reserva muerta se detecta en `verCarrito` (no se vende en silencio). Si `confirmar` falla *después* de que `comprar_carrito()` ya cerró la venta: **la compra se mantiene** (PG es el libro), el fallo **se registra en el log** (no es silencioso), y queda un desajuste acotado en el contador de Redis que se corrige al cerrar la venta. |
| **N — venta cerrada con ticket colgado** | `revertir` mientras la línea sigue en el carrito, luego el comprador cambia la cantidad | **Bug encontrado y corregido:** el `PUT` normal no limpiaba el campo `t:<id>` huérfano, así que la línea seguía saliendo como `es_inventario_limitado` y el checkout intentaba `confirmar` un ticket muerto. Ahora el `PUT` normal hace `HDEL` de ese campo siempre. |
| **O — línea agregada antes de abrir la venta** | añadir al carrito, luego abrir la venta relámpago | La línea sin ticket se compra por la vía PG normal, sin pasar por la reserva. PG (libro real) queda bien; el contador de Redis sobrestima esa cantidad hasta el cierre. Aceptable por el diseño de dos contadores — anotarlo en el informe. |
| **M — caídas de infra** | Redis caído durante `GET` / `DELETE` / `POST /carrito/comprar`; PostgreSQL caído (`docker stop`) durante el checkout | Redis caído → **503 limpio** (no cuelga, no 500), sin pedido, reserva intacta al volver. PostgreSQL caído → la petición muere en el `SesionGuard` (ver hallazgo abajo), **sin medio-commit** (0 pedidos, nada vendido); la reserva se libera sola por su TTL. |
| **L — concurrencia** | `DELETE /carrito/lineas` \|\| `POST /carrito/comprar` (×12); dos `PUT` concurrentes sobre la misma línea (×12) | **Limpio**: nunca un pedido a medias, nunca un contador negativo, el carrito y la reserva viva siempre coinciden. La atomicidad del `.lua` sostiene la concurrencia. |
| **doble submit** (`test-candado-checkout.sh`) | dos `POST /carrito/comprar` idénticos a la vez — carrito normal (×12) y carrito de inventario limitado (×10); dos cuentas distintas a la vez; segunda compra inmediata; doble submit sobre `POST /comprador/pedidos/:id/comprar` | Con el candado de checkout: **0/22 dobles**, el perdedor recibe 409 "Ya tienes una compra en curso". Dos cuentas distintas no se estorban (candado por cuenta). El candado se suelta tras cada compra. `POST /comprador/pedidos/:id/comprar` **ya era seguro** sin candado (revalida el estado del `pedido` bajo `FOR UPDATE`). |

**Conclusión sobre "el eslabón débil":** el ciclo de reserva ↔ liberación
aguanta. Todas las liberaciones son idempotentes, ningún camino
sobre-libera, los fallos de `confirmar`/`devolver` se registran y la
compra en PostgreSQL (el libro real, con `FOR UPDATE`) nunca queda a
medias. El "coste" del diseño no-bloqueante es un posible **desajuste
temporal entre el contador de Redis y PostgreSQL** (grupos K, O) — nunca
una sobreventa del producto, y se corrige al cerrar la venta (`revertir`
borra las claves / el `EXPIRE` las vence).

La batería sí destapó un problema **fuera** de ese eslabón — la doble
compra por doble submit del checkout — que se corrigió con el candado de
Redis (ver `POST /carrito/comprar`). El resumen de los dos hallazgos y qué
se hizo con cada uno está justo abajo.

### Hallazgos de la batería, y qué se hizo con cada uno

1. **Doble compra por doble submit del checkout** — dos `POST /carrito/comprar`
   idénticos y concurrentes creaban **dos pedidos** y cobraban dos veces
   (5/10 en la prueba). **CORREGIDO (2026-09-03)** con el candado de
   checkout (`mesh:checkout:<id_usuario>`, `SET EX 30 NX`) — ver
   `POST /carrito/comprar` § "Candado de checkout" y la prueba
   `test-candado-checkout.sh` (0/22 dobles tras el cambio). El otro camino
   de compra, `POST /comprador/pedidos/:id/comprar`, se comprobó y **ya
   era seguro**: opera sobre un `pedido` que ya existe y `comprar_pedido()`
   revalida su estado bajo `FOR UPDATE`, así que la segunda petición recibe
   "El pedido N ya esta comprado" (1 solo `pago`, verificado).
2. **PostgreSQL caído → 500 en vez de 503 en rutas con sesión.**
   **CORREGIDO (2026-09-04).** Se había anotado como "el `SesionGuard` no
   traduce el error a `ErrorConexion`", pero al reproducirlo de nuevo en
   vivo (`docker stop mesh-postgres` con el server ya corriendo, el
   escenario más común de probar esto a mano) la causa real es más
   precisa: `SesionGuard` **sí** pasa el error por el clasificador
   compartido (`manejarErrorConexion`), pero ese clasificador
   (`esFalloDeConexion()` en `helpers/manejar-error-db.ts` — lo usa casi
   todo el backend, no solo el guard) solo reconocía el fallo por su
   `.code` (`08*`, `ECONNREFUSED`, etc.). Cuando Postgres se cae con
   conexiones del pool ya abiertas, `pg` no tira un error con código: tira
   un `Error` a secas con el mensaje `"Connection terminated
   unexpectedly"`, que se colaba sin clasificar y terminaba en 500. El fix
   agrega ese mensaje (y `ECONNRESET`, mismo patrón, que tampoco estaba en
   la lista de códigos) al clasificador. Como es el helper compartido,
   corrige **toda ruta autenticada** de un solo cambio, no solo el
   carrito. Probado en vivo: `GET /comprador/pedidos/:id` con Postgres
   apagado a mitad de sesión → `503` "No se pudo conectar con PostgreSQL"
   (antes: `500`); recuperación automática al volver Postgres, sin
   reiniciar el server.

---

## Pruebas — rediseño "el carrito resiste por sí solo" (2026-09-23)

Pedido del profesor, relayado por el usuario: arreglar Redis para que el
carrito "nunca haga un GET a nada más, solo a sí mismo" — guardar ahí
nombre, precio y demás. Contra el servidor real y los contenedores
(`comprador_sur`, id 3; oferta 3 = Laptop Ambar Campus 14, `ventas_norte`,
5840.00; oferta 7 = misma laptop otra variante, `mesh_tienda`, 4750.00).

| Caso | Resultado |
|---|---|
| `PUT /carrito/lineas/3` `{cantidad:2}` | `HGET` del campo `3` en Redis sale como JSON completo: `cantidad, id_producto, id_producto_variante, nombre_producto, nombre_variante, imagen, precio, vendedor_usuario, vendedor_nombre, stock_disponible, disponible, motivo` |
| `GET /carrito` inmediatamente después | Devuelve exactamente esos datos, mismo shape de siempre (`CarritoLinea`) |
| `PUT /carrito/lineas/999999` (id inventado) | 200 — se guarda con foto de relleno: `nombre_producto: "(oferta no encontrada)"`, `precio: "0.00"`, `disponible: false`, `motivo: "oferta_no_existe"` — igual que antes del rediseño, pero ahora es la FOTO la que trae ese relleno, no un cálculo al vuelo |
| **`docker stop mesh-postgres mesh-mongo`**, después `GET /carrito` con una línea válida en el carrito | **503** "No se pudo conectar con PostgreSQL" — **no** por `CarritoService` (que ya no toca ninguna de las dos), sino por `SesionGuard` (ver el hallazgo pendiente en el banner de arriba). `docker start` de las dos, recuperación automática sin reiniciar el server |
| `POST /carrito/comprar` con la línea inventada (999999) en el carrito | 409 `"(oferta no encontrada)" ya no existe` — el chequeo itemizado en vivo sigue funcionando igual que siempre, sin cobrar nada |
| `UPDATE oferta SET precio = 5900.00` directo en Postgres (simula que el vendedor cambió el precio) **sin tocar Redis**, después `GET /carrito` | Sigue mostrando `"precio": "5840.00"` — la foto vieja, tal como se diseñó |
| `POST /carrito/comprar` sin mandar nada de precios en el body (`{metodo_pago, id_direccion}` nomás) | `comprado: false`, `avisos: [{id_oferta:3, precio_visto:"5840.00", precio_actual:"5900.00"}]` — el aviso salió **sin que el cliente mandara nada sobre precios**: el backend comparó la foto de Redis contra Postgres él solo |
| Misma petición + `confirmar_cambios: true` | **201**, `comprado: true`, `total: "5900.00"` (pedido real `id_pedido: 30`) — se cobró el precio **de hoy** (5900.00), no el congelado en la foto (5840.00); verificado contra `precio_historial` (`pedido_producto` → `precio_historial.precio = 5900.00`) |
| Regresión — carrito con oferta 7 sin ningún cambio de precio, `POST /carrito/comprar` | **201** directo, `comprado: true` de una — sin pedir confirmación, igual que siempre cuando no hay discrepancia (pedido real `id_pedido: 31`) |
| `npx tsc --noEmit` y `eslint` sobre los archivos tocados | limpios |

**Teardown:** `oferta.precio`/`oferta.stock` de las dos ofertas de prueba
devueltos a sus valores originales (5840.00/24 y 33); los campos
calculados de Mongo (`stock_total`/`stock_tienda` del producto 1 y sus dos
variantes) resincronizados a mano tras los `UPDATE` directos de teardown
— mismo criterio que las pruebas de 2026-08-29/09-03. **Los pedidos 30 y
31 quedan como registro permanente** (la cadena `ON DELETE RESTRICT` no
permite borrarlos), igual que en las rondas de prueba anteriores.

**Inventario limitado / venta relámpago con el `PUT` nuevo** (que ahora
también arma la foto para estas líneas): probado aparte, oferta 2
(`ventas_sur`, sembrada con 3 unidades vía `POST /vendedor/ofertas/2/venta-limitada`).
`PUT /carrito/lineas/2` `{cantidad:2}` reservó de verdad en
`mesh:oferta:2` (`reservado: 2`) **y** guardó la foto completa en el campo
`2` del carrito **y** el ticket en el campo compañero `t:2` — los dos
campos del mismo `HSET`, como siempre. `GET /carrito` mostró
`es_inventario_limitado: true` con la foto completa. `DELETE
/carrito/lineas/2` soltó la reserva (`stock` volvió a 3, `reservado` a 0)
antes de quitar la línea. Cerrada la venta después
(`DELETE /vendedor/ofertas/2/venta-limitada`), sin dejar ninguna clave
`mesh:oferta:*` huérfana.

**Lo que NO se probó en esta ronda** (no debería estar roto por este
cambio, pero tampoco se re-verificó): la batería completa de estrés/
concurrencia de la reserva (grupos I–O más abajo) y la redimensión de una
reserva ya existente (`PUT` dos veces sobre la misma línea limitada). Si
se vuelve a tocar `carrito.service.ts`, vale la pena correr esas de nuevo.
