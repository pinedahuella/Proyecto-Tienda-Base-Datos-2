# migrations/lote/

Dos archivos, `generar_lote.sql` y `borrar_lote.sql`, y esta carpeta existe para
que no se corran solos.

| | |
|---|---|
| `generar_lote.sql` | agrega N productos con sus variantes y sus ofertas |
| `borrar_lote.sql` | borra productos generados, los mas nuevos primero |

Los dos se manejan mejor por `arrancar.ps1`, con `-Productos` y con `-Borrar`,
porque el catalogo vive en DOS bases y el script hace las dos mitades. Corridos
a mano solo tocan PostgreSQL y hay que limpiar MongoDB aparte.

## La semilla, en dos lineas

`.\arrancar.ps1 -Productos 300` sin mas **elige una semilla libre y te dice
cual**, asi que se puede correr las veces que haga falta y cada vez sale un lote
nuevo. Poner `-Semilla 7` fija el numero a mano y sirve para que dos personas
generen exactamente el mismo catalogo. Las dos formas son igual de
reproducibles: la diferencia es quien elige el numero.

## Que es

Un generador **incremental** de productos y ofertas. Se corre en cualquier
momento, sobre una base que ya tiene datos, y agrega N productos mas sin tocar
ni una fila de las que ya estaban.

Es lo contrario de `migrations/datos/001_catalogo.sql`. Aquel retrata un
catalogo entero y **solo entra en una base vacia**, y la razon es que ahi la
guardia es la excepcion y no la norma. Sus `INSERT` de primer nivel son
veintiseis -- se recuentan con
`grep -c '^INSERT INTO' migrations/datos/001_catalogo.sql`, que es lo unico
que no caduca cuando alguien agregue otro -- y solo nueve llevan `NOT EXISTS`:
los tres de cuentas, direcciones e historial de direccion del principio, y los
seis del tramo del anillo de fraude del final. Los otros diecisiete entran a
pelo, asi que la segunda pasada choca contra el `UNIQUE` de las categorias
raiz y se deshace entera. Cuando lo que hace falta es volumen encima de lo que
ya hay, ese archivo no sirve, y esa es la unica razon por la que este existe.

Cada producto nuevo se genera **clonando** uno que ya existe. Hereda su
categoria hoja, su descripcion, sus caracteristicas con los tipos de dato
correctos y su fotografia. Lo que se sortea es el reparto: que plantilla le
toca, cuantas variantes lleva, que vendedores lo ofertan, a que precio y con
cuanto stock.

Sus `INSERT` van a nueve tablas, y hay una decima que se llena sola:

```
productos                                   producto_variante_caracteristica_variante
productos_historial                         imagen_producto_producto
productos_variantes                         oferta
productos_variantes_historial               stock_movimiento
producto_caracteristica

precio_historial      la escribe el trigger del 005, no este archivo
```

## Como se corre

Las dos formas hacen lo mismo. La primera es la que se usa.

### Por `arrancar.ps1`

```powershell
.\arrancar.ps1 -Productos 300
.\arrancar.ps1 -Productos 300 -Semilla 7
```

`-Productos 0`, o sea no escribir la bandera, quiere decir "no generes nada": el
arranque de todos los dias sigue siendo exactamente el de antes y este paso ni
se anuncia. `-Semilla` sin `-Productos` se para antes de tocar Docker, porque
una semilla sola no dice cuantos generar y adivinarlo seria inventarle la
intencion a quien tecleo la linea.

**`-Semilla` por defecto vale 0**, y eso importa mas de lo que parece:
`.\arrancar.ps1 -Productos 300` dos veces seguidas no genera 600 productos, la
segunda corrida muere contra la guardia diciendo que la semilla 0 ya genero 300.
Para un segundo lote hay que dar otra semilla.

El script hace por su cuenta lo unico que el generador no puede averiguar solo:
le pregunta a MongoDB por sus dos maximos y se los pasa. Si Mongo no contesta un
numero, **se para** en vez de mandar un cero a ciegas.

### A mano

```bash
export MSYS_NO_PATHCONV=1

docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> \
    -v ON_ERROR_STOP=1 \
    -v productos=50 \
    -v semilla=42 \
    -v max_mongo_producto=<max _id de db.productos> \
    -v max_mongo_variante=<max variantes.id_producto_variante> \
    -f /migrations/lote/generar_lote.sql
```

`ON_ERROR_STOP=1` no es opcional. Sin el, psql imprime el error y **sale con
codigo 0**, asi que un script que lo llame se lleva un "todo bien" con la
guardia rechazando el lote. Es la misma trampa que ya documenta
`migrations/README.md` para el conjunto de datos.

Los dos maximos van como marcadores y no como numeros copiados de una corrida,
y eso no es pereza de escribirlos: son el estado de Mongo **en el momento de
correr**, suben cada vez que un vendedor publica desde el panel, y un numero
pegado aqui a mano quedaria caducado sin que nada avise. Se preguntan justo
antes de lanzar el comando, a la base documental, que es la unica que los sabe:

```js
db.productos.find().sort({_id:-1}).limit(1)
db.productos.aggregate([{$unwind:"$variantes"},
    {$group:{_id:null,m:{$max:"$variantes.id_producto_variante"}}}])
```

`productos` va de 1 a 9999. El tope sale del marcador del nombre, que lleva
cuatro digitos.

## Por que vive en `migrations/lote/` y no en `migrations/datos/`

Dos razones, y cada una sola ya bastaria.

**1. El bucle de `arrancar.ps1` lo correria sin sus variables.**
`Correr-Migraciones` recoge los `.sql` con `Get-ChildItem` y **sin `-Recurse`**,
sobre `migrations\` y sobre `migrations\datos\`. Un archivo en `datos/` lo
recogeria el segundo bucle y saldria con `psql -f` a secas, sin ninguno de los
cuatro `-v`. Peor todavia: este archivo **crea** filas cada vez que corre, asi
que un arranque que lo ejecutara solo duplicaria el catalogo en cada reinicio de
la maquina, y nadie sabria de donde salieron esos productos. Una subcarpeta no
la ve ningun bucle, ni siquiera el dia que alguien renombre archivos. La unica
puerta que tiene es la bandera `-Productos`.

**2. En `datos/` no correria nunca de todos modos.** La guardia de
`$productosEnBase` en `arrancar.ps1` -- se busca con `Ctrl+F` por
`$productosEnBase = (`, que no se mueve, y no por un numero de linea, que se
mueve cada vez que alguien agrega un paso -- pregunta
`SELECT count(*) FROM productos` y, si hay productos, **se salta esa carpeta
entera**. O sea que un `datos/002_*.sql` sobre
una base ya cargada se avisa en amarillo y se ignora. Eso ya esta reconocido por
escrito en `migrations/README.md`, en la contrapartida honesta de esa seccion:
la guardia es todo o nada por carpeta.

El precio de vivir fuera del bucle es que tampoco lo protege el numero de
migracion, asi que el archivo trae su propia guardia contra correrse dos veces.
Un archivo que se invoca a mano tiene que defenderse solo.

## La semilla

Misma semilla, mismos productos, en cualquier maquina y en cualquier version de
PostgreSQL. Sin guardar nada en ningun sitio.

El azar sale de una funcion propia que vive en `pg_temp` y que, dados semilla,
numero de fila y canal, devuelve el mismo double siempre. No usa `setseed()` ni
`random()` a proposito: el orden en que PostgreSQL evalua `random()` sobre las
filas de un `SELECT` no esta garantizado, y la implementacion cambio entre
versiones, asi que la misma semilla daria catalogos distintos en dos maquinas.
Aqui cada fila calcula su numero a partir de su propio indice y de nada mas, asi
que el orden de evaluacion deja de importar.

### La advertencia que de verdad importa

**La semilla reproduce el mismo SORTEO, no la misma BASE.**

Correr dos veces la misma semilla no deja el mismo resultado, deja **el doble**.
El sorteo es identico, si, pero se aplica encima de lo que ya hay: los productos
del primer lote siguen ahi y se les suman otros iguales.

Por eso el nombre de cada producto lleva un marcador con esta forma exacta:

```
<nombre de la plantilla> L<semilla>-<n con cuatro digitos>
Monitor Panorama 34 L42-0007
```

y por eso el PASO 0 aborta si esa semilla ya corrio en esta base:

```
ERROR: La semilla 42 ya genero 300 productos en esta base
HINT:  Corre con otra semilla, o borra antes los productos cuyo nombre
       termina en el marcador de esa semilla, en el orden de las llaves foraneas
```

La expresion regular exige el formato completo (espacio, L, la semilla, guion y
cuatro digitos al final) y no un `LIKE` amplio, para que un producto curado que
por casualidad lleve una L y un numero no se confunda con un lote.

## Por que el nombre lleva marcador

El marcador hace tres trabajos, y el tercero es el que lo vuelve obligatorio.

**Deja ver de un vistazo que producto es generado.** Un catalogo de prueba que
no se distingue del curado acaba siendo citado como si fuera de verdad.

**Le da a la guardia por donde reconocer un lote ya generado.** Sin marcador no
habria forma de saber que la semilla 42 ya corrio.

**Y sobre todo: `productos.nombre` NO tiene `UNIQUE`.** Se puede comprobar en
`migrations/003_productos.sql`, donde la tabla declara su PK y dos indices por
categoria y por estado, y ninguno sobre el nombre. Al mismo tiempo, la regla del
proyecto es que **ningun id se escribe a mano**, asi que este archivo resuelve
el id de cada producto recien insertado buscandolo **por nombre**, igual que
todos los `INSERT ... SELECT` del proyecto.

Las dos cosas juntas son una trampa. Dos productos con el mismo nombre
convierten ese `JOIN` en un producto cartesiano: cada variante, cada
caracteristica y cada oferta se escribiria dos veces. Y no fallaria limpio.
Fallaria mas adelante, contra el `UNIQUE (id_producto, nombre_variante)` del
`003`, con un mensaje que no explica nada de lo que de verdad paso.

Los cuatro digitos son lo que hace unico el nombre dentro del lote, y de ahi
sale el tope de 9999 productos por corrida. El nombre de la plantilla se recorta
con `left()` para caber en el `varchar(200)`, y se recorta **la base, nunca el
marcador**: al reves, el nombre se quedaria sin sus cuatro digitos y dos
productos del mismo lote podrian llamarse igual, que es justo lo que el marcador
existe para impedir.

## El problema de los dos asignadores de id

Esto es lo mas importante de este documento. No es una precaucion teorica: las
dos bases **ya divergieron**, y esta medido.

### Lo que pasa

Un vendedor que publica un producto desde el panel **no escribe nada en
PostgreSQL**. Ese producto nace en MongoDB y su `_id` se calcula como el mayor
`_id` que ya existe mas uno, leido **de Mongo**
(`backend/src/services/vendedores/productos.service.ts`, la funcion
`siguienteIdProducto`; el comentario de la clase, el que empieza por
`Todo vive en MongoDB:`, lo dice con todas sus letras). Las dos se buscan con
`Ctrl+F` por esos textos y no por numero de linea, que en ese archivo se mueve
cada vez que se le agrega un metodo.

O sea que hay **dos asignadores de id de producto que no se hablan**:

```
PostgreSQL   el bigserial de productos.id_producto
MongoDB      el maximo _id mas uno, calculado por el panel
```

La forma de la divergencia no depende de cuantos productos haya hoy, y por eso
se describe y no se retrata: **Mongo va por delante de la secuencia de
PostgreSQL en exactamente tantos numeros como productos se hayan publicado
desde el panel**, porque cada uno de esos consume un `_id` de Mongo sin gastar
uno del `bigserial`. Ese hueco solo puede crecer: nada lo cierra solo.

Aqui se mide, y estas cuatro consultas son las que hay que correr antes de
creerle un numero a este documento:

```sql
-- PostgreSQL
SELECT count(*) FROM productos;
SELECT last_value FROM productos_id_producto_seq;
```

```js
// MongoDB
db.productos.countDocuments({})
db.productos.aggregate([{$group:{_id:null,m:{$max:"$_id"}}}])
```

Y los productos que estan de un lado y no del otro, que son la causa entera:

```sql
-- los _id de Mongo que no tienen fila en PostgreSQL se cruzan a mano,
-- porque las dos bases no se hablan; del lado relacional se ven asi:
SELECT DISTINCT o.id_producto_mongo
  FROM oferta o
 WHERE NOT EXISTS (SELECT 1 FROM productos p
                    WHERE p.id_producto = o.id_producto_mongo);
```

**Ejemplo de una corrida concreta, la del 2026-09-02**, y vale como ejemplo de
la forma, no como el estado de la base de hoy:

```
PostgreSQL    102 productos, secuencia en 102     -->  entregaria el 103
              202 variantes, secuencia en 202
MongoDB       106 productos                       -->  los _id 103, 104, 105 y 106
              max id_producto_variante 206             ya estan ocupados
```

Los cuatro de mas en Mongo eran productos nacidos en el panel (tecnokid,
barbuchin, "PRUEBA candado propuesta", crepas), sin fila de este lado.

### Por que eso es grave

Si este generador dejara que la secuencia eligiera a ciegas, su primer producto
se llevaria un numero que en Mongo ya es de otro -- en el ejemplo de arriba, el
**103**, que es tecnokid. Y el ETL lleva el catalogo a Mongo con

```js
replaceOne: { filter: { _id: doc._id }, replacement: doc, upsert: true }
```

o sea que **machacaria tecnokid entero**, con `replaceOne` y no con un `$set`,
asi que no quedaria ni un campo del original.

Y nada avisaria. `etl/cargar.js` tiene `deleteMany` sobre `db.categorias` y
sobre `db.productos_eventos`, pero **no sobre `db.productos`**. Es a proposito y
esta comentado alli mismo, porque un barrido se llevaria por delante justo a los
productos nacidos en Mongo. Lo que ese comentario cubre es el **borrado**. El
`replaceOne` por `_id` se cuela por debajo de esa proteccion: respeta al
producto huerfano solo mientras nadie de PostgreSQL reclame su numero. Un
`replaceOne` que pisa una fila ajena se ve exactamente igual que uno que
actualiza la propia.

### Como lo esquiva el generador

Por eso el archivo recibe los dos maximos de Mongo por parametro y, **antes de
insertar nada**, empuja las dos secuencias al mayor de los dos mundos:

```sql
SELECT setval(
    pg_get_serial_sequence('productos', 'id_producto'),
    GREATEST(
        (SELECT coalesce(max(id_producto), 0) FROM productos),
        (SELECT max_mongo_producto FROM lote_parametro)
    )
);
```

El nombre de la secuencia sale de `pg_get_serial_sequence()` y no escrito a
mano: si algun dia la columna cambia de tipo o de nombre, esto falla en voz alta
en vez de empujar una secuencia que ya no manda.

Y esto **no viola** la regla de que ningun id se escribe a mano. No hay ningun
numero clavado en el archivo: se calcula en el momento contra el maximo real de
las dos bases. Lo que la regla prohibe es un numero copiado que funciona en una
maquina y revienta en la de al lado.

**El hueco de ids es correcto y es permanente.** Los numeros que van desde el
maximo de PostgreSQL hasta el maximo de Mongo no van a tener nunca una fila de
este lado: son de Mongo, y reclamarlos seria el pisoton que este paso viene a
evitar. El primer producto del lote sale del siguiente al maximo de los dos
mundos, no del siguiente al de PostgreSQL.

**Ejemplo de una corrida concreta, la del 2026-09-02:** con la secuencia en 102
y Mongo en 106, un lote de 5 productos se llevo los id **107 al 111**, y del
103 al 106 quedo el hueco. Los numeros de manana seran otros; lo que no cambia
es que el lote arranca por encima del mayor de los dos.

La comprobacion 7 del PASO 12 cierra el circulo por el lado que puede: mira que
ningun id nuevo caiga dentro del rango que el **parametro** declara para Mongo,
para que un `setval` que no surtio efecto se note. Ojo con lo que eso es y lo
que no es, que el propio comentario de esa comprobacion lo explica entero: desde
SQL no se puede abrir la base documental, asi que no compara contra Mongo, sino
contra el numero que se le paso. Que ese numero corresponda al Mongo de verdad
es cosa de `arrancar.ps1`, que se lo pregunta a Mongo y se para si no contesta.

### Lo que esto NO es

Un parche del lado de las migraciones. Solo protege a los `INSERT` que pasan por
este archivo. Cualquier otro `INSERT INTO productos` sigue entregando el id que
le toque a la secuencia. La pregunta de fondo (de donde sale el id de un
producto, de una sola fuente o de dos) queda planteada en
`docs/BACKEND-PENDIENTE.md`, bloque 8, que es de quien la tiene que decidir.

## Lo que este archivo NO hace

- **No borra nada.** Ni una fila, en ninguna tabla.
- **No toca los productos que ya existen.** Los lee como plantillas y nada mas.
  Un producto generado por un lote anterior queda excluido de ser plantilla, o
  su nombre acumularia marcadores hasta chocar contra el `varchar(200)`.
- **No escribe resenas, comentarios, likes, pedidos ni pagos.** Los productos
  nacen sin opiniones y sin ventas.
- **No escribe `precio_historial` a mano.** Esa fila la pone el trigger
  `trg_oferta_registrar_precio` del `005`, que se deja **encendido**.
  `001_catalogo.sql` lo apaga porque sus ofertas son de meses pasados; estas
  nacen hoy y no cambian de precio nunca. Escribirla ademas dejaria dos filas de
  nacimiento por oferta, con el mismo precio y la misma fecha, y ninguna
  comprobacion lo veria.
- **No inserta filas en `imagen_producto`.** Cada variante nueva apunta a la
  MISMA fila de imagen que ya usa su variante plantilla.
  `imagen_producto.imagen_producto_url` tiene `UNIQUE`, asi que reinsertar una
  URL existente tumbaria la transaccion entera.
- **No crea ofertas pendientes.** Este lote retrata un catalogo que ya funciona.
  Para probar la cola de aprobacion se publica una desde el panel, que el
  backend ya la crea pendiente sola.
- **No mueve el grafo de Neo4j**, y esta bien que no lo mueva, aunque el
  motivo no es el que parece. La lista `$NODOS_ETL` de `arrancar.ps1` **si
  tiene un contador `Producto`**, y decir que no lo tiene seria mentira. Lo
  que hay que mirar es contra que cuenta:

  ```
  Producto   SELECT count(DISTINCT id_producto_mongo) FROM resena;
  ```

  O sea que el grafo no guarda el catalogo, guarda **los productos que alguien
  ha resenado**, que es lo unico que la consulta de fraude necesita. Y este
  archivo **no escribe ni una resena**, como dice otra de estas vinetas, asi
  que un lote no cambia ese `count(DISTINCT)` ni en uno. Lo mismo vale para los
  otros contadores, que salen de `usuarios`, de `resena` y de `direcciones`.
  El grafo no se queda viejo despues de un lote porque el lote no toca nada de
  lo que el grafo cuenta, no porque el grafo ignore a los productos. Forzarlo
  aqui seria trabajo por gusto.
- **No fuerza el ETL**, y tampoco hace falta. Las guardias de la seccion 7 de
  `arrancar.ps1` ven mas filas en PostgreSQL que documentos en Mongo y lo
  disparan solas. Por eso el paso va **antes** del ETL en el arranque: puesto
  despues, PostgreSQL tendria las filas del lote y Mongo todavia no, el
  verificador de la seccion 7b compara con `-lt` (Mongo por debajo es fallo) y
  mataria el arranque acusando al ETL, con absolutamente todo bien.

## Como se deshace un lote

No hay bandera para esto. Se hace a mano, y el orden importa: todas las llaves
foraneas de este tramo son `ON DELETE RESTRICT`, asi que una borrada fuera de
orden falla en vez de arrastrar.

Cambia `L999` por el marcador de la semilla que quieras borrar.

```sql
BEGIN;

CREATE TEMP TABLE lote_ids AS
  SELECT id_producto FROM productos
   WHERE nombre ~ ' L999-[0-9]{4}$';

CREATE TEMP TABLE lote_var AS
  SELECT id_producto_variante FROM productos_variantes
   WHERE id_producto IN (SELECT id_producto FROM lote_ids);

CREATE TEMP TABLE lote_of AS
  SELECT id_oferta FROM oferta
   WHERE id_producto_mongo IN (SELECT id_producto FROM lote_ids);

CREATE TEMP TABLE lote_img AS
  SELECT DISTINCT ipp.id_imagen_producto
    FROM imagen_producto_producto ipp
   WHERE ipp.id_producto_variante IN (SELECT id_producto_variante FROM lote_var);

-- La oferta y todo lo que cuelga de ella
DELETE FROM stock_movimiento WHERE id_oferta IN (SELECT id_oferta FROM lote_of);
DELETE FROM rechazo_oferta   WHERE id_oferta IN (SELECT id_oferta FROM lote_of);
DELETE FROM precio_historial WHERE id_oferta IN (SELECT id_oferta FROM lote_of);
DELETE FROM oferta           WHERE id_oferta IN (SELECT id_oferta FROM lote_of);

-- Las imagenes: primero el enlace, y la foto SOLO si ya no la apunta nadie
DELETE FROM imagen_producto_producto
 WHERE id_producto_variante IN (SELECT id_producto_variante FROM lote_var);

DELETE FROM imagen_producto i
 WHERE i.id_imagen_producto IN (SELECT id_imagen_producto FROM lote_img)
   AND NOT EXISTS (SELECT 1 FROM imagen_producto_producto q
                    WHERE q.id_imagen_producto = i.id_imagen_producto);

-- Las variantes
DELETE FROM producto_variante_caracteristica_variante
 WHERE id_producto_variante IN (SELECT id_producto_variante FROM lote_var);
DELETE FROM productos_variantes_historial
 WHERE id_producto_variante IN (SELECT id_producto_variante FROM lote_var);
DELETE FROM productos_variantes
 WHERE id_producto_variante IN (SELECT id_producto_variante FROM lote_var);

-- El producto
DELETE FROM producto_caracteristica WHERE id_producto IN (SELECT id_producto FROM lote_ids);
DELETE FROM productos_historial     WHERE id_producto IN (SELECT id_producto FROM lote_ids);
DELETE FROM productos               WHERE id_producto IN (SELECT id_producto FROM lote_ids);

COMMIT;
```

**Probado contra la base viva**, con `ROLLBACK` al final para no perder el
lote. Lo que se comprobo, y es lo que hay que volver a comprobar cada vez que
alguien lo use, es que las cuatro cuentas de `productos`, `productos_variantes`,
`oferta` e `imagen_producto` vuelven **exactamente** a lo que valian antes del
lote: ni una fila de menos, que seria haberse llevado algo curado por delante,
ni una de mas, que seria un resto del lote sin borrar. Se apuntan los cuatro
numeros antes de generar y se comparan despues de deshacer; el valor de cada
uno no importa, importa que sean los mismos.

**Ejemplo de una corrida concreta, la del 2026-09-02**, sobre el lote de la
semilla 999 (5 productos, 9 variantes, 28 ofertas):

```
antes del lote     102 productos, 202 variantes, 560 ofertas, 102 imagenes
con el lote        107 productos, 211 variantes, 588 ofertas, 102 imagenes
tras deshacerlo    102 productos, 202 variantes, 560 ofertas, 102 imagenes
```

Tres cosas que hay que saber antes de usarlo:

**El `NOT EXISTS` del borrado de imagenes no es adorno.** Las variantes
generadas comparten la foto de su plantilla, que sigue siendo de un producto
curado. Sin esa condicion, el borrado sale con:

```
ERROR: update or delete on table "imagen_producto" violates RESTRICT setting of
foreign key constraint "imagen_producto_producto_id_imagen_producto_fkey"
```

Con la condicion, borra **cero** filas de `imagen_producto`, que es lo correcto:
el generador nunca creo ninguna.

**Si alguien ya compro algo del lote, esto falla y tiene que fallar.**
`pedido_producto` referencia `precio_historial` con `RESTRICT`, asi que el
borrado se para ahi con un mensaje claro. Medido: el mismo procedimiento sobre
un producto del catalogo curado que si tiene ventas muere en
`pedido_producto_id_precio_historial_fkey`. Borrar un producto que alguien
compro dejaria un pedido sin explicacion, y vale mas no poder deshacerlo.

**La secuencia no vuelve atras.** `setval` vive fuera de la transaccion a
proposito, asi que borrar el lote no devuelve la secuencia a donde estaba. No
hay que devolverla: quedo alineada con Mongo, que es donde tiene que estar.

**Y falta la mitad: en MongoDB hay que borrarlos aparte.** Esto es lo que mas
facil se olvida, porque no da ningun error y las cuentas siguen pareciendo
bien.

Correr el ETL **NO** los quita. Aqui decia que si, y era mentira; se midio y no
lo es. `etl/cargar.js` escribe con `replaceOne` y `upsert`, o sea que agrega y
actualiza pero **nunca borra**, y su unico barrido de sobrantes es sobre
`categorias` y sobre `productos_eventos`. Para `db.productos` no hay ninguno.

Se comprobo borrando un lote entero de PostgreSQL y corriendo
`.\arrancar.ps1 -Etl` justo despues: los documentos del lote **seguian en
Mongo**, el paso del ETL informo la cuenta de PostgreSQL (que ya no los
incluye), y el verificador vio Mongo por encima de PostgreSQL y lo dio por
bueno. **Ejemplo de una corrida concreta, la del 2026-09-02**, con el lote de
la semilla 7, de 300 productos:

```
PostgreSQL                 102 productos
MongoDB                    406 productos, 300 de ellos del lote borrado
el paso del ETL dijo       productos   102
el verificador dijo        productos  406 de 102     y lo dio por bueno
```

El verificador no protesta porque compara con `-lt`: solo se queja si Mongo
tiene MENOS que PostgreSQL. Que tenga de mas es normal en este proyecto, porque
ahi viven los productos publicados desde el panel, que no tienen fila en
PostgreSQL. Un fantasma se esconde exactamente en ese hueco.

Asi que el borrado se termina a mano, contra MongoDB, y por NOMBRE, que es lo
unico que distingue un producto de lote de uno del panel:

```javascript
const ids = db.productos.find({ nombre: / L999-[0-9]{4}$/ }, { _id: 1 })
                        .toArray().map(d => d._id)

db.productos.deleteMany({ _id: { $in: ids } })
db.productos_eventos.deleteMany({ id_producto: { $in: ids } })
```

Se filtra por el marcador y no por un rango de `_id` a proposito: un rango se
llevaria por delante los productos del panel, que viven en los mismos numeros.

Y despues si, el ETL, para que los que quedan vuelvan a quedar al dia:

```powershell
.\arrancar.ps1 -Etl
```

## Se comprueba a si mismo

El archivo termina con un bloque `DO` de **ocho comprobaciones**, y cada una
**falla la transaccion entera**. Es el mismo criterio que `001_catalogo.sql`: un
conjunto de datos que no se verifica es un conjunto de datos que miente en
silencio, y este ademas se mete encima de uno que ya funciona.

Esta lista se cae de la realidad en cuanto alguien agregue una precondicion, y
esa es la clase de lista que caduca sin avisar. Se recuenta abriendo
`generar_lote.sql` por el `PASO 12` y leyendo los comentarios numerados del
bloque `DO $verificar$`, que es la unica fuente que no miente:

1. se crearon exactamente los productos que se pidieron
2. toda variante nueva tiene su oferta de la tienda
3. el saldo de cada oferta nueva es la suma de su kardex
4. el precio de cada oferta nueva es el ultimo de su `precio_historial`
5. ninguna oferta nueva activa o pausada quedo sin `fecha_aprobacion`
6. ningun producto nuevo se quedo sin su fila de historial
7. ningun id nuevo cae dentro del rango que el PARAMETRO declara para MongoDB
8. toda variante nueva ensena una imagen

Las ocho miran **solo las filas del lote**, no la base entera. Si el conjunto
curado ya venia con algo torcido de antes, este archivo no es el que lo tiene
que descubrir: culparlo de eso solo lograria que nadie pudiera generar un lote
hasta arreglar algo sin relacion.

Vale la pena leer tres de ellas al reves de como suenan.

**La 4 no valida el precio, valida que el trigger corrio.** El PASO 10 no
escribe `precio_historial` y descansa entero en `trg_oferta_registrar_precio`
del `005`. Si alguien lo dejara apagado (`001_catalogo.sql` lo apaga y lo vuelve
a encender, y una corrida interrumpida a la mitad lo deja apagado para siempre y
en silencio), el lote naceria sin historial de precio y nada mas lo notaria.

**La 3 existe por lo que rompe a distancia.** Sin las filas de apertura del
kardex, lo que falla no es este archivo: es la comprobacion 1 de
`001_catalogo.sql`, semanas despues, la proxima vez que alguien recargue la base
desde cero, en la corrida de otra persona y sin nada que la ligue a este lote.

**La 8 vigila un descarte silencioso, no una imagen que falte.** El `INSERT`
del PASO 8 va por un `CROSS JOIN LATERAL` contra la variante plantilla, y un
`LATERAL` que no encuentra fila no falla: se salta la variante y no dice nada.
Hoy no puede pasar, porque el filtro del PASO 3 exige que TODAS las variantes
de una plantilla tengan imagen, pero esa condicion vive a cientos de lineas de
distancia y alguien puede relajarla sin ver la consecuencia. Un filtro que
protege a distancia no es un mecanismo, es un acuerdo, y por eso ademas se
comprueba.

Cuando todo cuadra, imprime un resumen contado contra las tablas vivas, con la
semilla, los productos y el rango de id que se llevaron, las variantes, las
ofertas, los movimientos de apertura y el tope de MongoDB por encima del que
arrancaron. **Ejemplo de una corrida concreta, la del 2026-09-02:**

```
NOTICE: Lote de la semilla 999 verificado. 5 productos (id 107 al 111),
        9 variantes, 28 ofertas y 25 movimientos de apertura.
        Los id arrancan despues del 106 de MongoDB
```

Y todo el archivo va dentro de un `BEGIN` / `COMMIT`, asi que la pasada que
falla no deja rastro. La unica excepcion es el `setval` del PASO 1, que las
secuencias no se deshacen con el `ROLLBACK`. Por eso la guardia de repeticion va
**antes** del `setval`: una corrida rechazada ni siquiera llega a tocarlas.
