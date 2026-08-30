# Endpoints del carrito

El carrito de compra de la Entrega 2. **Vive solo en Redis** — reemplaza al
carrito viejo, que era una fila de `pedido` en estado `pendiente` en
PostgreSQL con el `id_pedido` en `localStorage`.

> **Estado (2026-08-29): las cinco rutas del carrito están hechas y
> probadas** — `GET /carrito`, `PUT /carrito/lineas/:idOferta`,
> `DELETE /carrito/lineas/:idOferta`, `DELETE /carrito` (43 comprobaciones)
> y `POST /carrito/comprar` (29 comprobaciones), 0 fallos — ver "Pruebas".

Código: `src/controllers/carrito/carrito.controller.ts` +
`src/services/carrito/carrito.service.ts`. Cliente Redis:
`src/database/redis.ts`.

---

## El modelo

Una sola clave por cuenta, un **HASH**:

```
mesh:carrito:<id_usuario>   HASH   { <id_oferta>: cantidad, ... }
```

El carrito es literalmente un `Map<id_oferta, cantidad>` — la **intención**
("quiero N de la oferta X"), nada más. El nombre, el precio, el stock y la
imagen **no se guardan acá**: viven en `oferta` (PostgreSQL) y en
`productos` (MongoDB), cambian, y una copia en Redis se desactualizaría en
segundos. Se resuelven al vuelo en `GET /carrito` y al pagar.

### Qué toca cada base

| Ruta | Redis | PostgreSQL / Mongo |
|---|---|---|
| `PUT /carrito/lineas/:idOferta` | `HSET` + `EXPIRE` | **nada** |
| `DELETE /carrito/lineas/:idOferta` | `HDEL` + `EXPIRE` | **nada** |
| `DELETE /carrito` | `DEL` | **nada** |
| `GET /carrito` | `HGETALL` + `EXPIRE` | 1 consulta a `oferta` + 1 a `productos` (Mongo), **en lote**, para todo el carrito de una |
| `POST /carrito/comprar` | `HGETALL`, y `DEL` al final | el `GET` de arriba + `resolverDireccionHistorial` + `comprar_carrito()` (una transacción) + recálculo de campos calculados en Mongo |

Agregar / cambiar cantidad / quitar es **Redis puro**: ni una consulta a
PostgreSQL. El stock no se comprueba al agregar — nunca fue una reserva —
se comprueba al pintar el carrito y de forma bloqueante al pagar.

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

## GET /carrito

El carrito completo, cada línea enriquecida con nombre, precio **actual**,
stock, subtotal, vendedor y si se puede comprar. Renueva el TTL.

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
        "subtotal": "58400.00",
        "vendedor": { "usuario": "ventas_norte", "nombre": "Carlos Ramirez" },
        "stock_disponible": 24,
        "disponible": true,
        "motivo": null
      },
      {
        "id_oferta": 15,
        "cantidad": 3,
        "...": "...",
        "precio": "10958.00",
        "subtotal": "32874.00",
        "stock_disponible": 1,
        "disponible": false,
        "motivo": "stock_insuficiente"
      }
    ],
    "total": "103957.00",
    "total_lineas": 5,
    "total_items": 16
  }
}
```

- **`precio`** es el de la oferta **ahora** (no el que se vio al agregar —
  el carrito no guarda precios). `subtotal` = `precio` × `cantidad`.
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

- Un producto o variante que no aparezca en Mongo (no debería: el catálogo
  no borra) sale con `"(producto no encontrado)"` / `"(variante no
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
cantidad. Si el carrito no existía, nace acá. Renueva el TTL. **Redis puro**
— ni una consulta a PostgreSQL.

```
PUT /carrito/lineas/3
```

```json
{ "cantidad": 10 }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `cantidad` | Sí | Entero de **1 a 1000**. Para quitar la línea → `DELETE /carrito/lineas/:idOferta`, no `cantidad: 0`. El límite real es el stock, que **no se comprueba acá** (se ve en `GET /carrito` y bloquea al pagar); el 1000 es solo un tope de sanidad |

`:idOferta` tiene que ser un entero. **No se valida que la oferta exista** —
un id inventado se guarda igual y aparece en `GET /carrito` con
`motivo: "oferta_no_existe"`, y `comprar_carrito()` lo rechaza al pagar.

### 200

```json
{
  "ok": true,
  "mensaje": "Cantidad actualizada",
  "payload": { "id_oferta": 3, "cantidad": 10, "total_lineas": 2, "total_items": 11 }
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

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
{ "ok": false, "mensaje": "No se pudo actualizar el carrito", "payload": null }
```

---

## DELETE /carrito/lineas/:idOferta

Quita una oferta del carrito. **Idempotente**: si la línea no estaba,
responde 200 igual. Si era la última línea, Redis borra la clave sola (un
HASH sin campos deja de existir). Renueva el TTL si quedan líneas.

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
pedido ni líneas a medias. Si sale bien: `DEL` del carrito y recálculo de
los campos calculados de Mongo de cada producto tocado.

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

**El precio que se cobra es el del momento de pagar** (el que muestra
`GET /carrito`). El carrito de Redis no guarda el precio que se vio, así que
no hay `confirmar_cambios` ni lista de `avisos` de cambio de precio (a
diferencia de `POST /comprador/pedidos/:id/comprar`). Cerrar la ventana de
carrera entre ver y pagar es la **fase 2**: guardar `id_precio_historial`
en cada línea del carrito y que `agregar_linea` lo respete — cambio en
`migrations/007` (del compañero). Ver `BACKEND-PENDIENTE.md`.

### 201

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
```

El carrito está vacío, o alguna línea no se puede comprar. El chequeo
previo (con `GET /carrito`) arma la **lista** de todos los problemas; si
algo cambia entre ese chequeo y `comprar_carrito()`, la propia función lo
rechaza dentro de su transacción y no queda nada escrito.

Motivos de bloqueo: oferta pausada/retirada (`ya no esta disponible`),
variante desactivada en el catálogo (`ya no esta disponible en el
catalogo`), stock 0 (`esta agotada`), stock insuficiente (`no tiene stock
suficiente`), id de oferta inexistente (`ya no existe`).

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
