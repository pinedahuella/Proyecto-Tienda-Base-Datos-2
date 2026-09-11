# Pendiente: valores y eventos de características en la carga a MongoDB

Este archivo no es una propuesta ni una decisión de diseño: es un registro de
que la carga actual de datos (seed / migraciones + ETL) no hace lo que
[Elementos Documentales/productos_subproductos.md](../Elementos%20Documentales/productos_subproductos.md)
y [Elementos Documentales/ejemplos_bson_productos.md](../Elementos%20Documentales/ejemplos_bson_productos.md)
ya dicen que debe hacer. Esos dos archivos describen la forma correcta;
este archivo dice qué falta para que la base real coincida con ellos.

Verificado consultando MongoDB directamente (no leyendo código), el
2026-08-22:

```
Tipos de valor en caracteristicas_adicionales (producto + variante, las 50 productos):
  { string: 1407 }              <- deberían ser Number/Boolean/String, según tipo_dato

Eventos de creación con caracteristicas_adicionales en "datos":   0 de 50
Eventos de modificación con caracteristicas_adicionales en "cambios": 0 de 6
```

## 1. El `valor` se está guardando siempre como texto

`productos_subproductos.md` dice que `valor` debe usar el tipo nativo de
Mongo que le corresponda según `tipo_dato` de la característica: `Number`
para `entero`/`decimal` (`16`, no `"16"`), `Boolean` para `booleano` (`true`,
no `"true"`), y `String` solo para `texto` (y cada entrada de una `lista` de
texto).

Ahora mismo el ETL copia literalmente la columna `producto_caracteristica.valor`
(que en PostgreSQL sí es `text` para las cuatro clases de dato a la vez, sin
excepción) tal cual a Mongo, sin convertirla según el `tipo_dato` de la
definición. Por eso los 1407 valores de característica que existen hoy en la
base son `string`, sin ninguno de otro tipo — incluyendo `Nucleos: "10"`,
`Frecuencia: "4.40"` y `Garantia: "true"`.

**Dónde se arregla:** en el ETL (`etl/`), en el paso que arma cada entrada de
`caracteristicas_adicionales`: antes de escribir `valor`, tiene que mirar el
`tipo_dato` de esa característica (viene de `caracteristica` /
`caracteristica_variante` en PostgreSQL) y convertir el texto al tipo real
correspondiente.

## 2. Los eventos no traen características

Ningún evento de `productos_eventos` — ni los 50 de creación, ni los 6 de
modificación que existen — trae `caracteristicas_adicionales`, ni en `datos`
ni en `cambios`. `ejemplos_bson_productos.md` ya explica que esto no es a
propósito: una característica cambia y se guarda igual que `nombre`,
`categoria` o `variantes`, así que debería:

- Salir completa dentro de `datos` en el evento de creación.
- Salir completa dentro de `cambios` en cualquier evento de modificación
  donde haya cambiado algo de las características (el array entero, no solo
  la entrada que cambió — mismo criterio que ya se usa para `categoria` y
  `variantes`).

**Dónde se arregla, y en qué orden:**

1. **Migraciones.** `004_caracteristicas.sql` no tiene un historial para
   `producto_caracteristica` ni para `producto_variante_caracteristica_variante`
   (a diferencia de `productos_historial`, `productos_variantes_historial` y
   `categorias_historial`, que sí existen en `003_productos.sql`). Sin ese
   historial no hay de dónde sacar "qué decía esta característica el 20 de
   febrero": hace falta agregarlo antes de que el ETL pueda construir el
   evento.
2. **Seed / datos de prueba.** Los conjuntos de `migrations/datos/` tendrían
   que dejar también una fila en ese historial nuevo al crear o modificar
   una característica de prueba, igual que ya hacen con producto, variante y
   categoría.
3. **ETL.** El paso que arma cada evento (`datos` en la creación, `cambios`
   en cada modificación) tiene que leer también el historial de
   características y agregarlas al evento, con el mismo criterio de "array
   completo" que ya usa para `categoria` y `variantes`.

## 3. Las características `lista` deberían guardarse como un array literal

Esto es distinto a los dos puntos de arriba: no es una brecha entre lo
documentado y lo cargado, es un cambio de diseño que todavía no se aplicó
en ningún lado (ni en la documentación ni en la carga).

Ahora mismo (y así quedó documentado en `productos_subproductos.md`), una
característica `lista` se representa como **varias entradas repetidas**,
una por cada valor, todas con el mismo `nombre`:

```json
{ "nombre": "Contenido del paquete", "valor": "Laptop",   "unidad": null },
{ "nombre": "Contenido del paquete", "valor": "Cargador", "unidad": null },
{ "nombre": "Contenido del paquete", "valor": "Manual",   "unidad": null }
```

Eso es un calco directo de cómo vive en PostgreSQL (varias filas de
`producto_caracteristica` con el mismo `id_producto` e `id_caracteristica`,
por la regla de normalización 1FN: una columna no puede guardar varios
valores). Pero esa regla es de SQL, no de Mongo — un documento sí puede
tener un campo que sea un array de verdad. El cambio pendiente: que una
característica `lista` sea **una sola entrada, con `valor` como un array de
palabras (strings)**:

```json
{ "nombre": "Contenido del paquete", "valor": ["Laptop", "Cargador", "Manual"], "unidad": null }
```

**Dónde se arregla:** en el ETL, en el mismo paso que arma cada entrada de
`caracteristicas_adicionales` — para las características cuyo `tipo_dato`
sea `lista`, en vez de escribir una entrada por cada fila de
`producto_caracteristica`, agrupar (`GROUP BY id_producto, id_caracteristica`)
y escribir una sola entrada con todos los valores juntos en el array.

**Impacto revisado en los filtros de `GET /productos` y `GET /productos/paginacion`:
ninguno.** Se probó insertando un documento de prueba con
`caracteristicas_adicionales` en esta forma nueva (`valor` como array) y
pidiendo `GET /productos?Contenido del paquete=Cargador`: encontró el
producto igual, sin tocar ni una línea del backend. La razón: Mongo compara
un campo array contra un valor suelto por contención (`$elemMatch: { valor: "Cargador" }`
encuentra el elemento aunque su `valor` sea `["Laptop","Cargador","Manual"]`),
así que el mismo `$elemMatch: { nombre, valor }` que ya existe sirve para
las dos formas por igual. Cuando este cambio se aplique en el ETL, no hace
falta avisar al backend ni tocar `ProductosService`.

## Qué no hay que tocar

La documentación de la forma actual (`productos_subproductos.md`,
`ejemplos_bson_productos.md`) sigue describiendo bien los puntos 1 y 2 — no
hace falta cambiarla otra vez por esos. El punto 3 sí es una forma nueva que
`productos_subproductos.md` todavía no refleja (sigue mostrando las
entradas repetidas); se actualiza ahí cuando se decida aplicar el cambio, no
antes. El backend (`ProductosService`) no necesita ningún cambio para
ninguno de los tres puntos: ya es tolerante a los tres.
