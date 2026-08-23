# Endpoints de productos

Este archivo documenta solo las rutas de `/productos` (la base documental,
MongoDB). Las demás rutas del backend (usuario, perfil, direcciones, admin)
están en [endpoints.md](endpoints.md).

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
| `id_vendedor` | entero | No | Igualdad exacta sobre `vendedor.id_usuario` |
| `precio_min` / `precio_max` | decimal | No | Rango de precio, sobre `variantes[].precio` |
| `estado_variante` | texto | No | Igualdad exacta sobre `variantes[].estado` |
| _cualquier otro nombre_ | texto | No | Filtro dinámico de característica (catálogo o personalizada) — ver abajo |

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
"Obligatorios" de `productos_subproductos.md`). `estado_variante` y el rango
de precio se combinan entre sí exigiendo que sea **la misma variante** la que
cumpla las dos condiciones (por ejemplo, "una variante activa Y que cueste
entre 100 y 500"): si una variante está activa y otra distinta cuesta en ese
rango, no cuenta, porque no son la misma variante.

```
GET /productos?nombre=laptop
GET /productos?id_categoria=5
GET /productos?precio_min=100&precio_max=500&estado_variante=activa
```

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

**El valor se compara de forma exacta**, a diferencia de `nombre` (el
filtro fijo del producto), que sí es una búsqueda parcial.

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
cuál de las dos formas tenga guardadas en este momento.

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

```json
{
  "ok": true,
  "mensaje": "Productos obtenidos",
  "payload": {
    "productos": [
      {
        "_id": 2,
        "nombre": "Laptop 14 pulgadas",
        "descripcion": "Laptop de 14 pulgadas para trabajo y estudio",
        "fecha_creacion": "2026-01-15T17:30:00.000Z",
        "estado": "activo",
        "vendedor": {
          "id_usuario": 5,
          "usuario": "vendedor_prueba",
          "nombre": "Carlos",
          "apellido": "Ramirez"
        },
        "categoria": {
          "id_categoria": 5,
          "nombre": "Computadoras",
          "categoria_padre": "Electronica",
          "porcentaje_comision": { "$numberDecimal": "6.00" }
        },
        "variantes": [
          {
            "id_producto_variante": 3,
            "nombre_variante": "8 GB RAM",
            "precio": { "$numberDecimal": "4299.00" },
            "descripcion": "Pantalla de 14 pulgadas, 8 GB de RAM, 256 GB SSD",
            "fecha_creacion": "2026-01-15T17:30:00.000Z",
            "estado": "activa",
            "imagenes": ["https://..."]
          }
        ]
      }
    ],
    "siguiente_cursor": 2
  }
}
```

`siguiente_cursor` es `null` cuando esa tanda ya trajo el último producto
del catálogo (o de lo que quedaba despues de aplicar los filtros).

### 400

```json
{ "ok": false, "mensaje": "El limite debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "despues_de debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "id_categoria debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "id_vendedor debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "precio_min debe ser un numero valido, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "precio_max debe ser un numero valido, con hasta 2 decimales", "payload": null }
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

## GET /productos/paginacion

Pública, igual que `GET /productos`. Lista el mismo catálogo, con los
mismos filtros fijos y dinámicos, la misma exclusión de `inactivo`/`borrador`
y las mismas reglas de validación — la única diferencia es **cómo se
pagina**: en vez de un cursor (`despues_de`), se pide un número de página
(`pagina`) y un tamaño de página (`limite`), y sí se puede saltar
directo a cualquier página sin haber pedido las anteriores.

A cambio de ese salto directo, esta ruta sí necesita contar cuántos
productos hay en total (`countDocuments`) para calcular `total_paginas`, que
es justo el costo que `GET /productos` evita al no permitir saltos.

### Query params

| Param | Tipo | Obligatorio | Qué hace |
| --- | --- | --- | --- |
| `pagina` | entero | No (por defecto 1) | Qué página pedir, 1 es la primera |
| `limite` | entero | No (por defecto 20, tope 100) | Cuántos productos trae cada página |
| `nombre`, `estado`, `id_categoria`, `id_vendedor`, `precio_min`, `precio_max`, `estado_variante` | — | No | Los mismos filtros fijos de `GET /productos` |
| _cualquier otro nombre_ | texto | No | Filtro dinámico de característica (catálogo o personalizada), igual que en `GET /productos` |

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
{ "ok": false, "mensaje": "id_vendedor debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "precio_min debe ser un numero valido, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "precio_max debe ser un numero valido, con hasta 2 decimales", "payload": null }
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
| `id_vendedor` | `GET /productos?id_vendedor=5` | Productos del vendedor 5 |
| `precio_min` | `GET /productos?precio_min=100` | Productos con alguna variante de precio >= 100 |
| `precio_max` | `GET /productos?precio_max=500` | Productos con alguna variante de precio <= 500 |
| `estado_variante` | `GET /productos?estado_variante=activa` | Productos con alguna variante activa |

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
