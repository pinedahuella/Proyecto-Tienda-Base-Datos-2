# Cambio: `pendiente_busqueda` -- el primer paso para que el buscador se mantenga solo

**Fecha:** 2026-09-04, noche.
**Alcance:** solo `backend/`. No toca `mongo/`, `etl/` ni `elastic/`.
**Es el PASO 1 de dos.** Lo que falta despues de esto -- el worker que lea
la bandera y reindexe, y el indice parcial de Mongo sobre ella -- se explica
al final, con lo que le toca a cada quien.

## El problema

El buscador de la Entrega 3 (Elasticsearch, indice `mesh_productos`) hoy
solo se carga con `etl/cargar_busqueda.sh`, que **reconstruye el indice
entero** desde el catalogo de Mongo cada vez que se corre. Un producto que
se crea o se edita desde el panel del vendedor queda invisible para el
buscador hasta la proxima corrida manual del ETL -- exactamente el mismo
agujero que ya tenia `resenas_promedio` antes de que se le agregara su
tercera etapa (ver `docs/PENDIENTES.md`, punto 6).

## Por que no es un outbox como el del grafo

El outbox de Neo4j (`evento_grafo` + trigger, `migrations/015_outbox_grafo.sql`)
funciona porque la reseña se escribe en **PostgreSQL**, y ahi un trigger
puede encolar el evento **en la misma transaccion** que el dato. Un producto
nuevo o editado, en cambio, **no toca PostgreSQL en absoluto**: nace y se
edita directo en `db.productos` de MongoDB, dentro del propio codigo del
backend. No hay tabla ni trigger de Postgres donde enganchar nada.

## Por que tampoco Change Streams de Mongo

Es la alternativa nativa de Mongo a un trigger (se suscribe al oplog de la
coleccion), pero **exige que Mongo corra como replica set**. `mesh-mongo`
hoy es standalone (`docker-compose.yml`, imagen `mongo:8`, sin `--replSet`
en ningun lado) -- contra un standalone, `$changeStream` tira
`"is only supported on replica sets"`. Convertirlo a un replica set de un
solo nodo es un cambio de infraestructura fuera de `backend/`.

Por la misma razon tampoco sirven las transacciones multi-documento de
Mongo (tambien exigen replica set): no hay forma de que "crear el producto"
y "encolar el aviso" sean una sola operacion atomica sin tocar
infraestructura.

## El diseño elegido: una bandera "cola sin cola"

En vez de una tabla o coleccion de pendientes aparte, **el propio documento
se marca**. Un campo nuevo, `pendiente_busqueda`, con una regla que lo hace
mucho mas barato que un booleano cualquiera:

- **Solo EXISTE cuando hace falta reindexar. Nunca vale `false`** -- cuando
  ya no hace falta, se le hace `$unset`, no se pone en `false`. "Existe y es
  `true`" y "no existe" son la misma pregunta, y como en cualquier momento
  la inmensa mayoria del catalogo va a estar ya sincronizado, el campo
  **no aparece casi en ningun documento**.
- Es atomico de verdad para el ALTA: va **dentro del mismo `insertOne`/
  `updateOne`** que ya cambia el producto, nunca en una escritura aparte.
  MongoDB garantiza la atomicidad de un documento sola, sin necesitar
  replica set para eso.
- La unica ventana que queda abierta es al FINAL, cuando el futuro worker
  termine de reindexar y le quite la bandera: si el proceso se cae justo
  ahi, en el peor caso se reindexa una vez de mas en la siguiente pasada.
  Nunca se pierde un cambio, que es lo que importa.

## Lo que se agrego HOY: la bandera en los 7 sitios donde se toca `productos`

Se revisaron los DOS unicos archivos del backend que escriben la coleccion
`productos` de Mongo (`grep` sobre `collection<Producto>('productos')` en
todo `src/`, sin mas resultados que estos dos) y se marco **cada** punto de
escritura, sin condicionarlo a que campo cambie -- decidir si algo afecta
al buscador es tarea del futuro worker, no de la ruta que edita:

| Archivo | Metodo | Que hace |
|---|---|---|
| `services/vendedores/productos.service.ts` | `crear()` | Nace con `pendiente_busqueda: true` |
| `services/vendedores/productos.service.ts` | `proponer()` | Igual, aunque nazca `en_revision` (no circula todavia, pero el documento cambio) |
| `services/vendedores/productos.service.ts` | `revisarPropuesta()` | Se agrega al `$set` que cambia el estado (aprobar o rechazar) |
| `services/vendedores/productos.service.ts` | `reenviarPropuesta()` | Igual, al `$set` que vuelve a `en_revision` |
| `services/vendedores/productos.service.ts` | `editar()` | El `conjuntoSet` nace **ya** con la bandera, antes de saber que campo especifico cambia |
| `services/productos/productos.service.ts` | `recalcularUnProducto()`, rama sin ofertas | Se agrega al `$set` que solo toca `resenas_promedio`/`resenas_total` |
| `services/productos/productos.service.ts` | `recalcularUnProducto()`, rama con ofertas | Se agrega al `$set` que toca precio/stock/reseñas del producto y sus variantes |

`deshacerProductoMongo()` (el `deleteOne` que compensa una propuesta cuando
falla el `INSERT` en `propuesta_producto`) **no** se toco: el documento
desaparece entero, no hay nada que marcar.

El modelo `Producto` (`src/models/producto.ts`) declara el campo como
`pendiente_busqueda?: true` -- el tipo literal `true` y no `boolean`, para
que el compilador **imponga** la regla de que nunca se escriba `false` por
accidente. Costo real: `soloResenas` en `recalcularUnProducto()` no tenia
tipo explicito y TypeScript le viuda el literal a `boolean`; se le puso
`Record<string, unknown>` (igual que ya tenia la rama de al lado) para que
la asignacion compile.

## Probado en vivo, contra el servidor y las dos bases reales

Los 6 de los 7 sitios que se pueden ejercitar sin fabricar una compra
completa se probaron con el backend corriendo de verdad (`npm run
start:dev`), como `tienda@mesh.com` y `ventas.norte@mesh.com`, limpiando la
bandera a mano entre cada paso (`$unset` por `mongosh`) para comprobar que
CADA operacion la vuelve a poner, no que ya estaba puesta de antes:

```
crear()               producto nuevo -> pendiente_busqueda: true       [OK]
editar()              se le cambia la descripcion -> vuelve a true     [OK]
proponer()            propuesta nueva (en_revision) -> true            [OK]
revisarPropuesta()    se aprueba -> estado activo, vuelve a true       [OK]
reenviarPropuesta()   se rechaza y se reenvia -> estado en_revision,
                      vuelve a true                                    [OK]
recalcularUnProducto  se le crea una oferta y se le edita el precio ->
(rama con ofertas)    precio_tienda cambia Y vuelve a true             [OK]
```

**No se probo en vivo** la rama de `recalcularUnProducto()` **sin ofertas**
(la que solo toca `resenas_promedio`/`resenas_total`): exige un producto
sin ninguna oferta que reciba una reseña, y eso pide una compra pagada real
de por medio (`exigirCompraPagada`) -- demasiado monte para esta pasada. Es
el mismo `Record<string, unknown>` con la misma linea agregada que la rama
ya probada; el riesgo de que falle es minimo, pero queda dicho para no
inflar la lista de "medido" con algo que no se midio.

Los productos y la oferta de prueba (`_id` 103, 104, 105 en Mongo; oferta
557, su `precio_historial` y sus filas de `propuesta_producto`/
`rechazo_producto` en Postgres) se borraron al terminar. `npx tsc --noEmit`
y `npx eslint` sobre los tres archivos tocados, limpios.

## Un detalle de entorno que casi se cuela

Al escribir estos cambios con el editor, los tres archivos tocados
(`producto.ts` y los dos `productos.service.ts`) **se convirtieron enteros
de LF a CRLF** -- un efecto secundario de esta maquina/herramienta, no una
decision. `git diff` no lo mostraba (probablemente por `core.autocrlf`
normalizando la comparacion), pero una lectura de los bytes crudos lo
confirmo contra `git show HEAD:...`. Se revirtieron los tres a LF puro
antes de dejarlos, que es como estaba el resto del arbol (`src/**/*.ts` es
LF en todo el repo; solo la documentacion `.md` es CRLF). Vale la pena
revisar esto mismo si alguna vez un diff de un archivo `.ts` sale
sospechosamente grande sin razon.

## Lo que falta, y de quien es cada mitad

**Del backend (mio, no escrito todavia):** el worker que consuma la
bandera -- mismo patron que `GrafoSyncService` (`@Interval`, ya en el
proyecto): cada N segundos, `db.productos.find({ pendiente_busqueda: true
})`, por cada uno decide si indexarlo en Elasticsearch (si `estado ===
'activo'`) o quitarlo del indice (si no), y al terminar le hace `$unset` a
la bandera. Se escribe cuando se pida seguir con el paso 2.

**De Mongo (del compañero, en `mongo/`):** el indice que hace que
`find({ pendiente_busqueda: true })` no recorra el catalogo entero cada
vez. Tiene que ser **parcial**, no un indice normal sobre un booleano
cualquiera -- un indice comun pagaria mantenimiento en CADA escritura a
CUALQUIER producto del catalogo, aunque casi ninguno vaya a estar
pendiente nunca. Con `partialFilterExpression`, el indice solo contiene una
entrada por cada documento que **hoy** este pendiente, y por diseño eso es
siempre un puñado, sin importar que tan grande sea el catalogo:

```js
db.productos.createIndex(
  { pendiente_busqueda: 1 },
  { partialFilterExpression: { pendiente_busqueda: true } },
);
```

Como el campo nunca vale `false` (o existe y es `true`, o no existe), la
consulta del worker (`find({ pendiente_busqueda: true })`) y el filtro del
indice piden exactamente lo mismo, que es la condicion que Mongo necesita
para poder usar un indice parcial.
