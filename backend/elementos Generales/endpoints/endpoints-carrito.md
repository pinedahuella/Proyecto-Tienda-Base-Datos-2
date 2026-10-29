# Endpoints del carrito

> **2026-10-17 — CAMBIO DE MODELO pedido por el profesor: "Redis nunca debe ser
> la fuente de verdad".** El carrito se escribe en Redis (rápido) y debajo, en
> un intento asíncrono, en PostgreSQL, que es la VERDAD: el pedido `pendiente`
> de cada cuenta es su carrito. Si Redis cae, todo sigue funcionando contra
> PostgreSQL (más lento). La venta relámpago igual: Redis decide primero con su
> script atómico y la reserva de verdad queda en `reserva_venta_relampago`.
> Diseño, decisiones, SQL y lo que le toca a otros:
> `plan pendiente/carrito-postgres-verdad.md`. Pruebas: "Pruebas — Redis nunca
> es la verdad (2026-10-17)", al final.
>
> Lo que cambia para quien llama a esta API:
>
> - `GET /carrito` trae dos campos nuevos: `sincronizado` y `fuente`.
> - `PUT /carrito/lineas/:idOferta` con una oferta que **no existe** da **404**
>   (antes se guardaba con `motivo: "oferta_no_existe"`).
> - Ruta nueva: `POST /carrito/sincronizar`.
> - `POST /carrito/comprar` tiene dos 409 nuevos (carrito desincronizado,
>   carrito vencido) y con Redis caído **compra igual** (antes 503).
> - Las rutas viejas de `/comprador/pedidos` que armaban un pedido a mano se
>   quitaron (ver `endpoints-compradores.md`).
>
> El resto de la historia de este documento (entregas 2 y 3) sigue más abajo,
> en las secciones de "Pruebas" con su fecha.

Código: `src/controllers/carrito/carrito.controller.ts`,
`src/services/carrito/carrito.service.ts` (Redis y la orquestación),
`src/services/carrito/carrito-postgres.service.ts` (la verdad),
`src/services/carrito/carrito-barrido.service.ts` (borra los vencidos),
`src/services/inventario-limitado/` (venta relámpago).

**Hallazgo que sigue abierto (no es del carrito):** `SesionGuard` consulta
`usuarios` en PostgreSQL en **cada** petición con sesión para confirmar que la
cuenta sigue activa. Con PostgreSQL caído, toda ruta autenticada (el carrito
incluido) responde 503 antes de llegar al servicio. Se dejó así porque es un
control de seguridad de todo el backend; si se quiere que el carrito se vea con
PostgreSQL caído, hay que cachear "cuenta activa" (por ejemplo en Redis, con un
TTL corto).

---

## El modelo

### Las dos copias

| | Redis (rápido) | PostgreSQL (la verdad) |
|---|---|---|
| Dónde | `mesh:carrito:<id_usuario>`, un HASH | el pedido `pendiente` de la cuenta (`uq_pedido_pendiente_usuario`: uno solo) y sus líneas en `pedido_producto` |
| Qué guarda | por línea, una FOTO en JSON (nombre, precio, imagen, vendedor, stock, disponibilidad, la fila de precio que se vio); `t:<id_oferta>` el ticket de una reserva relámpago; `_v` la versión de PostgreSQL que conoce; `_d` la marca de desincronizado | las líneas con su `id_precio_historial` (el precio que la persona vio), `pedido.version` (sube en cada escritura) y `pedido.fecha_ultima_actividad` (el reloj de las 24 h). Sin dirección hasta que se paga |
| Reservas relámpago | el script `redis/inventario_limitado.lua` (stock, reservado, tickets con su vencimiento) | `reserva_venta_relampago` (cantidad, ticket, `fecha_vence`, estado `activa` / `confirmada` / `devuelta` / `vencida`) |

### Cómo se escribe

1. La petición escribe en Redis y contesta.
2. Debajo, sin hacer esperar a nadie, **un intento** copia el carrito entero de
   Redis a PostgreSQL (por diferencias: solo se toca lo que cambió). Una sola
   copia a la vez por cuenta, en orden.
3. La copia compara versiones: si PostgreSQL tiene cambios que Redis no vio, no
   pisa nada. Si choca o PostgreSQL falla, el carrito queda **desincronizado**
   (`_d`): `GET /carrito` lo dice (`sincronizado: false`), el checkout no
   compra, y se arregla con `POST /carrito/sincronizar` (o sola, con la
   siguiente escritura que sí se copie).

### Qué pasa si una base no está

| Situación | Qué hace |
|---|---|
| Redis no responde | Todo va directo a PostgreSQL: ver, agregar, quitar, vaciar y comprar (`fuente: "postgres"`). Una venta relámpago reserva en PostgreSQL. La cuenta queda anotada para reconstruir su Redis cuando vuelva |
| Redis no tiene el carrito (venció, se reinició) | Se reconstruye desde PostgreSQL, con el TTL que le queda |
| PostgreSQL no responde | Toda ruta con sesión da 503 por `SesionGuard` (ver arriba) |
| La copia a PostgreSQL falla | Carrito desincronizado (ver arriba) |

### Cómo nace y cómo muere

**No hay ruta para crear un carrito.** Nace con el primer `PUT`: en Redis el
primer `HSET`, en PostgreSQL el pedido `pendiente` lo crea la copia. Un carrito
vacío no existe, en ninguna de las dos: vaciarlo o quitar la última línea
borra la clave de Redis y el pedido pendiente.

**Las 24 h de inactividad las decide PostgreSQL** (`fecha_ultima_actividad`).
Cada escritura las renueva, y ver el carrito también (en Redis siempre, en
PostgreSQL como mucho cada 5 min). El TTL de Redis se pone igual, así que las
dos copias vencen juntas. Un carrito con más de 24 h sin tocar:

- se borra **al leerlo** (vencimiento pasivo): `GET` lo da vacío, el checkout
  contesta 409 "venció";
- y si nadie lo vuelve a leer, lo borra el **barrido** cada 10 min
  (`CarritoBarridoService`).

Al vencer no hay stock que liberar (agregar nunca reserva, salvo la venta
relámpago, cuya reserva dura 15 min y vence mucho antes).

### De quién es

Todas las rutas piden sesión y su permiso (`SesionGuard` + `PermisoGuard`, con
`carrito.usar` y `carrito.comprar` para pagar; los tres roles lo tienen en `rol_permiso`). El `id_usuario`
sale del token: no hay id de carrito. Dos dispositivos de la misma cuenta
comparten el carrito.

---

## La venta relámpago en el carrito

Una oferta con una venta relámpago **vigente según PostgreSQL**
(`oferta.es_inventario_limitado` y sin pasar `fecha_vencimiento_venta_limitada`)
reserva al agregarla:

- **Redis decide primero** (`redimensionar` de `redis/inventario_limitado.lua`):
  atómico, sin candados, rechaza en el acto (409) a quien llega tarde. La
  reserva dura 15 min (`TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS`).
- **PostgreSQL la registra** con la copia, y vuelve a comprobar que haya
  unidades (`oferta.stock` menos lo reservado por las demás cuentas, con un
  `FOR UPDATE` corto). Si no las hay (Redis se equivocó), PostgreSQL manda: el
  carrito queda desincronizado y Redis se reconstruye.
- **Redis caído:** PostgreSQL reserva solo, con el mismo control. La reserva
  queda sin ticket y recibe uno cuando Redis vuelve.
- **Redis perdió la venta** (se reinició): la siguiente reserva la reconstruye
  desde PostgreSQL y sigue; si nadie reserva, la reconstruye la reconciliación
  (`ReservasVentaRelampagoSyncService`, cada 10 s).
- **Abrir** la venta siembra Redis desde PostgreSQL y sigue numerando los
  tickets desde el más alto que la oferta repartió (antes empezaba en 0 y un
  ticket viejo podía chocar con uno nuevo ajeno).
- **Cerrarla** (a mano, por una regla o porque venció) devuelve sus reservas
  activas en la misma transacción y quita el ticket de los carritos: la línea
  se queda, como normal.
- **Al pagar**, cada línea relámpago necesita una reserva activa, sin vencer y de
  la misma cantidad. Si no la tiene (venció, o la venta se abrió después de
  agregarla) el checkout reserva ahí mismo si hay unidades; si no, 409.

---

## GET /carrito

El carrito con cada línea tal como se guardó (la foto), y su disponibilidad.
Renueva el TTL. Lo normal es Redis puro; si Redis no tiene el carrito se trae
de PostgreSQL, y si Redis no responde se lee PostgreSQL directo.

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
      }
    ],
    "total": "58400.00",
    "total_lineas": 1,
    "total_items": 10,
    "sincronizado": true,
    "fuente": "redis"
  }
}
```

- **`precio`** es el que la persona vio cuando agregó o cambió la línea (ya con
  el descuento que tuviera), no necesariamente el de ahora. El checkout avisa
  si cambió. `subtotal` = `precio` × `cantidad`.
- **`disponible`** / **`motivo`**: `oferta_no_disponible` (pausada, retirada…),
  `variante_no_disponible`, `agotado`, `stock_insuficiente`, `reserva_vencida`
  (venta relámpago cuya reserva venció). `oferta_no_existe` solo puede salir de
  un carrito de antes del 2026-10-17 (ahora el `PUT` lo rechaza).
- **`es_inventario_limitado`**: la línea tiene una reserva de venta relámpago.
- **`sincronizado`** (nuevo): `false` si lo que se ve no quedó guardado en
  PostgreSQL. El checkout no compra así: llamar a `POST /carrito/sincronizar`.
- **`fuente`** (nuevo): `redis` (lo normal) o `postgres` (Redis no respondía).

### 401 / 503 / 500

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No se pudo verificar la sesion", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo obtener el carrito", "payload": null }
```

Con Redis caído ya no da 503: lee PostgreSQL.

---

## PUT /carrito/lineas/:idOferta

Fija la cantidad **absoluta** de una oferta (no un `+1`/`-1`). Consulta
PostgreSQL una vez para tomar la foto de esa línea, la guarda en Redis y
contesta; la copia a PostgreSQL va debajo.

```
PUT /carrito/lineas/3
```

```json
{ "cantidad": 10 }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `cantidad` | Sí | Entero de **1 a 1000**. Para quitar → `DELETE`. El stock de una oferta normal no se comprueba aquí (se ve en `GET /carrito` y bloquea al pagar) |

- **Oferta normal:** se agrega siempre, aunque esté pausada o pida más que el
  stock (se avisa en `GET /carrito`).
- **Venta relámpago vigente:** reserva (ver arriba). Si no alcanza, 409 en el
  acto, sin tocar el carrito.
- **Redis caído:** se escribe directo en PostgreSQL. Mismo 200, mismo 409.

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

### 400 / 401 / 404

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "La cantidad debe ser un numero entero entre 1 y 1000", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
```

El 404 es nuevo (2026-10-17): una línea de una oferta que no existe no se puede
guardar en la verdad.

### 409 — solo venta relámpago

```json
{ "ok": false, "mensaje": "No hay suficiente stock en la venta relampago de la oferta 22: pediste 5 y hay 3 disponibles (contando lo que ya tenias reservado)", "payload": null }
```

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo actualizar el carrito", "payload": null }
```

---

## DELETE /carrito/lineas/:idOferta

Quita una oferta. **Idempotente.** Si tenía una reserva relámpago, la suelta en
Redis en el acto (`devolver`) y en PostgreSQL pasa a `devuelta` con la copia.
Si era la última línea, el carrito deja de existir (en Redis y en PostgreSQL).
Con Redis caído, se quita directo en PostgreSQL.

### 200

```json
{ "ok": true, "mensaje": "Producto quitado del carrito", "payload": { "total_lineas": 1, "total_items": 1 } }
```

### 400 / 401 / 503 / 500

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No se pudo quitar el producto del carrito", "payload": null }
```

---

## DELETE /carrito

Vacía el carrito. **Idempotente.** Suelta en el acto las reservas relámpago,
borra la clave de Redis, y la copia vacía PostgreSQL (borra el pedido
pendiente). Con Redis caído, se vacía directo en PostgreSQL.

### 200

```json
{ "ok": true, "mensaje": "Carrito vaciado", "payload": null }
```

---

## POST /carrito/sincronizar (nuevo, 2026-10-17)

Arregla un carrito desincronizado (`sincronizado: false`). Espera la copia en
curso y decide quién tiene razón:

- **Redis y PostgreSQL en la misma versión** (o PostgreSQL sin carrito): a
  PostgreSQL le falta la última escritura de Redis, que no se pudo copiar → se
  vuelve a copiar.
- **PostgreSQL más nuevo** (hubo escrituras con Redis caído, o el carrito
  venció), o la copia choca: PostgreSQL es la verdad → Redis se reconstruye
  desde ahí.

Sin cuerpo. Devuelve el carrito como queda (la misma forma que `GET /carrito`).

### 201

```json
{ "ok": true, "mensaje": "Carrito sincronizado", "payload": { "lineas": [], "total": "0.00", "total_lineas": 0, "total_items": 0, "sincronizado": true, "fuente": "redis" } }
```

### 401 / 503 / 500

Con PostgreSQL caído, 503 (no hay contra qué sincronizar).

---

## POST /carrito/comprar

El **checkout**. Compra el carrito de verdad (el pedido pendiente de
PostgreSQL) en **una sola transacción**: el pedido y las ofertas se bloquean
(`FOR UPDATE`, en orden de id), se comprueba todo, se llama a
`comprar_pedido()` (`migrations/007`: stock, kardex, pago, estado `comprado`) y
las reservas relámpago pasan a `confirmada`. Si algo falla, no queda nada a
medias. Después se borra el carrito de Redis.

```json
{
  "id_direccion": 2,
  "metodo_pago": "efectivo contra entrega"
}
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `id_direccion` | Sí | El id normal (`GET /direccion-usuario`), number o string. Tiene que ser **de la cuenta** |
| `metodo_pago` | Sí | `"tarjeta"`, `"transferencia"` o `"efectivo contra entrega"` |
| `tarjeta` | Solo con `"tarjeta"` | `{ numero, vencimiento (MM/AA), cvv, titular }` — mock (`helpers/validaciones-tarjeta.ts`) |
| `confirmar_cambios` | No | `true` para comprar al precio de **hoy** aunque haya cambiado |

En orden:

1. Si Redis responde: el carrito no puede estar desincronizado, y lo que ve
   Redis tiene que coincidir con PostgreSQL (versión y líneas). Si no → 409 y
   queda marcado. Si Redis no responde se compra lo que dice PostgreSQL (sin el
   candado de Redis: el `FOR UPDATE` del pedido evita el doble cobro).
2. Carrito vencido (24 h) → 409 y se borra. Vacío → 409.
3. Disponibilidad en vivo: oferta activa, variante activa, stock → si algo
   falla, 409 con la lista. Siempre, no se salta con nada.
4. Venta relámpago: reserva activa de la misma cantidad, o reservar ahí mismo
   si hay unidades → si no, 409.
5. Precio: si alguna línea cambió desde que se agregó y no vino
   `confirmar_cambios: true` → `comprado: false` con los `avisos`, sin tocar
   nada.
6. Dirección, tarjeta, `comprar_pedido()`, reservas confirmadas. COMMIT.

El pedido que se compra **es el mismo** que era el carrito: `id_pedido` de la
respuesta es su id.

### 201 — compra completada

```json
{
  "ok": true,
  "mensaje": "Compra realizada correctamente",
  "payload": {
    "comprado": true,
    "id_pedido": 534,
    "total": "70.00",
    "stock": [
      { "id_oferta": 6074, "id_usuario": 52, "id_producto": 83, "id_producto_variante": 167, "stock": 47 }
    ]
  }
}
```

### 201 — hay que confirmar un cambio de precio

```json
{
  "ok": true,
  "mensaje": "Hay cambios que revisar antes de comprar",
  "payload": {
    "comprado": false,
    "avisos": [
      { "id_oferta": 6074, "nombre_producto": "Cartas al puerto seco", "nombre_variante": "Pasta blanda", "precio_visto": "10.00", "precio_actual": "11.00" }
    ]
  }
}
```

No se tocó nada. Reenviar con `confirmar_cambios: true` compra al precio nuevo.

### 400 / 401 / 402 / 404

```json
{ "ok": false, "mensaje": "El metodo_pago es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El id_direccion es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La tarjeta fue rechazada", "payload": null }
{ "ok": false, "mensaje": "No existe una direccion con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El carrito esta vacio", "payload": null }
{ "ok": false, "mensaje": "El carrito vencio por inactividad (24 h sin tocarlo): vuelve a agregar los productos", "payload": null }
{ "ok": false, "mensaje": "Tu carrito no quedo guardado del todo: sincronizalo (POST /carrito/sincronizar) y revisalo antes de comprar", "payload": null }
{ "ok": false, "mensaje": "\"Pasta dura\" ya no esta disponible", "payload": null }
{ "ok": false, "mensaje": "\"Pasta blanda\" es de una venta relampago y su reserva vencio: pediste 2 y hay 0 disponibles", "payload": null }
{ "ok": false, "mensaje": "El metodo de pago \"trueque\" no existe", "payload": null }
{ "ok": false, "mensaje": "Ya tienes una compra en curso, espera un momento antes de reintentar", "payload": null }
```

**Interruptor `QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR`** (`helpers/constantes.ts`,
hoy `false`): si está en `true`, además de rechazar, las líneas que no se pueden
comprar se quitan del carrito.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo completar la compra", "payload": null }
```

---

> **Las secciones de "Pruebas" que siguen son HISTORIA**: prueban el carrito
> anterior al 2026-10-17 (el que vivia solo en Redis). Lo que dicen de "no toca
> PostgreSQL", de `comprar_carrito()` o de las rutas viejas ya no describe el
> codigo. Las pruebas del modelo actual estan en "Pruebas — Redis nunca es la
> verdad (2026-10-17)", al final.

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

---

## Pruebas — Redis nunca es la verdad (2026-10-17)

Contra el backend en marcha y las bases reales, con ofertas de prueba del
vendedor `vendcarga` (producto 83/84/85) y contenedores parados de verdad con
`docker stop`. El arnés es de Claude (scratchpad), no va al repo; aquí queda la
evidencia. Detalle de cada bloque en `plan pendiente/carrito-postgres-verdad.md`.

| Bloque | Comprobaciones | Resultado |
|---|---|---|
| A, B — carrito con Redis vivo, copia a PostgreSQL, versiones, idempotencia, validaciones (404 inventada, 400, 401), el pendiente oculto en `/comprador/pedidos`, rutas viejas 404, restricciones de la base, Redis pierde el carrito, precio visto | 65 | 65 OK |
| C, D, G — 24 h (vencido al leer, borde de 23 h 59 min, checkout vencido, vencimiento que choca con la versión), desincronizado (PostgreSQL rechaza, choque de versión, Redis tocado por fuera, sincronizar en los dos sentidos, arreglo solo), checkout (compra del mismo pedido, aviso de precio, bloqueantes, errores sin efecto, doble submit, vacío) | 75 | 75 OK |
| E, F — Redis parado (ver, agregar, quitar, tres compras a la vez: una sola, reconstrucción al volver); PostgreSQL parado (503 limpio, nada a medias, recupera) | 31 | 31 OK |
| H — venta relámpago (abrir, reservar, redimensionar, soltar, 30 cuentas sobre 10 unidades, comprar, reserva vencida con y sin unidades, cerrar con reservas vivas, reabrir sin choque de tickets, Redis pierde la venta, Redis caído en plena venta, comprar sin Redis, venta abierta con la línea ya en el carrito, Redis da de más, vence sola) | 85 | 85 OK |
| Regla por periodo — el disparador real abre la venta sola con un carrito que ya tenía la oferta, reserva otra cuenta, la primera compra reservando en el checkout, la regla deja de cubrir hoy y el disparador la cierra devolviendo la reserva | 15 | 15 OK |
| Barrido — un carrito con 25 h sin tocar que nadie lee | 1 | lo borró `CarritoBarridoService` (PostgreSQL y Redis) en su pasada |

Encontrado y arreglado durante las pruebas:

- **`redimensionar` provisional sin chequeo de venta**: con la venta perdida en
  Redis contestaba AGOTADO (409 a quien sí podía comprar) y dejaba un hash con
  solo `rechazos` que además escondía la venta perdida de la reconciliación.
  Ahora se usa la rama del script original.
- **El vencimiento de un carrito se deshacía si chocaba la versión** (ROLLBACK
  de toda la escritura). Ahora el borrado del vencido se guarda igual.
- **Cerrar una venta con reservas vivas** dejaba el ticket en el carrito y la
  línea se veía como "reserva vencida". Ahora el cierre lo quita.
- **Cancelar una compra de una oferta relámpago** devolvía el stock en
  PostgreSQL sin que Redis se enterara. Ahora se reconcilia.
- **Un carrito vaciado dejaba un pedido pendiente sin líneas** (y la clave de
  Redis con solo la versión). Ahora un carrito vacío no existe en ninguna de las
  dos.

Suites de `pruebas/`: `oferta_limitada.sh` 33/33, `descuentos.sh` 98/98,
`reglas_descuento.sh` 44/44, `reglas_periodo.sh` 61/61. `carrito.sh` (24/25),
`carrito_vencimiento.sh` y `falla_checkout.sh` fallan donde prueban el diseño
viejo; la tabla de qué cambiar está en el plan.
