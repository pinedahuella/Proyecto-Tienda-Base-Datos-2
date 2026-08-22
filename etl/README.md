# ETL de productos

Pasa el catalogo de PostgreSQL a MongoDB.

```
extraer.sql      la consulta que saca el JSON de PostgreSQL
cargar.js        arma los documentos y los escribe en Mongo
reconstruir.js   que decia un producto tal dia
correr.sh        los dos primeros, uno detras del otro
```

No hay nada que instalar. PostgreSQL arma el JSON solo con `jsonb_build_object`,
y `mongosh`, que ya viene en el contenedor de Mongo, corre el JavaScript.

## Como se corre

Desde Git Bash, no desde PowerShell: PowerShell se come las comillas al llamar a
docker y la consulta llega partida.

```bash
bash etl/correr.sh
```

Imprime cuantos productos y cuantos eventos escribio.

## Que escribe

Dos colecciones.

**`productos`**, un documento por producto. El `_id` es el `id_producto` del
relacional, no un ObjectId: asi la traza entre los dos sistemas es directa y
volver a correr el ETL actualiza el mismo documento.

Van embebidos la categoria, las variantes, las imagenes de cada variante y el
vendedor. Los tres cumplen lo mismo: se leen siempre junto con el producto, son
pocos campos y cambian poco. Las imagenes cuelgan de la variante, no del
producto, y por eso van adentro de cada una; el `numero_orden` se gasta al
ordenarlas, porque en un arreglo la posicion ya es el orden.

Las resenas no se embeben. Crecen sin techo, se escriben por su cuenta y se leen
paginadas: se quedan en PostgreSQL.

**`productos_eventos`**, el historial. Un documento por evento.

```
{ _id: "1-3", id_producto: 1, numero: 3, operacion: "modificacion",
  fecha: ISODate("2026-02-10T20:00:00Z"),
  cambios: { nombre: "Camisa de lino manga larga" } }
```

El primero es la creacion y lleva el estado completo en `datos`. Los que siguen
son modificaciones y llevan en `cambios` solo lo que cambio.

## De fotos a eventos

En el relacional cada fila de historial es una foto completa de esa entidad en
esa fecha, que es lo natural en SQL. Aqui hace falta lo contrario, y ademas son
tres historiales que corren por separado: el del producto, el de cada variante y
el de la categoria. Subir la comision no escribe nada en el historial del
producto.

El ETL junta las fechas de las tres tablas, y en cada fecha vuelve a armar el
estado completo del producto con la fila mas reciente de cada historial. La
primera fecha es la creacion; cada una despues se compara contra la anterior y
solo se guarda lo que difiere.

La comparacion es por campo de primer nivel. Cuando algo de la categoria cambia
se guarda la categoria entera, y cuando algo de una variante cambia se guarda el
arreglo de variantes entero. Es a proposito: la reconstruccion junta los eventos
con `$mergeObjects`, que mezcla superficial, y media categoria borraria la otra
mitad al mezclarse.

Las fechas de la categoria anteriores al nacimiento del producto se descartan. La
categoria casi siempre es mas vieja y ya cambio de comision antes de que el
producto existiera; contarlas deja un primer evento con el nombre en null.

Los eventos no llevan el estado del producto (activo, agotado). En el modelo
relacional los historiales no lo guardan: vive solo en la fila viva, y esta
explicado en `docs/base-de-datos.md`. Lo que se reconstruye es nombre,
descripcion, precio y comision.

## Reconstruir

```bash
docker exec -i mesh-mongo sh -c 'cat > /tmp/reconstruir.js' < etl/reconstruir.js
docker exec mesh-mongo sh -c 'mongosh --quiet \
    -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin "$MONGO_INITDB_DATABASE" \
    --eval "var producto = 1, corte = \"2026-03-15\"" \
    --file /tmp/reconstruir.js'
```

La consulta es esta:

```js
db.productos_eventos.aggregate([
    { $match: { id_producto: id, fecha: { $lte: fecha } } },
    { $sort:  { fecha: 1 } },
    { $replaceWith: { $ifNull: ['$datos', '$cambios'] } },
    { $group: { _id: null, estado: { $mergeObjects: '$$ROOT' } } },
    { $replaceWith: '$estado' }
]);
```

Reconstruir **no** es la creacion mas la ultima modificacion. Cada modificacion
guarda solo los campos que ella toco, asi que quedarse con la ultima pierde todas
las anteriores. Con los datos de prueba se ve al 15 de marzo: el nombre cambio el
10 de febrero y la comision el 1 de marzo.

```
creacion + TODAS en orden         Camisa de lino manga larga | comision 12.00
creacion + solo la ultima (mal)   Camisa de lino             | comision 12.00
```

`$mergeObjects` es lo que aplica todas en orden: toma el valor del ultimo evento
que traiga el campo y deja intactos los que nadie volvio a tocar.

## El indice

```js
db.productos_eventos.createIndex({ id_producto: 1, fecha: 1 });
```

Lo crea `cargar.js`. Sirve para las dos primeras etapas de la reconstruccion a la
vez: la base entra directo al producto y lee su tramo de eventos ya ordenado, sin
recorrer la coleccion y sin ordenar en memoria.

## Por que correrlo dos veces no duplica

Los `_id` no los genera Mongo, se calculan: `id_producto` para el producto y
`id_producto-numero` para cada evento. La escritura es `replaceOne` con
`upsert: true`, asi que el mismo `_id` cae siempre en el mismo documento.

Se reemplaza el documento entero y no se hace `$set` de unos campos: el documento
se deriva completo de PostgreSQL, y un campo que ya no exista alla tampoco debe
quedar aqui. Eso tambien quiere decir que el ETL es el unico dueno de estas dos
colecciones. Lo que la aplicacion escriba por su cuenta en ellas se pierde en la
siguiente corrida.

Si el historial encoge, porque se corrigio una fila mal fechada, los eventos
sobrantes de la corrida anterior se borran por numero. Lo que no se borra es un
producto que desaparezca de PostgreSQL, y no hace falta: en el modelo los
productos no se borran, se les pone estado inactivo.
