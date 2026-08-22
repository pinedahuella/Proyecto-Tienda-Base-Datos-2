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
  "fecha_creacion": "2026-02-01T14:00:00.000Z",
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
      "fecha_creacion": "2026-02-01T14:00:00.000Z",
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

## Cómo está organizado un evento

Un evento dice qué le pasó al producto y cuándo. Nunca se edita ni se borra: cada
cambio agrega uno nuevo.

| Campo | Qué es |
| --- | --- |
| `_id` | `"<id_producto>-<numero>"`. Determinista, para que el ETL no duplique. |
| `id_producto` | A qué producto pertenece |
| `numero` | El orden: 1 es el nacimiento |
| `fecha` | Cuándo pasó |
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
    "fecha": "2026-01-10T15:00:00.000Z",
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
    "fecha": "2026-02-05T17:00:00.000Z",
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
    "fecha": "2026-02-10T20:00:00.000Z",
    "operacion": "modificacion",
    "cambios": {
      "nombre": "Camisa de lino manga larga"
    }
  },
  {
    "_id": "1-4",
    "id_producto": 1,
    "numero": 4,
    "fecha": "2026-03-01T15:00:00.000Z",
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
