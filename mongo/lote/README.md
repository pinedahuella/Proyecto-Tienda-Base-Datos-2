# mongo/lote/

Productos que nacen **en MongoDB**, sin fila en PostgreSQL.

Esta carpeta es una subcarpeta y no `mongo/` a secas por un motivo concreto:
`arrancar.ps1` corre **todos** los `.js` de `mongo/` en cada arranque, con
`Get-ChildItem` y sin `-Recurse`. Un generador ahi se ejecutaria solo cada vez
que alguien enciende la maquina, y el catalogo creceria sin que nadie lo pidiera.

| | |
|---|---|
| `generar_lote_mongo.js` | crea N productos en MongoDB |
| `borrar_lote_mongo.js` | borra un lote por su semilla |

Los dos tienen una mitad en PostgreSQL, en `migrations/lote/`: `ofertas_mongo.sql`
y `borrar_ofertas_mongo.sql`. La razon esta abajo.

## Como se corre

```powershell
.\arrancar.ps1 -ProductosMongo 200              elige una semilla libre y te la dice
.\arrancar.ps1 -ProductosMongo 200 -Semilla 7   el mismo lote, repetible
.\arrancar.ps1 -BorrarMongo 7                   borra el lote M7 de las dos bases
```

La bandera hace las dos mitades. A mano hay que hacerlas por separado, y el
procedimiento esta al final.

## En que se diferencia de `-Productos`

No es el tamano ni la velocidad. Es el **origen**, y decide como se comporta el
producto despues:

| | `-Productos` (marcador `L`) | `-ProductosMongo` (marcador `M`) |
|---|---|---|
| Nace en | PostgreSQL | MongoDB |
| Fila en `productos` | si | **no** |
| Lo lleva a Mongo | el ETL | ya esta ahi |
| El ETL lo reescribe | en cada corrida | **nunca** |
| Reconstruible por fecha | si, con su historial | solo su evento de creacion |
| Se borra con | `-Borrar` | `-BorrarMongo` |

**El de Mongo es como nacen hoy los productos de verdad.** El backend lo dice
por escrito en `vendedores/productos.service.ts`: *"los productos ya no se
registran en PostgreSQL"*. Un vendedor que publica desde el panel crea
exactamente esto.

Hasta ahora no habia forma de tener muchos de ese tipo, y son los que mas
conviene probar: son los que el ETL no vigila.

## Por que el producto esta en Mongo y sus ofertas en PostgreSQL

Porque es el ADR-2 y esta medido. El descuento de stock tiene que ser atomico
para no vender dos veces la ultima unidad, y eso lo sostiene un
`SELECT ... FOR UPDATE` de PostgreSQL. El documento lleva cinco numeros
agregados (`precio_tienda`, `precio_desde`, `stock_tienda`, `stock_total`,
`total_ofertas`) y la bandera `hay_descuento` para que la tarjeta del
catalogo no tenga que preguntar por cada producto de la pagina, pero esos son
una **copia para pintar**. Las ofertas del lote nacen sin descuento, asi que
aqui `hay_descuento` es siempre `false` y los precios son los de lista. Cuanto
queda de verdad se pregunta en PostgreSQL.

Asi que crear uno de estos son dos escrituras en dos bases, y ningun script
habla con las dos.

### Y por eso el precio viaja en un archivo

El generador de Mongo sortea los precios, los escribe en el documento **y** los
deja en `/tmp/mesh-lote-mongo.csv`. `ofertas_mongo.sql` lee ese csv y crea las
ofertas con **esos mismos numeros**.

La alternativa era que cada lado sorteara los suyos con la misma semilla. Eso
exige dos implementaciones del mismo azar, una en JavaScript y otra en SQL, que
tienen que dar exactamente lo mismo para siempre. El dia que una cambie, el
documento diria un precio y la oferta otro, y nadie lo notaria hasta comparar
la tarjeta con la ficha.

**Un dato compartido no se puede desincronizar. Dos algoritmos si.**

El csv pasa de `mesh-mongo` a `mesh-postgres` por el host, con dos `docker cp`,
porque los contenedores no comparten sistema de archivos. Es el mismo camino
que ya usa `Correr-Etl` con `mesh-productos.json`.

## Los ids, que es lo que hay que no equivocar

El generador **no** empieza en el mayor `_id` de Mongo mas uno. Empieza despues
del mayor de **las dos bases**, y el de PostgreSQL le llega por parametro
porque desde Mongo no se puede ver.

No es prudencia. Hay dos repartidores de id que no se hablan:

```
PostgreSQL   productos.id_producto es un bigserial, con su propia cuenta
el panel     lee el mayor _id de Mongo y le suma uno
```

Ya divergieron una vez: Mongo tenia los `_id` 103 a 106 de productos del panel
y la secuencia de PostgreSQL seguia en 102, a punto de entregar el 103. Si eso
hubiera pasado, el ETL habria hecho `replaceOne` sobre ese `_id` y habria
**machacado** al producto del panel, sin un solo error: `etl/cargar.js` no
tiene barrido ni aviso para `db.productos`.

Un producto creado aqui con un id que PostgreSQL todavia puede repartir es una
bomba con temporizador: no falla hoy, falla la proxima vez que corra el ETL.

## La semilla

Misma semilla, mismo lote. Sin `-Semilla`, el generador **elige una libre y la
imprime**:

```
Sin -Semilla: se usa la 3, que esta libre
Para volver a generar ESTE mismo lote:  .\arrancar.ps1 -ProductosMongo 200 -Semilla 3
```

La eleccion la hace el propio script y no `arrancar.ps1`, porque el dato que hay
que mirar son los nombres de los productos de MongoDB y el unico que los ve es
el script.

El azar lleva la semilla mezclada con una constante para que el lote `M7` y el
lote `L7` **no** salgan iguales. Comparten el numero que se teclea, pero son
catalogos distintos y verlos identicos haria pensar que uno piso al otro.

## Por que no hay un "borra todos"

`-Borrar todos` existe para los lotes de PostgreSQL porque ahi la pregunta
tiene respuesta exacta: o hay fila en `productos` o no la hay.

Aqui no. Un producto de lote y uno que publico una persona de verdad desde el
panel viven los dos solo en Mongo, tienen la misma forma, y lo unico que los
separa es el marcador del nombre, que alguien puede haber editado.

Asi que se borra **un lote nombrado**, que es una peticion concreta, y no "todo
lo que parezca generado", que es una suposicion sobre el trabajo de otra
persona.

Del borrado se salta una oferta si tiene ventas detras, por lo mismo que en
`borrar_lote.sql`: `pedido_producto` la sujeta con `ON DELETE RESTRICT` y un
pedido sin lineas miente sobre lo que se vendio. Y hay que saber la
consecuencia: esa oferta queda apuntando a un documento que ya no existe,
porque el paso de Mongo corre primero. Es feo, y la alternativa era borrarle el
pedido a alguien.

## A mano, sin `arrancar.ps1`

Crear:

```bash
export MSYS_NO_PATHCONV=1

MAXP=$(docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> -qtAX \
  -c "SELECT coalesce(max(id_producto),0) FROM productos;")
MAXV=$(docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> -qtAX \
  -c "SELECT coalesce(max(id_producto_variante),0) FROM productos_variantes;")

docker cp mongo/lote/generar_lote_mongo.js mesh-mongo:/tmp/g.js
docker exec -e LOTE_PRODUCTOS=50 -e LOTE_SEMILLA=7 \
            -e LOTE_MAX_PG_PRODUCTO=$MAXP -e LOTE_MAX_PG_VARIANTE=$MAXV \
  mesh-mongo mongosh --quiet -u <MONGO_USER> -p <MONGO_PASSWORD> \
  --authenticationDatabase admin <MONGO_DB> --file /tmp/g.js

docker cp mesh-mongo:/tmp/mesh-lote-mongo.csv /tmp/c.csv
docker cp /tmp/c.csv mesh-postgres:/tmp/mesh-lote-mongo.csv
docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> \
  -v ON_ERROR_STOP=1 -f /migrations/lote/ofertas_mongo.sql
```

Borrar es lo mismo con `borrar_lote_mongo.js` (solo `LOTE_SEMILLA`), pasando
`/tmp/mesh-lote-mongo-borrados.csv` y corriendo
`/migrations/lote/borrar_ofertas_mongo.sql`.

**Si se corre solo la primera mitad**, los productos quedan en el catalogo sin
ofertas: sin precio y sin stock. Se arregla corriendo la segunda, o borrando el
lote entero.
