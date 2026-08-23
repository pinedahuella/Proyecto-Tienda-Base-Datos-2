# Características de Producto

Este documento tiene dos partes.

**Arriba, lo obligatorio.** Son los campos que todo documento de producto lleva
siempre, sin importar la categoría. No son una propuesta: ya existen en el modelo
relacional y son los que el ETL escribe hoy en MongoDB. Si un documento no los
trae, está incompleto.

**Abajo, lo opcional.** Las características que cada categoría puede traer o no.
Los atributos de una laptop no se parecen a los de una camisa, y esa es
precisamente la razón por la que el catálogo se migró a una base documental.

---

## Obligatorias

Lo que lleva todo producto, siempre.

### Raíz del documento

| Campo | Tipo | Ejemplo | De dónde sale |
| --- | --- | --- | --- |
| `_id` | `Number` | `1` | Es el `id_producto` de PostgreSQL, no uno que genere Mongo |
| `nombre` | `String` | `"Camisa de lino manga larga"` | `productos.nombre` |
| `descripcion` | `String` | `"Camisa de lino de corte regular"` | `productos.descripcion` |
| `fecha_creacion` | `Date` | `2026-01-10T15:00:00Z` | `productos.fecha_creacion` |
| `estado` | `String` | `"activo"` | Catálogo `estado_producto` |
| `vendedor` | `Object` | ver abajo | `usuarios`, por `productos.id_usuario` |
| `categoria` | `Object` | ver abajo | `categorias`, por `productos.id_categoria` |
| `variantes` | `Array<Object>` | ver abajo | `productos_variantes` |

### vendedor

| Campo | Tipo | Ejemplo |
| --- | --- | --- |
| `id_usuario` | `Number` | `5` |
| `usuario` | `String` | `"vendedor_prueba"` |
| `nombre` | `String` | `"Carlos"` |
| `apellido` | `String` | `"Ramirez"` |

### categoria

| Campo | Tipo | Ejemplo |
| --- | --- | --- |
| `id_categoria` | `Number` | `7` |
| `nombre` | `String` | `"Cocina"` |
| `categoria_padre` | `String` | `"Hogar"` |
| `porcentaje_comision` | `Decimal128` | `7.50` |

### Cada elemento de variantes

| Campo | Tipo | Ejemplo |
| --- | --- | --- |
| `id_producto_variante` | `Number` | `1` |
| `nombre_variante` | `String` | `"M azul"` |
| `precio` | `Decimal128` | `169.00` |
| `descripcion` | `String` | `"Talla M, color azul"` |
| `fecha_creacion` | `Date` | `2026-01-10T15:00:00Z` |
| `estado` | `String` | `"activa"` |
| `imagenes` | `Array<String>` | `["https://.../camisa.jpg"]` |
| `stock` | `Number` | `9` |

**Sobre el dinero.** `precio` y `porcentaje_comision` van en `Decimal128`, no en
`Number`. Con punto flotante los centavos se redondean mal y el error se acumula.

**Sobre `descripcion`.** Es el único campo obligatorio de la lista que en
PostgreSQL acepta nulo. Hoy los tres productos de prueba lo traen.

**Sobre `stock`.** A diferencia de los demás campos de esta tabla, no siempre
está: es opcional, y solo aparece una vez que esa variante tiene inventario
creado en PostgreSQL (tabla `inventario`). Es una copia de lectura — cuántas
unidades quedan — nunca la verdad; quien de verdad decide si alcanza para
vender es PostgreSQL. El backend la mantiene al día (`GET/POST/PATCH
/vendedor/productos/:id/inventario`, y `stock_inicial` al crear o editar un
producto), pero una variante recién creada sin inventario todavía no lo
trae. Detalle completo en
[cambios-etl-productos.md](../cambios-etl-productos.md) y
[endpoints-vendedores.md](../endpoints-vendedores.md).

Un ejemplo completo de cómo queda el documento está en
[ejemplos_bson_productos.md](ejemplos_bson_productos.md).

---

## Opcionales

Según la categoría. Un producto puede traer todas, algunas o ninguna. Van agrupadas
en un solo campo, `caracteristicas_adicionales`:

- Las de la Tabla 1 van en la raíz del documento de `productos`.
- Las de la Tabla 2 van en cada elemento del array `variantes`.

### La estructura, que es siempre la misma

`caracteristicas_adicionales` es un **array de objetos**, y cada objeto tiene
exactamente tres llaves, siempre las mismas:

```json
"caracteristicas_adicionales": [
  { "nombre": "Marca",       "valor": "Tecno Sur", "unidad": null },
  { "nombre": "Frecuencia",  "valor": 5.00,        "unidad": "GHz" },
  { "nombre": "Nucleos",     "valor": 10,          "unidad": null },
  { "nombre": "Garantia",    "valor": true,        "unidad": null }
]
```

| Llave | Tipo | Regla |
| --- | --- | --- |
| `nombre` | `String` | Sale del catálogo. Es uno de los de las tablas de abajo |
| `valor` | `String`, `Number` o `Boolean` | El tipo nativo de Mongo que corresponda al `tipo_dato` de la definición |
| `unidad` | `String` o `null` | `null` cuando la característica no se mide en nada |

Tres cosas que no son negociables, porque de ellas depende que se pueda filtrar:

**El `valor` usa el tipo nativo de Mongo que le toque, no siempre texto.**
`tipo_dato = "entero"` o `"decimal"` se guarda como `Number` (`10`, no `"10"`);
`"booleano"` se guarda como `Boolean` (`true`, no `"true"`); solo `"texto"` (y
cada elemento de una `"lista"` de texto) se guarda como `String`. En
PostgreSQL `producto_caracteristica.valor` sí es una sola columna `text` para
las cuatro clases de dato a la vez — es la única forma de tener una tabla
para todas las características sin una columna por tipo — pero eso es una
limitación de SQL, no una regla que Mongo tenga que heredar: al escribir el
documento, el ETL convierte ese texto al tipo real según `tipo_dato` antes de
guardarlo. Guardar todo como texto en Mongo también obligaría a convertir en
cada consulta para poder comparar por rango o hacer aritmética, que es
justo lo que se evita haciéndolo una sola vez, al escribir.

**La unidad nunca va dentro del valor.** Se guarda `10` con `"unidad": "GB"`, y
nunca `"10 GB"`. Con la unidad pegada al valor hay que partir la cadena para
comparar, y filtrar por rango deja de funcionar.

**El valor no lleva objetos ni arrays anidados.** Lo que en un catálogo suele ser un
objeto aquí se parte en varias características: las dimensiones no son
`{ largo, ancho, alto }`, son tres entradas, `Largo`, `Ancho` y `Alto`, cada una con
su unidad. La garantía no es `{ disponible, tipo }`, son `Garantia` (booleano) y
`Tipo de garantia` (texto).

### Una lista es una sola entrada, con un array adentro

Una característica de tipo `lista` va en **una entrada**, y su `valor` es un array
de texto:

```json
{ "nombre": "Contenido del paquete", "valor": ["Telefono", "Cable USB-C", "Manual"], "unidad": null }
```

En PostgreSQL esa misma lista son varias filas de `producto_caracteristica` con el
mismo producto y la misma característica: una columna no puede guardar varios
valores, y por eso esa tabla no tiene una restricción que impida repetirlos. Pero
esa regla es de SQL. Un documento sí puede guardar varios valores en un campo, así
que el ETL las agrupa al escribir y aquí llegan juntas.

**Filtrar sigue funcionando igual.** `?Contenido del paquete=Cargador` encuentra el
producto, porque Mongo compara un campo array contra un valor suelto por
contención: el `$elemMatch: { nombre, valor }` que ya usa el backend sirve para las
dos formas sin cambiarle una línea.

### El orden

**El orden del array es el orden.** Un array de Mongo conserva la posición en que se
escribió, así que quien lo lee puede mostrarlo tal como viene sin ordenar nada. El
ETL escribe las entradas ordenadas por el id de la característica, que es estable:
el mismo producto sale siempre igual.

Eso es una propiedad que da la base documental y que el modelo relacional no tiene.
En PostgreSQL las filas no tienen orden propio y por eso el ER no lleva ninguna
columna de posición: el orden aparece al migrar.

## Tabla 1 — Características del producto

Son las del producto entero: las que no cambian entre sus variantes.

| Característica | Tipo | Unidad | Categorías que la ofrecen | Ejemplo de `valor` |
| --- | --- | --- | --- | --- |
| **Marca** | `texto` | — | 19 | `Lino Vivo` |
| **Modelo** | `texto` | — | 17 | `LV-ML-01` |
| **Fabricante** | `texto` | — | 18 | `Tecno Sur Manufacturing` |
| **Pais de origen** | `texto` | — | 19 | `Guatemala` |
| **Garantia** | `booleano` | — | 17 | `true` |
| **Tipo de garantia** | `texto` | — | 5 | `Fabricante` |
| **Duracion de la garantia** | `entero` | `meses` | 17 | `12` |
| **Condiciones de garantia** | `texto` | — | 5 | `Cubre defectos de fabricacion, no cubre dano por liquidos` |
| **Materiales principales** | `lista` | — | 17 | `Lino` |
| **Procesador** | `texto` | — | 3 | `Intel Core i5-1235U` |
| **Nucleos** | `entero` | — | 3 | `10` |
| **Frecuencia** | `decimal` | `GHz` | 3 | `4.40` |
| **Tamano de pantalla** | `decimal` | `pulgadas` | 3 | `14` |
| **Resolucion** | `texto` | — | 3 | `1920x1080` |
| **Contenido del paquete** | `lista` | — | 14 | `Laptop` |
| **Largo** | `decimal` | `cm` | 16 | `14.0` |
| **Ancho** | `decimal` | `cm` | 16 | `14.0` |
| **Alto** | `decimal` | `cm` | 16 | `42.0` |
| **Peso** | `decimal` | `kg` | 19 | `1.45` |
| **Unidad de medida** | `texto` | — | 19 | `unidad` |
| **Edad recomendada minima** | `entero` | `anios` | 12 | `16` |
| **Uso recomendado** | `lista` | — | 19 | `Uso casual` |
| **Instrucciones de uso** | `texto` | — | 19 | `Lavar a mano con agua fria y secar a la sombra` |
| **Advertencias** | `lista` | — | 19 | `No obstruir las salidas de aire` |
| **Certificaciones** | `lista` | — | 17 | `CE` |
| **Codigo de fabricante** | `texto` | — | 10 | `TS14A-001` |
| **Codigo universal del producto** | `texto` | — | 19 | `7401000000011` |
| **Calorias** | `entero` | `kcal` | 0 | — |
| **Proteinas** | `decimal` | `g` | 0 | — |
| **Grasas** | `decimal` | `g` | 0 | — |
| **Carbohidratos** | `decimal` | `g` | 0 | — |
| **Ingredientes** | `lista` | — | 0 | — |
| **Compatibilidad** | `lista` | — | 3 | `Cargador USB-C de 65 W` |
| **Sistema operativo compatible** | `lista` | — | 3 | `Windows 11` |
| **Potencia** | `decimal` | `W` | 7 | `65` |
| **Voltaje** | `decimal` | `V` | 7 | `110` |
| **Tipo de producto** | `texto` | — | 19 | `Camisa` |
| **Caracteristicas destacadas** | `lista` | — | 19 | `Tela fresca` |
| **Etiquetas** | `lista` | — | 19 | `camisa` |

## Tabla 2 — Características de la variante

Son las que distinguen una variante de otra.

| Característica | Tipo | Unidad | Categorías que la ofrecen | Ejemplo de `valor` |
| --- | --- | --- | --- | --- |
| **Color** | `texto` | — | 17 | `Azul` |
| **Codigo hex del color** | `texto` | — | 17 | `#1F3A93` |
| **Talla** | `texto` | — | 9 | `M` |
| **Tamano** | `decimal` | `pulgadas` | 4 | `24` |
| **Capacidad** | `decimal` | `ml` | 2 | `1200` |
| **Memoria RAM** | `entero` | `GB` | 4 | `8` |
| **Almacenamiento** | `entero` | `GB` | 4 | `256` |
| **Tipo de almacenamiento** | `texto` | — | 4 | `SSD` |
| **Peso de presentacion** | `decimal` | `g` | 8 | `1200` |
| **Volumen** | `decimal` | `L` | 2 | `1.2` |
| **Largo** | `decimal` | `cm` | 1 | `300.0` |
| **Ancho** | `decimal` | `cm` | 0 | — |
| **Alto** | `decimal` | `cm` | 0 | — |
| **Sabor** | `texto` | — | 0 | — |
| **Aroma** | `texto` | — | 0 | — |
| **Fragancia** | `texto` | — | 0 | — |
| **Tipo de diseno** | `texto` | — | 3 | — |
| **Nombre del diseno** | `texto` | — | 3 | — |
| **Material** | `texto` | — | 11 | `Algodon` |
| **Acabado** | `texto` | — | 19 | — |
| **Modelo especifico** | `texto` | — | 5 | `Monitor de 24 pulgadas Con base` |
| **Voltaje** | `decimal` | `V` | 0 | — |
| **Potencia** | `decimal` | `W` | 1 | — |
| **Tipo de presentacion** | `texto` | — | 2 | `Pasta blanda` |
| **Descripcion de la presentacion** | `texto` | — | 0 | — |
| **Cantidad por paquete** | `entero` | — | 19 | — |
| **Numero de unidades** | `entero` | — | 2 | `1` |
| **Edicion** | `texto` | — | 2 | `Segunda edicion` |
| **Compatibilidad especifica** | `lista` | — | 0 | — |
| **Codigo SKU** | `texto` | — | 19 | `CDL-1-1` |
| **Codigo de barras** | `texto` | — | 19 | — |
| **Porcentaje de descuento** | `entero` | `%` | 19 | — |

---

## Personalizadas (las agrega quien crea el producto)

**Ya existen.** Van en `caracteristicas_personalizadas`, un campo aparte de
`caracteristicas_adicionales` (las de las Tablas 1 y 2), tanto en la raíz del
producto como en cada elemento de `variantes`. Usan **exactamente la misma
estructura** que las de arriba, el mismo array de `{ nombre, valor, unidad }`,
para que el backend las lea con el mismo código y no haya dos formatos que
mantener.

La diferencia es de dónde sale el `nombre` y qué tan estricta es la
validación: el de las Tablas 1 y 2 viene del catálogo de la categoría y tiene
que ser uno de los que esa categoría ofrece, con el `valor` cumpliendo su
`tipo_dato` exacto; el de una personalizada lo escribe quien publica el
producto, sin ningún catálogo de por medio — solo se revisa que el formato
sea razonable (nombre no vacío, hasta 100 caracteres, sin repetirse dentro
del mismo producto o variante) y que el `valor` sea algo suelto (texto,
número o verdadero/falso), nunca una lista ni un objeto anidado —
`tipo_dato = "lista"` no existe para las personalizadas. `unidad` siempre
sale `null`: no hay definición de catálogo de la que sacarla.

**Son tan filtrables como las del catálogo.** `GET /productos` busca por
igual en `caracteristicas_adicionales` y en `caracteristicas_personalizadas`
(del producto y de cada variante) con el mismo `$elemMatch`, así que un
filtro dinámico como `?Edicion especial=true` encuentra el producto sin
importar en cuál de las dos viva esa característica — ver
[endpoints-productos.md](../endpoints-productos.md).
