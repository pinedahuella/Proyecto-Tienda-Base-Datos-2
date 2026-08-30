# Los ETL de Mesh

Son **dos**, uno por cada base derivada. Los dos salen de PostgreSQL, que es la
unica fuente de verdad, y los dos son proyecciones: se pueden tirar enteras y
reconstruir sin perder un dato.

```
A MongoDB -- el catalogo            A Neo4j -- el grafo de resenas
-------------------------------     ---------------------------------------
extraer.sql                         extraer_grafo.sql
extraer_categorias.sql              cargar_grafo.sh
cargar.js                           (el esquema vive en neo4j/001_esquema.cypher)
reconstruir.js
correr.sh
```

**No hay nada que instalar, en ninguno de los dos.** Es la regla de esta
carpeta y se cumple igual en los dos casos: PostgreSQL arma el texto y lo carga
el cliente que ya viene DENTRO del contenedor. Para Mongo el texto es JSON
(`jsonb_build_object`) y lo carga `mongosh`; para Neo4j el texto es Cypher y lo
carga `cypher-shell`, que la imagen `neo4j:5-community` trae puesto.

Lo normal es no correr ninguno a mano: `.\arrancar.ps1` los corre solos cuando
detecta que la base derivada esta desfasada, y `.\arrancar.ps1 -Etl` fuerza
**los dos**.

- [ETL de productos: PostgreSQL a MongoDB](#etl-de-productos-postgresql-a-mongodb)
- [ETL del grafo: PostgreSQL a Neo4j](#etl-del-grafo-postgresql-a-neo4j)

---

# ETL de productos: PostgreSQL a MongoDB

Pasa el catalogo de PostgreSQL a MongoDB.

```
extraer.sql             saca el JSON de cada producto
extraer_categorias.sql  saca la paleta de cada categoria
cargar.js               arma los documentos y los escribe en Mongo
reconstruir.js          que decia un producto tal dia
correr.sh               todo lo anterior, uno detras del otro
```

## Como se corre

Lo normal es no correrlo a mano: `.\arrancar.ps1` lo hace solo cuando detecta que
Mongo esta desfasado, y `.\arrancar.ps1 -Etl` lo fuerza. Esa es la via recomendada
en Windows y **no necesita Git Bash**.

```powershell
.\arrancar.ps1 -Etl
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

Lo que si viaja son los cinco numeros AGREGADOS de arriba. Esos tambien son
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

Lo medido, con `explain("executionStats")` sobre los **105 productos** y los
**118 eventos** que hay hoy. Cada consulta se compara contra ella misma con
`hint({$natural:1})`, que es la forma de preguntarle a Mongo "y sin el
indice, cuanto?":

| Indice | Consulta | Con el indice | Sin el |
|---|---|---|---|
| `catalogo_categoria` | categoria 19, ordenado por `_id` | 6 docs, 7 claves | 105 docs |
| `catalogo_precio` | hasta Q500 | 51 docs, 53 claves | 105 docs |
| `eventos_por_producto_fecha` | eventos del producto 51 hasta el 1 de julio | 4 docs, 4 claves | 118 docs |

- **catalogo_categoria** "los productos de esta categoria, sin los ocultos".
  Va sobre `categoria.id_categoria` y NO sobre `categoria.nombre`, porque el
  backend filtra por id: un indice sobre el campo equivocado se ve igual de bien
  en la lista de indices y no lo usa nadie.
- **catalogo_precio** "los productos entre tal y tal precio". Va sobre
  `precio_desde`, el mas barato que se puede PAGAR, y no sobre `precio_tienda`,
  que es el que se ENSENA. Aqui la ganancia es menor que en el otro, y es
  esperable: un rango de precio ancho deja fuera poco, asi que el indice ahorra
  la mitad de los documentos y no el 95%. Con un rango estrecho ahorra mas.
- **eventos_por_producto_fecha** sirve para las dos primeras etapas de la
  reconstruccion a la vez: la base entra directo al producto y lee su tramo ya
  ordenado, sin recorrer la coleccion y sin ordenar en memoria. Es el que mas
  se nota: 4 documentos contra 118, y crece con cada edicion del catalogo.

Una nota que hubo que corregir: en `catalogo_categoria` el `_id` va al final para
que el listado salga ordenado del propio indice. Durante un tiempo eso **no** se
cumplia, porque el backend filtraba el estado con `$nin` -- un rango, y detras de
un rango el indice deja de sostener el orden, asi que `explain()` ensenaba un
`SORT` en memoria.

**Ya no.** El backend pasa el estado por igualdad (`$eq: 'activo'`, la lista
blanca de `ESTADO_PRODUCTO_VISIBLE`), que era justo el arreglo que esta nota
proponia, asi que el indice sostiene el orden y no hay ordenamiento en memoria.
Se deja escrito porque la version vieja de este parrafo circulo un tiempo y
conviene que quien la recuerde sepa que ya no aplica.

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

---

# ETL del grafo: PostgreSQL a Neo4j

Pasa las cuentas, las resenas y los productos calificados de PostgreSQL a Neo4j.
Es lo que sostiene la parte de la Entrega 2 que pide senalar, con una consulta de
varios saltos, un conjunto de cuentas con patron anomalo.

```
neo4j/001_esquema.cypher  restricciones e indices del grafo
extraer_grafo.sql         saca de PostgreSQL el Cypher que carga el grafo
cargar_grafo.sh           esquema + extraccion + carga, uno detras del otro
```

Las consultas de deteccion **no** viven aqui: estan en `neo4j/consultas/` y se
corren con `bash neo4j/correr_fraude.sh`; se explican en `neo4j/README.md`. Esta carpeta solo se encarga de que el grafo
exista y este al dia.

## Como se corre

Lo normal es no correrlo a mano.

```powershell
.\arrancar.ps1                  # lo corre solo si el grafo esta desfasado
.\arrancar.ps1 -Etl             # lo fuerza (y tambien fuerza el de Mongo)
.\arrancar.ps1 -ReiniciarGrafo  # borra el grafo entero y lo reconstruye
```

`arrancar.ps1` **no llama a `cargar_grafo.sh`**: hace los mismos pasos en
PowerShell con `docker cp`, exactamente por el motivo que ya esta contado mas
arriba para Mongo. Antes el ETL de Mongo si se llamaba a traves del bash de Git,
y cuando no lo encontraba **se saltaba con un aviso amarillo y el script
terminaba en verde**, con la base derivada vacia. Paso de verdad, en la maquina
de un companero.

Con el grafo eso seria peor de detectar, y conviene decir por que: el catalogo
vacio se nota el mismo dia, porque la tienda sale sin productos. Un grafo vacio
no se nota nunca -- se mira el dia de la entrega, y ese dia la consulta de
anillos contesta "no hay cuentas anomalas", que es una respuesta creible y
falsa. Por eso en `arrancar.ps1` el ETL del grafo **no tiene ni una rama que
avise y siga**: cualquier fallo suyo tumba el arranque, y al terminar se cuentan
los nodos **y las relaciones** contra PostgreSQL para comprobar el RESULTADO y no
que los pasos "parezcan" haber ido bien.

Las relaciones no estaban en esa cuenta y hacian falta: contar solo nodos **no
es** comprobar el resultado. Medido -- borrando las 272 relaciones y dejando los
163 nodos intactos, `arrancar.ps1` imprimia "Ya cargado", **saltaba el ETL**, las
tres cuentas de nodos en verde y `exit 0`, sobre un grafo donde la consulta de
varios saltos contesta "0 anillos". Y como los conteos de nodos cuadraban, el ETL
no volvia a correr en ningun arranque posterior: el hueco era permanente. Ahora
se comparan las ocho cosas (cuatro clases de nodo y cuatro relaciones), y con ese
mismo sabotaje el arranque detecta la falta, dispara el ETL y lo repara solo.

Para quien trabaje en Linux, en macOS o prefiera bash:

```bash
./etl/cargar_grafo.sh                 # carga sobre lo que haya
./etl/cargar_grafo.sh --limpiar       # borra el grafo entero y lo reconstruye
./etl/cargar_grafo.sh prueba_tuyo     # extrae de otra base de PostgreSQL
```

### La trampa de Git Bash, esquivada dos veces distintas

Git Bash sobre Windows convierte las rutas que empiezan con `/` cuando se las
pasa a `docker`. Un `cypher-shell --file /neo4j/001_esquema.cypher` no busca el
archivo dentro del contenedor: busca `C:/Program Files/Git/neo4j/...` y falla con
un "No such file or directory" que ni menciona a Docker. El parche conocido es
`export MSYS_NO_PATHCONV=1`.

Los dos caminos la esquivan, y cada uno a su manera:

- **`cargar_grafo.sh`** manda TODO por la entrada estandar y no escribe ni una
  ruta absoluta de contenedor, asi que no necesita el parche. De paso deja de
  depender de que `./neo4j` este montado dentro de `mesh-neo4j`.
- **`arrancar.ps1`** no pasa por Git Bash, asi que la trampa no existe; usa
  `docker cp` por el motivo contrario, que es el de PowerShell 5.1: lo que manda
  por tuberia sale con un BOM (`EF BB BF`) pegado al principio y del otro lado el
  SQL y el Cypher llegan rotos. `docker cp` mueve los bytes tal cual.

Tampoco lee del volumen `./neo4j` que el compose monta en el contenedor: copia
los dos archivos con `docker cp`. Es la misma decision que tomo `cargar_grafo.sh`
-- si alguien toca ese montaje en `docker-compose.yml`, el ETL sigue cargando en
vez de fallar por un archivo que "estaba ahi".

## Que escribe

Cuatro clases de nodo y cuatro relaciones. Los numeros son los medidos hoy:

```
Usuario   10     (a)-[:ESCRIBIO]->(r)      86
Producto  54     (r)-[:CALIFICA_A]->(v)    86
Resena    86     (r)-[:SOBRE]->(p)         86
Direccion 12     (u)-[:VIVE_EN]->(d)       14
```

El `id` de `:Usuario`, `:Resena` y `:Producto` es **el mismo de PostgreSQL**
(`usuarios.id_usuario`, `resena.id_resena`, `productos.id_producto`). No se
inventa uno nuevo: si el grafo tuviera identidad propia, volver del grafo a la
fila que lo origino -- que es lo primero que hace alguien cuando la consulta
senala una cuenta -- pediria una tabla de equivalencias que nadie va a mantener.

Tres cosas de esos numeros no cuadran con un `count(*)`, y las tres son a
proposito:

- **54 productos y no 102.** Solo viajan los que tienen al menos una resena. Un
  producto que nadie califico no es alcanzable por ningun camino del modelo:
  seria un nodo suelto que engorda el grafo y no aparece en ninguna consulta.

  **La lista sale de `resena`, no de `productos`,** y la diferencia importa:
  `resena.id_producto_mongo` no tiene llave foranea, porque el catalogo vive en
  MongoDB. Un producto que publica un vendedor existe en Mongo y **no** tiene
  fila en `productos` -- hoy hay tres asi con ofertas vivas. Con la version
  anterior, que partia de `productos`, una resena sobre uno de ellos se perdia
  **en silencio**: el nodo no se emitia, el `MATCH` de la sentencia 5 no lo
  encontraba y la fila entera se descartaba sin error. Medido dentro de un
  `BEGIN`/`ROLLBACK`: el Cypher salia con 87 resenas y 54 productos, y el grafo
  quedaba con 86 `:Resena`, con `cypher-shell` terminando en exito y sin una
  advertencia. Y era justo donde un anillo opera -- publica su propio producto y
  se resena encima. Cuando el producto solo vive en Mongo, el nodo lleva un
  nombre de relleno que lo dice.
- **10 usuarios, incluso los que no escribieron nada.** Al reves que con los
  productos, aqui si van todos: una cuenta sin resenas puede compartir direccion
  con otra, y eso ya es una senal.
- **12 direcciones de 16 filas, con 14 relaciones.** El ETL deduplica por el
  TEXTO normalizado (minusculas, sin tildes, espacios colapsados) y no por
  `id_direccion`. Esa resta ES la senal: si la identidad fuera el id, dos cuentas
  que viven en la misma casa serian dos nodos distintos y "comparten direccion"
  no existiria como camino. En los datos de hoy la misma casa de Antigua esta
  cargada tres veces, escrita distinto cada vez.

La normalizacion quita las tildes con `translate()` y `chr(225)||chr(233)||...`,
no con `unaccent()`. `unaccent` es una extension, o sea una dependencia nueva; y
las letras acentuadas escritas a la vista romperian la regla de ASCII puro del
proyecto -- un `.sql` con acentos que pase por la consola de Windows se reguarda
en otra codificacion y el `translate` deja de coincidir **en silencio**: no da
error, solo deja de normalizar, y la senal desaparece sin que nadie se entere.

### La direccion es un NODO y no una propiedad

Es la unica decision de modelado que el encargo dejaba abierta. Se eligio nodo
por dos razones: una cuenta tiene VARIAS direcciones (una tiene seis), y sobre
todo porque la senal es el **vecino compartido**. Con la direccion como nodo,
"estas dos cuentas viven en la misma casa" es literalmente un camino de dos
saltos:

```cypher
(a:Usuario)-[:VIVE_EN]->(:Direccion)<-[:VIVE_EN]-(b:Usuario)
```

Con la direccion como propiedad habria que comparar el texto de todas contra
todas, que es exactamente el trabajo que el grafo existe para no hacer.

### La fecha de la resena no esta en `resena`

`resena` no guarda fecha. La del grafo sale de `comentario.fecha_publicacion`,
por el `id_comentario` de la raiz de esa resena. Sin ese JOIN no hay consulta de
rafagas ("tres o mas calificaciones a la misma cuenta en 72 horas"), que es una
de las cuatro senales de `neo4j/consultas/A3_rafaga.cypher`. Esta anotado como trampa dentro de
`extraer_grafo.sql` porque es facil escribir el ETL sin fecha y no notarlo: el
grafo carga igual y solo esa consulta se queda muda.

### Lo que NO va al grafo, dicho para que nadie lo suponga

Ni los votos de `likes` ni las respuestas a las resenas.

Las respuestas las escribe el vendedor dentro de su propia resena, asi que no
agregan ningun camino entre cuentas que `ESCRIBIO` no de ya. Los votos si
agregarian uno -- quien apoya a quien -- y son lo primero que este grafo deberia
crecer si hiciera falta mas senal; hoy son 62 votos de dos cuentas, que no
alcanza para un patron y entraria como ruido con nombre.

## Por que Cypher y no JSON

Con Mongo el ETL es `cargar.js`, un programa que corre dentro de `mongosh` y que
tiene trabajo de verdad: convierte dos historiales de fotos a eventos. Aqui no
hay nada que reconstruir -- las tres columnas de `resena` YA son las tres
relaciones del grafo -- asi que un programa intermedio solo agregaria un archivo
mas donde equivocarse.

La alternativa era emitir JSON y cargarlo con `apoc.load.json`. Se descarto:
obliga a dejar el archivo dentro del contenedor y a habilitar
`apoc.import.file.enabled` en `neo4j.conf`, o sea a tocar `docker-compose.yml`
por una comodidad. Cypher por la entrada estandar no necesita permiso de nada.

Todos los textos salen por `to_json(x)::text` y **nunca** concatenados a mano
entre comillas. El escape de una cadena JSON es un subconjunto del de Cypher
(comilla doble, barra invertida, saltos de linea y los escapes numericos
significan lo mismo en los dos), asi que lo que `to_json` devuelve ya es un
literal de Cypher valido. Concatenar a mano se rompe con la primera resena que
lleve una comilla -- y en este proyecto los textos los escribe el usuario. Peor:
no se rompe con un error de sintaxis claro, sino con un script partido a la
mitad.

## El esquema va en CADA corrida

`neo4j/001_esquema.cypher` se aplica antes de cargar, siempre, y no una sola vez.
No es por gusto: el ETL carga con `MERGE`, y **`MERGE` sin restriccion de
unicidad no garantiza unicidad** -- hace un `MATCH` y, si no encuentra, un
`CREATE`. Sin indice ese `MATCH` es un barrido de etiqueta, y dos corridas al
mismo tiempo pueden no encontrar nada las dos y crear dos nodos con el mismo id.

Si alguien levanta el contenedor con el volumen de datos vacio, las restricciones
se fueron con el; un ETL que no las reaplique empieza a duplicar sin dar un solo
error. Todo el `001` lleva `IF NOT EXISTS`, asi que repetirlo cuesta milisegundos.

`ON_ERROR_STOP=1` en la extraccion es obligatorio por lo mismo. Sin el, `psql` se
salta la sentencia que fallo, sigue con las demas y termina en cero: el Cypher
sale INCOMPLETO, `cypher-shell` lo carga contento y el grafo queda con la mitad
de las relaciones. Es el peor final posible, porque parece que funciono.

## Por que correrlo dos veces no duplica

No hay ni un `CREATE` en `extraer_grafo.sql`: todo es `MERGE`. `MERGE` encuentra
el nodo por su id -- el mismo de PostgreSQL -- y solo lo crea si no estaba; el
`SET` que va despues lo pone al dia igual la primera vez que la decima.

Medido, no supuesto: cuatro corridas seguidas dejan los mismos conteos, y una
corrida con `--limpiar` (o `-ReiniciarGrafo`) deja exactamente esos mismos
numeros. El grafo incremental y el reconstruido desde cero son el mismo grafo.

**Lo que la idempotencia NO cubre:** el ETL solo agrega y actualiza, nunca resta.
Una resena borrada en PostgreSQL se queda en el grafo para siempre, y ahi el
grafo empieza a contestar cosas que ya no son ciertas. Para eso esta `--limpiar`
/ `-ReiniciarGrafo`, que se puede correr sin miedo porque el grafo es una
proyeccion: no hay ni un dato aqui que no exista en PostgreSQL.

Va detras de una bandera y no por defecto a proposito: si alguien sembro un
anillo de prueba a mano para una demostracion, un borrado automatico se lo lleva
en medio de la demostracion.

## Neo4j community no tiene restricciones de existencia ni de tipo

`NOT NULL` sobre una propiedad y el tipo de dato son de la edicion Enterprise.
Aqui no se pueden declarar, asi que "toda `:Resena` tiene calificacion entre 1 y
5" **no lo garantiza el grafo**: lo garantiza el `CHECK` de PostgreSQL, que es de
donde salen los datos.

Es el precio de que el grafo sea una proyeccion y no una fuente de verdad, y
conviene decirlo antes de que alguien lo descubra por su cuenta.
