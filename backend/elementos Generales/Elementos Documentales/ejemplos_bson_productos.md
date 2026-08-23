# Documentos de producto en MongoDB, con ejemplos reales

Todo lo que aparece aquí está copiado tal cual de la base, no es un boceto. El
catálogo son 50 productos, 92 variantes y 27 categorías, que el ETL de `etl/` carga
a partir de los conjuntos de `migrations/datos/`. Los ejemplos de abajo son los
tres primeros productos, que son los que tienen modificaciones y por eso sirven
para enseñar los eventos. Para verlos en tu máquina: DbGate en
http://localhost:3001, base `mesh`.

Los campos obligatorios de cada documento están explicados en
[productos_subproductos.md](productos_subproductos.md).

## Las tres colecciones

| Colección | Qué guarda |
| --- | --- |
| `productos` | Cómo está el producto **hoy**. Un documento por producto. |
| `productos_eventos` | Cómo **ha ido cambiando**. Un documento por cambio. |
| `categorias` | Qué características **ofrece** cada categoría. Un documento por categoría. |

La primera es la que lee el catálogo. La segunda es la que responde "¿cómo estaba
este producto el 20 de febrero?". La tercera no guarda valores: es la lista de
campos que el formulario le propone a quien publica en esa categoría.

## Los tres productos que se usan de ejemplo

| `_id` | Nombre | Categoría | Variantes | Eventos |
| --- | --- | --- | --- | --- |
| `1` | Camisa de lino manga larga | Ropa de hombre > Camisas | 2 | 4 |
| `2` | Laptop 14 pulgadas | Electronica > Computadoras | 2 | 3 |
| `3` | Cafetera de goteo | Hogar > Cocina | 1 | 2 |

Son de categorías a propósito muy distintas entre sí: lo que describe a una laptop
no describe a una camisa. Esa es la heterogeneidad que motiva usar una base
documental.

## Un documento completo

Este es el producto 3 entero, como sale de la base:

```json
{
  "_id": 3,
  "nombre": "Cafetera de goteo",
  "descripcion": "Cafetera de goteo con jarra de vidrio y filtro permanente",
  "fecha_creacion": { "$date": "2026-02-01T14:00:00.000Z" },
  "estado": "activo",
  "vendedor": {
    "nombre": "Carlos",
    "usuario": "vendedor_prueba",
    "apellido": "Ramirez",
    "id_usuario": 5
  },
  "categoria": {
    "nombre": "Cocina",
    "id_categoria": 7,
    "categoria_padre": "Hogar",
    "porcentaje_comision": {
      "$numberDecimal": "7.50"
    }
  },
  "variantes": [
    {
      "estado": "activa",
      "precio": {
        "$numberDecimal": "349.00"
      },
      "imagenes": [
        "https://upload.wikimedia.org/wikipedia/commons/thumb/b/bb/Hamilton_Beach_home_coffee_maker.jpg/960px-Hamilton_Beach_home_coffee_maker.jpg",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/b/b9/Our_new_coffee_maker_%282006%29_Hamilton_Beach.jpg/960px-Our_new_coffee_maker_%282006%29_Hamilton_Beach.jpg"
      ],
      "descripcion": "Jarra de 1.2 litros, rinde 10 tazas",
      "fecha_creacion": { "$date": "2026-02-01T14:00:00.000Z" },
      "nombre_variante": "1.2 litros",
      "id_producto_variante": 5
    }
  ]
}
```

Tres cosas que conviene notar:

- **El `_id` es el `id_producto` de PostgreSQL**, no uno que genere Mongo. Por eso
  volver a correr el ETL actualiza en vez de duplicar, y se sabe de inmediato a qué
  fila del relacional corresponde cada documento.
- **La categoría, el vendedor y las variantes van embebidos.** Se leen siempre junto
  con el producto, son pocos campos y cambian poco.
- **El dinero es `$numberDecimal`**, o sea `Decimal128`. Con punto flotante los
  centavos se redondean mal.
- **Las fechas son `Date` de Mongo**, o sea que en crudo se ven como
  `{ "$date": "..." }`, igual que el dinero se ve como `$numberDecimal`.

## Cómo está organizado un evento

Un evento dice qué le pasó al producto y cuándo. Nunca se edita ni se borra: cada
cambio agrega uno nuevo.

| Campo | Qué es |
| --- | --- |
| `_id` | `"<id_producto>-<numero>"`. Determinista, para que el ETL no duplique. |
| `id_producto` | A qué producto pertenece |
| `numero` | El orden: 1 es el nacimiento |
| `fecha` | Cuándo pasó. `Date`, en crudo aparece como `{ "$date": "..." }` |
| `operacion` | `"creacion"` o `"modificacion"` |
| `datos` | Solo en la creación. El estado **completo**. |
| `cambios` | Solo en las modificaciones. **Solo lo que cambió.** |

## Los eventos del producto 1, completos

Este es el ejemplo que conviene entender, porque tiene cambios sobre campos
distintos en fechas distintas.

```json
[
  {
    "_id": "1-1",
    "id_producto": 1,
    "numero": 1,
    "fecha": { "$date": "2026-01-10T15:00:00.000Z" },
    "operacion": "creacion",
    "datos": {
      "nombre": "Camisa de lino",
      "descripcion": "Camisa de lino de corte regular, cuello italiano",
      "categoria": {
        "nombre": "Camisas",
        "porcentaje_comision": {
          "$numberDecimal": "10.00"
        }
      },
      "variantes": [
        {
          "id_producto_variante": 1,
          "nombre_variante": "M azul",
          "precio": {
            "$numberDecimal": "149.00"
          },
          "descripcion": "Talla M, color azul"
        },
        {
          "id_producto_variante": 2,
          "nombre_variante": "L azul",
          "precio": {
            "$numberDecimal": "159.00"
          },
          "descripcion": "Talla L, color azul"
        }
      ]
    }
  },
  {
    "_id": "1-2",
    "id_producto": 1,
    "numero": 2,
    "fecha": { "$date": "2026-02-05T17:00:00.000Z" },
    "operacion": "modificacion",
    "cambios": {
      "variantes": [
        {
          "id_producto_variante": 1,
          "nombre_variante": "M azul",
          "precio": {
            "$numberDecimal": "169.00"
          },
          "descripcion": "Talla M, color azul"
        },
        {
          "id_producto_variante": 2,
          "nombre_variante": "L azul",
          "precio": {
            "$numberDecimal": "159.00"
          },
          "descripcion": "Talla L, color azul"
        }
      ]
    }
  },
  {
    "_id": "1-3",
    "id_producto": 1,
    "numero": 3,
    "fecha": { "$date": "2026-02-10T20:00:00.000Z" },
    "operacion": "modificacion",
    "cambios": {
      "nombre": "Camisa de lino manga larga"
    }
  },
  {
    "_id": "1-4",
    "id_producto": 1,
    "numero": 4,
    "fecha": { "$date": "2026-03-01T15:00:00.000Z" },
    "operacion": "modificacion",
    "cambios": {
      "categoria": {
        "nombre": "Camisas",
        "porcentaje_comision": {
          "$numberDecimal": "12.00"
        }
      }
    }
  }
]
```

Leído en palabras:

1. **10 de enero** nace la camisa. El evento trae todo.
2. **5 de febrero** sube el precio de la variante "M azul", de 149.00 a 169.00.
3. **10 de febrero** le cambian el nombre al producto. El precio no se toca.
4. **1 de marzo** sube la comisión de la categoría Camisas, de 10 a 12 por ciento.
   Nadie tocó la camisa ese día y aun así le cambió la comisión.

## Cómo se reconstruye una fecha

Para saber cómo estaba el producto el **20 de febrero** se toma la creación y se le
aplican **todas** las modificaciones anteriores a esa fecha, en orden:

```
creación (10 ene)  +  cambio del 5 feb  +  cambio del 10 feb
= nombre "Camisa de lino manga larga", precio de M azul 169.00, comisión 10.00
```

**El error a evitar:** quedarse con la creación y la última modificación. Daría el
nombre nuevo pero el precio viejo, porque el cambio del 5 de febrero se saltó. Los
eventos guardan solo lo que cambió, así que hay que aplicarlos todos.

La consulta ya está escrita en `etl/reconstruir.js`.

---

## Un producto con sus características

Es la laptop (`_id: 2`), recortada a las primeras seis características y sin las
imágenes de las variantes, que son URLs largas.

**Con una corrección sobre lo que hay en la base ahora mismo.** El ETL que cargó
estos datos de prueba todavía guarda `valor` siempre como texto (`"10"`,
`"true"`), copiando tal cual la columna `text` de PostgreSQL. Eso quedó
pendiente de arreglar: el `valor` debe salir con el tipo nativo de Mongo que le
corresponda según `tipo_dato` (`Number` para `entero`/`decimal`, `Boolean` para
`booleano`), no como texto — así lo de abajo ya no obliga a convertir en cada
consulta. Lo que sigue es cómo debe quedar el documento una vez corregido eso,
no un calco literal de lo que hay hoy en Mongo.

```json
{
  "_id": 2,
  "nombre": "Laptop 14 pulgadas",
  "descripcion": "Laptop de 14 pulgadas para trabajo y estudio",
  "fecha_creacion": {
    "$date": "2026-01-15T17:30:00Z"
  },
  "estado": "activo",
  "vendedor": {
    "nombre": "Carlos",
    "usuario": "vendedor_prueba",
    "apellido": "Ramirez",
    "id_usuario": 5
  },
  "categoria": {
    "nombre": "Computadoras",
    "id_categoria": 5,
    "categoria_padre": "Electronica",
    "porcentaje_comision": {
      "$numberDecimal": "6.00"
    }
  },
  "variantes": [
    {
      "estado": "activa",
      "precio": {
        "$numberDecimal": "4299.00"
      },
      "descripcion": "Pantalla de 14 pulgadas, 8 GB de RAM, 256 GB SSD",
      "fecha_creacion": {
        "$date": "2026-01-15T17:30:00Z"
      },
      "nombre_variante": "8 GB RAM",
      "id_producto_variante": 3,
      "caracteristicas_adicionales": [
        {
          "nombre": "Memoria RAM",
          "valor": 8,
          "unidad": "GB"
        },
        {
          "nombre": "Almacenamiento",
          "valor": 256,
          "unidad": "GB"
        },
        {
          "nombre": "Tipo de almacenamiento",
          "valor": "SSD",
          "unidad": null
        },
        {
          "nombre": "Codigo SKU",
          "valor": "L1P-2-3",
          "unidad": null
        }
      ]
    },
    {
      "estado": "activa",
      "precio": {
        "$numberDecimal": "4999.00"
      },
      "descripcion": "Pantalla de 14 pulgadas, 16 GB de RAM, 1 TB SSD",
      "fecha_creacion": {
        "$date": "2026-01-15T17:30:00Z"
      },
      "nombre_variante": "16 GB RAM",
      "id_producto_variante": 4,
      "caracteristicas_adicionales": [
        {
          "nombre": "Memoria RAM",
          "valor": 16,
          "unidad": "GB"
        },
        {
          "nombre": "Almacenamiento",
          "valor": 512,
          "unidad": "GB"
        },
        {
          "nombre": "Tipo de almacenamiento",
          "valor": "SSD",
          "unidad": null
        },
        {
          "nombre": "Codigo SKU",
          "valor": "L1P-2-4",
          "unidad": null
        }
      ]
    }
  ],
  "caracteristicas_adicionales": [
    {
      "nombre": "Marca",
      "valor": "Tecno Sur",
      "unidad": null
    },
    {
      "nombre": "Modelo",
      "valor": "TS-14A",
      "unidad": null
    },
    {
      "nombre": "Fabricante",
      "valor": "Tecno Sur Manufacturing",
      "unidad": null
    },
    {
      "nombre": "Pais de origen",
      "valor": "China",
      "unidad": null
    },
    {
      "nombre": "Garantia",
      "valor": true,
      "unidad": null
    },
    {
      "nombre": "Tipo de garantia",
      "valor": "Fabricante",
      "unidad": null
    }
  ]
}
```

Cuatro cosas para notar:

- **`caracteristicas_adicionales` es un array, no un objeto.** Cada entrada tiene
  siempre las mismas tres llaves: `nombre`, `valor` y `unidad`.
- **El `valor` usa el tipo nativo que le toque, no siempre texto.** `10`
  (`Number`), no `"10"`; `true` (`Boolean`), no `"true"`. De qué tipo es lo dice
  `tipo_dato` en la definición de la característica, no el dato en sí — pero
  eso decide qué tipo de Mongo usar al escribirlo, no que se escriba como texto
  siempre. Solo el texto (y cada entrada de una lista de texto) es `String`.
- **La unidad no va pegada al valor.** `4.40` con `"unidad": "GHz"`, nunca
  `"4.40 GHz"`. Con la unidad dentro habría que partir la cadena para comparar, y
  filtrar por rango dejaría de funcionar.
- **La variante trae las suyas, y son otras.** Al producto se le pregunta el
  procesador; a la variante, cuánta RAM tiene. Son dos catálogos distintos.

Un producto que no tenga ninguna característica sale **sin el campo**, no con un
array vacío: "sin características" y "características vacías" son lo mismo.

## La colección `categorias`

Es la paleta del formulario. Aquí no hay valores, solo qué se puede preguntar y de
qué tipo. Este es Computadoras (`_id: 5`), recortado a las primeras entradas:

```json
{
  "_id": 5,
  "nombre": "Computadoras",
  "categoria_padre": "Electronica",
  "porcentaje_comision": {
    "$numberDecimal": "6.00"
  },
  "fecha_creacion": {
    "$date": "2026-01-05T16:20:00Z"
  },
  "caracteristicas": [
    {
      "nombre": "Marca",
      "unidad": null,
      "tipo_dato": "texto"
    },
    {
      "nombre": "Modelo",
      "unidad": null,
      "tipo_dato": "texto"
    },
    {
      "nombre": "Fabricante",
      "unidad": null,
      "tipo_dato": "texto"
    },
    {
      "nombre": "Pais de origen",
      "unidad": null,
      "tipo_dato": "texto"
    }
  ],
  "caracteristicas_variante": [
    {
      "nombre": "Color",
      "unidad": null,
      "tipo_dato": "texto"
    },
    {
      "nombre": "Codigo hex del color",
      "unidad": null,
      "tipo_dato": "texto"
    },
    {
      "nombre": "Tamano",
      "unidad": "pulgadas",
      "tipo_dato": "decimal"
    }
  ]
}
```

Ofrece 34 características de producto y 12 de variante. Ningún producto suyo las
llena todas, y ese es el punto: la categoría propone y el producto dispone. Las
categorías de en medio del árbol (Ropa, Electronica, Hogar) salen con las dos
listas vacías, porque no se publica en ellas.

## Las características sí van en los eventos

Los ejemplos de arriba (`"1-1"` a `"1-4"`, `"2-1"` a `"2-3"`) **no traen
características en ningún evento**, ni en la creación ni en las
modificaciones. Eso no es a propósito: esos eventos se generaron cargando de
golpe una cantidad grande de productos de prueba (50 productos, 92 variantes),
y esa carga se hizo antes de que las características tuvieran su propio
historial, así que ese pedazo quedó afuera. No es una decisión de diseño, es
un pendiente.

Una característica se comporta exactamente igual que `nombre`, `categoria` o
`variantes`: tiene un valor, ese valor puede cambiar, y cada cambio se guarda.
Nada de eso cambió con esta reestructuración — lo único que cambió fue la
*forma* en que se guarda una característica (antes suelta dentro de
`descripcion`, ahora con su propio catálogo tipado) y qué categorías ofrecen
cuáles. Por eso los eventos deben tratarla como a cualquier otro campo:

- **En la creación**, `datos` debe traer `caracteristicas_adicionales`
  completo (y el de cada variante, dentro de `variantes`), igual que ya trae
  `categoria` y `variantes`.
- **En una modificación**, si cambió algo dentro de las características,
  `cambios` debe traer `caracteristicas_adicionales` **completo** (no solo la
  característica que cambió) — el mismo criterio que ya se usa para
  `categoria` (evento `"1-4"`) y `variantes` (evento `"1-2"`): la unidad de
  "qué cambió" es el array entero, no cada entrada suelta adentro.

Para que esto funcione de verdad — para poder reconstruir qué decía una
característica en una fecha pasada — el modelo relacional necesita su propio
historial para `producto_caracteristica` y
`producto_variante_caracteristica_variante`, del mismo estilo que
`productos_historial`, `productos_variantes_historial` y
`categorias_historial` ya tienen. `004_caracteristicas.sql` todavía no lo
incluye; hace falta agregarlo para que el ETL tenga de dónde sacar el evento.

Mientras ese historial no exista, reconstruir un producto a una fecha pasada
sigue devolviendo su nombre, su descripción, sus variantes con el precio de
ese día y la comisión que regía — pero las características que se ven, por
ahora, son las de hoy.
