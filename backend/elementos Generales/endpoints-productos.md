# Endpoints de productos

Este archivo documenta solo las rutas públicas de `/productos` y
`/categorias` (la base documental, MongoDB) — `GET /productos`,
`GET /productos/paginacion`, `GET /productos/:id`, `GET /categorias` y
`GET /categorias/:id`. Ninguna requiere sesión. Las demás rutas del
backend (usuario, perfil, direcciones, admin) están en
[endpoints.md](endpoints.md); las de vendedor (que sí requieren sesión) en
[endpoints-vendedores.md](endpoints-vendedores.md); y las de comprar (con
sesión, pero sin exigir un rol en particular) en
[endpoints-compradores.md](endpoints-compradores.md).

La forma de los documentos que devuelven estas rutas está explicada en
[Elementos Documentales/productos_subproductos.md](Elementos%20Documentales/productos_subproductos.md)
y [Elementos Documentales/ejemplos_bson_productos.md](Elementos%20Documentales/ejemplos_bson_productos.md).

Hay dos formas de listar el catálogo, con exactamente los mismos filtros y
el mismo comportamiento (mismos estados ocultos, mismas reglas de
validación): `GET /productos` pagina por cursor (scroll infinito) y
`GET /productos/paginacion` pagina por número de página (con salto directo).
Los filtros están documentados una sola vez, en la sección
["Ejemplo de cada filtro por separado"](#ejemplo-de-cada-filtro-por-separado),
y aplican igual a las dos rutas.

---

## GET /productos

Pública: no requiere la cookie `mesh_token`. Cualquiera puede navegar el
catálogo sin haber iniciado sesión, a diferencia de `/perfil` o
`/direccion-usuario`.

Lista productos **paginados por cursor**, pensado para scroll infinito: cada
tanda trae el `_id` del último producto que devolvió, y esa es la pista para
pedir la siguiente tanda. No hay "número de página" ni forma de saltar
directo a una página arbitraria — a cambio, la consulta es igual de rápida
sin importar qué tan adentro del catálogo estés, porque Mongo usa el índice
de `_id` para saltar directo al punto de partida en vez de contar y
descartar documentos uno por uno (que es lo que sí pasa con `skip`/`limit`
por número de página).

Esto es posible sin cambiar nada en el ETL ni en la base: `_id` ya es el
mismo `id_producto` `bigserial` de PostgreSQL, así que ya es único y siempre
creciente por sí solo.

**Los productos `inactivo` o `borrador` nunca aparecen aquí.** No es un
filtro opcional que se pueda desactivar: la consulta los excluye siempre,
incluso si se pide explícitamente `?estado=inactivo` (en ese caso, la
respuesta es una lista vacía, no un error). No cuentan como parte del
catálogo público.

### Query params

| Param | Tipo | Obligatorio | Qué hace |
| --- | --- | --- | --- |
| `limite` | entero | No (por defecto 20, tope 100) | Cuántos productos trae esta tanda |
| `despues_de` | entero | No | El cursor: el `_id` del último producto visto. Si no viene, empieza desde el principio |
| `nombre` | texto | No | Búsqueda parcial (sin distinguir mayúsculas) sobre `nombre` |
| `estado` | texto | No | Igualdad exacta sobre `estado` del producto |
| `id_categoria` | entero | No | Igualdad exacta sobre `categoria.id_categoria` |
| `precio_min` / `precio_max` | decimal | No | Rango sobre `precio_tienda` |
| `estado_variante` | texto | No | Igualdad exacta sobre `variantes[].estado` |
| `stock_min` / `stock_max` | entero | No | Rango sobre `stock_total` (existencias activas entre TODOS los vendedores, ya sumadas sobre las variantes) |
| `stock_tienda_min` / `stock_tienda_max` | entero | No | Rango sobre `stock_tienda` (existencias activas solo de la tienda, ya sumadas sobre las variantes) |
| _cualquier otro nombre_ | texto | No | Filtro dinámico de característica (catálogo o personalizada) — igualdad por defecto, o `min_`/`max_`/`contiene_` como prefijo — ver abajo |

### Paginación por cursor: ejemplo

```
GET /productos?limite=5                    -> productos 1 a 5, siguiente_cursor: 5
GET /productos?limite=5&despues_de=5        -> productos 6 a 10, siguiente_cursor: 10
GET /productos?limite=5&despues_de=10       -> productos 11 a 15, siguiente_cursor: 15
```

Cuando la tanda devuelta trae menos productos que el `limite` pedido, ya no
hay más: `siguiente_cursor` sale en `null` y el frontend deja de pedir.

### Filtros fijos

Son los campos que existen siempre, sin importar la categoría (los
"Obligatorios" de `productos_subproductos.md`).

```
GET /productos?nombre=laptop
GET /productos?id_categoria=5
GET /productos?precio_min=100&precio_max=500&estado_variante=activa
GET /productos?stock_min=10
```

**Modelo multi-vendedor** (ver `docs/base-de-datos.md` en la raíz del
repo, "El catálogo se mudó a MongoDB"): el producto ya no tiene un precio
ni un stock propios — cada vendedor pone los suyos en su oferta, que vive
solo en PostgreSQL. Lo que trae el documento son cuatro números ya
calculados (nunca agregados al vuelo en la consulta): `precio_tienda`,
`stock_tienda`, `stock_total` y `total_ofertas`, tanto en la raíz del
producto como dentro de cada variante — son los que necesita la tarjeta
del catálogo sin ir a pedir las ofertas reales.

- **`precio_min`/`precio_max`** van sobre `precio_tienda`: el precio de la
  oferta de la tienda (a nivel de producto, el menor entre sus variantes).
  Ya no se puede filtrar por el precio de un vendedor cualquiera desde
  aquí — para eso está la lista de `ofertas` de `GET /productos/:id`.
- **`estado_variante`** sigue siendo `variantes[].estado` (si la
  presentación está activa o inactiva), pero ya **no se combina** con el
  rango de precio en la misma variante: como el precio ahora es un campo
  calculado de la raíz y no de cada variante, las dos condiciones se
  evalúan por separado.
- **`stock_min`/`stock_max`** van sobre `stock_total`: existencias activas
  entre TODOS los vendedores, ya sumadas sobre las variantes del producto.
  **`stock_tienda_min`/`stock_tienda_max`** son la misma idea pero solo
  con las existencias de la tienda (`stock_tienda`). Los dos son campos ya
  calculados en el documento — filtrar por ellos es directo, no hace falta
  ninguna agregación previa.

### Filtros dinámicos (características, del catálogo o personalizadas)

`caracteristicas_adicionales` y `caracteristicas_personalizadas` son, las
dos, un `Array<{ nombre, valor, unidad }>` (ver
[productos_subproductos.md](Elementos%20Documentales/productos_subproductos.md)) —
la primera sale del catálogo de la app, la segunda la escribe quien crea el
producto, pero comparten exactamente la misma forma. Por eso **cualquier
query param que no sea uno de los nombres fijos de la tabla de arriba se
trata como el `nombre` de una característica**, y se busca por igual en las
cuatro ubicaciones posibles: las dos, tanto del producto como de cada una
de sus variantes.

```
GET /productos?Marca=Lenovo
```

Encuentra un producto si en cualquiera de esos cuatro lugares existe una
entrada `{ nombre: "Marca", valor: "Lenovo", ... }`. No hace falta que sea
la misma variante que otro filtro dinámico, ni que las dos coincidencias
vengan del mismo campo (`caracteristicas_adicionales` vs.
`caracteristicas_personalizadas`): cada filtro se busca por su cuenta.

Se pueden combinar varios a la vez (todos deben cumplirse, cada uno por su
lado):

```
GET /productos?Marca=Lenovo&Memoria%20RAM=16
```

(los espacios del nombre van codificados en la URL: `Memoria%20RAM`, o
`Memoria+RAM`)

**Por defecto el valor se compara de forma exacta**, a diferencia de
`nombre` (el filtro fijo del producto), que sí es una búsqueda parcial —
salvo que el nombre del query param lleve uno de estos prefijos, que
cambian el operador:

| Prefijo | Operador | Ejemplo |
| --- | --- | --- |
| _(ninguno)_ | Igualdad exacta | `Marca=Lenovo` |
| `min_` | Mayor o igual (`$gte`) | `min_Nucleos=8` |
| `max_` | Menor o igual (`$lte`) | `max_Nucleos=16` |
| `contiene_` | Contiene, sin distinguir mayúsculas (como `nombre`) | `contiene_Marca=Len` |

`min_`/`max_` se pueden combinar en el mismo filtro (`min_Nucleos=8&max_Nucleos=16`
es "entre 8 y 16"). El prefijo se quita del nombre antes de buscar
(`min_Nucleos` filtra la característica `Nucleos`), y el operador se
aplica **por igual a características del catálogo y personalizadas**, sin
necesidad de conocer su `tipo_dato` de antemano: si el operador no tiene
sentido contra lo que hay guardado (por ejemplo `min_` sobre una
característica de texto), Mongo simplemente no encuentra coincidencia —
no es un error, el filtro se aplicó, solo no encontró nada porque se usó
mal.

**Las características de tipo `lista`** aparecen como varias entradas con
el mismo `nombre` (ver `productos_subproductos.md`). Filtrar por una de
ellas encuentra el producto si **al menos una** de esas entradas tiene ese
valor: `?Contenido del paquete=Cargador` encuentra un producto aunque esa
misma lista también tenga "Manual" y "Laptop".

**Sobre el tipo del valor.** El texto que llega en la URL se intenta
convertir al tipo que le corresponde según cómo se ve: `"true"`/`"false"` a
`Boolean`, texto que parece un número a `Number`, y el resto se queda como
texto — porque así es como debe estar guardado el valor (ver
`productos_subproductos.md`). Pero la carga de datos actual todavía guarda
todo como texto sin excepción (es un pendiente, ver
[pendientes-etl-caracteristicas.md](pendientes-etl-caracteristicas.md)), así
que el filtro busca contra **las dos formas a la vez** — el valor
convertido y el texto tal cual — para encontrar el producto sin importar
cuál de las dos formas tenga guardadas en este momento. Esta conversión
también se le aplica al valor de `min_`/`max_` (para que `min_Nucleos=8`
compare contra el número `8`, no contra el texto `"8"`) — pero solo contra
la forma convertida, sin el `$in` de las dos formas, porque `$gte`/`$lte`
no tendría sentido comparando contra texto. `contiene_` no convierte nada:
siempre compara el texto tal cual llegó, igual que `nombre`.

**Seguridad.** El nombre de la característica y su valor nunca se usan para
armar un nombre de campo de Mongo: siempre entran como *valores* dentro de
llaves fijas que escribe el propio código (`{ nombre: ..., valor: ... }`),
nunca el usuario. Por eso no hace falta restringir qué caracteres trae el
nombre — "Memoria RAM" o "Pais de origen" son tan válidos como cualquier
otro texto — y tampoco hay forma de inyectar un operador de Mongo a través
de él, sin importar qué le manden.

### Qué nombres se pueden usar

Para las del catálogo, el nombre es literalmente el que aparece en la
columna "Característica" de la Tabla 1 y la Tabla 2 de
[productos_subproductos.md](Elementos%20Documentales/productos_subproductos.md)
— `Marca`, `Memoria RAM`, `Pais de origen`, `Duracion de la garantia`, etc.
Esas tablas también dicen el tipo y la unidad de cada una, que es lo que
hace falta para saber qué clase de `valor` mandar. Para las personalizadas
no hay una lista que consultar: el nombre es el que haya escrito quien
publicó el producto.

### 200

Ejemplo real, contra el catálogo cargado hoy (`GET /productos?limite=1`):

```json
{
  "ok": true,
  "mensaje": "Productos obtenidos",
  "payload": {
    "productos": [
      {
        "_id": 1,
        "nombre": "Laptop Nimbo 13",
        "descripcion": "Equipo de entrada para estudio y oficina, silencioso y sin ventilador.",
        "fecha_creacion": "2026-01-14T16:32:00.000Z",
        "estado": "activo",
        "categoria": {
          "nombre": "Laptops",
          "id_categoria": 7,
          "categoria_padre": "Electronica"
        },
        "precio_tienda": { "$numberDecimal": "4100.00" },
        "stock_tienda": 22,
        "stock_total": 43,
        "total_ofertas": 3,
        "variantes": [
          {
            "id_producto_variante": 1,
            "nombre_variante": "8 GB / 256 GB",
            "descripcion": null,
            "fecha_creacion": "2026-01-14T16:32:00.000Z",
            "estado": "activa",
            "imagenes": [],
            "precio_tienda": { "$numberDecimal": "4100.00" },
            "stock_tienda": 22,
            "stock_total": 43,
            "total_ofertas": 3,
            "caracteristicas_adicionales": [
              { "nombre": "Memoria RAM", "valor": 8, "unidad": "GB" }
            ]
          }
        ],
        "caracteristicas_adicionales": [
          { "nombre": "Marca", "valor": "Nimbo", "unidad": null }
        ]
      }
    ],
    "siguiente_cursor": 1
  }
}
```

**Modelo multi-vendedor.** Ya no viene `vendedor` (el producto no es de
nadie) ni `porcentaje_comision` (salió del alcance), y las variantes ya no
traen `precio` ni `stock` propios — eso es de cada oferta, que vive solo
en PostgreSQL (ver `docs/base-de-datos.md`). Lo que sí trae, sin tener que
pedirlo con ningún query param, son cuatro números ya calculados —
`precio_tienda`, `stock_tienda`, `stock_total`, `total_ofertas` — tanto en
la raíz del producto como dentro de cada variante; en la raíz, los dos de
stock son la SUMA de las variantes. Son una copia (se recalculan cuando
una oferta cambia de precio, se queda sin unidades o se pausa), no la
verdad: la ficha completa, con las ofertas reales de cada vendedor, está
en `GET /productos/:id`.

`siguiente_cursor` es `null` cuando esa tanda ya trajo el último producto
del catálogo (o de lo que quedaba despues de aplicar los filtros).

### 400

```json
{ "ok": false, "mensaje": "El limite debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "despues_de debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "id_categoria debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "precio_min debe ser un numero valido, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "precio_max debe ser un numero valido, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "stock_min debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "stock_max debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "stock_tienda_min debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "stock_tienda_max debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "El filtro \"<nombre>\" no es un nombre de caracteristica valido", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudieron obtener los productos", "payload": null }
```

---

## GET /productos/:id

Pública, igual que `GET /productos`. Un producto completo por su `_id`, con
la misma forma que cada elemento del array `productos` de arriba (todas sus
variantes, características del catálogo y personalizadas incluidas) — **más
un campo que no está en el listado**, `ofertas`: la lista real de quién lo
vende, a cómo y con cuántas unidades.

**Los productos `inactivo` o `borrador` nunca aparecen aquí tampoco**:
pedirlos por id da el mismo 404 que un id que no existe, para no confirmar
por otra vía que el producto existe pero está oculto.

```
GET /productos/1
```

### `ofertas`: de dónde sale y qué trae

A diferencia de todo lo demás del documento, `ofertas` no viene de Mongo:
se pide a PostgreSQL en el momento, con una sola consulta indexada por
`id_producto_mongo` (tabla `oferta`, `migrations/005_ofertas.sql`), y se
arma solo para responder esta ruta — no se guarda en ningún lado. La razón
está en `docs/base-de-datos.md`: precio, stock y estado de una oferta
cambian en cada venta, así que copiarlos a Mongo obligaría a sostenerlos al
día en dos bases a la vez.

Solo trae las ofertas **activas** (una pausada o retirada no se puede
comprar, y confundiría a quien compra), ordenadas por variante y, dentro de
cada variante, de la más barata a la más cara.

| Campo | Qué es |
| --- | --- |
| `id_oferta` | El id de la oferta en PostgreSQL |
| `id_producto_variante_mongo` | A qué variante de `variantes[]` pertenece esta oferta |
| `vendedor` | `{ id_usuario, usuario, nombre, apellido }` de quien la vende |
| `es_tienda` | `true` solo en la oferta de la cuenta de la tienda (`tienda@mesh.com`) — es la que se enseña como `precio_tienda` en el resto del documento |
| `precio` | Precio de esta oferta en particular, como texto (`"4100.00"`) |
| `stock` | Unidades disponibles de esta oferta |
| `fecha_actualizacion` | Último cambio de precio, stock o estado de esta oferta |

### 200

Ejemplo real (`GET /productos/1`):

```json
{
  "ok": true,
  "mensaje": "Producto obtenido",
  "payload": {
    "_id": 1,
    "nombre": "Laptop Nimbo 13",
    "descripcion": "Equipo de entrada para estudio y oficina, silencioso y sin ventilador.",
    "fecha_creacion": "2026-01-14T16:32:00.000Z",
    "estado": "activo",
    "categoria": { "nombre": "Laptops", "id_categoria": 7, "categoria_padre": "Electronica" },
    "precio_tienda": { "$numberDecimal": "4100.00" },
    "stock_tienda": 22,
    "stock_total": 43,
    "total_ofertas": 3,
    "variantes": [ "... misma forma que en GET /productos ..." ],
    "caracteristicas_adicionales": [ "..." ],
    "ofertas": [
      {
        "id_oferta": "1",
        "id_producto_variante_mongo": "1",
        "vendedor": { "id_usuario": "1", "usuario": "ventas_poniente", "nombre": "Paola", "apellido": "Guzman" },
        "es_tienda": false,
        "precio": "3856.00",
        "stock": 7,
        "fecha_actualizacion": "2026-08-25T13:38:51.071Z"
      },
      {
        "id_oferta": "2",
        "id_producto_variante_mongo": "1",
        "vendedor": { "id_usuario": "6", "usuario": "ventas_sur", "nombre": "Lucia", "apellido": "Morales" },
        "es_tienda": false,
        "precio": "4029.00",
        "stock": 14,
        "fecha_actualizacion": "2026-08-25T13:38:51.071Z"
      },
      {
        "id_oferta": "3",
        "id_producto_variante_mongo": "1",
        "vendedor": { "id_usuario": "2", "usuario": "mesh_tienda", "nombre": "Mesh", "apellido": "Tienda" },
        "es_tienda": true,
        "precio": "4100.00",
        "stock": 22,
        "fecha_actualizacion": "2026-08-25T13:38:51.071Z"
      }
    ]
  }
}
```

`id_oferta`, `id_producto_variante_mongo` y `vendedor.id_usuario` salen
como texto: son `bigint` de PostgreSQL, y el driver los devuelve como
string para no perder precisión (el mismo motivo por el que `id_usuario`
es string en el resto del backend). Si un producto no tiene ninguna oferta
activa, `ofertas` sale como un array vacío, no falta el campo.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

Un id inexistente o de un producto oculto (`inactivo`/`borrador`) da 404
antes de siquiera consultar PostgreSQL: no tiene sentido pedir ofertas de
un producto que no se va a mostrar.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo obtener el producto", "payload": null }
```

---

## GET /productos/:id/historial

**Pública, sin restricción de rol ni de dueño** — a diferencia de la
versión que usa la tienda para administrar el catálogo
(`GET /vendedor/productos/:id/historial`), esta no exige ser
`tienda@mesh.com`: es solo lectura de un dato histórico, cualquiera con
sesión puede pedirlo. Pensada para mostrar el detalle de un pedido viejo
tal como se veía el producto en el momento de comprarlo — por eso, a
diferencia de `GET /productos/:id`, **no oculta** productos en `borrador`
o `inactivo`: un pedido tiene que poder mostrar su producto aunque hoy ya
no esté visible en el catálogo activo.

Reconstruye el producto **como estaba en una fecha específica**: toma el
evento de creación y todos los de modificación anteriores a esa fecha (o
de ese mismo día), en orden, y los fusiona uno encima del otro con el
framework de agregación de Mongo — mismo mecanismo, mismo resultado, que
`GET /vendedor/productos/:id/historial` (ver ese archivo para el detalle
del pipeline).

```
GET /productos/2/historial?fecha=2026-01-10
```

### 200

```json
{
  "ok": true,
  "mensaje": "Producto reconstruido correctamente",
  "payload": { "_id": 2, "nombre": "Laptop Bastion 16", "...": "..." }
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

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo reconstruir el producto", "payload": null }
```

---

## GET /productos/paginacion

Pública, igual que `GET /productos`. Lista el mismo catálogo, con los
mismos filtros fijos y dinámicos, la misma exclusión de `inactivo`/`borrador`
y las mismas reglas de validación — la única diferencia es **cómo se
pagina**: en vez de un cursor (`despues_de`), se pide un número de página
(`pagina`) y un tamaño de página (`limite`), y sí se puede saltar
directo a cualquier página sin haber pedido las anteriores.

A cambio de ese salto directo, esta ruta sí necesita contar cuántos
productos hay en total para calcular `total_paginas`, que es justo el costo
que `GET /productos` evita al no permitir saltos. Ese conteo pasa por los
mismos filtros que la tanda, `stock_min`/`stock_max` incluido: si se pide
`?stock_min=50`, `total_productos` es cuántos productos cumplen ese
mínimo, no el total del catálogo entero.

### Query params

| Param | Tipo | Obligatorio | Qué hace |
| --- | --- | --- | --- |
| `pagina` | entero | No (por defecto 1) | Qué página pedir, 1 es la primera |
| `limite` | entero | No (por defecto 20, tope 100) | Cuántos productos trae cada página |
| `nombre`, `estado`, `id_categoria`, `precio_min`, `precio_max`, `estado_variante`, `stock_min`, `stock_max`, `stock_tienda_min`, `stock_tienda_max` | — | No | Los mismos filtros fijos de `GET /productos` |
| _cualquier otro nombre_ | texto | No | Filtro dinámico de característica (catálogo o personalizada), igualdad por defecto o `min_`/`max_`/`contiene_` como prefijo, igual que en `GET /productos` |

### Ejemplo

```
GET /productos/paginacion?limite=5&pagina=1    -> productos 1 a 5
GET /productos/paginacion?limite=5&pagina=2    -> productos 6 a 10
GET /productos/paginacion?limite=5&pagina=8    -> salta directo, sin pedir las 7 paginas anteriores
```

### 200

```json
{
  "ok": true,
  "mensaje": "Productos obtenidos",
  "payload": {
    "productos": [ "... mismos documentos que GET /productos ..." ],
    "pagina": 1,
    "limite": 5,
    "total_productos": 3,
    "total_paginas": 1
  }
}
```

Una página más allá del final (por ejemplo `pagina=99` cuando solo hay 3
páginas) no es un error: da `200` con `productos: []`, y `total_paginas`
sigue diciendo cuántas páginas hay de verdad.

### 400

```json
{ "ok": false, "mensaje": "La pagina debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El limite debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "id_categoria debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "precio_min debe ser un numero valido, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "precio_max debe ser un numero valido, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "stock_min debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "stock_max debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "stock_tienda_min debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "stock_tienda_max debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "El filtro \"<nombre>\" no es un nombre de caracteristica valido", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudieron obtener los productos", "payload": null }
```

---

## GET /categorias

Pública, igual que `GET /productos`. Las categorías en las que de verdad
hay productos publicados: las que **no son raíz** (su `categoria_padre` no
es `null`) — mismo criterio y misma fuente
(`categorias.listarValidas()`) que usa `GET /vendedor/categorias`, solo que
sin sesión. Pensada para armar un selector de categoría en la búsqueda.
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

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudieron obtener las categorias", "payload": null }
```

---

## GET /categorias/:id

Pública, igual que `GET /productos`. Una categoría completa, con el menú
entero de características que ofrece — tanto las de producto
(`caracteristicas`) como las de variante (`caracteristicas_variante`), cada
una con su `tipo_dato` y su `unidad` — pensada para armar los filtros de
búsqueda de esa categoría (los mismos prefijos `min_`/`max_`/`contiene_` de
`GET /productos`, ver arriba). Misma fuente que `GET /vendedor/categorias/:id`,
sin sesión.

Solo categorías válidas (no raíz): pedir una raíz (`Ropa`, `Electronica`,
etc.) da el mismo 404 que un id que no existe.

```
GET /categorias/3
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
    "fecha_creacion": "2026-01-05T16:10:00.000Z",
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

## Ejemplo de cada filtro por separado

Uno por uno, sin combinar (para ver cómo se combinan, ver los ejemplos de
más arriba).

### Filtros fijos

| Filtro | Ejemplo | Qué trae |
| --- | --- | --- |
| `limite` | `GET /productos?limite=5` | Los primeros 5 productos |
| `despues_de` | `GET /productos?despues_de=2` | Productos con `_id` mayor a 2 |
| `nombre` | `GET /productos?nombre=laptop` | Productos cuyo nombre contenga "laptop" |
| `estado` | `GET /productos?estado=activo` | Productos con estado exactamente "activo" |
| `id_categoria` | `GET /productos?id_categoria=7` | Productos de la categoría 7 |
| `precio_min` | `GET /productos?precio_min=100` | Productos con `precio_tienda` >= 100 |
| `precio_max` | `GET /productos?precio_max=500` | Productos con `precio_tienda` <= 500 |
| `estado_variante` | `GET /productos?estado_variante=activa` | Productos con alguna variante activa |
| `stock_min` | `GET /productos?stock_min=10` | Productos con `stock_total` (entre todos los vendedores) >= 10 |
| `stock_max` | `GET /productos?stock_max=0` | Productos con `stock_total` = 0 (agotados en todos lados) |
| `stock_tienda_min` | `GET /productos?stock_tienda_min=10` | Productos con `stock_tienda` >= 10 |
| `stock_tienda_max` | `GET /productos?stock_tienda_max=0` | Productos sin existencias de la tienda (aunque otro vendedor sí tenga) |

### Filtros dinámicos — un ejemplo por tipo de dato

No se repite aquí la lista completa de características: son las mismas
filas, con los mismos nombres, tipos y unidades, de la Tabla 1 y la Tabla 2
de
[productos_subproductos.md](Elementos%20Documentales/productos_subproductos.md) —
duplicar esa lista aquí sería mantener dos copias que se pueden desincronizar
apenas se agregue o cambie una característica en el catálogo. La regla es
siempre la misma: el nombre del query param es el nombre exacto de la
columna "Característica" de esas tablas.

Un ejemplo real por cada `tipo_dato`, para ver la forma del `valor` en cada
caso (todos probados contra el catálogo real):

| `tipo_dato` | Ejemplo de filtro | Qué trae |
| --- | --- | --- |
| `texto` | `GET /productos?Marca=Tecno Sur` | Productos con esa marca |
| `texto` (con espacio en el nombre) | `GET /productos?Pais%20de%20origen=China` | Productos fabricados en China |
| `entero` | `GET /productos?Nucleos=10` | Productos cuyo procesador tiene 10 núcleos |
| `decimal` | `GET /productos?Frecuencia=4.40` | Productos con esa frecuencia |
| `booleano` | `GET /productos?Garantia=true` | Productos con garantía |
| `lista` | `GET /productos?Contenido%20del%20paquete=Cargador` | Productos cuya lista de contenido incluye "Cargador" |
| característica de variante | `GET /productos?Memoria%20RAM=16` | Productos con alguna variante de 16 GB de RAM |
| característica personalizada | `GET /productos?Edicion%20especial=true` | Productos que tengan esa característica personalizada, con ese valor |

Y un ejemplo de cada prefijo de operador, sobre una característica `entero`
del catálogo:

| Prefijo | Ejemplo de filtro | Qué trae |
| --- | --- | --- |
| `min_` | `GET /productos?min_Nucleos=8` | Productos cuyo procesador tiene 8 núcleos o más |
| `max_` | `GET /productos?max_Nucleos=8` | Productos cuyo procesador tiene 8 núcleos o menos |
| `min_` + `max_` | `GET /productos?min_Nucleos=6&max_Nucleos=10` | Productos con entre 6 y 10 núcleos |
| `contiene_` | `GET /productos?contiene_Marca=Tec` | Productos cuya marca contiene "Tec" (sin distinguir mayúsculas) |
