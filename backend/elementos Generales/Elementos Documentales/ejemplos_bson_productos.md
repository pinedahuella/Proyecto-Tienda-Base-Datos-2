# Documentos de producto en MongoDB, con ejemplos reales

Todo lo que aparece aquí está copiado tal cual de la base, no es un boceto. Son
los tres productos de prueba que carga el ETL de `etl/` a partir de los datos de
`migrations/003_productos.sql`. Para verlos en tu máquina: DbGate en
http://localhost:3001, base `mesh`.

Los campos obligatorios de cada documento están explicados en
[productos_subproductos.md](productos_subproductos.md).

## Las dos colecciones

| Colección | Qué guarda |
| --- | --- |
| `productos` | Cómo está el producto **hoy**. Un documento por producto. |
| `productos_eventos` | Cómo **ha ido cambiando**. Un documento por cambio. |

La primera es la que lee el catálogo. La segunda es la que responde "¿cómo estaba
este producto el 20 de febrero?".

## Los tres productos de ejemplo

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

## Un producto con `caracteristicas_adicionales` (ejemplo inventado)

A diferencia de todo lo de arriba, esto **no** está copiado de la base: hoy
ninguno de los tres productos de prueba trae `caracteristicas_adicionales`
todavía. Es solo para mostrar la forma, usando la laptop (`_id: 2`) y
algunas de las características de las Tablas 1 y 2 de
[productos_subproductos.md](productos_subproductos.md).

```json
{
  "_id": 2,
  "nombre": "Laptop 14 pulgadas",
  "descripcion": "Laptop de 14 pulgadas para trabajo y estudio",
  "fecha_creacion": { "$date": "2026-01-15T17:30:00.000Z" },
  "estado": "activo",
  "vendedor": {
    "id_usuario": 5,
    "usuario": "vendedor_prueba",
    "nombre": "Carlos",
    "apellido": "Ramirez"
  },
  "categoria": {
    "id_categoria": 3,
    "nombre": "Computadoras",
    "categoria_padre": "Electronica",
    "porcentaje_comision": { "$numberDecimal": "6.00" }
  },
  "caracteristicas_adicionales": {
    "marca": "Lenovo",
    "modelo": "IdeaPad 5 15IAL7",
    "fabricante": "Lenovo Group Limited",
    "pais_origen": "China",
    "garantia": { "disponible": true, "tipo": "Fabricante" },
    "duracion_garantia": { "valor": 12, "unidad": "meses" }
  },
  "variantes": [
    {
      "id_producto_variante": 3,
      "nombre_variante": "8 GB RAM",
      "precio": { "$numberDecimal": "4299.00" },
      "descripcion": "Pantalla de 14 pulgadas, 8 GB de RAM, 256 GB SSD",
      "fecha_creacion": { "$date": "2026-01-15T17:30:00.000Z" },
      "estado": "activa",
      "imagenes": [],
      "caracteristicas_adicionales": {
        "memoria_ram": { "valor": 8, "unidad": "GB" },
        "almacenamiento": { "valor": 256, "unidad": "GB", "tipo": "SSD" }
      }
    },
    {
      "id_producto_variante": 4,
      "nombre_variante": "16 GB RAM",
      "precio": { "$numberDecimal": "5199.00" },
      "descripcion": "Pantalla de 14 pulgadas, 16 GB de RAM, 512 GB SSD",
      "fecha_creacion": { "$date": "2026-01-15T17:30:00.000Z" },
      "estado": "activa",
      "imagenes": [],
      "caracteristicas_adicionales": {
        "memoria_ram": { "valor": 16, "unidad": "GB" },
        "almacenamiento": { "valor": 512, "unidad": "GB", "tipo": "SSD" }
      }
    }
  ]
}
```

Dos cosas para notar:

- `caracteristicas_adicionales` es un objeto normal: cada campo adentro usa el
  tipo que le corresponda (`duracion_garantia.valor` y `memoria_ram.valor` son
  `Number`, no dinero, así que no necesitan `$numberDecimal`).
- Cada variante trae su propio `caracteristicas_adicionales`, distinto del de
  la otra variante: la de 8 GB no tiene por qué traer los mismos campos que
  la de 16 GB.

## Eventos sobre `caracteristicas_adicionales` (ejemplo inventado)

También inventados: dos eventos más para esta misma laptop, siguiendo a los
tres reales que ya tiene en la tabla de arriba (numeros 1, 2 y 3).

**Un cambio en las características del producto en sí** (no de una variante,
no de la categoría) — por ejemplo, extender la garantía:

```json
{
  "_id": "2-4",
  "id_producto": 2,
  "numero": 4,
  "fecha": { "$date": "2026-04-01T10:00:00.000Z" },
  "operacion": "modificacion",
  "cambios": {
    "caracteristicas_adicionales": {
      "marca": "Lenovo",
      "modelo": "IdeaPad 5 15IAL7",
      "fabricante": "Lenovo Group Limited",
      "pais_origen": "China",
      "garantia": { "disponible": true, "tipo": "Fabricante" },
      "duracion_garantia": { "valor": 24, "unidad": "meses" }
    }
  }
}
```

Mismo patrón que ya usan los eventos reales de categoría (`"1-4"`) y de
variantes (`"1-2"`): aunque solo cambió `duracion_garantia`, el evento guarda
`caracteristicas_adicionales` completo, no solo el campo que cambió. La
unidad de "qué cambió" es el sub-objeto entero, no cada llave suelta adentro.

**Un cambio en las características de una variante específica** — por
ejemplo, corregir el almacenamiento real de la variante de 16 GB:

```json
{
  "_id": "2-5",
  "id_producto": 2,
  "numero": 5,
  "fecha": { "$date": "2026-04-10T14:00:00.000Z" },
  "operacion": "modificacion",
  "cambios": {
    "variantes": [
      {
        "id_producto_variante": 3,
        "nombre_variante": "8 GB RAM",
        "precio": { "$numberDecimal": "4299.00" },
        "descripcion": "Pantalla de 14 pulgadas, 8 GB de RAM, 256 GB SSD",
        "caracteristicas_adicionales": {
          "memoria_ram": { "valor": 8, "unidad": "GB" },
          "almacenamiento": { "valor": 256, "unidad": "GB", "tipo": "SSD" }
        }
      },
      {
        "id_producto_variante": 4,
        "nombre_variante": "16 GB RAM",
        "precio": { "$numberDecimal": "5199.00" },
        "descripcion": "Pantalla de 14 pulgadas, 16 GB de RAM, 512 GB SSD",
        "caracteristicas_adicionales": {
          "memoria_ram": { "valor": 16, "unidad": "GB" },
          "almacenamiento": { "valor": 1, "unidad": "TB", "tipo": "SSD" }
        }
      }
    ]
  }
}
```

Igual que el evento real `"2-3"` (el que sube el SSD de la variante de 16 GB
a 1 TB): cuando cambia algo dentro de `variantes`, el evento trae el array
completo, no solo la variante que cambió ni solo el campo de adentro.

**¿Y un cambio de categoría?** Eso ya está documentado arriba y no hace falta
inventarlo: es el evento real `"1-4"`, donde sube el `porcentaje_comision` de
Camisas sin que nadie tocara la camisa ese día.
