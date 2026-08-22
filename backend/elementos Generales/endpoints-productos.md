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
| _cualquier otro nombre_ | texto | No | Filtro dinámico sobre `caracteristicas_adicionales` — ver abajo |

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

### Filtros dinámicos (características opcionales)

Como las características opcionales (Tabla 1 y Tabla 2 de
`productos_subproductos.md`: marca, RAM, color, garantía, etc.) cambian
según la categoría, no tienen un nombre de query param fijo cada una. En su
lugar: **cualquier query param que no sea uno de los nombres fijos de la
tabla de arriba se trata como un filtro sobre `caracteristicas_adicionales`**,
buscándolo tanto en el producto como en cada una de sus variantes.

```
GET /productos?marca=Lenovo
```

Busca productos donde `caracteristicas_adicionales.marca` sea `"Lenovo"`, **o**
donde alguna de sus variantes tenga `caracteristicas_adicionales.marca`
igual a `"Lenovo"`. No hace falta que sea la misma variante que otros
filtros dinámicos: cada uno se busca por su cuenta, en el producto o en
cualquier variante.

Se pueden combinar varios a la vez (todos deben cumplirse, cada uno por su
lado):

```
GET /productos?marca=Lenovo&ram=16
```

**Un nivel de anidamiento.** Algunas características opcionales son objetos,
no valores sueltos (por ejemplo `memoria_ram: { valor: 16, unidad: "GB" }`).
Para esos casos se admite un punto en el nombre del filtro:

```
GET /productos?memoria_ram.valor=16
```

**Sobre el tipo del valor.** El texto que llega en la URL se intenta
convertir al tipo que probablemente tiene guardado en Mongo: `"true"` /
`"false"` a booleano, texto que parece un número a `Number`, y el resto se
queda como texto. Sin esto, comparar `ram=16` (texto) contra un campo
guardado como número `16` nunca haría match.

**Seguridad.** El nombre del filtro solo admite letras, números, guion bajo
y puntos (`/^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)*$/`). Nunca admite `$`: como
siempre se antepone `caracteristicas_adicionales.` al nombre que llega, un
nombre con `$` intentando inyectar un operador de Mongo (`$where`, etc.) se
rechaza con 400 en vez de ejecutarse.

### `caracteristicas_personalizadas` — se devuelven, pero no se filtran

Además de `caracteristicas_adicionales` (el catálogo de la app), un producto
o una variante puede traer `caracteristicas_personalizadas`: pares
nombre-valor sueltos que agregó quien creó el producto, fuera de cualquier
catálogo (ver
[productos_subproductos.md](Elementos%20Documentales/productos_subproductos.md#personalizadas-las-agrega-quien-crea-el-producto)).

Esta ruta **sí** las devuelve como parte normal del producto o la variante
en la respuesta — no se ocultan. Lo que no hacen es participar del filtro
dinámico: los filtros de arriba solo arman condiciones contra
`caracteristicas_adicionales`, nunca contra `caracteristicas_personalizadas`.
No es una validación que rechace el intento con un 400 — simplemente esa
ruta de campo nunca se construye, así que un filtro con ese nombre no
encuentra nada, en vez de encontrar algo que no debería.

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
| _cualquier otro nombre_ | texto | No | Filtro dinámico sobre `caracteristicas_adicionales`, igual que en `GET /productos` |

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
más arriba). Los nombres de las características opcionales no están fijados
en ningún lado del backend — `caracteristicas_adicionales` no tiene esquema
fijo — así que los nombres de abajo son una propuesta en snake_case de cada
fila de las Tablas 1 y 2 de
[productos_subproductos.md](Elementos%20Documentales/productos_subproductos.md).
Si el producto real usa otro nombre de campo, el filtro es el nombre que de
verdad se haya guardado, no el de esta lista.

**Sobre arrays.** Cuando la característica es `Array<...>` (por ejemplo
`tags` o `materiales_principales`), el filtro compara si el array *contiene*
ese valor exacto: `?tags=laptop` encuentra productos donde `tags` incluya
`"laptop"` entre otros, no que sea el único valor.

**Sobre objetos.** Cuando la característica es un `Object` (por ejemplo
`garantia` o `dimensiones`), el filtro tiene que apuntar a un campo de
adentro con un punto, como se explicó arriba (`garantia.disponible=true`),
no al objeto completo.

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

### Filtros dinámicos — Tabla 1 (características del producto)

| Característica | Ejemplo de filtro |
| --- | --- |
| Marca | `GET /productos?marca=Lenovo` |
| Modelo | `GET /productos?modelo=IdeaPad 5 15IAL7` |
| Fabricante | `GET /productos?fabricante=Lenovo Group Limited` |
| País de origen | `GET /productos?pais_origen=China` |
| Garantía | `GET /productos?garantia.disponible=true` |
| Duración de la garantía | `GET /productos?duracion_garantia.valor=12` |
| Condiciones de garantía | `GET /productos?condiciones_garantia=Cubre defectos de fabricacion` |
| Materiales principales | `GET /productos?materiales_principales=Aluminio` |
| Características técnicas | `GET /productos?caracteristicas_tecnicas.procesador=Intel i5` |
| Especificaciones | `GET /productos?especificaciones.pantalla=15.6 pulgadas` |
| Contenido del paquete | `GET /productos?contenido_paquete=Cargador` |
| Dimensiones generales | `GET /productos?dimensiones_generales.unidad=cm` |
| Peso | `GET /productos?peso.valor=1.85` |
| Unidad de medida | `GET /productos?unidad_medida=unidad` |
| Edad recomendada | `GET /productos?edad_recomendada.minimo=12` |
| Uso recomendado | `GET /productos?uso_recomendado=Ofimatica` |
| Instrucciones de uso | `GET /productos?instrucciones_uso=Conectar el cargador antes del primer uso` |
| Advertencias | `GET /productos?advertencias=No exponer al agua` |
| Certificaciones | `GET /productos?certificaciones.nombre=CE` |
| Código de fabricante / MPN | `GET /productos?codigo_fabricante_mpn=82SF00XXUS` |
| Código universal del producto (UPC, EAN, GTIN) | `GET /productos?codigo_universal=0196801234567` |
| Información nutricional — alimentos | `GET /productos?informacion_nutricional.calorias=250` |
| Ingredientes — alimentos/cosméticos | `GET /productos?ingredientes=Harina` |
| Compatibilidad — electrónicos, accesorios, repuestos | `GET /productos?compatibilidad=iPhone 15` |
| Sistema operativo compatible | `GET /productos?sistema_operativo_compatible=Windows 11` |
| Potencia / voltaje — electrónicos | `GET /productos?potencia_voltaje.voltaje=110` |
| Tipo de producto | `GET /productos?tipo_producto=Laptop` |
| Características destacadas | `GET /productos?caracteristicas_destacadas=Wi-Fi 6` |
| Etiquetas o tags | `GET /productos?tags=laptop` |

### Filtros dinámicos — Tabla 2 (características de variante)

| Característica | Ejemplo de filtro |
| --- | --- |
| Color | `GET /productos?color=Negro` |
| Talla | `GET /productos?talla=M` |
| Tamaño | `GET /productos?tamano=15.6 pulgadas` |
| Capacidad | `GET /productos?capacidad.valor=500` |
| Memoria RAM | `GET /productos?memoria_ram.valor=16` |
| Almacenamiento | `GET /productos?almacenamiento.valor=512` |
| Peso de presentación | `GET /productos?peso_presentacion.valor=500` |
| Volumen | `GET /productos?volumen.valor=1.5` |
| Dimensiones | `GET /productos?dimensiones.largo=30` |
| Sabor | `GET /productos?sabor=Chocolate` |
| Aroma | `GET /productos?aroma=Vainilla` |
| Fragancia | `GET /productos?fragancia=Floral` |
| Diseño / estampado | `GET /productos?diseno_estampado=Rayas` |
| Material | `GET /productos?material=Algodon` |
| Acabado | `GET /productos?acabado=Mate` |
| Modelo específico | `GET /productos?modelo_especifico=iPhone 17 Pro Max 256GB` |
| Voltaje | `GET /productos?voltaje.valor=110` |
| Potencia | `GET /productos?potencia.valor=1500` |
| Presentación | `GET /productos?presentacion=Paquete` |
| Cantidad por paquete | `GET /productos?cantidad_paquete=12` |
| Número de unidades | `GET /productos?numero_unidades=1` |
| Edición | `GET /productos?edicion=Edicion limitada` |
| Compatibilidad específica | `GET /productos?compatibilidad_especifica=iPhone 15 Pro` |
| Configuración | `GET /productos?configuracion.ram=16GB` |
| Código SKU | `GET /productos?codigo_sku=LAP-LEN-I7-16-512-GRY` |
| Código de barras | `GET /productos?codigo_barras=7501234567890` |
| Porcentaje de descuento | `GET /productos?porcentaje_descuento=10` |
