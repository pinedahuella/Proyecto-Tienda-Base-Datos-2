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
datos de prueba vía ETL — de aquí en adelante, crear o editar un producto no
toca PostgreSQL para nada.

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
validadas contra `caracteristicas_variante` de la categoría vigente, ids
nuevos para cada una) — pero siempre tiene que traer al menos una: un
producto nunca se queda sin ninguna variante, ni siquiera al editar.

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

## GET /vendedor/productos/:id

Un producto propio tal como está **hoy**, con todos sus detalles (el mismo
documento completo que devuelven las rutas de creación y edición). A
diferencia del catálogo público (que no tiene una ruta de detalle por id
todavía, y de cualquier forma solo mostraría productos `activo`), esta
funciona sin importar el estado — sirve justo para ver un producto propio
en `borrador` o `inactivo` antes de publicarlo.

Un producto de otro vendedor da el mismo 404 que un id que no existe.

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
