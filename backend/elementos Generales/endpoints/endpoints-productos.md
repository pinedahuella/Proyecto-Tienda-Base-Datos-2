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

`GET /productos/:id/resenas` (las reseñas de un producto, en su ficha) es
pública pero vive en PostgreSQL, no en el catálogo de Mongo: está
documentada aparte en [endpoints-resenas.md](endpoints-resenas.md) junto
con `POST /resenas`.

La forma de los documentos que devuelven estas rutas está explicada en
[Elementos Documentales/productos_subproductos.md](../Elementos%20Documentales/productos_subproductos.md)
y [Elementos Documentales/ejemplos_bson_productos.md](../Elementos%20Documentales/ejemplos_bson_productos.md).

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

**Solo los productos `activo` aparecen aquí — lista blanca, no lista
negra.** No es "se excluyen `inactivo`/`borrador`", es "solo entra
`activo`": cualquier otro valor, incluido uno que se agregue más
adelante y nadie recuerde excluir, queda oculto por defecto. No es un
filtro opcional que se pueda ampliar: pedir explícitamente
`?estado=inactivo` (o cualquier valor que no sea `activo`) da una lista
vacía, no un error. No cuentan como parte del catálogo público.

### Query params

| Param | Tipo | Obligatorio | Qué hace |
| --- | --- | --- | --- |
| `limite` | entero | No (por defecto 20, tope 100) | Cuántos productos trae esta tanda |
| `despues_de` | entero | No | El cursor: el `_id` del último producto visto. Si no viene, empieza desde el principio |
| `nombre` | texto | No | Búsqueda parcial (sin distinguir mayúsculas) sobre `nombre` |
| `estado` | texto | No | Igualdad exacta sobre `estado` del producto |
| `id_categoria` | entero | No | Igualdad exacta sobre `categoria.id_categoria` |
| `precio_min` / `precio_max` | decimal | No | Rango sobre `precio_desde` |
| `precio_tienda_min` / `precio_tienda_max` | decimal | No | Rango sobre `precio_tienda` |
| `estado_variante` | texto | No | Igualdad exacta sobre `variantes[].estado` |
| `stock_min` / `stock_max` | entero | No | Rango sobre `stock_total` (existencias activas entre TODOS los vendedores, ya sumadas sobre las variantes) |
| `stock_tienda_min` / `stock_tienda_max` | entero | No | Rango sobre `stock_tienda` (existencias activas solo de la tienda, ya sumadas sobre las variantes) |
| `resenas_promedio_min` / `resenas_promedio_max` | decimal | No | Rango sobre `resenas_promedio` (nota media del producto, 1 a 5). Exige además que el producto tenga al menos una reseña |
| `resenas_total_min` / `resenas_total_max` | entero | No | Rango sobre `resenas_total` (cuántas reseñas tiene el producto) |
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
solo en PostgreSQL. Lo que trae el documento son cinco números ya
calculados (nunca agregados al vuelo en la consulta): `precio_tienda`,
`precio_desde`, `stock_tienda`, `stock_total` y `total_ofertas`, tanto en
la raíz del producto como dentro de cada variante — son los que necesita
la tarjeta del catálogo sin ir a pedir las ofertas reales.

- **`precio_min`/`precio_max`** van sobre `precio_desde`: el precio más
  barato al que se ofrece el producto entre TODOS los vendedores activos
  (no solo la tienda). Filtrar por `precio_tienda` en cambio dejaba fuera
  21 de los 34 productos del conjunto de datos en los que algún vendedor
  la tiene más barata que la tienda — para ese filtro estricto está
  `precio_tienda_min`/`precio_tienda_max` (mismo rango, pero sobre
  `precio_tienda`). Ya no se puede filtrar por el precio de un vendedor
  cualquiera desde aquí — para eso está la lista de `ofertas` de
  `GET /productos/:id`.
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
- **`resenas_promedio_min`/`resenas_promedio_max`** van sobre
  `resenas_promedio` (la nota media del producto, de 1 a 5, entre TODAS sus
  reseñas y todos sus vendedores) y **`resenas_total_min`/`resenas_total_max`**
  sobre `resenas_total` (cuántas reseñas tiene). Los dos son campos ya
  calculados en la raíz del documento — las reseñas apuntan a producto +
  vendedor, nunca a una variante, así que estos dos números **no bajan a
  `variantes[]`**. Los mantiene al día el ETL y el backend cuando se publica
  una reseña. Un detalle: **cualquier filtro sobre `resenas_promedio` exige
  además que el producto tenga al menos una reseña** — "filtrar por nota"
  implica "tiene notas", así que un producto sin reseñas (`resenas_promedio`
  = 0) no se cuela en un `resenas_promedio_max` bajo. Para "productos sin
  reseñas" el filtro es `resenas_total_max=0`.

### Filtros dinámicos (características, del catálogo o personalizadas)

`caracteristicas_adicionales` y `caracteristicas_personalizadas` son, las
dos, un `Array<{ nombre, valor, unidad }>` (ver
[productos_subproductos.md](../Elementos%20Documentales/productos_subproductos.md)) —
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
[pendientes-etl-caracteristicas.md](../historico/pendientes-etl-caracteristicas.md)), así
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
[productos_subproductos.md](../Elementos%20Documentales/productos_subproductos.md)
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
        "resenas_promedio": 4.5,
        "resenas_total": 2,
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
pedirlo con ningún query param, son números ya calculados:
`precio_tienda`, `precio_desde`, `stock_tienda`, `stock_total`,
`total_ofertas` y `hay_descuento` van tanto en la raíz como dentro de cada
variante (en la raíz, los dos de stock son la SUMA de las variantes, y
`hay_descuento` es `true` si CUALQUIER variante lo tiene); `resenas_promedio`
(nota media, 1 a 5) y `resenas_total` van **solo en la raíz** (una reseña
apunta a producto + vendedor, nunca a una variante), y valen `0` mientras
el producto no tenga ninguna reseña. Todos son una copia (se recalculan
cuando una oferta cambia de precio / descuento / unidades / estado, o
cuando se publica una reseña), no la verdad: la ficha completa, con las
ofertas reales de cada vendedor (`precio` de lista, `porcentaje_descuento`
y `precio_final` de cada una), está en `GET /productos/:id`, y la nota
media autoritativa (calculada en vivo desde PostgreSQL) está en
`GET /productos/:id/resenas`.

**Descuentos (2026-09-23, ver `plan pendiente/descuentos-oferta.md`):**
`precio_tienda`/`precio_desde` ya salen con el descuento aplicado cuando
la oferta correspondiente lo tiene — no es el precio de lista de esa
oferta, es lo que de verdad se cobraría. `hay_descuento` es la bandera
rápida para pintar un badge "en oferta" en la tarjeta del catálogo sin
tener que consultar las ofertas reales.

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
{ "ok": false, "mensaje": "resenas_promedio_min debe ser un numero valido, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "resenas_total_min debe ser un numero entero", "payload": null }
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
| `es_inventario_limitado` | `true` si esta oferta está en **venta relámpago** (`oferta.es_inventario_limitado`, migración `014`): su stock lo lleva un contador atómico en Redis con un plazo, no el flujo normal. Lo enciende el vendedor con `POST /vendedor/ofertas/:id/venta-limitada` (ver `endpoints-vendedores.md`). Agregar una oferta así al carrito **reserva** unidades de verdad (ver `endpoints-carrito.md`) |
| `precio` | Precio de esta oferta en particular, como texto (`"4100.00"`) |
| `stock` | Unidades de esta oferta según PostgreSQL. Para una oferta en venta relámpago este número **queda congelado** desde que se abrió la venta — el real es `stock_disponible` |
| `stock_disponible` | Unidades que quedan **ahora mismo**, leídas del contador de Redis (operación `estado` de `redis/inventario_limitado.lua`). Solo se llena cuando `es_inventario_limitado` es `true`; en el resto de ofertas es `null`. También `null` si la venta relámpago ya cerró o si Redis no respondió — en ese caso el número que hay que mostrar es `stock`. La ficha se pinta igual aunque Redis esté caído |
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
    "hay_descuento": true,
    "resenas_promedio": 4.5,
    "resenas_total": 2,
    "variantes": [ "... misma forma que en GET /productos ..." ],
    "caracteristicas_adicionales": [ "..." ],
    "ofertas": [
      {
        "id_oferta": "2",
        "id_producto_variante_mongo": "1",
        "vendedor": { "id_usuario": "6", "usuario": "ventas_sur", "nombre": "Lucia", "apellido": "Morales" },
        "es_tienda": false,
        "es_inventario_limitado": true,
        "precio": "4029.00",
        "porcentaje_descuento": "10.00",
        "precio_final": "3626.10",
        "stock": 14,
        "stock_disponible": 3,
        "fecha_actualizacion": "2026-08-25T13:38:51.071Z"
      },
      {
        "id_oferta": "1",
        "id_producto_variante_mongo": "1",
        "vendedor": { "id_usuario": "1", "usuario": "ventas_poniente", "nombre": "Paola", "apellido": "Guzman" },
        "es_tienda": false,
        "es_inventario_limitado": false,
        "precio": "3856.00",
        "porcentaje_descuento": null,
        "precio_final": "3856.00",
        "stock": 7,
        "stock_disponible": null,
        "fecha_actualizacion": "2026-08-25T13:38:51.071Z"
      },
      {
        "id_oferta": "3",
        "id_producto_variante_mongo": "1",
        "vendedor": { "id_usuario": "2", "usuario": "mesh_tienda", "nombre": "Mesh", "apellido": "Tienda" },
        "es_tienda": true,
        "es_inventario_limitado": false,
        "precio": "4100.00",
        "porcentaje_descuento": null,
        "precio_final": "4100.00",
        "stock": 22,
        "stock_disponible": null,
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

**Descuentos (2026-09-23).** `precio` es siempre el precio de LISTA de esa
oferta, nunca cambia por un descuento. `porcentaje_descuento` es el % (o
`null`) y `precio_final` es lo que de verdad se cobra/muestra — ver
`plan pendiente/descuentos-oferta.md`. **El orden del array es por
`precio_final`, no por `precio`** (dentro de cada variante): en el
ejemplo de arriba, la oferta 2 tiene el precio de lista más alto de las
tres (Q4029) pero con el 10% de descuento queda primera (Q3626.10 es
menos que Q3856).

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

## GET /productos/mas-vendidos

**Pública, sin sesión** — controlador separado (`MasVendidosController`,
mismo criterio que `OfertasVendedorController`/`VentasLimitadasController`,
que ya comparten el prefijo `vendedor/ofertas`), no un método más de
`ProductosController`: esta ruta no consulta Mongo con los filtros de
siempre, primero lee el ranking ya calculado en Redis.

Un GET sencillo, sin query params ni cuerpo:

```
GET /productos/mas-vendidos
```

**De dónde sale el ranking:** `MasVendidosSyncService`
(`src/services/productos/mas-vendidos-sync.service.ts`) recalcula cada 10
minutos, agregando `compra_producto` de ClickHouse de las últimas 24h (o
de los últimos 7 días si no hubo ninguna compra en 24h; si tampoco hay
nada en 7 días, deja lo anterior sin tocar), y publica hasta 20 ids en el
ZSET `mesh:productos:mas_vendidos`. **Solo cuenta `lote = 'real'`**
(agregado el 2026-09-19), sin ningún parámetro para pedir lo contrario --
nunca mezcla con datos sembrados por un script. Ver
`elementos Generales/plan pendiente/eventos-clickhouse.md`.

> **Cambio (2026-09-23): esta ruta ya NO toca MongoDB.** Antes,
> `MasVendidosService.obtener()` leía el ZSET y traía el detalle real a
> Mongo con `$in` **en cada request** — un cache que para responder
> necesita ir a preguntarle a otra base no está cacheando nada. Ahora el
> propio worker, en la misma corrida de cada 10 minutos, consulta Mongo
> **una sola vez** por todos los ids ganadores y guarda el detalle de cada
> uno en un HASH nuevo, `mesh:productos:mas_vendidos:detalle`
> (`{ id_producto: <detalle en JSON> }`, mismo reemplazo atómico vía clave
> temporal + `RENAME` que ya usaba el ZSET). Esta ruta ahora lee las dos
> estructuras de Redis y ya — **ni Postgres ni Mongo**. Solo se cachea el
> detalle de productos `activo` (mismo criterio de visibilidad de siempre);
> a cambio de no depender de Mongo, esa comprobación de visibilidad pasó de
> ser en vivo (en cada request) a solo cada 10 minutos — un producto que se
> desactiva a mitad de esa ventana puede seguir apareciendo aquí hasta la
> próxima corrida del worker. Mismo principio que el rediseño del carrito
> ese mismo día (ver `endpoints-carrito.md`).

> **Cambio (2026-09-23, más tarde el mismo día): el detalle es una versión
> acotada, no el documento completo.** Al principio el HASH guardaba el
> documento `Producto` tal cual (variantes completas, con su propio precio,
> stock y características por variante, más `caracteristicas_adicionales`/
> `caracteristicas_personalizadas` de la raíz) — pero esta vitrina solo
> pinta una tarjeta (foto, nombre, precio, calificación); nunca necesita
> mostrar variantes. `MasVendidosSyncService.consultarProductosMongo` ahora
> pide una proyección de Mongo con solo los campos de la tarjeta
> (`ProductoTarjetaMasVendido`: `_id`, `nombre`, `imagen`, `precio_tienda`,
> `precio_desde`, `hay_descuento`, `resenas_promedio`, `resenas_total`,
> `stock_total`) más `variantes.imagenes` (Mongo no deja combinar un
> `$slice` sobre `variantes` con una subruta de esa misma proyección en un
> `find` — "path collision" — así que vienen las imágenes de todas las
> variantes, cada una sin el resto de sus campos, y en JS se toma solo la
> primera imagen de la primera variante). Bajó de 2405 a 418 bytes por
> producto cacheado (mismo producto de prueba de la sección de abajo) — un
> **83% menos**, tanto en el HASH de Redis como en la respuesta HTTP de esta
> ruta. Distinto del resto de rutas de listado (`GET /productos`,
> `GET /productos/:id`), que sí siguen devolviendo el documento completo —
> aquí se justifica el recorte porque esta vitrina nunca necesita variantes.

Esta ruta (`MasVendidosService.obtener()`) lee los primeros 8 ids del ZSET
(`ZREVRANGE`, ya en orden de más a menos vendido) y pide ese mismo detalle
al HASH con `HMGET` — a diferencia del `$in` de Mongo que se usaba antes,
`HMGET` sí respeta el orden de los ids que se le piden, así que ya no hace
falta reordenar nada a mano. Un id del ranking sin detalle cacheado (no
ganó en la última corrida del worker, o no era `activo` entonces) se salta
en silencio, sin romper la respuesta.

### 200

La versión acotada de cada producto (no el documento completo que devuelve
`GET /productos/:id` — ver el cambio del 2026-09-23 más arriba), en un
array ordenado de más a menos vendido:

```json
{
  "ok": true,
  "mensaje": "Productos mas vendidos obtenidos",
  "payload": [
    {
      "_id": 1,
      "nombre": "Laptop Ambar Campus 14",
      "imagen": "https://.../laptop.png",
      "precio_tienda": { "$numberDecimal": "4750.00" },
      "precio_desde": { "$numberDecimal": "4269.00" },
      "hay_descuento": false,
      "resenas_promedio": 4,
      "resenas_total": 3,
      "stock_total": 115
    }
  ]
}
```

Si el ranking todavía no existe (el worker nunca corrió con éxito, por
ejemplo justo después de levantar el stack sin ninguna compra en los
últimos 7 días) o no queda ningún producto visible entre los ids del
ranking, `payload` sale como array vacío — nunca un error.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
```

Desde el 2026-09-23 **ya no puede salir un 503 de Mongo** en esta ruta — no
la toca. Si Mongo está caído, el peor caso es que el detalle cacheado
tenga hasta 10 minutos (lo que tarda el worker en volver a intentar).

## Pruebas — hechas el 2026-09-18

Contra el servidor, Redis y MongoDB reales, sin sesión.

| Caso | Resultado |
|---|---|
| Ranking real con una compra (producto 1) | `200`, `payload` con el documento completo de ese producto |
| `RENAME` del ZSET a un lado (simula que el worker nunca corrió) | `200`, `payload: []` — no rompe |
| Ranking restaurado | `200`, vuelve a traer el producto real |
| `GET /productos/:id` y `GET /productos` (del otro controlador) | siguen respondiendo `200` normal — sin colisión de rutas con `mas-vendidos` |
| Un id inexistente (`99999`) insertado a mano al frente del ZSET | `200`, ese id se salta en silencio, solo sale el producto real — confirma el filtro de visibilidad/reordenado sin romper nada |

`npx tsc --noEmit` y `eslint` limpios sobre los archivos nuevos.

## Pruebas — rediseño "el cache no debe necesitar a nadie más" (2026-09-23)

Contra el servidor y los contenedores reales. El worker se disparó a mano
(en vez de esperar los 10 min) con un script en el scratchpad que
instancia `MasVendidosSyncService` y llama `recalcular()` directo — el
worker no tiene dependencias inyectadas (usa los clientes de
`database/*.ts` tal cual), así que correrlo fuera de Nest es idéntico a
como lo dispara `@Interval` en producción.

| Caso | Resultado |
|---|---|
| Worker corrido con datos reales del día (1 producto con compras reales) | `HASH mesh:productos:mas_vendidos:detalle` queda con el campo `1` = el documento `Producto` completo en JSON (2405 bytes); `GET /productos/mas-vendidos` lo devuelve idéntico a `GET /productos/1` — mismo `precio_tienda`/`precio_desde` como `{"$numberDecimal": "..."}` (confirmado: el doble viaje por Redis, `JSON.stringify` en el worker → `JSON.parse` en el servicio → `JSON.stringify` de la respuesta HTTP, produce el mismo texto en el wire que un solo viaje — `Decimal128.toJSON()` es idempotente sobre su propio resultado) |
| Ranking sintético de 3 ids con detalle cacheado solo para 2 | Los 2 con detalle salen en el **orden correcto** del ranking (`HMGET` respeta el orden pedido, a diferencia del `$in` de Mongo que se usaba antes); el tercero se salta sin romper nada |
| **`docker stop mesh-postgres mesh-mongo`**, después `GET /productos/mas-vendidos` | **200 normal**, con el producto completo — la ruta no tocó ninguna de las dos bases. `docker start` de las dos, sin necesidad de reiniciar el server |
| El único producto del ranking se desactiva en Mongo (`estado: "inactivo"`), se corre el worker | El worker cachea `0 con detalle` (se filtró por `activo`) y **borra** `mesh:productos:mas_vendidos:detalle` (no intenta un `RENAME` sobre una clave temporal vacía, que Redis rechaza); el ZSET del ranking **sigue** con ese id (no se filtra ahí); `GET /productos/mas-vendidos` responde `200` con `payload: []`, sin error |
| Producto reactivado, worker corrido de nuevo | Vuelve a aparecer normal |
| `npx tsc --noEmit` y `eslint` sobre los dos archivos tocados | limpios |

**Teardown:** el producto de prueba quedó reactivado (`estado: "activo"`) y
el worker se corrió una última vez para dejar el ranking/detalle
reflejando los datos reales, sin residuos de las pruebas sintéticas.

## Pruebas — detalle acotado, no el documento completo (2026-09-23)

Contra el servidor y los contenedores reales. El worker se disparó a mano
(mismo mecanismo que la ronda de pruebas de arriba: un script en el
scratchpad que instancia `MasVendidosSyncService` y llama `recalcular()`
directo).

| Caso | Resultado |
|---|---|
| Primer intento de proyección, `variantes: { $slice: 1 }` + `'variantes.imagenes': 1` juntos | el worker lanzó `Path collision at variantes.imagenes remaining portion imagenes` y se saltó la corrida (logueado como warning, ranking anterior intacto) — confirma que Mongo no deja combinar un `$slice` sobre un array con una subruta de esa misma proyección en un `find` |
| Corregido a solo `'variantes.imagenes': 1` (sin el `$slice`) | worker corre limpio: `"ranking recalculado con 1 producto(s) ..., 1 con detalle cacheado"` |
| `HGET mesh:productos:mas_vendidos:detalle 1` en Redis | JSON con exactamente `_id, nombre, imagen, precio_tienda, precio_desde, hay_descuento, resenas_promedio, resenas_total, stock_total` — sin `variantes`, `categoria`, `descripcion`, `caracteristicas_adicionales`/`caracteristicas_personalizadas`, `stock_tienda`, `total_ofertas`, `fecha_creacion` ni `estado` |
| Tamaño del detalle cacheado | 418 bytes, contra 2405 bytes del documento completo que se cacheaba antes (mismo producto) — **83% menos** |
| `GET /productos/mas-vendidos` | `200`, `payload` con exactamente esos mismos 9 campos — confirma que la ruta HTTP devuelve la versión acotada, no solo el HASH interno |
| `npx tsc --noEmit` y `eslint` sobre los dos archivos tocados | limpios |

---

## GET /productos/mas-vistos

**Pública, sin sesión** — mismo patrón exacto que `GET /productos/mas-vendidos`
(controlador separado `MasVistosController`, mismo criterio de vitrina),
pensada como plan B público para cuando "para ti" (`GET /productos/para-ti`)
viene vacío: el ranking de vistas equivalente en `AdminTendenciasService`
(`GET /admin/eventos/vista`) solo lo puede pedir un admin, un cliente
normal no tiene permiso.

```
GET /productos/mas-vistos
```

**De dónde sale el ranking:** `MasVistosSyncService`
(`src/services/productos/mas-vistos-sync.service.ts`) recalcula cada 10
minutos, agregando `vista_producto` de ClickHouse de las últimas 24h (o de
los últimos 7 días si no hubo ninguna vista en 24h; si tampoco hay nada en
7 días, deja lo anterior sin tocar), contando **sesiones distintas**
(`count(DISTINCT sesion)`, mismo criterio que
`AdminTendenciasService.rankingVistas`: ver una ficha es una acción de bajo
esfuerzo que la misma persona puede repetir varias veces), y publica hasta
20 ids en el ZSET `mesh:productos:mas_vistos`. Mismo detalle acotado que
`mas-vendidos` (`_id, nombre, imagen, precio_tienda, precio_desde,
hay_descuento, resenas_promedio, resenas_total, stock_total`), cacheado por
el propio worker en el HASH `mesh:productos:mas_vistos:detalle` — esta ruta
nunca toca ClickHouse ni Mongo en el momento, solo lee las dos estructuras
de Redis. Solo cuenta `lote = 'real'`, sin excepción.

### Pruebas — hechas el 2026-09-25

Contra el servidor y los contenedores reales.

| Caso | Resultado |
|---|---|
| `npx tsc --noEmit` sobre los tres archivos nuevos | limpio |
| `npx nest start` con Postgres/Mongo/Redis/ClickHouse reales | arranca sin errores, ruta `GET /productos/mas-vistos` mapeada |
| `GET /productos/mas-vistos` sin datos aún cacheados | `200`, `payload: []` |
| Consulta manual contra ClickHouse (`vista_producto`, ventana 7 días, `lote = 'real'`) | devuelve filas reales (sin datos en 24h, cae a 7 días como se espera) — confirma que la consulta del worker es válida |
| ZSET/HASH sembrados a mano en Redis (ids con y sin detalle cacheado) | `GET /productos/mas-vistos` devuelve solo los ids con detalle, en el orden correcto del ranking, saltando el resto sin romper nada — mismo comportamiento verificado que `mas-vendidos` |
| Teardown | claves de prueba borradas de Redis; el worker real (`@Interval`, cada 10 min) las recalcula solo en su próxima corrida |

---

## GET /productos/ofertas/descuento y GET /productos/ofertas/venta-relampago

**Públicas, sin sesión** — vitrina, mismo criterio que `GET /productos/mas-vendidos`: controlador separado
(`OfertasDestacadasController`), que no consulta Postgres ni Mongo con los
filtros de siempre. Estas dos leen directo, y nada más, los dos `HASH` de
Redis que mantiene `RegistroOfertasRedisService`
(`src/services/vendedores/registro-ofertas-redis.service.ts`):

```
GET /productos/ofertas/descuento
GET /productos/ofertas/venta-relampago
```

**De dónde salen los datos:** `mesh:ofertas:descuento` (ofertas con un
descuento activo, sin venta relámpago) y `mesh:ofertas:venta_relampago`
(ofertas en venta relámpago — que, por la regla de negocio del 2026-09-23,
siempre tienen descuento) — un `HASH` cada una, campo = `id_oferta`, valor
= un JSON representativo (nombre, imagen, precio, vendedor, stock — nunca
la fila cruda de `oferta`). Las dos llaves son mutuamente excluyentes: una
oferta vive en una o la otra, nunca en las dos.

Quién las mantiene al día — **ninguna de las dos rutas de abajo escribe
nada**, solo leen:
- Los 4 escritos que pueden cambiar el estado: `POST`/`DELETE
  .../:id/descuento` y `POST`/`DELETE .../:id/venta-limitada`
  (`OfertasVendedorService`/`VentasLimitadasService`) — al instante, justo
  después de comitear.
- `VentasLimitadasService.revisarVencidas()` (movido desde
  `InventarioLimitadoService` el 2026-09-24, ver `endpoints-vendedores.md`)
  — cuando una venta relámpago vence sola por su TTL de Redis (no por un
  `DELETE` manual), esa misma corrida saca la oferta de las DOS llaves
  (desde el 2026-09-24 también le quita el descuento, no solo la venta
  relámpago — antes de esa fecha la movía de vuelta a
  `mesh:ofertas:descuento`, comportamiento que era un bug), sin esperar al
  worker de reconciliación.
- `RegistroOfertasSyncService` (worker cada 10 min) — red de seguridad:
  repara un escrito reactivo que se perdió o una llave que se corrompió.

Detalle completo de las tres piezas de arriba en `endpoints-vendedores.md`
y en los comentarios de `registro-ofertas-redis.service.ts`/
`registro-ofertas-sync.service.ts`.

**Sin querys ni cuerpo.** Tres segmentos (`productos/ofertas/descuento`),
así que no chocan con `GET /productos/ofertas/:id/historial` (tres
segmentos, pero el del medio es `:id`, no un literal) ni con
`GET /productos/:id` (un solo segmento).

### 200

```json
{
  "ok": true,
  "mensaje": "Ofertas con descuento obtenidas",
  "payload": [
    {
      "id_oferta": 18,
      "id_producto": 4,
      "id_producto_variante": 8,
      "nombre_producto": "Laptop Lienzo 15",
      "nombre_variante": "32 GB / 1 TB",
      "imagen": "https://.../laptop.jpeg",
      "precio": "6509.00",
      "porcentaje_descuento": "5.00",
      "precio_final": "6183.55",
      "vendedor_usuario": "ventas_norte",
      "vendedor_nombre": "Carlos Ramirez",
      "stock": 13
    }
  ]
}
```

`GET .../venta-relampago` responde con la misma forma, filas de
`mesh:ofertas:venta_relampago`. Sin ninguna oferta en ese estado, `payload`
sale como array vacío — nunca un error. Sin orden particular: Redis no
promete ningún orden estable en un `HGETALL`, y no se pidió ninguno (a
diferencia de `mas-vendidos`, que sí tiene un criterio — el ranking por
unidades vendidas).

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
```

Ninguna de las dos toca Postgres ni Mongo, así que ese es el único caso de
error posible.

## Pruebas — hechas el 2026-09-23

Contra el servidor y los contenedores reales (`ventas_norte`, ofertas 18 y
549).

| Caso | Resultado |
|---|---|
| Los dos `GET` sin ninguna oferta con descuento | `200`, `payload: []` en los dos |
| Aplicar descuento a la oferta 549, después a la 18 | `GET .../descuento` trae las dos, con el detalle representativo esperado |
| Abrir venta relámpago en la 549 | desaparece de `GET .../descuento` y aparece — sola — en `GET .../venta-relampago`; la 18 se queda donde estaba |
| Cerrar la venta relámpago y quitar los dos descuentos | los dos `GET` vuelven a `payload: []` |
| `npx tsc --noEmit` y `eslint` sobre los archivos nuevos | limpios |

---

## GET /productos/vistos-recientemente (agregado 2026-09-25)

R1 de la propuesta del compañero (`docs/fraude-entrega3/03-consultas-clickhouse.md`):
los últimos productos DISTINTOS que la persona miró, del más nuevo al más
viejo. **Pública, sin sesión obligatoria** — mismo criterio que
`GET /buscador/productos`: un visitante sin cuenta es un caso normal, no
un error. Controller y servicio separados (`VistosRecientementeController`/
`Service`), mismo criterio que `MasVendidosController`/`OfertasDestacadasController`
-- cada feature del catálogo público va aparte aunque comparta el prefijo
`/productos`.

**Quién es "la persona":** su cuenta (si inició sesión, vía la cookie de
siempre) O su `sesion` (query param opcional, generada por el navegador,
mismo mecanismo que `POST /eventos/vista`) -- las dos a la vez, para que
quien mira sin cuenta y después inicia sesión siga viendo lo de antes de
entrar. Sin cuenta NI `sesion`, se devuelve `[]` sin gastar una consulta a
ClickHouse.

```
GET /productos/vistos-recientemente?sesion=<sesion>&dias_historial=30&limite=10
```

`dias_historial` (defecto 30, reusa `validarDiasVentana`) y `limite`
(defecto 20, reusa `validarLimiteEvento`) son opcionales. Los umbrales
propios de la consulta (ninguno, R1 no tiene mínimos) no aplican aquí.

`ya_comprado` no filtra nada -- informa; el frontend decide si lo esconde
o lo marca con una etiqueta.

### 200 (ejemplo)

```json
{
  "ok": true,
  "mensaje": "Vistos recientemente obtenidos",
  "payload": [
    { "ultima_vista": "2026-09-25 10:50:40.000", "veces": 1, "ya_comprado": true, "producto": { "...": "..." } }
  ]
}
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con ClickHouse", "payload": null }
```

### Probado en vivo — 2026-09-25

Contra el servidor, ClickHouse y MongoDB reales.

| Caso | Resultado |
|---|---|
| Sesión real de `compradora_norte`, con 2 vistas sembradas (una de un producto que sí compró, otra de otro que también resultó ya comprado -- dato real preexistente, no de esta prueba) | `200`, las dos en orden de más reciente a más vieja, `ya_comprado: true` en las dos -- confirmado contra `compra_producto` directo |
| Visitante SIN cuenta, con `?sesion=...` de una sesión sembrada | `200`, trae el producto visto por esa sesión, `ya_comprado: false` |
| Sin cuenta y sin `sesion` | `200`, `payload: []`, sin tocar ClickHouse |
| ClickHouse real caído (`docker stop`) | `503` "No se pudo conectar con ClickHouse" |
| ClickHouse recuperado | `200` normal |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

Teardown: las filas sembradas (`vista_producto`, `compra_producto`) se
borraron con `ALTER TABLE ... DELETE`; el pedido real preexistente de
`compradora_norte` (hallado durante la prueba, no tocado) se dejó intacto.

## GET /productos/:id/tambien-vieron y GET /productos/para-ti (agregado 2026-09-25)

R2 y R3 de la propuesta del compañero. A diferencia de R1
(`vistos-recientemente`, calculado al pedir), estas dos **nunca calculan
nada en vivo** -- leen directo de Redis, lo que dejó el worker
correspondiente en su último ciclo (`TambienVieronSyncService`/
`ParaTiSyncService`, cada 15 min). Ver esos dos archivos para el diseño
completo del worker.

**`GET /productos/:id/tambien-vieron`** -- pública, sin sesión. Lee
`mesh:producto:<id>:tambien-vieron`. Sin caché para ese producto (nunca
calculado, excluido por no tener suficientes sesiones en común posibles, o
la clave ya venció) -> `[]`, nunca un error.

**`GET /productos/para-ti`** -- **requiere sesión** (`SesionGuard`, sin
`@Roles`: cualquier cuenta tiene sus propias recomendaciones, igual que el
carrito) -- a diferencia de R1, R3 no tiene sentido sin una cuenta real.
`id_usuario` sale del token, nunca de un parámetro. Lee
`mesh:cuenta:<id_usuario>:para-ti`. Un arreglo vacío puede significar "sin
recomendaciones calculables", "el worker todavía no proceso esta cuenta" o
"la cuenta lleva mas de 24h sin actividad y su clave vencio" -- las tres se
ven igual desde esta ruta; la decisión de caer a
`GET /productos/mas-vistos` (o a `mas-vendidos`) en ese caso queda para el
frontend, no está resuelta en el backend todavía.

**TTL de limpieza (agregado 2026-09-25, tarde):** las dos claves se
reescriben con `EX 86400` (24h) en cada ciclo del worker (`TTL_SEGUNDOS`
en `tambien-vieron-sync.service.ts`/`para-ti-sync.service.ts`) -- mientras
el producto/cuenta siga calificando (actividad dentro de los 30 dias que
exige el descubrimiento de R2/R3), el propio worker renueva el TTL cada 15
min y en la practica nunca vence; el dia que deje de calificar, el worker
deja de tocar esa clave puntual y Redis la borra sola dentro de 24h, en vez
de quedar huerfana mostrando una recomendacion vieja para siempre.

### 401 (`para-ti`) / 503

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
```

### Probado en vivo -- 2026-09-25

Contra el servidor, ClickHouse, MongoDB y Redis reales.

| Caso | Resultado |
|---|---|
| **Corrección previa del worker de R2**: antes de esto, el descubrimiento de productos exigía solo "alguna vista"; con datos reales, los 6 productos candidatos tenían 1 sola sesión cada uno y R2 exige mínimo 2 en común -- las 6 claves quedaban siempre vacías. Corregido: el descubrimiento ahora exige `>= min_sesiones_en_comun` sesiones distintas | de 6 candidatos (criterio viejo) bajó a 4 (criterio nuevo) -- el producto con 1 sola sesión se excluyó, confirmado en vivo |
| Escenario sembrado (Juan + 5 sesiones ajenas, mismo que ya se había verificado a mano) | `GET /productos/990001/tambien-vieron` -> `[{990003, afinidad 0.707}]`, idéntico al valor ya conocido |
| `GET /productos/990004/tambien-vieron` (producto excluido por el filtro nuevo, sin caché) | `200`, `[]` |
| Escenario de referencia con productos REALES (1 y 4, dos sesiones ajenas viéndolos juntos) | `GET /productos/1/tambien-vieron` -> `[{4, afinidad, "Laptop Lienzo 15", ...detalle completo}]` -- el `producto` viene resuelto desde Mongo por el propio worker, la ruta no tocó Mongo |
| `GET /productos/para-ti` sin sesión | `401` "No hay sesion activa" |
| `GET /productos/para-ti` con sesión real (`comprador_sur`, con un escenario de referencia sembrado: vio el producto 1, dos sesiones ajenas vieron 1 y 4) | `200`, `[{4, puntaje: 1.724, porque_viste: [1], producto: "Laptop Lienzo 15"}]` |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

**Llaves de referencia dejadas a propósito en Redis** (pedido explícito del
usuario, para inspeccionar cómo se ven con datos no vacíos):
`mesh:producto:1:tambien-vieron`, `mesh:cuenta:3:para-ti` (las dos con
"Laptop Lienzo 15" resuelto completo) y `mesh:cuenta:999101:para-ti`
(cuenta ficticia de prueba, `producto: null` en sus dos entradas porque
los ids no existen en Mongo). El servidor de prueba se detuvo ANTES de
limpiar las filas sembradas en ClickHouse, para que el worker no
sobrescribiera estas claves con un resultado vacío en su siguiente ciclo
-- quedan "congeladas" con su último valor bueno, mismo comportamiento que
tendría cualquier producto/cuenta real que dejara de tener actividad.

Teardown: todas las filas sembradas en ClickHouse (`vista_producto`,
`compra_producto`) se borraron; las tres claves de Redis de arriba se
dejaron a propósito, sin TTL, no se van a limpiar solas.

### Probado en vivo -- TTL de limpieza, 2026-09-25 (tarde)

Contra el servidor y los contenedores reales, sin datos sembrados nuevos
(se corrieron los dos workers a mano una vez, contra los datos reales que
hubiera en ese momento, mismo mecanismo que las rondas de prueba de
`mas-vendidos`).

| Caso | Resultado |
|---|---|
| `TTL` de las tres claves "congeladas" de la ronda anterior, antes del cambio | `-1` las tres (sin TTL), confirma el estado descrito arriba |
| `npx tsc --noEmit` y `npx eslint` sobre los dos archivos tocados | limpios |
| Ciclo real de los dos workers corrido a mano | R2: 0 productos calificaron (sin datos sembrados activos en este momento, ninguna clave tocada); R3: 2 cuentas calificaron y se recalcularon |
| `TTL mesh:cuenta:3:para-ti` tras el ciclo | `86392` (~24h) -- la cuenta 3 sí calificó, su clave se reescribió con datos reales actuales y quedó con el TTL nuevo |
| `TTL mesh:cuenta:999101:para-ti` (cuenta ficticia) y `TTL mesh:producto:1:tambien-vieron` tras el ciclo | siguen en `-1` -- ninguna de las dos calificó en este ciclo (la cuenta ficticia no existe en ClickHouse; R2 no tuvo candidatos), así que el worker no las tocó y se quedaron exactamente como estaban |

**Nota:** `mesh:cuenta:3:para-ti` deja de ser la foto "congelada" de la
ronda anterior (esa dependía de filas ya borradas de ClickHouse) -- ahora
tiene el resultado real y vigente, con TTL. Es el comportamiento esperado
del propio arreglo: una clave con actividad real se mantiene viva sola. Las
otras dos referencias (`mesh:producto:1:tambien-vieron`,
`mesh:cuenta:999101:para-ti`) siguen congeladas tal cual, sin TTL, hasta
que algo las toque de nuevo o pase el resto de su vida útil sin que ocurra.

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

Reconstruye el producto **como estaba en un momento específico**: toma el
evento de creación y todos los de modificación hasta ese momento, en
orden, y los fusiona uno encima del otro con el framework de agregación de
Mongo — mismo mecanismo, mismo resultado, que
`GET /vendedor/productos/:id/historial` (ver ese archivo para el detalle
del pipeline).

**El query param `fecha` acepta dos formas:**

| Forma | Qué significa |
| --- | --- |
| `AAAA-MM-DD` | Todo ese día. El día se cuenta en hora de Guatemala (-06:00) y el corte es la medianoche del día siguiente, exclusivo. Es el comportamiento de siempre. |
| `AAAA-MM-DDTHH:MM` o `AAAA-MM-DDTHH:MM:SS` | Hasta ese instante **inclusive**. La hora se interpreta en **UTC**, igual que como la API devuelve las fechas de los eventos (`"2026-02-18T21:00:00.000Z"`): pedir `fecha=2026-02-18T21:00` incluye el evento que ocurrió exactamente a esa hora. Los segundos son opcionales (por defecto `:00`). Un espacio en vez de la `T` también vale (`2026-02-18 21:00`, URL-encoded). |

```
GET /productos/2/historial?fecha=2026-01-10
GET /productos/2/historial?fecha=2026-01-10T14:30
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
{ "ok": false, "mensaje": "La fecha debe tener el formato AAAA-MM-DD o AAAA-MM-DDTHH:MM (con :SS opcional)", "payload": null }
{ "ok": false, "mensaje": "La fecha no es valida", "payload": null }
{ "ok": false, "mensaje": "La hora no es valida", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
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

## GET /productos/ofertas/:id/historial

**Protegida (`SesionGuard`), sin restricción de rol ni de dueño** — vive a
la par de `GET /productos/:id/historial` y exige lo mismo: cualquier
cuenta logueada puede pedir el historial de precio/stock de **cualquier**
oferta, no solo la propia. Pensada para completar la reconstrucción de un
pedido viejo: `:id/historial` reconstruye el producto tal como se veía, y
esta reconstruye el precio y el stock de la oferta puntual que se compró,
tal como estaban ese día — el lado económico vive en PostgreSQL
(`precio_historial` + `stock_movimiento`), no en Mongo.

```
GET /productos/ofertas/3/historial?fecha=2026-01-10
```

> **`fecha` aquí es solo `AAAA-MM-DD`** (día completo), a diferencia de
> `GET /productos/:id/historial`, que ya acepta también `AAAA-MM-DDTHH:MM`.
> Si hace falta reconstruir un pedido a la hora exacta, esta ruta todavía
> redondea al día — pendiente de igualar.

Dos consultas de solo lectura, ambas hasta la medianoche del día
**siguiente** al pedido (zona Guatemala, igual que el caso de solo fecha de
`:id/historial`):

- **`precio`**: la última fila de `precio_historial` antes de esa fecha —
  siempre hay al menos una desde que nace la oferta (el trigger
  `oferta_registrar_precio` la escribe sola). Que no aparezca ninguna
  significa que la oferta todavía no existía en esa fecha.
- **`stock`**: la última fila de `stock_movimiento` antes de esa fecha. A
  diferencia del precio, que no aparezca ninguna **no** es un error: una
  oferta creada sin stock inicial no tiene ninguna fila hasta la primera
  reposición, así que "ninguna fila todavía" significa `0`, no que la
  oferta no existiera.

### 200

```json
{
  "ok": true,
  "mensaje": "Oferta reconstruida correctamente",
  "payload": { "id_oferta": "3", "precio": "4100.00", "stock": 22 }
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "La fecha es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La fecha debe tener el formato AAAA-MM-DD", "payload": null }
{ "ok": false, "mensaje": "La fecha no es valida", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
{ "ok": false, "mensaje": "La oferta no existia en esa fecha", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo reconstruir la oferta", "payload": null }
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
| `nombre`, `estado`, `id_categoria`, `precio_min`, `precio_max`, `precio_tienda_min`, `precio_tienda_max`, `estado_variante`, `stock_min`, `stock_max`, `stock_tienda_min`, `stock_tienda_max`, `resenas_promedio_min`, `resenas_promedio_max`, `resenas_total_min`, `resenas_total_max` | — | No | Los mismos filtros fijos de `GET /productos` |
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
{ "ok": false, "mensaje": "resenas_promedio_min debe ser un numero valido, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "resenas_total_min debe ser un numero entero", "payload": null }
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
| `precio_min` | `GET /productos?precio_min=100` | Productos con `precio_desde` >= 100 |
| `precio_max` | `GET /productos?precio_max=500` | Productos con `precio_desde` <= 500 |
| `precio_tienda_min` | `GET /productos?precio_tienda_min=100` | Productos con `precio_tienda` >= 100 |
| `precio_tienda_max` | `GET /productos?precio_tienda_max=500` | Productos con `precio_tienda` <= 500 |
| `estado_variante` | `GET /productos?estado_variante=activa` | Productos con alguna variante activa |
| `stock_min` | `GET /productos?stock_min=10` | Productos con `stock_total` (entre todos los vendedores) >= 10 |
| `stock_max` | `GET /productos?stock_max=0` | Productos con `stock_total` = 0 (agotados en todos lados) |
| `stock_tienda_min` | `GET /productos?stock_tienda_min=10` | Productos con `stock_tienda` >= 10 |
| `stock_tienda_max` | `GET /productos?stock_tienda_max=0` | Productos sin existencias de la tienda (aunque otro vendedor sí tenga) |
| `resenas_promedio_min` | `GET /productos?resenas_promedio_min=4` | Productos con nota media >= 4 (y al menos una reseña) |
| `resenas_promedio_max` | `GET /productos?resenas_promedio_max=2` | Productos con nota media <= 2 (y al menos una reseña; los que no tienen ninguna NO entran) |
| `resenas_total_min` | `GET /productos?resenas_total_min=3` | Productos con 3 o más reseñas |
| `resenas_total_max` | `GET /productos?resenas_total_max=0` | Productos sin ninguna reseña |

### Filtros dinámicos — un ejemplo por tipo de dato

No se repite aquí la lista completa de características: son las mismas
filas, con los mismos nombres, tipos y unidades, de la Tabla 1 y la Tabla 2
de
[productos_subproductos.md](../Elementos%20Documentales/productos_subproductos.md) —
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

---

## Pruebas — filtros por reseñas (14/14, 2026-09-02)

Fixture: se poblaron `resenas_promedio` / `resenas_total` en Mongo desde
PostgreSQL (`ROUND(AVG(calificacion), 2)` y `COUNT(*)` por
`id_producto_mongo` — lo que hará la migración del compañero; hoy 54 de los
107 productos tienen reseñas), se corrieron los casos, y el teardown hizo
`$unset` de los dos campos en todos los productos. Cada caso se comparó
contra un `countDocuments` equivalente en Mongo y contra
`GET /productos/paginacion` (paginado) además de `GET /productos` (cursor).

| Caso | Resultado |
|---|---|
| `?resenas_promedio_min=4.5` | 27 productos (media ≥ 4.5 y ≥ 1 reseña); mismos 27 por cursor y por paginación |
| `?resenas_promedio_max=2` | 3 productos — los que tienen 0 reseñas **no** entran |
| `?resenas_promedio_min=2&resenas_promedio_max=2` | 2 productos (media exactamente 2.0) |
| `?resenas_total_min=3` | 7 productos |
| `?resenas_total_min=4` | 3 productos |
| `?resenas_total_min=2&resenas_total_max=2` | 15 productos (exactamente 2 reseñas) |
| `?resenas_promedio_min=3&resenas_promedio_max=3.5` | 10 productos |
| `?resenas_total_min=3&resenas_promedio_min=4` | 4 productos (combina los dos rangos) |
| `?resenas_promedio_min=1&resenas_total_min=3` | 7 productos — el `>= 1 reseña` que impone el filtro de media **no pisa** un `resenas_total_min` mayor pedido por el cliente |
| `?resenas_promedio_min=abc` | 400 "resenas_promedio_min debe ser un numero valido, con hasta 2 decimales" |
| `?resenas_total_min=1.5` / `?resenas_total_min=-2` | 400 "resenas_total_min debe ser un numero entero" |
| `GET /productos?limite=3` (sin filtros de reseña) | 200 — no rompe |

---

## Pruebas — reconstrucción por fecha y hora (28/28, 2026-09-02)

Sobre el producto 7 (eventos reales de la semilla: crea `2026-01-04T16:52Z`
con nombre "Laptop Aurora 14"; `2026-02-18T21:00Z` renombra a "Laptop
Aurora 14 (2026)"; `2026-03-04T20:00Z` cambia las variantes;
`2026-04-18T20:00Z` vuelve el nombre a "Laptop Aurora 14").

| Caso | Resultado |
|---|---|
| `?fecha=2026-01-04` / `?fecha=2026-02-18` / `?fecha=2026-04-18` (solo fecha, regresión) | nombre "Laptop Aurora 14" / "…(2026)" / "Laptop Aurora 14" — idéntico a antes |
| `?fecha=2026-02-18T20:59` y `?fecha=2026-02-18T20:59:59` | nombre "Laptop Aurora 14" — el evento de las 21:00Z **no** entra |
| `?fecha=2026-02-18T21:00` y `?fecha=2026-02-18T21:00:00` | nombre "Laptop Aurora 14 (2026)" — el instante exacto **sí** entra (`$lte`) |
| `?fecha=2026-02-18%2021:00` (espacio en vez de `T`) | igual que con `T` |
| `?fecha=2026-03-04T19:59` vs `?fecha=2026-03-04T20:00` | variante 0 pasa de "16 GB" a "16 GB / 512 GB" — el corte por hora también aplica a un evento de modificación |
| `?fecha=2026-01-04T16:52` | 200, estado de creación; `?fecha=2026-01-04T16:51` → 404 "El producto no existia en esa fecha" |
| `?fecha=` / `hola` / `2026-02-30` / `2026-13-01` | 400: "La fecha es obligatoria" / formato / "La fecha no es valida" ×2 |
| `?fecha=2026-02-18T25:00` / `T21:60` / `T21:00:99` | 400 "La hora no es valida" |
| `?fecha=2026-02-18T21` (sin minutos) | 400 formato |
| sin sesión | 401; id no numérico → 400 "El id no es valido" |
| `GET /vendedor/productos/7/historial?fecha=…` (ruta gemela) | mismo resultado, misma validación |

`GET /productos/ofertas/:id/historial` (precio/stock de la oferta, lado
PostgreSQL) **no** se tocó: sigue aceptando solo `AAAA-MM-DD`.
