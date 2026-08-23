# Endpoints de vendedor

Este archivo documenta solo las rutas de `/vendedor/*`. Las demás rutas del
backend están en [endpoints.md](endpoints.md) (usuario, perfil, direcciones,
admin) y [endpoints-productos.md](endpoints-productos.md) (el catálogo
público).

Todas las rutas de aquí requieren la cookie `mesh_token`. Las de
`/vendedor/categorias` aceptan vendedor o admin (`id_rol_usuario` 2 o 3);
todas las de `/vendedor/productos` son solo para vendedor (2) — un producto
siempre pertenece a quien lo crea, y un admin no es dueño de productos
propios. Un rol sin permiso recibe 403, igual que en `/admin/*`.

**Todo lo de productos vive solo en MongoDB.** Las migraciones SQL
(`003_productos.sql`, `004_caracteristicas.sql`) fueron solo para cargar los
datos de prueba vía ETL — crear o editar un producto no toca PostgreSQL
para nada. **La única excepción es el stock real** (tabla `inventario` de
PostgreSQL, migración `005_pedidos_stock.sql`): las dos rutas de
`/inventario` (ver abajo) sí lo consultan, y son las únicas de
`/vendedor/productos` que hablan con las dos bases a la vez.

---

## GET /vendedor/categorias

Las categorías en las que de verdad se puede publicar un producto: las que
**no son raíz** (su `categoria_padre` no es `null`). Pensada para armar el
selector de categoría al crear un producto — trae solo lo mínimo, no el
menú de características (para eso está `GET /vendedor/categorias/:id`).
Ordenadas alfabéticamente por `nombre`.

### 200

```json
{
  "ok": true,
  "mensaje": "Categorias obtenidas",
  "payload": [
    { "id_categoria": 16, "nombre": "Audifonos", "categoria_padre": "Audio" },
    { "id_categoria": 15, "nombre": "Audio", "categoria_padre": "Electronica" },
    { "id_categoria": 3, "nombre": "Camisas", "categoria_padre": "Ropa de hombre" }
  ]
}
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudieron obtener las categorias", "payload": null }
```

---

## GET /vendedor/categorias/:id

Una categoría completa, con el menú entero de características que ofrece
—tanto las de producto (`caracteristicas`) como las de variante
(`caracteristicas_variante`)—, cada una con su `tipo_dato` y su `unidad`.
Es lo que arma el formulario de crear un producto en esa categoría: qué
campos mostrar y de qué tipo es cada uno.

Solo categorías válidas (no raíz): pedir una raíz (`Ropa`, `Electronica`,
etc.) da el mismo 404 que un id que no existe, porque en ninguna de las dos
se puede publicar.

```
GET /vendedor/categorias/3
```

### 200

```json
{
  "ok": true,
  "mensaje": "Categoria obtenida",
  "payload": {
    "id_categoria": 3,
    "nombre": "Camisas",
    "categoria_padre": "Ropa de hombre",
    "porcentaje_comision": { "$numberDecimal": "12.00" },
    "fecha_creacion": { "$date": "2026-01-05T16:10:00.000Z" },
    "caracteristicas": [
      { "nombre": "Marca", "unidad": null, "tipo_dato": "texto" },
      { "nombre": "Duracion de la garantia", "unidad": "meses", "tipo_dato": "entero" }
    ],
    "caracteristicas_variante": [
      { "nombre": "Color", "unidad": null, "tipo_dato": "texto" },
      { "nombre": "Talla", "unidad": null, "tipo_dato": "texto" }
    ]
  }
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

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una categoria con ese id", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo obtener la categoria", "payload": null }
```

---

## POST /vendedor/productos

Solo vendedor (`id_rol_usuario` 2), no admin. Crea un producto **con al
menos una variante** — no existe un producto sin ninguna, porque el precio
vive en la variante. El vendedor sale del token, no del cuerpo: no se puede
crear un producto a nombre de otro usuario.

Nace siempre en estado `borrador` (por eso `GET /productos` y
`GET /productos/paginacion` nunca lo muestran hasta que alguien lo publique
— ver [endpoints-productos.md](endpoints-productos.md)). Las variantes
nacen siempre `activa`.

**El `_id` del producto y el `id_producto_variante` de cada variante se
calculan como "el máximo que ya existe, más 1"**, sin colección de
contadores ni transacción — más simple, a cambio de un riesgo aceptado y
bajo: si dos vendedores crean un producto en el mismo instante exacto,
uno de los dos podría fallar por id duplicado (recuperable reintentando).
El producto y su primer evento se escriben uno después del otro, sin
transacción (Mongo no está en modo replica set).

### Cuerpo de la petición

```json
{
  "id_categoria": 3,
  "nombre": "Camisa de lino manga larga",
  "descripcion": "Camisa de lino de corte regular",
  "caracteristicas_adicionales": [
    { "nombre": "Marca", "valor": "MarcaTest" },
    { "nombre": "Garantia", "valor": true },
    { "nombre": "Duracion de la garantia", "valor": 12 },
    { "nombre": "Materiales principales", "valor": ["Algodon", "Lino"] }
  ],
  "caracteristicas_personalizadas": [
    { "nombre": "Lote de prueba", "valor": "L001" }
  ],
  "variantes": [
    {
      "nombre_variante": "M azul",
      "precio": "169.00",
      "descripcion": "Talla M, color azul",
      "imagenes": ["https://..."],
      "caracteristicas_adicionales": [
        { "nombre": "Color", "valor": "Azul" },
        { "nombre": "Talla", "valor": "M" }
      ],
      "caracteristicas_personalizadas": [
        { "nombre": "Nota interna", "valor": 42 }
      ]
    }
  ]
}
```

| Campo | Obligatorio | Qué es |
| --- | --- | --- |
| `id_categoria` | Sí | Debe ser una categoría válida (no raíz) |
| `nombre` | Sí | Hasta 200 caracteres |
| `descripcion` | No | Acepta null |
| `caracteristicas_adicionales` | No | Del catálogo de la categoría — ver abajo |
| `caracteristicas_personalizadas` | No | Libres — ver abajo |
| `variantes` | Sí, al menos 1 | Cada una con `nombre_variante`, `precio` y `descripcion` obligatorios |
| `variantes[].imagenes` | No | Array de URLs, vacío si no viene |
| `variantes[].stock_inicial` | No | Entero mayor o igual a 0 — ver abajo |

### El stock inicial de una variante (`variantes[].stock_inicial`)

Opcional, y por variante: si viene, apenas se crea el producto se crea
también su inventario real en PostgreSQL, reutilizando el mismo mecanismo
de
[POST /vendedor/productos/:id/inventario](#post-vendedorproductosidinventario)
(fila en `inventario`, más su primer movimiento de `reposicion` si es
mayor a 0, más el `$set` de `variantes[].stock` en Mongo) — una variante a
la vez, nunca en lote.

Si no viene, esa variante nace **sin inventario**, exactamente como
funcionaba antes de que existiera esta ruta: el vendedor la publica y
arregla el inventario después, con el POST de arriba, o consultando
`GET /vendedor/productos/:id/inventario` para ver cuáles le hacen falta
(le va a contestar 409 hasta que las cree).

**Se valida antes de crear nada.** Si alguna variante trae un
`stock_inicial` inválido (negativo, no entero), toda la petición se
rechaza con 400 y **no se crea ningún producto** — no tendría sentido
crear el producto y fallar a medias intentando su inventario.

**Si el producto sí se crea pero crear el inventario de alguna variante
fallara** (por ejemplo, PostgreSQL no responde en ese instante), **el
producto queda creado igual**: esa variante en particular se queda sin
inventario, en el mismo estado de "pendiente" de siempre, arreglable
después con el POST de inventario. La respuesta de esta ruta no cambia de
forma para avisar esto — sigue siendo el producto completo, tal como
estaba antes de que existiera `stock_inicial`.

### Características del catálogo (`caracteristicas_adicionales`)

Solo `nombre` y `valor` — **nunca `unidad`**: el backend la rellena solo,
tomándola de la definición de la categoría (`GET /vendedor/categorias/:id`
para saber qué ofrece y de qué tipo es cada una). Cada `nombre` tiene que
ser una de las que esa categoría ofrece (`caracteristicas` para el
producto, `caracteristicas_variante` para cada variante), sin repetirse
dentro del mismo producto o variante, y el `valor` tiene que cumplir su
`tipo_dato`:

| `tipo_dato` | `valor` esperado |
| --- | --- |
| `texto` | Texto no vacío |
| `entero` | `Number` entero |
| `decimal` | `Number` |
| `booleano` | `true` / `false` |
| `lista` | Array de texto, con al menos un elemento |

### Características personalizadas (`caracteristicas_personalizadas`)

No salen de ningún catálogo — el nombre lo inventa el vendedor. Solo se
valida que el formato sea razonable: nombre no vacío (hasta 100
caracteres) y sin repetirse, valor suelto (texto, número o
verdadero/falso), nunca un array ni un objeto. Siempre se guardan con
`unidad: null`.

### 201

```json
{
  "ok": true,
  "mensaje": "Producto creado correctamente",
  "payload": {
    "_id": 51,
    "nombre": "Camisa de lino manga larga",
    "descripcion": "Camisa de lino de corte regular",
    "fecha_creacion": { "$date": "2026-08-23T01:19:20.964Z" },
    "estado": "borrador",
    "vendedor": { "id_usuario": 8, "usuario": "vendtest", "nombre": "Test", "apellido": "Vendedor" },
    "categoria": {
      "id_categoria": 3,
      "nombre": "Camisas",
      "categoria_padre": "Ropa de hombre",
      "porcentaje_comision": { "$numberDecimal": "12.00" }
    },
    "variantes": [
      {
        "id_producto_variante": 93,
        "nombre_variante": "M azul",
        "precio": { "$numberDecimal": "169.00" },
        "descripcion": "Talla M, color azul",
        "fecha_creacion": { "$date": "2026-08-23T01:19:20.964Z" },
        "estado": "activa",
        "imagenes": ["https://..."],
        "caracteristicas_adicionales": [
          { "nombre": "Color", "valor": "Azul", "unidad": null },
          { "nombre": "Talla", "valor": "M", "unidad": null }
        ],
        "caracteristicas_personalizadas": [
          { "nombre": "Nota interna", "valor": 42, "unidad": null }
        ]
      }
    ],
    "caracteristicas_adicionales": [
      { "nombre": "Marca", "valor": "MarcaTest", "unidad": null },
      { "nombre": "Garantia", "valor": true, "unidad": null },
      { "nombre": "Duracion de la garantia", "valor": 12, "unidad": "meses" },
      { "nombre": "Materiales principales", "valor": ["Algodon", "Lino"], "unidad": null }
    ],
    "caracteristicas_personalizadas": [
      { "nombre": "Lote de prueba", "valor": "L001", "unidad": null }
    ]
  }
}
```

También se crea, en `productos_eventos`, el primer evento
(`_id: "51-1"`, `numero: 1`, `operacion: "creacion"`) con `datos` siendo la
copia completa del producto recién creado (sin `_id`, ese ya va en
`id_producto`).

### 400

```json
{ "ok": false, "mensaje": "El nombre del producto es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El nombre del producto no puede tener mas de 200 caracteres", "payload": null }
{ "ok": false, "mensaje": "El id de la categoria no es valido", "payload": null }
{ "ok": false, "mensaje": "La categoria no existe o no es valida para publicar", "payload": null }
{ "ok": false, "mensaje": "Debes enviar al menos una variante", "payload": null }
{ "ok": false, "mensaje": "El nombre de la variante es obligatorio", "payload": null }
{ "ok": false, "mensaje": "La descripcion de la variante es obligatoria", "payload": null }
{ "ok": false, "mensaje": "El precio es obligatorio y debe ser un numero mayor a 0, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "imagenes debe ser una lista de URLs de texto", "payload": null }
{ "ok": false, "mensaje": "El stock_inicial es obligatorio y debe ser un numero entero mayor o igual a 0", "payload": null }
{ "ok": false, "mensaje": "Cada caracteristica necesita un nombre", "payload": null }
{ "ok": false, "mensaje": "La caracteristica \"<nombre>\" viene repetida", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" no es una caracteristica de esta categoria", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser texto", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser un numero", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser verdadero o falso", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser una lista de texto con al menos un elemento", "payload": null }
{ "ok": false, "mensaje": "Cada caracteristica personalizada necesita un nombre valido", "payload": null }
{ "ok": false, "mensaje": "La caracteristica personalizada \"<nombre>\" viene repetida", "payload": null }
{ "ok": false, "mensaje": "El valor de \"<nombre>\" debe ser texto, numero o verdadero/falso", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo crear el producto", "payload": null }
```

---

## PATCH /vendedor/productos/:id

Solo el vendedor dueño del producto (no otro vendedor, no admin). Edita
cualquier campo que tenga sentido cambiar: `nombre`, `descripcion`,
`estado`, `id_categoria`, `caracteristicas_adicionales`,
`caracteristicas_personalizadas` y **`variantes`** — sí, las variantes se
editan aquí mismo, como un campo más del producto, no en una ruta aparte.

Cada campo es independiente: el que venga en `null` (o no venga) no se
toca. Debe venir al menos uno. Para las dos listas de características, un
array (aunque sea `[]`) reemplaza la lista completa; `null` es no tocarla.
Enviar `[]` a propósito la vacía del todo (el producto queda sin ese campo,
igual que si nunca hubiera tenido características).

**`variantes` se comporta distinto: no admite quedar vacío.** Si se manda,
reemplaza el array completo — mismas reglas que al crear el producto
(`nombre_variante`, `precio` y `descripcion` obligatorios, características
validadas contra `caracteristicas_variante` de la categoría vigente) —
pero siempre tiene que traer al menos una: un producto nunca se queda sin
ninguna variante, ni siquiera al editar.

### Conservar una variante (`variantes[].id_producto_variante`)

Cada variante del array puede traer, opcionalmente, el
`id_producto_variante` que ya tenía (el mismo que devuelve `GET
/vendedor/productos/:id`). Esto decide si esa variante se trata como "la
misma, editada" o como una completamente nueva:

- **Si lo manda y coincide con una variante que el producto ya tenía**, esa
  variante **conserva ese mismo id** — no se le asigna uno nuevo — y
  también **conserva su `stock`** (la copia de lectura que se ve en el
  catálogo público no se pierde solo por reenviar la variante en una
  edición). PostgreSQL ni se entera: su fila de `inventario` sigue
  apuntando al mismo id de siempre, no hace falta tocarla.
- **Si no lo manda**, es una variante nueva de verdad: le toca un
  `id_producto_variante` nuevo, y nace sin stock — exactamente como una
  variante agregada en `POST /vendedor/productos`.
- **Si lo manda y no coincide con ninguna variante actual del producto**,
  la edición completa se rechaza (400) — no se crea una variante nueva
  ignorando el id que se mandó, ni se adivina a cuál se refería.

```
PATCH /vendedor/productos/53
{
  "variantes": [
    { "id_producto_variante": 5, "nombre_variante": "M azul (renombrada)", "precio": "175.00", "descripcion": "..." },
    { "nombre_variante": "Talla XL", "precio": "175.00", "descripcion": "..." }
  ]
}
-> la variante 5 conserva su id y su stock; "Talla XL" nace con id nuevo y sin stock
```

### El stock de una variante al editar (`variantes[].stock_inicial`)

Igual que en `POST /vendedor/productos`: si una variante del array trae
`stock_inicial` y todavía no tiene fila en `inventario` (porque es nueva,
o porque ya existía pero nunca se le creó), se le crea de una vez,
reutilizando el mismo mecanismo de
[POST /vendedor/productos/:id/inventario](#post-vendedorproductosidinventario)
— una variante a la vez, con su primer movimiento de `reposicion` si es
mayor a 0. **Si esa variante ya tenía inventario, `stock_inicial` se
ignora** — no lo sobreescribe; para eso haría falta una ruta de ajuste,
todavía no hecha.

Se valida antes de escribir nada: un `stock_inicial` inválido en cualquier
variante rechaza toda la edición, igual que al crear un producto.

Un producto de otro vendedor da el mismo 404 que un id que no existe — no
hay forma de usar esta ruta para confirmar que productos tiene otra
persona.

Un mismo evento de modificación puede traer varias llaves en `cambios` a
la vez, una por cada cosa que cambió en esa edición (por ejemplo, `nombre`
y `estado` juntos, o `categoria` y `variantes` juntos, si se mandan en la
misma petición).

### El caso especial: cambiar de categoría

Las características siempre están atadas a la categoría — nunca sueltas, y
esto aplica igual a las de la raíz que a las de cada variante. Por eso:

- **Si mandas `caracteristicas_adicionales` y/o `variantes` nuevas**, se
  validan contra la categoría que quede vigente después de esta edición (la
  nueva, si también mandaste `id_categoria`; si no, la que ya tenía).
- **Si cambias `id_categoria` sin mandar características ni variantes
  nuevas**, se revisa que las que el producto ya tenía — las suyas y las de
  cada variante existente — sigan siendo válidas para la categoría nueva.
  Si alguna ya no encaja, la edición se rechaza: hay que mandar también las
  características (o las variantes) correctas en la misma petición.

```
PATCH /vendedor/productos/53
{ "id_categoria": 27 }
-> rechazado si alguna variante tenia "Color" y la categoria nueva no lo ofrece

PATCH /vendedor/productos/53
{ "id_categoria": 27, "variantes": [{ "nombre_variante": "Edicion unica", "precio": "15.00", "descripcion": "Libro" }] }
-> aceptado: categoria y variantes cambian juntas, en el mismo evento
```

### 200

```json
{
  "ok": true,
  "mensaje": "Producto actualizado correctamente",
  "payload": { "...": "el producto completo, ya actualizado" }
}
```

También se agrega un evento de modificación en `productos_eventos`, con
`cambios` conteniendo solo las llaves que de verdad cambiaron, cada una
completa (el array entero, no un diff adentro) — mismo criterio que ya usan
`categoria` y `variantes` en los eventos existentes.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "Debes enviar al menos un campo para actualizar", "payload": null }
{ "ok": false, "mensaje": "El nombre del producto es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El nombre del producto no puede tener mas de 200 caracteres", "payload": null }
{ "ok": false, "mensaje": "La descripcion no puede quedar vacia", "payload": null }
{ "ok": false, "mensaje": "El estado debe ser uno de: borrador, activo, inactivo", "payload": null }
{ "ok": false, "mensaje": "El id de la categoria no es valido", "payload": null }
{ "ok": false, "mensaje": "La categoria no existe o no es valida para publicar", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" ya no es una caracteristica valida para la nueva categoria", "payload": null }
{ "ok": false, "mensaje": "Debes enviar al menos una variante", "payload": null }
{ "ok": false, "mensaje": "El stock_inicial es obligatorio y debe ser un numero entero mayor o igual a 0", "payload": null }
{ "ok": false, "mensaje": "La variante <id> no pertenece a este producto", "payload": null }
```

Más los mismos errores de característica que `POST /vendedor/productos`
(nombre repetido, tipo incorrecto, no pertenece a la categoría, formato de
personalizada inválido — ver arriba).

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo actualizar el producto", "payload": null }
```

---

## GET /vendedor/productos

Todos los productos del vendedor logueado, **en cualquier estado**
(`borrador`, `activo` e `inactivo` — a diferencia del catálogo público, que
oculta `borrador` e `inactivo`). Es el panel de "mis productos": el
vendedor tiene que poder ver y administrar los que todavía no ha
publicado, no solo los que ya están activos. Ordenados por
`fecha_creacion`, más reciente primero. Sin paginación ni filtros — trae
todos de una vez.

**Sin `variantes[].stock`, a propósito.** Esta es una ruta "rápida": no
toca PostgreSQL. El stock real vive aparte, en
[GET /vendedor/productos/inventario](#get-vendedorproductosinventario).

### 200

```json
{
  "ok": true,
  "mensaje": "Productos obtenidos",
  "payload": [
    { "_id": 52, "nombre": "...", "estado": "borrador", "...": "..." }
  ]
}
```

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas de `/vendedor/productos` (ver arriba).

---

## GET /vendedor/productos/inventario

**El stock real** de todos los productos del vendedor logueado — la tabla
`inventario` de PostgreSQL, no la copia de lectura que trae
`variantes[].stock` en el catálogo público. Por eso es la ruta más pesada
de las de vendedor: primero pregunta a MongoDB qué productos y qué
variantes son suyas, y después le pregunta a PostgreSQL el stock de cada
una de esas variantes.

Devuelve una lista **plana**, un elemento por variante (no agrupada por
producto):

```json
{
  "ok": true,
  "mensaje": "Inventario obtenido",
  "payload": [
    { "id_producto": 1, "id_producto_variante": 1, "stock": 9 },
    { "id_producto": 1, "id_producto_variante": 2, "stock": 11 },
    { "id_producto": 2, "id_producto_variante": 3, "stock": 12 }
  ]
}
```

Sin productos propios, `payload` sale `[]` (no es un error).

**Si una variante propia todavía no tiene fila en `inventario`** (hoy pasa
con las que se publican desde el panel: `POST /vendedor/productos` y
`PATCH /vendedor/productos/:id` todavía no crean esa fila, pendiente
documentado en `cambios-etl-productos.md`), **la petición entera falla**
con 409 — no se rellena con `0` en silencio, ni se omite esa variante y se
muestran las demás. El mensaje nombra el producto y la variante exactos
que faltan, para que el vendedor sepa qué arreglar:

### 409

```json
{ "ok": false, "mensaje": "El producto \"Camisa de lino manga larga\" (id 1), variante \"L azul\" (id 2), todavia no tiene inventario creado", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo obtener el inventario", "payload": null }
```

---

## GET /vendedor/productos/inventario/motivos-ajuste

Trae los dos motivos de `motivo_movimiento` que admite
[PATCH /vendedor/productos/:id/inventario](#patch-vendedorproductosidinventario)
— "ajuste positivo" y "ajuste negativo" — con sus ids reales de
PostgreSQL, para que el frontend arme el select sin tenerlos escritos a
mano. No trae los otros cuatro motivos del catálogo (`venta`,
`devolucion`, `reposicion`, `merma`): esos nacen de otros flujos (una
compra, publicar un producto), nunca de un ajuste manual.

### 200

```json
{
  "ok": true,
  "mensaje": "Motivos obtenidos",
  "payload": [
    { "id_motivo_movimiento": 4, "motivo_nombre": "ajuste positivo" },
    { "id_motivo_movimiento": 5, "motivo_nombre": "ajuste negativo" }
  ]
}
```

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas de `/vendedor/productos` (el 503 es de
PostgreSQL).

---

## GET /vendedor/productos/:id

Un producto propio tal como está **hoy**, con todos sus detalles (el mismo
documento completo que devuelven las rutas de creación y edición). A
diferencia del catálogo público (que no tiene una ruta de detalle por id
todavía, y de cualquier forma solo mostraría productos `activo`), esta
funciona sin importar el estado — sirve justo para ver un producto propio
en `borrador` o `inactivo` antes de publicarlo.

Un producto de otro vendedor da el mismo 404 que un id que no existe.

**Sin `variantes[].stock`, a propósito** — mismo motivo que
`GET /vendedor/productos` (ver arriba): el stock real de este producto
está en
[GET /vendedor/productos/:id/inventario](#get-vendedorproductosidinventario).

### 200

```json
{
  "ok": true,
  "mensaje": "Producto obtenido",
  "payload": { "_id": 52, "nombre": "...", "estado": "activo", "...": "..." }
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas.

---

## GET /vendedor/productos/:id/inventario

Lo mismo que
[GET /vendedor/productos/inventario](#get-vendedorproductosinventario),
pero de un solo producto propio: la misma lista plana
`{ id_producto, id_producto_variante, stock }`, filtrada a las variantes
de ese producto. Mismo chequeo de dueño que `GET /vendedor/productos/:id`
(404 si no es tuyo o no existe), y el mismo 409 si alguna de sus variantes
no tiene fila en `inventario` todavía.

```
GET /vendedor/productos/1/inventario
```

### 200

```json
{
  "ok": true,
  "mensaje": "Inventario obtenido",
  "payload": [
    { "id_producto": 1, "id_producto_variante": 1, "stock": 9 },
    { "id_producto": 1, "id_producto_variante": 2, "stock": 11 }
  ]
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El producto \"Camisa de lino manga larga\" (id 1), variante \"L azul\" (id 2), todavia no tiene inventario creado", "payload": null }
```

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas (el 503 puede ser de MongoDB o de
PostgreSQL, ver
[GET /vendedor/productos/inventario](#get-vendedorproductosinventario)).

---

## POST /vendedor/productos/:id/inventario

La reconstrucción de un inventario que falta: crea la fila de `inventario`
de **una sola variante** propia, cuando el GET de arriba (o el de "todas
las mías") rechazó con 409 porque esa variante todavía no la tenía. No
admite lote — una variante a la vez, con su propio `id_producto_variante`
y su stock inicial.

`id_producto` sale de la URL (igual que en los GET de un producto
específico); el cuerpo solo trae lo que falta:

```json
{ "id_producto_variante": 2, "stock_inicial": 20 }
```

| Campo | Obligatorio | Qué es |
| --- | --- | --- |
| `id_producto_variante` | Sí | Número entero mayor a 0, y tiene que ser una variante que de verdad tenga ese producto |
| `stock_inicial` | Sí | Número entero mayor o igual a 0 |

**También dejas un primer renglón en `stock_movimiento`** (motivo
`reposicion`), para que el libro mayor nazca cuadrado con `inventario.stock`
desde el primer día — salvo que `stock_inicial` sea `0`: ahí no hay nada
que mover (`stock_movimiento.cantidad` no admite `0`), así que solo se crea
la fila de `inventario`. Las dos escrituras van en una sola transacción.

**Solo para crear, no para ajustar.** Si esa variante ya tenía fila en
`inventario`, se rechaza con 409 — esta ruta es solo la reconstrucción del
primer inventario. Para subir o bajar el stock de una variante que ya lo
tiene está
[PATCH /vendedor/productos/:id/inventario](#patch-vendedorproductosidinventario).

**También deja `variantes[].stock` al día en el documento de Mongo**, con
un `$set` sobre esa variante — es uno de los tres momentos documentados en
`cambios-etl-productos.md` en que la copia de lectura se actualiza ("al
publicar un producto o agregar una variante"), y este POST es justamente
ese momento para una variante que no lo tenía. Pasa después de que la
transacción de PostgreSQL ya confirmó: si esta segunda escritura fallara,
el inventario real en PostgreSQL queda creado igual (es la fuente de la
verdad), solo la copia de lectura en Mongo se queda desactualizada hasta
que se reintente.

Mismo chequeo de dueño que las demás rutas de `/vendedor/productos/:id`:
un producto ajeno da el mismo 404 que un id que no existe.

```
POST /vendedor/productos/1/inventario
{ "id_producto_variante": 2, "stock_inicial": 20 }
```

### 201

```json
{
  "ok": true,
  "mensaje": "Inventario creado correctamente",
  "payload": { "id_producto": 1, "id_producto_variante": 2, "stock": 20 }
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El id_producto_variante es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El stock_inicial es obligatorio y debe ser un numero entero mayor o igual a 0", "payload": null }
{ "ok": false, "mensaje": "La variante <id> no existe en el producto \"<nombre>\" (id <id_producto>)", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "Ya existe inventario para el producto \"Camisa de lino manga larga\" (id 1), variante \"L azul\" (id 2)", "payload": null }
```

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas (el 503 puede ser de MongoDB o de
PostgreSQL).

---

## PATCH /vendedor/productos/:id/inventario

Ajusta (sube o baja) el stock de **una variante propia que YA tiene
inventario** — para correcciones manuales, por ejemplo un conteo físico
que no cuadraba. Solo sobre productos propios: mismo chequeo de dueño que
las demás rutas de `/vendedor/productos/:id` (404 si no es tuyo o no
existe).

`id_producto` sale de la URL (igual que en
[POST /vendedor/productos/:id/inventario](#post-vendedorproductosidinventario));
el cuerpo trae la variante, el motivo y la cantidad:

```json
{ "id_producto_variante": 2, "id_motivo_movimiento": 4, "cantidad": 10 }
```

| Campo | Obligatorio | Qué es |
| --- | --- | --- |
| `id_producto_variante` | Sí | Tiene que ser una variante de este producto, y ya tener inventario creado |
| `id_motivo_movimiento` | Sí | Solo el de "ajuste positivo" o "ajuste negativo" — ver [GET /vendedor/productos/inventario/motivos-ajuste](#get-vendedorproductosinventariomotivos-ajuste) |
| `cantidad` | Sí | Entero mayor a 0 — nunca 0, un movimiento siempre mueve algo |

El nuevo stock sale de `stock_actual + cantidad * valor_del_motivo`
(`valor` es `1` o `-1`, ver `motivo_movimiento.valor`). Bloquea la fila de
`inventario` (`FOR UPDATE`) mientras decide, igual que `comprar_pedido`,
para que dos ajustes al mismo tiempo no se pisen.

**No crea inventario que no existía.** Si la variante no tiene fila en
`inventario` todavía, se rechaza — para crearla por primera vez está
[POST /vendedor/productos/:id/inventario](#post-vendedorproductosidinventario),
no esta ruta.

**Nunca deja el stock en negativo.** Si el ajuste negativo dejaría el
stock por debajo de 0, se rechaza con un mensaje que dice cuánto queda y
cuánto se quiso quitar — no se escribe nada, ni en `inventario` ni en
`stock_movimiento`.

**Deja `variantes[].stock` al día en Mongo**, con el mismo `$set` que ya
usan las demás rutas de inventario, después de confirmar el ajuste real en
PostgreSQL.

```
PATCH /vendedor/productos/1/inventario
{ "id_producto_variante": 2, "id_motivo_movimiento": 4, "cantidad": 10 }
```

### 200

```json
{
  "ok": true,
  "mensaje": "Inventario ajustado correctamente",
  "payload": { "id_producto": 1, "id_producto_variante": 2, "stock": 30 }
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El id_producto_variante es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La cantidad es obligatoria y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El id_motivo_movimiento es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El id_motivo_movimiento debe ser el de \"ajuste positivo\" o \"ajuste negativo\"", "payload": null }
{ "ok": false, "mensaje": "La variante <id> no existe en el producto \"<nombre>\" (id <id_producto>)", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El producto \"Camisa de lino manga larga\" (id 1), variante \"L azul\" (id 2), todavia no tiene inventario creado", "payload": null }
{ "ok": false, "mensaje": "No hay suficiente stock: quedan <n> y se quiere quitar <n>", "payload": null }
```

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas (el 503 puede ser de MongoDB o de
PostgreSQL).

---

## GET /vendedor/productos/:id/historial

Reconstruye un producto propio **como estaba en una fecha específica**:
toma el evento de creación y todos los de modificación anteriores a esa
fecha (o de ese mismo día), en orden, y los fusiona uno encima del otro.

**Se arma con el framework de agregación de Mongo, no en el código del
backend**: la búsqueda, el orden y la fusión de eventos pasan dentro de un
pipeline de `db.productos_eventos.aggregate(...)` (`$match`, `$sort`,
`$group`, `$reduce`, `$mergeObjects`) — el backend solo valida el id y la
fecha, y le agrega el `_id` de vuelta al resultado.

Como cada evento aporta el estado completo de lo que cambió (`datos` en la
creación, `cambios` en cada modificación — nunca un campo suelto), fusionar
todos en orden con `$mergeObjects` reconstruye el documento exacto de ese
día: si algo cambió dos veces antes de la fecha pedida, se queda con el
valor de la segunda vez, porque se fusiona después y lo sobrescribe.

Solo productos propios: un producto de otro vendedor da el mismo 404 que
un id que no existe. Una fecha anterior a la creación del producto también
da 404, con un mensaje distinto (el producto sencillamente no existía
todavía).

```
GET /vendedor/productos/52/historial?fecha=2026-01-07
```

### 200

```json
{
  "ok": true,
  "mensaje": "Producto reconstruido correctamente",
  "payload": { "_id": 52, "nombre": "Producto historico editado", "estado": "borrador", "...": "..." }
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "La fecha es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La fecha debe tener el formato AAAA-MM-DD", "payload": null }
{ "ok": false, "mensaje": "La fecha no es valida", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
{ "ok": false, "mensaje": "El producto no existia en esa fecha", "payload": null }
```

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas.
