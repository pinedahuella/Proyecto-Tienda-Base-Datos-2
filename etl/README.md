# ETL de productos

Pasa el catalogo de PostgreSQL a MongoDB.

```
extraer.sql             saca el JSON de cada producto
extraer_categorias.sql  saca la paleta de cada categoria
cargar.js               arma los documentos y los escribe en Mongo
reconstruir.js          que decia un producto tal dia
correr.sh               todo lo anterior, uno detras del otro
```

No hay nada que instalar. PostgreSQL arma el JSON solo con `jsonb_build_object`,
y `mongosh`, que ya viene en el contenedor de Mongo, corre el JavaScript.

## Como se corre

Lo normal es no correrlo a mano: `.rrancar.ps1` lo hace solo cuando detecta que
Mongo esta desfasado, y `.rrancar.ps1 -Etl` lo fuerza. Esa es la via recomendada
en Windows y **no necesita Git Bash**.

```powershell
.rrancar.ps1 -Etl
```

`arrancar.ps1` no llama a este `correr.sh`: hace los mismos pasos en PowerShell
con `docker cp`. El motivo es que antes SI lo llamaba, a traves del bash de Git,
y cuando no lo encontraba **se saltaba el ETL con un aviso y el script terminaba
en verde**: los productos quedaban en PostgreSQL pero el catalogo de Mongo vacio,
que es de donde los lee la tienda. Paso de verdad, en la maquina de un companero.

El script de abajo sigue aqui para quien trabaje en Linux, en macOS, o prefiera
bash:

```bash
bash etl/correr.sh
```

Va por tuberia (`psql ... | docker exec -i mongo ...`), y eso es justo lo que no
se puede hacer desde PowerShell 5.1: le pega un BOM (`EF BB BF`) al principio de
lo que manda, y del otro lado el SQL y el JavaScript llegan rotos. Por eso la
version de PowerShell mueve archivos con `docker cp`, que copia los bytes tal
cual.

Las dos formas imprimen cuantos productos, categorias y eventos escribio.

## Que escribe

Tres colecciones. **Las ofertas no**: ver mas abajo.

**`productos`**, un documento por producto. El `_id` es el `id_producto` del
relacional, no un ObjectId: asi la traza entre los dos sistemas es directa y
volver a correr el ETL actualiza el mismo documento.

Van embebidas la categoria, las variantes, las imagenes de cada variante y las
caracteristicas. Las cuatro cumplen lo mismo: se leen siempre junto con el
producto, son pocos campos y cambian poco. Las imagenes cuelgan de la variante,
no del producto, y por eso van adentro de cada una; el `numero_orden` se gasta
al ordenarlas, porque en un arreglo la posicion ya es el orden.

**NO va el vendedor, ni el precio, ni el stock por vendedor.** Dejaron de ser
del producto al volverse multi-vendedor: son de cada oferta. Lo unico que queda
de ellas son cinco numeros calculados, que son los que la LISTA del catalogo
necesita en cada tarjeta:

| Campo | Que es |
|---|---|
| `precio_tienda` | el precio de la tienda, que es el que se ensena |
| `precio_desde` | el mas barato al que se ofrece, de cualquier vendedor |
| `stock_tienda` | unidades de la tienda |
| `stock_total` | unidades entre todos los vendedores activos |
| `total_ofertas` | cuantos vendedores lo tienen activo |

Los tres primeros estan tambien dentro de cada variante. **En el padre los dos
de stock son SUMAS** de sus variantes, porque la tarjeta ensena un producto y no
una variante. Y los dos cuentan **solo ofertas activas**: una pausada tiene
unidades y no se puede comprar.

Son una **copia** y hay que recalcularlos cuando una oferta cambie de precio, se
quede sin unidades o se pause. Si no, la tarjeta dice un precio y la ficha otro.

**Las caracteristicas** van en `caracteristicas_adicionales`, en la raiz del
producto y en cada variante, como un arreglo de `{ nombre, valor, unidad }`. Tres
reglas al escribirlas:

- **El valor sale con su tipo**, no como texto. En PostgreSQL la columna es
  `text` para los cuatro tipos a la vez, porque una sola tabla no puede tener una
  columna por tipo; pero esa es una atadura de SQL y Mongo no la hereda. Se
  convierte aqui, una vez, segun el `tipo_dato` de la definicion: `entero` y
  `decimal` a numero, `booleano` a booleano.
- **Una caracteristica de tipo `lista` es UNA entrada con un arreglo adentro**,
  no cinco entradas repetidas. Las filas repetidas son como vive en el relacional
  por la 1FN; un documento si puede guardar varios valores en un campo.
- **La unidad se copia de la definicion.** En el relacional se dice una vez que
  la RAM se mide en GB; aqui se pone en cada entrada para que quien lea el
  documento no tenga que ir a buscarla.

**Las ofertas NO viajan a Mongo**, y es LA decision de modelado de esta entrega.

Se quedan en `oferta`, en PostgreSQL. El motivo no es el tamano -- un documento
aguanta 16 MB y ningun producto va a tener tantos vendedores. Son dos:

- **Precio, stock y estado cambian en cada venta.** Copiarlos aqui obligaria a
  sostenerlos al dia en dos bases a la vez, y ese es justo el riesgo de
  inconsistencia que el proyecto entero quiere evitar. Ademas PostgreSQL es
  donde se decide si alcanza para vender, dentro de la transaccion: tener una
  segunda copia que se puede desfasar solo agrega formas de mentir.
- **Embeberlas dentro del producto seria peor todavia.** Mongo reescribe el
  documento entero en cada actualizacion, asi que comprar una camisa
  reescribiria su catalogo completo -- variantes, caracteristicas, imagenes --
  y dos vendedores vendiendo a la vez pelearian por el mismo documento, que es
  lo contrario de lo que pide la Entrega 2.

Lo que si viaja son los cuatro numeros AGREGADOS de arriba. Esos tambien son
copias, pero de un dato agregado y para pintar una tarjeta: si quedan viejos la
lista miente un rato, no se vende de mas.

La ficha del producto, que si necesita las ofertas de verdad (quien vende, a
como, cuantas quedan), las pide a PostgreSQL con una consulta directa.

Las resenas tampoco se embeben. Crecen sin techo, se escriben por su cuenta y se
leen paginadas.

**`categorias`**, un documento por categoria: que caracteristicas ofrece, con su
tipo y su unidad. Es la paleta del formulario de publicar y no guarda valores. La
categoria propone, el producto dispone.

**`productos_eventos`**, el historial. Un documento por evento.

```
{ _id: "1-3", id_producto: 1, numero: 3, operacion: "modificacion",
  fecha: ISODate("2026-02-10T20:00:00Z"),
  cambios: { nombre: "Camisa de lino manga larga" } }
```

El primero es la creacion y lleva el estado completo en `datos`. Los que siguen
son modificaciones y llevan en `cambios` solo lo que cambio.

**Ni el stock ni el precio entran en los eventos**, a proposito. Los eventos
existen para reconstruir el CATALOGO, y ninguno de los dos es del catalogo: son
de la oferta. Ademas cambian con cada venta y llenarian la coleccion de ruido,
haciendo lenta la reconstruccion, que los fusiona todos.

Sus historiales ya viven en PostgreSQL y con mas detalle: `stock_movimiento`
(con motivo, usuario y pedido) y `precio_historial` (con quien lo cambio).

Consecuencia, y hay que decirla en el informe: reconstruir un producto a una
fecha pasada devuelve su nombre, su descripcion, su categoria y sus variantes,
pero **no un precio**, porque un producto ya no tiene uno: tiene tantos como
vendedores.

**Las caracteristicas si entran, pero solo en la creacion.** No tienen historial
en el relacional, asi que el ETL solo conoce las de hoy: las escribe iguales en
todas las fotos que arma y por eso salen enteras en el evento de creacion y
nunca como un cambio.

## De fotos a eventos

En el relacional cada fila de historial es una foto completa de esa entidad en
esa fecha, que es lo natural en SQL. Aqui hace falta lo contrario, y ademas son
**dos** historiales que corren por separado: el del producto y el de cada
variante. Renombrar el producto no escribe nada en el historial de sus
variantes.

(Antes eran tres. El tercero era el de la categoria, que existia solo para
congelar la comision del dia de la venta; la comision salio del alcance y la
tabla se fue con ella. En su lugar, cada fila del historial del producto dice en
que categoria estaba ese dia, que ademas arregla un hueco viejo: antes, mover un
producto de categoria reescribia su pasado.)

El ETL junta las fechas de las dos tablas, y en cada fecha vuelve a armar el
estado completo del producto con la fila mas reciente de cada historial. La
primera fecha es la creacion; cada una despues se compara contra la anterior y
solo se guarda lo que difiere.

La comparacion es por campo de primer nivel. Cuando algo de la categoria cambia
se guarda la categoria entera, y cuando algo de una variante cambia se guarda el
arreglo de variantes entero. Es a proposito: la reconstruccion junta los eventos
con `$mergeObjects`, que mezcla superficial, y media categoria borraria la otra
mitad al mezclarse.

Los eventos **no llevan el estado** del producto (activo, inactivo). En el
modelo relacional los historiales no lo guardan: vive solo en la fila viva, y
esta explicado en `docs/base-de-datos.md`.

Lo que se reconstruye es **nombre, descripcion, categoria y variantes**. El
precio no, y no es un olvido: dejo de ser del producto al volverse
multi-vendedor.

## Reconstruir

```bash
docker exec -i mesh-mongo sh -c 'cat > /tmp/reconstruir.js' < etl/reconstruir.js
docker exec mesh-mongo sh -c 'mongosh --quiet     -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD"     --authenticationDatabase admin "$MONGO_INITDB_DATABASE"     --eval "var producto = 19, corte = \"2026-06-01\""     --file /tmp/reconstruir.js'
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
guarda solo los campos que ella toco, asi que quedarse con la ultima pierde
todas las anteriores.

Con los datos que carga el conjunto se ve en el producto 19, la camisa de lino,
que tiene cuatro eventos:

```
#1  12 ene  creacion       nombre "Camisa de lino", descripcion "...de corte regular."
#2   4 mar  modificacion   solo la descripcion: "Lino lavado ... con cuello italiano."
#3  12 mar  modificacion   solo las variantes: se renombro "Mediana azul" a "M azul"
#4   4 may  modificacion   solo el nombre: "Camisa de lino manga larga"
```

Al 1 de junio:

```
creacion + TODAS en orden      Camisa de lino manga larga | Lino lavado ... cuello italiano
creacion + solo la ultima      Camisa de lino manga larga | Camisa de lino de corte regular
                               (mal: se perdio el cambio de descripcion del 4 de marzo)
```

`$mergeObjects` es lo que aplica todas en orden: toma el valor del ultimo evento
que traiga el campo y deja intactos los que nadie volvio a tocar.

### Y el otro producto, el que cambio de categoria

El balon de futbol nacio mal clasificado, en Fitness, y se movio a Futbol en
abril. Es el caso que justifica `id_categoria` en `productos_historial`:

```
reconstruido al 1 de mayo    categoria: Fitness
reconstruido al 20 de agosto categoria: Futbol
```

Sin esa columna las dos dirian Futbol, porque el historial no sabria en que
categoria estaba el producto ese dia.

### El precio y la disponibilidad se preguntan del otro lado

```sql
-- a como estaba esta oferta el 3 de marzo
SELECT precio FROM precio_historial
WHERE id_oferta = 42 AND fecha_creacion <= '2026-03-03'
ORDER BY fecha_creacion DESC LIMIT 1;

-- cuantas unidades habia ese dia
SELECT stock_resultante FROM stock_movimiento
WHERE id_oferta = 42 AND fecha_movimiento <= '2026-03-03'
ORDER BY fecha_movimiento DESC LIMIT 1;
```

## Los indices

Los crea `mongo/001_productos.js`, no el ETL: son parte de la forma de la base y
no de la carga, igual que un `CREATE INDEX` vive en la migracion y no en el
`INSERT`.

```js
db.productos.createIndex({ 'categoria.id_categoria': 1, estado: 1, _id: 1 }, { name: 'catalogo_categoria' })
db.productos.createIndex({ estado: 1, precio_desde: 1 },                     { name: 'catalogo_precio' })
db.productos_eventos.createIndex({ id_producto: 1, fecha: 1 },               { name: 'eventos_por_producto_fecha' })
db.categorias.createIndex({ nombre: 1 },                                     { name: 'categorias_por_nombre' })
```

Cada uno responde a una consulta concreta, no a la idea general de que conviene
tener indices. Los dos del catalogo salieron de MEDIR con `explain()`: se
probaron tres y solo dos se ganaron el puesto, porque un indice que nadie usa no
es gratis -- cuesta en cada escritura.

- **catalogo_categoria** "los productos de esta categoria, sin los ocultos".
  Va sobre `categoria.id_categoria` y NO sobre `categoria.nombre`, porque el
  backend filtra por id: un indice sobre el campo equivocado se ve igual de bien
  en la lista de indices y no lo usa nadie. Medido: examina 3 documentos para
  devolver 3, en vez de recorrer los 34.
- **catalogo_precio** "los productos entre tal y tal precio". Va sobre
  `precio_desde`, el mas barato que se puede PAGAR, y no sobre `precio_tienda`,
  que es el que se ENSENA. Medido: 10 claves para 10 resultados.
- **eventos_por_producto_fecha** sirve para las dos primeras etapas de la
  reconstruccion a la vez: la base entra directo al producto y lee su tramo ya
  ordenado, sin recorrer la coleccion y sin ordenar en memoria.

Una nota medida, para no prometer de mas: en `catalogo_categoria` el `_id` va al
final para que el listado salga ordenado del propio indice. Con el filtro tal
como lo manda hoy el backend eso **no** se cumple: el estado se filtra con `$nin`,
que es un rango, y detras de un rango el indice ya no sostiene el orden, asi que
`explain()` ensena un `SORT` en memoria. Con el tamano actual del catalogo da
igual; se arreglaria filtrando el estado por igualdad.

## El ETL solo manda sobre su tramo

Borra de Mongo lo que ya no esta en PostgreSQL -- hace falta, porque si no un
documento cuyo `_id` ya no existe del otro lado se queda ahi para siempre.

Pero **no todo lo de estas colecciones sale de PostgreSQL**. Un producto que
publica un vendedor nace solo en Mongo y no tiene fila en el relacional: si se
borrara "todo lo que no esta alla", la primera corrida se llevaria lo que la
gente publico. Paso de verdad en pruebas: dos productos publicados desde el panel
desaparecieron al correr el ETL.

Por eso el borrado va acotado del 1 al id mas alto que trajo de PostgreSQL. Lo de
mas arriba lo creo la aplicacion y el ETL no entra ahi ni para borrar ni para
escribir -- ni siquiera para ponerle el stock, que en esos productos lo tiene que
escribir la aplicacion.

`arrancar.ps1` compara el id mas alto **dentro de ese tramo** por lo mismo: si
mirara el maximo absoluto, un producto de vendedor lo haria creerse desfasado y
volveria a migrar en cada arranque.

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
