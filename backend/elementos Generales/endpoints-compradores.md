# Endpoints de comprador

Este archivo documenta solo las rutas de `/comprador/*`. Las demás rutas del
backend están en [endpoints.md](endpoints.md) (usuario, perfil, direcciones,
admin), [endpoints-productos.md](endpoints-productos.md) (el catálogo
público) y [endpoints-vendedores.md](endpoints-vendedores.md) (el panel del
vendedor).

**Todas las rutas de aquí requieren la cookie `mesh_token`, pero ninguna
exige un rol en particular.** A diferencia de `/vendedor/*` (solo
`id_rol_usuario` 2) o `/admin/*` (solo 3), comprar no es un privilegio de
un rol: cualquiera con sesión activa puede hacerlo, sea comprador (1),
vendedor (2) o admin (3) — un vendedor también compra en la tienda, y un
admin también podría probarla. Por eso ninguna ruta de aquí lleva
`@Roles(...)`, solo `@UseGuards(SesionGuard)`.

El flujo de pedido vive en PostgreSQL, en cuatro funciones
(`migrations/007_flujo_pedido.sql`, ya documentadas en
[cambios-etl-productos.md](cambios-etl-productos.md)):
`crear_pedido`, `agregar_linea`, `comprar_pedido` y `cancelar_pedido`. Las
dos primeras ya tienen ruta (junto con `quitar_linea`); `comprar_pedido` y
`cancelar_pedido` todavía no.

**Ninguna de las cuatro funciones comprueba de quién es el pedido** — eso
lo hace el backend antes de llamar a cada una, en una consulta aparte: un
pedido ajeno siempre da el mismo 404 que uno que no existe, nunca un 403 ni
un mensaje que confirme que el pedido existe pero es de otra persona.

---

## POST /comprador/pedidos

Abre un pedido vacío, en estado `pendiente`. No agrega ninguna línea
todavía (eso es una ruta aparte, pendiente) y no toca stock — `crear_pedido`
en PostgreSQL nunca lo toca.

```json
{ "id_direccion": 1 }
```

| Campo | Obligatorio | Qué es |
| --- | --- | --- |
| `id_direccion` | Sí | El id normal de una dirección propia (el que devuelve `GET /direccion-usuario`) — no el `id_direccion_historial` |

**`id_usuario` nunca viene en el cuerpo.** Sale del token de sesión, igual
que en el resto del proyecto: nadie puede crear un pedido a nombre de otro
usuario pasando su id.

### De `id_direccion` a `id_direccion_historial`

La función de PostgreSQL `crear_pedido(id_usuario, id_direccion_historial)`
no recibe el `id_direccion` normal — recibe la **versión congelada** de esa
dirección en `direccion_historial`, para que el pedido siempre diga a dónde
se mandó de verdad, así la persona edite su dirección después.

Quien compra no tiene por qué conocer ese detalle interno (`id_direccion_historial`
ni siquiera lo devuelve `GET /direccion-usuario`, solo `GET /direccion-usuario/:id`,
dentro de su `historial`). Por eso esta ruta solo pide `id_direccion`, y
resuelve internamente cuál es su versión más reciente en `direccion_historial`
antes de llamar a la función:

```sql
SELECT dh.id_direccion_historial
FROM direccion_historial dh
JOIN direcciones d ON d.id_direccion = dh.id_direccion
WHERE dh.id_direccion = $1 AND d.id_usuario = $2
ORDER BY dh.fecha_creacion DESC
LIMIT 1
```

Esa misma consulta ya exige que la dirección sea del usuario logueado —
**una dirección ajena da el mismo 404 que una que no existe**, el mismo
criterio que ya usa `GET /direccion-usuario/:id`. `crear_pedido` vuelve a
comprobar la misma relación por su cuenta (defensa extra dentro de la
función), pero para cuando llega ahí la petición ya pasó por esta
validación.

### 201

```json
{
  "ok": true,
  "mensaje": "Pedido creado correctamente",
  "payload": { "id_pedido": "8" }
}
```

`id_pedido` sale como texto: es un `bigserial` de PostgreSQL, y el driver
`pg` entrega los `bigint` como `string` para no perder precisión.

### 400

```json
{ "ok": false, "mensaje": "El id_direccion es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una direccion con ese id", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo crear el pedido", "payload": null }
```

---

## GET /comprador/pedidos/:id

Trae un pedido propio completo de un solo golpe: el pedido, la versión de
la dirección que regía al crearlo, y sus líneas (una lista vacía si
todavía no tiene ninguna). Es la consulta rápida de "ver mi pedido" — por
eso `pedido_producto` guarda copiado el nombre, el precio y la comisión de
cada línea: esta ruta no consulta Mongo para nada, todo sale de
PostgreSQL en dos consultas.

Solo sobre un pedido propio: `:id` tiene que ser de quien está logueado,
mismo criterio de siempre — un pedido ajeno da el mismo 404 que uno que no
existe.

```
GET /comprador/pedidos/11
```

### 200

```json
{
  "ok": true,
  "mensaje": "Pedido obtenido correctamente",
  "payload": {
    "pedido": {
      "id_pedido": "11",
      "fecha_creacion": "2026-08-20T15:04:00.000Z",
      "id_usuario": "3",
      "id_direccion_historial": "5",
      "id_estado_pedido": 1,
      "estado_pedido_nombre": "pendiente"
    },
    "direccion": {
      "id_direccion_historial": "5",
      "id_direccion": "2",
      "pais": "Colombia",
      "departamento": "Antioquia",
      "ciudad": "Medellín",
      "codigo_postal": "050001",
      "fecha_creacion": "2026-08-10T12:00:00.000Z"
    },
    "detalles": [
      {
        "id_pedido_producto": "10",
        "id_pedido": "11",
        "id_producto_mongo": "1",
        "id_producto_variante_mongo": "1",
        "nombre_producto": "Camisa de lino manga larga",
        "nombre_variante": "M azul",
        "precio_unitario": "169.00",
        "porcentaje_comision": "12.00",
        "cantidad": 3
      }
    ]
  }
}
```

`direccion` es la fila de `direccion_historial` (la versión congelada al
crear el pedido), no la dirección vigente hoy — si la persona la editó
después, este pedido sigue mostrando la que regía ese día.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un pedido con ese id", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo obtener el pedido", "payload": null }
```

---

## POST /comprador/pedidos/:id/detalles

Agrega una variante al pedido — o, si esa variante ya estaba en el pedido,
**le suma la cantidad** a la línea existente (nunca crea una segunda línea
para la misma variante). Una variante por llamada, no admite lote.

```json
{ "id_producto": 1, "id_producto_variante": 1, "cantidad": 2 }
```

| Campo | Obligatorio | Qué es |
| --- | --- | --- |
| `id_producto` | Sí | Entero mayor a 0 — el `_id` del producto en Mongo |
| `id_producto_variante` | Sí | Entero mayor a 0 — tiene que ser una variante de ese producto |
| `cantidad` | Sí | Entero mayor a 0 — la que se agrega **esta vez**, no la total |

Solo sobre un pedido propio: `id_pedido` (`:id` en la URL) tiene que ser de
quien está logueado, y da el mismo 404 que uno inexistente si no lo es.

### `nombre_producto`, `precio_unitario`, `porcentaje_comision`: los pone el backend

La función de PostgreSQL `agregar_linea(id_pedido, linea_jsonb)` los pide
como parte de la línea porque viven en Mongo, y PostgreSQL no los puede
leer. Esta ruta no se los pide a quien compra: los busca ella misma en el
catálogo público (mismo mecanismo que `GET /productos/:id`, incluyendo que
un producto `borrador`/`inactivo` da el mismo 404 que uno inexistente) y
se los pasa ya congelados a la función — así, si el vendedor sube el
precio después, esta línea conserva el que se le mostró a quien compró.

### El stock se comprueba, no se descuenta ni se reserva

`agregar_linea` mira el stock real (`inventario` en PostgreSQL) y avisa si
no alcanza, pero no descuenta ni aparta nada — es un aviso temprano, no una
garantía. Si dos personas meten la última unidad en su pedido, se la lleva
la primera que compre (`comprar_pedido`, todavía sin ruta): la segunda
recibirá "no hay suficiente stock" al intentar comprar, aunque al agregar
la línea sí le haya alcanzado.

```
POST /comprador/pedidos/11/detalles
{ "id_producto": 1, "id_producto_variante": 1, "cantidad": 2 }

-> primera vez: cantidad: 2
POST /comprador/pedidos/11/detalles
{ "id_producto": 1, "id_producto_variante": 1, "cantidad": 1 }
-> misma variante otra vez: cantidad: 3 (sumada, sigue siendo una sola linea)
```

### 200

```json
{
  "ok": true,
  "mensaje": "Producto agregado al pedido",
  "payload": {
    "id_pedido": 11,
    "id_producto": 1,
    "id_producto_variante": 1,
    "cantidad": 3,
    "stock_disponible": 9
  }
}
```

`cantidad` es la **acumulada** (lo que ya tenía esa línea, más lo que se
acaba de agregar), no la de esta llamada sola. Los ids numéricos de este
payload en particular (`id_pedido`, `id_producto`, `id_producto_variante`)
salen como `Number`, no como `string` — a diferencia del resto de la API:
es lo único que devuelve un `jsonb` de PostgreSQL en vez de una fila
normal, y JSON no distingue un `bigint` de un `number`.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El id_producto es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El id_producto_variante es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La cantidad es obligatoria y debe ser un numero entero mayor a 0", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un pedido con ese id", "payload": null }
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
{ "ok": false, "mensaje": "No existe una variante con ese id en este producto", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El pedido <id> esta <estado> y ya no se puede cambiar", "payload": null }
{ "ok": false, "mensaje": "No hay suficiente stock de \"<nombre_variante>\": quedan <n> y el pedido pide <n>", "payload": null }
```

Los dos mensajes de 409 salen tal cual los levanta `agregar_linea` en
PostgreSQL — ya son claros y seguros de mostrar, así que el backend no los
reescribe. "El pedido pide" es la cantidad **acumulada** que quedaría
(lo que ya tenía la línea más lo que se pidió agregar en esta llamada),
no solo esta llamada.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo agregar el producto al pedido", "payload": null }
```

---

## DELETE /comprador/pedidos/:id/detalles/:idDetalle

Saca una línea del pedido por completo — nunca la deja con cantidad `0`:
la función de PostgreSQL `quitar_linea` simplemente borra la fila, no
resta cantidad.

`idDetalle` es el id propio de la línea
(`pedido_producto.id_pedido_producto`), no el par producto+variante — se
resuelve a ese par internamente, en la misma consulta que comprueba que la
línea sea de un pedido propio: un detalle ajeno, o de un pedido ajeno, da
el mismo 404 que uno que no existe.

```
DELETE /comprador/pedidos/11/detalles/10
```

### 200

```json
{
  "ok": true,
  "mensaje": "Producto quitado del pedido",
  "payload": null
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un detalle con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El pedido <id> esta <estado> y ya no se puede cambiar", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo quitar el producto del pedido", "payload": null }
```
