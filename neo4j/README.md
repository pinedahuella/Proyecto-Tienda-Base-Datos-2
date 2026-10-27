# neo4j

Los scripts de Cypher del grafo de Mesh. La carpeta esta montada dentro del
contenedor en `/neo4j`, igual que `migrations/` en PostgreSQL y `mongo/` en
MongoDB.

## Para que existe el grafo

La Entrega 2 pide senalar *"conjuntos de cuentas que se califican entre si de
forma reiterada sobre los mismos productos"*. Eso es recorrer relaciones entre
cuentas, no leer filas, y es lo que decide la familia elegida.

## El modelo: TRES nodos, no cuatro

```
(:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(:Usuario)
                        (:Resena)-[:SOBRE]->(:Producto)
```

**No hay nodo `:Vendedor`.** Es el mismo `:Usuario`, y no es una simplificacion:
en Mesh comprar no pide rol, asi que un vendedor tambien compra. Partirlo en dos
etiquetas dejaria a la misma cuenta como dos nodos distintos y **el anillo nunca
cerraria** -- A-como-vendedor y A-como-comprador no serian el mismo nodo. La
frase "se califican entre si" solo se puede expresar si quien califica y quien
es calificado son la misma clase de cosa.

**Y la resena es un NODO, no una relacion.** Una relacion de Neo4j conecta
exactamente dos cosas; la resena conecta TRES -- autor, vendedor y producto. Por
eso va reificada. Ademas es lo que permite exigir "sobre los MISMOS productos",
que es la mitad de la senal y se perderia con una relacion directa
cuenta -> cuenta.

## De donde salen los datos

De PostgreSQL, con el ETL. Las tres columnas de `resena` son exactamente las
tres relaciones de arriba:

| Columna en PostgreSQL | Relacion en el grafo |
|---|---|
| `resena.id_usuario` | `(:Usuario)-[:ESCRIBIO]->(:Resena)` |
| `resena.id_usuario_vendedor` | `(:Resena)-[:CALIFICA_A]->(:Usuario)` |
| `resena.id_producto_mongo` | `(:Resena)-[:SOBRE]->(:Producto)` |

El grafo es una PROYECCION, no una fuente de verdad: se puede borrar entero y
reconstruir desde PostgreSQL. Nada se escribe aqui que no exista alla.

## Las compras, desde el 2026-10-16

Jose David sumo las compras al grafo (25f0fe0, migracion 041,
`backend/elementos Generales/plan pendiente/grafo-compras.md`), con la misma
forma que la resena: un NODO `:Compra` por linea de pedido, con el id de
`pedido_producto`.

```
(:Usuario)-[:HIZO]->(:Compra)-[:DE]->(:Producto)
                    (:Compra)-[:A_VENDEDOR]->(:Usuario)
```

La variante, la cantidad, el precio y la fecha van como propiedades. Cuenta como
compra un pedido `comprado`, `enviado` o `entregado`; `pendiente` (el carrito) y
`cancelado` no. De aqui salen "para ti" (lo que compraron quienes compraron lo
mismo que tu, `GET /productos/para-ti`) y "tambien compraron"
(`GET /productos/:id/tambien-compraron`), en vivo.

**No las carga el ETL.** Las proyecta el worker `GrafoComprasSyncService` del
backend, cada 10 s, desde la cola `evento_grafo_compra` (una fila por CUENTA: el
worker relee todas sus compras y deja sus `:Compra` iguales a eso). La
restriccion `compra_id` esta en `001_esquema.cypher`, porque el worker tambien
usa MERGE. Como `--limpiar` borra el grafo entero, al terminar el ETL (el de
arrancar y `etl/cargar_grafo.sh`) encola todas las cuentas con pedidos y el
worker las vuelve a proyectar. La conciliacion (`GET /admin/grafo/conciliacion`)
compara las `:Compra` con las lineas compradas de PostgreSQL.

Prueba: `bash pruebas/grafo_compras.sh` (30 OK el 2026-10-18), que compra de
verdad, para Neo4j a mitad y cancela.

## La categoria en el `:Producto`, desde el 2026-10-26

"Tambien compraron" ordena por grupos: primero SIEMPRE los productos de la misma
categoria que el de la ficha, despues el resto, y dentro de cada grupo por
cuantas cuentas los compraron (ADR-25). Para que Neo4j lo resuelva en la misma
consulta, cada `:Producto` lleva `id_categoria` (Integer) y `categoria` (el
nombre), copiados de `producto_catalogo` y `categorias` de PostgreSQL.

```
MATCH (base:Producto {id: $id})<-[:DE]-(:Compra)<-[:HIZO]-(cuenta:Usuario)
MATCH (cuenta)-[:HIZO]->(:Compra)-[:DE]->(rec:Producto)
WHERE rec <> base
WITH base, rec, count(DISTINCT cuenta) AS compradores
WITH rec, compradores,
     CASE WHEN base.id_categoria IS NOT NULL AND rec.id_categoria = base.id_categoria
          THEN 0 ELSE 1 END AS grupo
RETURN rec.id AS id, compradores, grupo = 0 AS misma_categoria
ORDER BY grupo, compradores DESC, id
```

La escriben los workers de compras y de resenas al proyectar, el ETL
(`etl/extraer_grafo.sql`) y `GrafoCategoriasSyncService`, que al arrancar y cada
60 s compara todos los `:Producto` con PostgreSQL y corrige los que no
coinciden. Ese ultimo es el que recoge un cambio de categoria hecho por la API
(medido, de 14 a 59 s) y el que rellena un grafo cargado antes de la copia del
catalogo. Nunca crea nodos: un producto entra al grafo cuando alguien lo compra
o lo resena.

Solo se copia la categoria. El precio, la existencia y la foto cambian a cada
rato y siguen saliendo del catalogo, igual que antes.

Prueba: `bash pruebas/tambien_compraron_categoria.sh`, que compra de verdad,
cambia la categoria a mano en el grafo para ver que el worker la arregla, la
cambia por la API, y apaga Neo4j y MongoDB para ver que el respaldo da lo mismo.

## Como entrar

La ventana del navegador esta en <http://localhost:7474> (usuario `neo4j`, la
contrasena del `.env`). Por linea de comandos:

```bash
docker exec -it mesh-neo4j cypher-shell -u neo4j -p LA_CONTRASENA
```


## Los archivos, y quien hace que

| Archivo | Que hace |
|---|---|
| `neo4j/001_esquema.cypher` | Restricciones de unicidad e indices. Se aplica en cada carga. |
| `neo4j/consultas/A1_anillo.cypher` .. `A5_puntaje.cypher` | Las cinco consultas de deteccion. **Un solo texto de cada una**, que se corre dos veces. |
| `neo4j/consultas/siembra.cypher` | El anillo de mentira que demuestra que las cinco sirven. |
| `neo4j/correr_fraude.sh` | Corre las cinco contra el grafo real, siembra, las vuelve a correr, comprueba con aserciones y limpia. |
| `etl/extraer_grafo.sql` | PostgreSQL arma el script de Cypher con todo lo que va al grafo. |
| `etl/cargar_grafo.sh` | Aplica el esquema, corre lo anterior y se lo pasa a cypher-shell. |

Es el mismo reparto que el ETL de MongoDB (`etl/extraer.sql` + `etl/cargar.js`
+ `etl/correr.sh`) y por la misma razon: **no hay nada que instalar**. PostgreSQL
arma el texto y lo carga el cliente que ya viene dentro del contenedor. Alla es
`mongosh`; aqui es `cypher-shell`, que trae la imagen `neo4j:5-community`. Cero
paquetes de npm, cero archivos intermedios en el disco.


## Como se carga

Desde **Git Bash**, no desde PowerShell. Es la misma razon que dice
`etl/correr.sh`: PowerShell se come las comillas al llamar a `docker` y la
consulta llega partida.

```bash
# Carga normal. Idempotente: se puede correr las veces que sea.
./etl/cargar_grafo.sh

# Reconstruccion desde cero. Borra el grafo entero y lo vuelve a armar.
./etl/cargar_grafo.sh --limpiar

# Extraer de otra base de PostgreSQL en vez de la del .env.
./etl/cargar_grafo.sh prueba_tuyo
```

El script imprime al final cuantos nodos y cuantas relaciones quedaron. No es
adorno: la sentencia que carga las resenas empieza con tres `MATCH`, y si los
nodos no estuvieran no fallaria -- simplemente no crearia nada. Un ETL que dice
"listo" sin decir cuanto cargo puede haber cargado cero.

**El grafo no necesita estar montado en el contenedor para cargar.** Todo entra
por la entrada estandar, y eso es a proposito: asi se esquiva la trampa de Git
Bash, que convierte cualquier ruta que empiece con `/` antes de pasarsela a
`docker` y hace que `--file /neo4j/001_esquema.cypher` busque el archivo en
`C:/Program Files/Git/neo4j/...`. El error que da ni menciona a Docker.


## Que quedo cargado

Medido el 2026-08-29 contra la base `mesh`, con `./etl/cargar_grafo.sh`:

| Nodo | Cuantos | De donde salen |
|---|---|---|
| `:Usuario` | 10 | Todas las filas de `usuarios`. |
| `:Producto` | 54 | Los `id_producto_mongo` distintos que aparecen en `resena`. |
| `:Resena` | 86 | Todas las filas de `resena`. |
| `:Direccion` | 12 | Las 16 filas de `direcciones`, deduplicadas por texto normalizado. Cada una lleva `tiene_calle`. |

| Relacion | Cuantas |
|---|---|
| `ESCRIBIO` | 86 |
| `CALIFICA_A` | 86 |
| `SOBRE` | 86 |
| `VIVE_EN` | 14 |

Las tres primeras dan 86 exactas porque cada resena tiene sus tres relaciones,
siempre. Si alguna vez no cuadran, hay resenas cargadas a medias.

**Los productos son 54 y no 102 a proposito.** Un producto sin resenas no puede
aparecer en ningun camino: las tres relaciones del modelo lo alcanzan solo desde
una `:Resena`. Cargar los 102 meteria 48 nodos que ninguna consulta puede tocar,
y el catalogo completo ya vive en MongoDB y en PostgreSQL.

Y la lista sale de `resena`, no de la tabla `productos`. `resena.id_producto_mongo`
no tiene llave foranea porque el catalogo vive en MongoDB, asi que un producto
publicado por un vendedor **no** tiene fila en `productos` -- hoy hay tres asi
con ofertas vivas. Partiendo de `productos`, una resena sobre uno de ellos se
perdia en silencio; esta contado en `etl/README.md`.

**Las direcciones son 12 y no 16, y esa resta es la senal.** Dos cuentas que
viven en la misma casa tienen dos filas distintas en `direcciones`; el ETL las
normaliza (minusculas, sin tildes, espacios colapsados) y las hace caer en un
solo nodo. Por eso hay 14 relaciones `VIVE_EN` repartidas en 12 nodos.

**Pero compartir nodo no alcanza para decir "misma casa".** La clave incluye la
calle, y 13 de esas 16 filas no la tienen: sin calle la clave queda en
`guatemala|sacatepequez|antigua guatemala|` y el nodo junta a todo el que declaro
esa ciudad. Por eso cada nodo lleva `tiene_calle` y las consultas lo exigen; hoy
solo 3 de los 12 nodos lo tienen en `true` y ninguno es compartido.


### El nodo `:Direccion` es la unica decision que se aparto del modelo

El enunciado de la carpeta pedia tres tipos de nodo. La direccion se agrego como
un **cuarto tipo**, y no como una propiedad de `:Usuario`, por dos razones:

1. **Una cuenta tiene VARIAS direcciones.** En los datos de hoy hay una con
   seis. Una propiedad guarda una sola; una lista de propiedades no se puede
   recorrer con un patron.
2. **La senal es el vecino compartido, no el valor.** Con la direccion como
   nodo, "estas dos cuentas viven en la misma casa" es literalmente un camino de
   dos saltos, `(a)-[:VIVE_EN]->(d)<-[:VIVE_EN]-(b)`. Con la direccion como
   propiedad habria que comparar el texto de todas contra todas, que es
   exactamente lo que el grafo existe para no hacer.

Es el mismo argumento que ya justificaba no partir `:Usuario` en `:Usuario` y
`:Vendedor`: lo que tiene que ser el mismo nodo, tiene que ser el mismo nodo.

Y la identidad del nodo es el **texto normalizado**, no el `id_direccion`. Si
fuera el id, dos filas de la misma casa serian dos nodos y no se compartiria
nada. La normalizacion la hace `etl/extraer_grafo.sql` y no la consulta, porque
es la identidad del nodo y no un filtro.


## Que consulta contesta que pregunta

Cada una en su archivo, en `neo4j/consultas/`. Se corren todas con
`bash neo4j/correr_fraude.sh`.

| # | Pregunta | Como la contesta |
|---|---|---|
| A.1 | *Hay un grupo de cuentas donde la calificacion vuelve al punto de partida?* | Camino cerrado `*4..8` sobre `ESCRIBIO`/`CALIFICA_A`. 4 saltos = par mutuo, 6 = triangulo, 8 = cuadrado. **Es la consulta de varios saltos de la entrega.** |
| A.2 | *Hay cuentas que se califican entre si sobre los MISMOS productos?* | La frase literal del enunciado. Los dos sentidos, mas las dos resenas encontrandose en el mismo `:Producto`. |
| A.3 | *Alguien califico a la misma cuenta muchas veces en pocos dias?* | Busca una VENTANA MOVIL: ordena las resenas del par y exige que alguna este a 72 horas o menos de la que esta dos posiciones despues. No es el lapso total del par -- ver abajo. |
| A.4 | *Que cuentas comparten domicilio?* | Dos saltos por el nodo `:Direccion`, **exigiendo que ese domicilio tenga calle** (`d.tiene_calle`). Sin eso media "misma ciudad" -- ver abajo. |
| A.5 | *Cuales son los pares mas sospechosos, ordenados?* | Suma las cuatro senales anteriores por par y ordena. Es la que se lee primero. |

**A.1 es la que vale los 3 puntos.** Camina seis relaciones para cerrar un
triangulo y ocho para un cuadrado. En SQL cada salto es un self-join de `resena`
contra si misma, y para largo variable hace falta un CTE recursivo con control
de ciclos escrito a mano. Aqui es `*4..8`, y recorrer una relacion no consulta
ningun indice: cada nodo guarda punteros a las suyas.

Medido con `PROFILE` sobre el grafo real (259 nodos, 271 relaciones): **365
DbHits** para barrer todos los anillos posibles de 2 a 4 cuentas.

**Ninguna de las cinco prueba fraude.** Senalan un conjunto de cuentas para que
alguien lo mire. Compartir casa es normal en una familia; calificarse mutuamente
es normal entre dos cuentas que de verdad se compraron cosas. Lo que pesa es la
acumulacion, y por eso existe la A.5.


## Como se prueba que la consulta sirve

Aqui esta la parte incomoda, y esta escrita a proposito.

**Hasta el 2026-08-30 esta seccion decia que A.1, A.2 y A.3 devolvian VACIO**
contra los datos sembrados, y que eso era lo correcto porque el conjunto no
tenia ningun anillo. Era cierto, y era tambien el problema: el panel de fraude
de la Entrega 2 no tenia **nada real** que ensenar, y para demostrarlo habia que
sembrar un anillo de mentira en Neo4j o mirar datos inventados en el frontend.

Ahora el anillo es de verdad y vive en **PostgreSQL**: tres cuentas
`anillo.*@mesh.com` que **se compran entre si** -- tienen que hacerlo, porque el
backend exige compra pagada para calificar -- y despues se califican 5 estrellas
en circulo, desde la misma casa. El ETL las arrastra al grafo como a cualquier
otra cuenta, sin ningun paso especial. Ver `docs/PENDIENTES.md`.

Que un anillo de verdad tenga que comprarse a si mismo para poder resenar no es
un rodeo del sembrado: **es como opera uno real**, y el costo de esas compras
(cuatro ofertas a un cuarto del precio de la tienda) es justo lo que lo hace
detectable.

Sigue en pie el otro lado del argumento: una consulta que solo encuentra lo que
alguien sembro a proposito tampoco esta demostrada del todo. Por eso
`correr_fraude.sh` sigue existiendo: siembra un SEGUNDO anillo, de mentira y en
el grafo, corre otra vez **las mismas consultas** y lo borra.

```bash
bash neo4j/correr_fraude.sh
```

Correrlo es seguro: empieza borrando cualquier resto de una corrida anterior y
termina borrando el suyo, y compara los conteos de antes y despues. Todo lo
sembrado lleva la etiqueta `:Prueba`, asi que el borrado es una sola linea.

Va en `bash` y no en PowerShell a proposito: el comando que habia antes
(`cypher-shell ... < archivo.cypher`) **no corre en PowerShell 5.1**, que
contesta `The '<' operator is reserved for future use` y sale sin ejecutar una
sola consulta.

### Por que es un `.sh` y no un `.cypher` con dos partes

Porque antes era eso y no demostraba nada. Las dos partes vivian en un solo
`neo4j/002_fraude.cypher` y la "parte B" era una **copia pegada** de la parte A.
Se midio: cambiando `*4..8` por `*40..80` **unicamente en la copia de arriba** --
o sea rompiendo a proposito la consulta de varios saltos que vale los 3 puntos --
la salida del archivo entero quedaba identica y la demostracion seguia
imprimiendo los anillos sembrados con exito, porque corria la copia de abajo,
intacta. Mientras haya dos textos, el de abajo no prueba nada sobre el de arriba.

Cypher no puede incluir un archivo dentro de otro, asi que el unico lugar donde
se puede correr el MISMO texto contra dos estados del grafo es afuera.

### Y el arnes ahora tiene aserciones

Antes no tenia ni una. Se podia dejar la siembra sin la relacion que la hace
anillo, las cuatro comprobaciones devolvian **cero filas** -- la demostracion
fracasaba entera -- y el archivo terminaba con codigo 0 y sin un solo mensaje.
`cypher-shell` devuelve 1 si el Cypher **no compila**, nunca si no encuentra
nada.

Cada comprobacion hace `grep` sobre la salida que imprimio la consulta de la
entrega, no sobre otra consulta parecida: volver a preguntarle al grafo con un
texto distinto seria volver a tener dos copias. Comprobado con cinco sabotajes,
cada uno detectado:

| Sabotaje | Resultado |
|---|---|
| `*4..8` -> `*40..80` en A.1 | 2 FALLA, exit 1 |
| A.3 vuelta a la version de `max - min` | 1 FALLA, exit 1 |
| A.1 sin el filtro de cuentas distintas | 1 FALLA, exit 1, e imprime el anillo inventado |
| A.4 sin el filtro `d.tiene_calle` | 1 FALLA, exit 1 |
| La siembra sin `CREATE (a)-[:ESCRIBIO]->(r)` | 6 FALLA, exit 1 (antes: exit 0, sin un mensaje) |

**El anillo se siembra en Neo4j y no en PostgreSQL** porque el grafo es una
proyeccion: se puede ensuciar y reconstruir. Meter cuentas falsas en la fuente
de verdad las pondria delante del backend y del catalogo de Mongo, y sacarlas
obligaria a deshacer resenas, comentarios y usuarios en el orden que exigen las
llaves foraneas con `ON DELETE RESTRICT`.

Los ids de prueba son **negativos**. `usuarios.id_usuario` es un `bigserial` y
nunca va a dar un negativo, asi que no pueden chocar con uno real, y como el ETL
hace `MERGE` por id, la siguiente corrida no los toca.

### Lo que se midio

Corrida contra el grafo real, **sin sembrar nada** (2026-08-30, ya con el anillo
de `anillo.*@mesh.com` en PostgreSQL):

```
A.1  EL ANILLO ........................ 2 filas: el triangulo uno/dos/tres
                                        y el par uno+dos
A.2  PAR MUTUO SOBRE MISMO PRODUCTO ... 1 fila:  uno <-> dos sobre
                                        "Cartas al puerto seco", 5 y 5, 1 hora
A.3  RAFAGA ........................... 1 fila,  y NO es el anillo (ver abajo)
A.4  COMPARTEN DIRECCION .............. 1 casa con las 3 cuentas del anillo
A.4b MISMA CIUDAD (no es senal) ....... 0 filas
A.5  PUNTAJE COMPUESTO ................ el par uno+dos con 4 senales de 4,
                                        y los otros dos pares del anillo con 2
```

La medicion anterior -- **todas en 0 filas** -- era de antes de que el anillo
existiera en PostgreSQL. Se cambio el conjunto de datos, no las consultas: el
texto de las cinco es el mismo.

#### La A.3 encuentra algo que NO es el anillo, y esta bien

Su unica fila es `comprador.sur@mesh.com` calificando a `tienda@mesh.com`: 3
resenas en 16 horas, notas 5, 5 y 3. Es una cuenta normal comprando normal.

**No es un falso positivo de la consulta, es el limite de la senal.** "Varias
notas en pocos dias" describe igual de bien a un anillo que a alguien que se
sento un domingo a calificar lo que compro; el 3 en medio lo delata. Por eso
A.3 nunca decide sola: A.5 la suma con las otras, y ese par se queda en **1
senal de 4** mientras el anillo llega a 4. El backend hace lo mismo -- no expone
A.3 como un `tipo` propio, la usa como la frase de la ventana de tiempo.

#### La A.4 daba dos hallazgos y los dos eran falsos

Este README publicaba estas dos filas como hallazgos reales de "la misma casa":

- `comprador.sur@mesh.com` + `compradora.norte@mesh.com`, en Antigua Guatemala.
- `tienda@mesh.com` + `Meme#gordo@gmail.com`, en San Jose Pinula.

**Ninguna de las cuatro cuentas tiene calle registrada.** Solo coinciden en la
ciudad, y la propia salida de la consulta imprimia `direccion_exacta NULL` al
lado.

La causa esta en la clave del nodo: incluye `direccion_exacta`, y cuando esa
columna es `NULL` la clave termina en barra con nada detras
(`guatemala|sacatepequez|antigua guatemala|`), asi que **todas** las cuentas que
solo declararon su ciudad caen en el mismo nodo `:Direccion`. No es un caso
raro: **13 de las 16 filas** de `direcciones` no tienen calle. Con dos cuentas
cualesquiera de la capital, la senal se disparaba sola -- y A.5 les sumaba un
punto por eso.

Arreglado en `etl/extraer_grafo.sql`: el nodo ahora lleva `tiene_calle`, y A.4 y
la columna `comparten_direccion` de A.5 lo exigen. Una direccion sin calle no
identifica una casa. Los nodos se siguen cargando todos -- el grafo tiene que
poder contestar donde vive una cuenta -- y los pares que solo comparten ciudad se
listan aparte, en A.4b, rotulados como lo que son: **no son senal**.

Consecuencia: con el arreglo, A.4 dejo de devolver las dos filas falsas. Y hoy
devuelve **una fila verdadera**: las tres cuentas del anillo, que si tienen
calle.

Esa fila demuestra ademas por que la normalizacion existe. Las tres direcciones
estan escritas **distinto a proposito** en la semilla:

```
Callejon del Manzano 4, Casa B      <- anillo_uno
Callejon del Manzano 4,  casa b     <- anillo_dos   (doble espacio, minusculas)
Callejon  del Manzano 4, Casa B     <- anillo_tres  (doble espacio)
```

Comparadas tal cual son tres casas distintas y la senal no existe. `clave_direccion()`
las colapsa en una sola, y por eso las tres caen en el mismo nodo `:Direccion`.

#### La A.3 no media una ventana

Comparaba el lapso entre la **primera y la ultima** resena del par completo, no
una ventana movil, asi que **agregar mas evidencia apagaba la alerta**. Medido:
una rafaga de tres notas de 5 en 20 minutos mas una cuarta resena cinco meses
despues daba **cero filas**; borrando solo esa cuarta, la misma consulta la
encontraba.

Y en los datos reales era peor: los pares establecidos tienen de 8 a 11 resenas
repartidas en 70 a 140 dias, asi que la consulta **no podia** devolver una sola
fila para ningun par con historia, tuviera la rafaga que tuviera. Su "0 filas"
no significaba "no hay rafagas" sino "ningun par tiene toda su historia dentro
de 72 horas".

#### La A.1 inventaba anillos

Un camino de largo variable en Cypher garantiza que no se repita una
**relacion**, no que no se repita un **nodo**. Dos cuentas que se califican dos
veces en cada sentido son cuatro relaciones, asi que ademas del camino correcto
de 4 saltos existe uno de 8 que va y vuelve dos veces. Medido: ese par salia
**dos veces**, una como anillo de 2 cuentas (verdad) y otra como anillo de 4
cuentas con los dos correos repetidos (mentira). Y el caso que lo dispara es
justo el que la consulta busca. Arreglado exigiendo que las cuentas del ciclo
sean todas distintas.

#### Con el anillo sembrado

Las mismas consultas -- el mismo texto, no una copia -- encuentran:

```
A.1  3 anillos: el par (anillo.a, anillo.b), el triangulo (a, b, c)
     y el par (doble.a, doble.b). Ninguno repite cuenta.
A.2  3 pares mutuos sobre el mismo producto
A.3  1 rafaga: anillo.d califico 3 veces a anillo.a en 20 minutos,
     y la encuentra PESE a la cuarta resena de diciembre
A.4  1 direccion compartida, con calle
A.5  el par (anillo.a, anillo.b) con las 4 senales, y (doble.a, doble.b)
     con 3 porque no comparten casa
```

Y al borrarlo, los conteos vuelven exactos a 12 / 54 / 86 / 10 nodos y
86 / 86 / 86 / 14 relaciones. El arnes compara esas dos cadenas y falla si no
coinciden, en vez de imprimirlas para que una persona las compare de memoria.

### La idempotencia, medida

`./etl/cargar_grafo.sh` corrido tres veces seguidas imprime los mismos conteos
las tres veces (se comparo con `diff` la salida de la segunda y la tercera:
identicas). Correr `--limpiar` y volver a cargar da tambien esos mismos numeros,
que es la otra mitad de la prueba: el grafo incremental y el reconstruido desde
cero son el mismo grafo.


## Lo que este grafo NO sabe, dicho de frente

- **No garantiza nada.** Neo4j community no tiene restricciones de existencia ni
  de tipo: son de la edicion Enterprise. "Toda `:Resena` tiene calificacion" lo
  garantiza el `CHECK` de PostgreSQL, no el grafo.
- **El ETL solo suma.** Una resena borrada en PostgreSQL se queda aqui hasta que
  alguien corra `--limpiar`. Es la contrapartida de que sea idempotente.
- **Los votos (`likes`) no viajan.** Si agregarian un camino entre cuentas -- quien
  apoya a quien -- y son lo primero que este grafo deberia crecer si hiciera falta
  mas senal. Hoy son 62 votos de dos cuentas: no alcanza para un patron.
- **Las respuestas a las resenas tampoco.** Las escribe el vendedor en su propia
  resena, asi que no agregan ningun camino que `ESCRIBIO` no de ya.
- **La consulta A.5 solo ranquea pares que ya se calificaron.** Dos cuentas que
  comparten casa y nunca se calificaron no salen ahi con puntaje 1: no salen del
  todo. Eso lo contesta la A.4, y por eso las dos hacen falta.
