# Estrategia de consistencia del flujo de checkout

**Mesh -- Bases de Datos 2, Universidad del Istmo. Entrega 3.**

Fecha: 2026-09-04. Ultima actualizacion: 2026-10-18, el carrito pasa a tener
su verdad en PostgreSQL y Redis caido ya no impide comprar (ver 0 bis y las
filas 12 a 14). Antes, el 2026-10-01, la fila 11 (MongoDB caido durante el
checkout) quedo resuelta. Todo lo que dice este documento sale de codigo que
corre hoy y de mediciones contra la base viva. Donde algo no esta resuelto, se
dice que no lo esta.

---

## 0. Por que este documento tiene algo que contar

Comprar en Mesh **no es una transaccion**. Es una transaccion de PostgreSQL
rodeada de escrituras en otras tres bases que no participan de ella, porque no
pueden.

```
PostgreSQL   el pedido, el stock, el kardex y el pago    transaccional
Redis        el carrito y las unidades apartadas         fuera de la transaccion
MongoDB      el catalogo y sus numeros agregados         copia, se refresca
Neo4j        el grafo de resenas                         proyeccion, va detras
Elasticsearch el indice de busqueda                      proyeccion, va detras
```

Un `COMMIT` de PostgreSQL no puede deshacer un `HDEL` de Redis, y Redis no puede
escribir en PostgreSQL. Todo lo que sigue existe por esa frase.

La postura del proyecto, dicha de una vez: **el dinero y el stock son
transaccionales y no se negocian; todo lo demas se acepta como eventual y se
declara cuanto tarda.**

---

## 0 bis. Desde el 2026-10-17, Redis nunca es la fuente de verdad

El profesor lo pidio asi, y Jose David lo hizo en 25f0fe0 (migracion 045,
`backend/elementos Generales/plan pendiente/carrito-postgres-verdad.md`). Lo
que cambia en la tabla de arriba:

```
PostgreSQL   el pedido, el stock, el kardex, el pago,   transaccional
             EL CARRITO (el pedido pendiente) y las
             reservas de venta relampago
Redis        la copia rapida del carrito, el script     fuera de la transaccion,
             que decide primero en la venta relampago   nunca la verdad
             y el candado
```

Como se escribe: el carrito va a Redis y se contesta, y debajo un intento
asincrono lo copia al pedido `pendiente` de la cuenta, por diferencias. Si la
copia falla o choca con una version que Redis no vio, el carrito queda
**desincronizado**: la pantalla lo dice con un boton, `POST /carrito/sincronizar`
decide quien tiene razon, y mientras tanto el checkout contesta 409 y no cobra.

Como se compra: `POST /carrito/comprar` bloquea el pedido pendiente y las
ofertas (`FOR UPDATE`, en orden de id), compara Redis con PostgreSQL si Redis
esta, comprueba disponibilidad, reservas y precio, y llama a
`cambiar_direccion_pedido()` y `comprar_pedido()` en la misma transaccion. Ya no
usa `comprar_carrito()`.

Lo que ganan los puntos de falla:

| # | Que puede pasar | Que se hace | Categoria |
|---|---|---|---|
| 12 | Redis cae durante el checkout | se compra contra PostgreSQL; el `FOR UPDATE` del pedido hace de candado | **resuelto**, medido en 4 bis |
| 13 | Redis pierde el carrito o la venta relampago (reinicio, FLUSHALL) | el carrito se reconstruye desde PostgreSQL al leerlo; la venta, con `restaurar` desde `reserva_venta_relampago` | **reintento idempotente** |
| 14 | La copia de Redis a PostgreSQL falla | carrito desincronizado, el checkout no cobra hasta sincronizar | **rechazo explicito** |

La fila 6 (el proceso muere entre el COMMIT y vaciar el carrito) deja de ser
una ventana: el carrito que se compra ES el pedido, y el COMMIT lo pasa a
`comprado`. Lo que quede en Redis no coincide con PostgreSQL y se descarta.

---

## 1. Los componentes que intervienen

En orden de aparicion durante un `POST /carrito/comprar`.

| # | Componente | Que aporta | Participa del `COMMIT` |
|---|---|---|---|
| 1 | **Redis** -- candado de checkout | evita el doble cobro | no |
| 2 | **Redis** -- hash del carrito | las lineas y sus cantidades | no |
| 3 | **Redis** -- contador de venta relampago | las unidades apartadas y el ticket | no |
| 4 | **MongoDB** -- catalogo | el nombre del producto y de la variante | no |
| 5 | **PostgreSQL** -- `oferta` | precio y stock de verdad | **SI** |
| 6 | **PostgreSQL** -- `comprar_carrito()` | pedido, lineas, kardex, pago | **SI** |
| 7 | **PostgreSQL** -- `evento_grafo` | la cola hacia Neo4j | **SI** |
| 8 | **MongoDB** -- campos agregados | stock y ofertas por producto, para la lista | no |
| 9 | **Neo4j** | el grafo de resenas y fraude | no |
| 10 | **Elasticsearch** | el indice de busqueda | no |

Solo tres de los diez estan dentro de la transaccion. Ese reparto es el
documento entero.

### El orden real de las llamadas

```
1  candado         SET carrito:lock:<usuario> 1 EX 30 NX
2  verCarritoEnVivo  lee Redis + Mongo (nombres) + PostgreSQL (precio y stock)
3  leerLineasConReserva   lee los tickets vivos ANTES de tocar nada
4  bloqueantes     lineas que ya no se pueden comprar
5  precio          compara la foto de Redis contra el precio de hoy
6  COMPRA          SELECT comprar_carrito(...)      <-- la unica transaccion
7a fallo           devolverReservas       (compensacion)
7b exito           confirmarReservas      (best-effort)
8  vaciar          DEL del hash del carrito
9  recalcular      los agregados de Mongo
```

El paso 3 va antes del 6 **a proposito**, y no es un detalle de estilo: el paso
8 borra el hash del carrito y con el los tickets. Leerlos despues seria leerlos
cuando ya no existen, y entonces no habria forma de confirmarlos ni de
devolverlos.

---

## 2. Lo que SI es atomico, y por que se puede afirmar

`comprar_carrito()` (`migrations/012_comprar_carrito.sql`) compone tres
funciones dentro de **una sola llamada**, o sea una sola transaccion implicita
de PostgreSQL:

```
crear_pedido(usuario, direccion)
agregar_linea(pedido, linea)      por cada linea
comprar_pedido(pedido, metodo)    stock, kardex, pago y estado
```

Si cualquiera falla, las tres se deshacen juntas. **No existe el pedido a
medias**: o hay pedido con su pago y su stock descontado, o no hay ni fila de
pedido.

Dentro de `comprar_pedido` (`migrations/007_flujo_pedido.sql:413`) el bucle
hace, por cada linea:

```sql
SELECT * INTO v_oferta FROM oferta WHERE id_oferta = ... FOR UPDATE;
IF v_oferta.stock < v_linea.cantidad THEN RAISE EXCEPTION ...
INSERT INTO stock_movimiento (...)          -- el kardex
UPDATE oferta SET stock = stock - cantidad
```

Tres cosas de ahi que son decisiones de consistencia:

**`FOR UPDATE` y no una lectura suelta.** La fila de la oferta queda bloqueada
hasta el final de la transaccion. Dos compras del mismo producto a la vez se
ponen en fila; la segunda ve el stock que dejo la primera, no el de antes.

**`ORDER BY ph.id_oferta` en el cursor que recorre las lineas.** Es
antibloqueo mutuo, y es facil que se pierda si alguien reordena esa consulta.
Dos carritos con las mismas dos ofertas en distinto orden se agarrarian una
fila cada uno y se esperarian para siempre. Tomandolas siempre en el mismo
orden, eso no puede pasar.

**El kardex se escribe ANTES del `UPDATE`.** `stock_movimiento` guarda el
`stock_resultante`, o sea la foto de como quedo. Escribirlo dentro de la misma
transaccion es lo que permite reconstruir el stock de cualquier dia sin
creerle a la columna de hoy.

---

## 3. Los puntos de falla, uno por uno

Cada uno con lo que se adopto. La ultima columna usa las tres categorias que
pide el enunciado.

| # | Que puede pasar | Que se hace | Categoria |
|---|---|---|---|
| 1 | Doble clic en Pagar, dos peticiones identicas | candado en Redis, 30 s, por cuenta | reintento idempotente |
| 2 | El precio cambio entre ver y pagar | se compara la foto guardada en Redis y se rechaza pidiendo confirmacion | rechazo explicito |
| 3 | Se acabo el stock entre ver y pagar | `comprar_pedido` lanza excepcion, no se escribe nada | todo o nada |
| 4 | Falla la compra con reservas tomadas | `devolverReservas` las suelta ya, sin esperar el TTL | **compensacion** |
| 5 | La compra sale bien y falla Redis al confirmar | se sigue, la venta esta cerrada | ventana aceptada |
| 6 | El proceso muere entre el COMMIT y el vaciado del carrito | el carrito vence solo por TTL | ventana aceptada |
| 7 | Dos compras a la vez sobre la misma oferta | `FOR UPDATE` con orden fijo | serializacion |
| 8 | Los numeros del catalogo de Mongo quedan viejos | cola `evento_producto` (migracion 030): el trigger anota el producto en la misma transaccion y un worker los recalcula | **reintento idempotente** |
| 9 | El grafo de Neo4j queda viejo | cola `evento_grafo` + worker cada 10 s | **reintento idempotente** |
| 10 | El indice de busqueda queda viejo | se reconstruye entero con el ETL | ventana aceptada |
| 11 | MongoDB cae durante el checkout | la compra sale igual: el nombre, el estado y la portada de la variante estan copiados en `producto_catalogo` y `variante_catalogo` (migracion 029), y el recalculo va por la cola de la fila 8 | **resuelto** (6f89237 de Jose David). La copia la escribe el backend al editar un producto y el paso 7e de arrancar la pone al dia; queda la ventana de un proceso que muere entre escribir Mongo y el COMMIT de la copia |

### 1. El doble cobro, que ya paso

Dos `POST /carrito/comprar` identicos y concurrentes **creaban dos pedidos y
cobraban dos veces**. Esta escrito como hallazgo, no como hipotesis.

Se cierra con un candado corto en Redis:

```
SET mesh:checkout:<id_usuario> 1 EX 30 NX
```

`NX` es todo el mecanismo: el segundo no lo obtiene y recibe un 409 que dice
"ya tienes una compra en curso".

El `EX 30` es la red de abajo. El candado se suelta en un `finally`, o sea en el
camino feliz y en el de error, pero si ese `DEL` fallara el vencimiento lo
limpia igual. Sin el, un proceso que muriera con el candado tomado dejaria a esa
cuenta **sin poder comprar nunca mas**, y eso no se arregla solo.

**Medido el 2026-09-04** contra el sistema vivo, poniendo el candado a mano y
pidiendo el checkout con esa misma cuenta:

```
SET mesh:checkout:7 1 EX 30 NX      ->  OK
POST /carrito/comprar               ->  HTTP 409
   "Ya tienes una compra en curso, espera un momento antes de reintentar"
```

**Lo que este candado NO da**, y conviene decirlo antes de que alguien se
confie: no es un `mutex` distribuido correcto. Si la peticion tardara mas de 30
segundos, el candado vence estando ella viva y una segunda entraria. Se acepta
porque el checkout tarda milisegundos y porque **debajo hay una segunda
defensa** que si es transaccional, el `FOR UPDATE` sobre la oferta. El candado
ahorra el trabajo; quien de verdad impide vender dos veces la misma unidad es
PostgreSQL.

### 2. El precio que se movio

El precio **no se congela al agregar al carrito**, se congela al pagar. Es una
decision con costo conocido y esta en `docs/PENDIENTES.md`, punto 1.

Lo que si se hace es no cobrarlo en silencio. Desde el 2026-09-23 cada linea
del HASH `mesh:carrito:<id>` es una foto en JSON (`id_oferta -> {cantidad,
precio, porcentaje_descuento, nombre, imagen, vendedor...}`), y `GET /carrito`
solo lee esa foto. El precio de la foto ya lleva el descuento de la oferta, si
tenia uno. Al pagar, el backend compara la foto con el precio de hoy **dentro
de la misma peticion que cobra**, y si alguno cambio contesta `comprado:false`
con `avisos`, sin cobrar. El cliente ya no manda precios (`lineas_precio_visto`
se quito). La compra pasa solo si se reenvia con `confirmar_cambios: true`, y
entonces se cobra el precio final de hoy.

O sea que la garantia no es "pagaras lo que viste", es **"no se te cobra un
precio distinto del que viste sin que lo aceptes"**. Son cosas distintas y la
segunda es la que el sistema cumple.

### 3 y 4. El stock y las reservas, que es donde vive la compensacion

Aqui hay que separar dos mecanismos que se parecen y no son lo mismo.

**El carrito NO reserva stock.** Meter algo al carrito no aparta nada; el stock
se comprueba y se descuenta al pagar. Es una decision, no un olvido: un carrito
que reserva obliga a cosechar reservas de carritos abandonados, y eso es un
proceso mas que mantener. Se acepta que dos personas puedan tener lo mismo en
el carrito y que una se quede sin ello al pagar. Comprobado en
`redis/prueba_carrito.sh`: al vencer un carrito no queda nada que liberar en
PostgreSQL.

**La venta relampago SI reserva**, y ahi si hay unidades apartadas en Redis con
un ticket por persona y 15 minutos de plazo (`redis/inventario_limitado.lua`).

De esa segunda sale el unico patron de compensacion del flujo:

```
la compra falla   ->  devolverReservas(usuario, lineasConReserva)
                      las unidades vuelven al contador de Redis EN EL ACTO
la compra pasa    ->  confirmarReservas(...)
                      lo apartado pasa a vendido
```

Sin esa compensacion las unidades igual volverian, pero **quince minutos
despues**, al vencer el ticket. En una venta relampago de pocas unidades eso es
la diferencia entre venderlas y no venderlas.

### 5. Confirmar la reserva es best-effort, y es correcto que lo sea

Si la compra se cerro en PostgreSQL y despues Redis no contesta al confirmar,
**no se deshace la venta**. Se sigue.

Es la decision menos obvia del documento y por eso se justifica: la venta ya
esta pagada y con su stock descontado en la base que manda. Deshacerla por un
fallo del contador auxiliar seria dejar sin su compra a alguien que pago,
para arreglar un numero.

Lo que queda mal mientras tanto es el contador de Redis, que sigue diciendo
"reservada" sobre una unidad que ya se vendio. Se arregla solo al cerrar la
venta relampago, que borra las claves. **Consecuencia aceptada: durante una
venta relampago abierta, el contador puede quedar por debajo de lo real tras un
fallo de Redis.** Nadie sobrevende por eso; a lo sumo se dejan de vender
unidades que si estaban.

### 6. La ventana entre el COMMIT y el vaciado del carrito

Si el proceso muere justo despues del `COMMIT` y antes del `DEL`, la compra
existe y el carrito sigue lleno. La persona veria su carrito con lo que acaba
de comprar.

No se cierra con nada, y se acepta por dos razones: el carrito vence solo por
inactividad, y volver a comprarlo pasaria por el paso 3, que ahora encontraria
el stock ya descontado. O sea que la ventana es fea de ver pero no cobra dos
veces.

### 9. El grafo, que es el unico con reintentos de verdad

Este es el mecanismo mas completo del sistema y no es del checkout, es de las
resenas, pero es el patron que el proyecto adopta para las proyecciones.

El problema que resuelve: si el backend le escribiera a Neo4j **despues** de
commitear en PostgreSQL, un proceso que se cae entre las dos cosas deja la
resena escrita, el grafo sin ella, y **ninguna constancia de que falte**.

La solucion es un outbox. `migrations/015_outbox_grafo.sql` crea `evento_grafo`
y un trigger sobre `resena` que encola el cambio **en la misma transaccion que
la resena**. Esa frase es todo el diseno: o se guardan las dos cosas o ninguna.

Despues un worker del backend (`@Interval` cada 10 s) vacia la cola contra
Neo4j. Es idempotente porque proyecta con `MERGE`, asi que aplicar dos veces el
mismo evento deja el grafo igual. Lleva un contador de `intentos` para que un
evento envenenado no bloquee la cola para siempre.

**La ventana es de unos 10 segundos y esta medida:**

```
resena creada   ->  ~10 s despues  ->  el nodo y sus 3 relaciones en Neo4j
resena borrada  ->  ~10 s despues  ->  el nodo desaparece
```

Y no se afirma que este al dia, se comprueba: `GET /admin/grafo/conciliacion`
compara los conteos de las dos bases y el panel de fraude ensena en su cabecera
de cuando son los datos que acaba de analizar. Si no cuadran, lo dice en rojo.

### 8 y 10. Las dos copias que van detras

**Los agregados de Mongo** (stock y ofertas por producto, que pinta la lista del
catalogo) se recalculan al final del checkout. Si eso falla, la lista ensena
numeros viejos un rato. Se acepta: la ficha del producto y el propio cobro
preguntan a PostgreSQL, asi que **una lista vieja no vende de mas**, solo se ve
mal.

**El indice de Elasticsearch** no se toca en el checkout. Se reconstruye entero
con `bash etl/cargar_busqueda.sh`, y `arrancar.ps1` lo rehace cuando no cuadra
con el catalogo. Su ventana es "hasta la proxima corrida del ETL", que es la mas
larga de todas y la mas barata de aceptar: que el buscador tarde en enterarse de
un producto nuevo no le cuesta dinero a nadie.

**La nota del producto** (`resenas_promedio`) tiene la misma ventana, y ahi hay
una asimetria deliberada que conviene declarar: la **ficha** calcula la nota en
vivo contra PostgreSQL y la **lista** lee la copia de Mongo. Pueden ensenar dos
numeros distintos a la vez. Es correcto y esta decidido: el numero que se le
ensena a la persona sale en vivo, y la copia existe para **filtrar y ordenar** el
catalogo, que es una operacion masiva que no se puede hacer en vivo.

### 11. MongoDB cae durante el checkout

**Resuelta el 2026-09-30 (6f89237 de Jose David, migraciones 029 y 030).** El
carrito y las dos rutas de compra leen el nombre, el estado y la portada de la
variante de `producto_catalogo` y `variante_catalogo`, una copia en PostgreSQL
que Mongo sigue mandando. El recalculo del catalogo despues de cobrar ya no se
espera: el trigger de `oferta` anota el producto en `evento_producto` dentro de
la misma transaccion y un worker lo hace despues. El escenario B de
`pruebas/falla_checkout.sh` exige ahora que la compra salga con Mongo parado.
Lo de abajo es como estaba y como se midio antes.

**Agregada el 2026-09-11.** Salio como hallazgo de la prueba de falla de la
seccion 4 bis, y Jose David la midio por su lado el 2026-09-07. Su documento es
`backend/elementos Generales/prueba-falla-mongo-checkout.md`, y pedia esta fila.

MongoDB no participa del `COMMIT`, pero las dos rutas de compra lo **leen antes**
de llegar a el: el nombre del producto y de la variante, y el estado de la
variante, que no se copia a PostgreSQL.

```
POST /carrito/comprar                  verCarrito() lee Mongo antes de la transaccion
POST /comprador/pedidos/:id/comprar    lee el estado de la variante dentro de la
                                       transaccion, antes del COMMIT
```

Si esa lectura falla, la compra se corta ahi y nunca llega a
`comprar_carrito()` ni a `comprar_pedido()`:

```
HTTP 503   "No se pudo conectar con MongoDB"
pedido, pago, kardex y stock   iguales antes y despues
candado de Redis               suelto, se puede reintentar de inmediato
el carrito                     entero
```

Es lo que mide el escenario B de `bash pruebas/falla_checkout.sh`, y lo volvio
a medir la corrida del 2026-09-11 (31 OK, 0 FALLA). En la ruta del pedido, segun
el documento de Jose David, la transaccion hace `ROLLBACK` y el pedido se queda
`pendiente`, reintentable.

**Lo que ya cambio es cuanto tarda en fallar.** Con los valores por defecto del
driver, la compra se quedaba colgada unos 32 s: son los 30 s de
`serverSelectionTimeoutMS` reintentando, con la peticion y una conexion del pool
tomadas todo ese rato. Jose David lo bajo a 3 s en `src/database/mongo.ts`, y
ahora falla en unos 5 s (los 3 del driver mas lo que `verCarrito` hace antes).
La semantica no cambia: sigue siendo 503 y sigue sin escribir nada.

**Por eso la categoria es "todo o nada" y no "ventana aceptada".** No hay
ninguna escritura que quede a medias, ni una que haya que compensar. Lo que hay
es una dependencia de **disponibilidad**: sin Mongo no se vende, aunque Mongo
nunca escriba nada del pedido.

**Como manejarla sigue por decidir con el profesor.** Las tres salidas que
propone el documento de Jose David:

1. **Aceptarla y dejarla escrita**, como ya se acepta la confirmacion de reservas
   de la fila 5. Es lo que hace esta fila hoy.
2. **Copiar el estado de la variante a PostgreSQL**, como ya se copian precio y
   stock a `oferta`. En la ruta del pedido el nombre ya esta congelado en
   `pedido_producto`, asi que el estado de la variante es lo unico vivo que falta.
3. **Degradar en vez de fallar**: seguir con el ultimo nombre conocido y dar la
   variante por activa. El riesgo es vender una variante que se desactivo sin
   que el backend se enterara.

---

## 4. Lo que NO esta resuelto

Un documento de consistencia que solo cuente lo que funciona no sirve para
retomar el proyecto.

**El precio no se congela al agregar.** Cubierto por el aviso del punto 2, pero
la garantia fuerte sigue sin existir. `docs/PENDIENTES.md`, punto 1.

**La nota del catalogo no tiene cola.** Se refresca cuando alguien corre el ETL.
El camino esta claro y es el mismo patron del grafo, pero no esta hecho.

Aqui decia tambien que el indice de busqueda no la tenia, y **eso dejo de ser
cierto la misma noche en que se escribio este documento**: Jose David monto la
bandera `pendiente_busqueda` en Mongo con su `BuscadorSyncService`, un
`@Interval` cada 10 s, unas horas despues. El documento se quedo con la frase
vieja hasta el 2026-09-06. Queda escrito porque es el mismo fallo que este
proyecto persigue en el codigo, un dato derivado que envejece sin que nadie
avise, solo que aqui el dato derivado era una frase.

**Los eventos de la base columnar tampoco tienen cola, y es a proposito.** La
copia de `log_login` y `log_registro` a ClickHouse es incremental por marca de
agua, no por outbox, y la diferencia importa: un logueo no se edita ni se borra
nunca, asi que basta con preguntar por el mayor id ya copiado. Una cola hace
falta cuando el origen puede CAMBIAR debajo, que es el caso de una resena y no
el de un evento. Ver `etl/cargar_eventos.sh`.

**Dos repartidores de id de producto.** PostgreSQL con su `bigserial` y el panel
del vendedor con el maximo de Mongo mas uno. Cuando se crucen, el `replaceOne`
del ETL machaca un producto **sin dar ningun error**. Desde el 2026-09-04 el
arranque avisa cuando el margen se acaba, pero avisar no es arreglar.
`docs/PENDIENTES.md`, punto 5.

---

## 4 bis. La prueba de falla simulada, con su evidencia

**Hecha el 2026-09-06, y cierra el requisito de la Entrega 3** que pide
"evidencia de al menos una prueba de falla simulada sobre el flujo de checkout y
el comportamiento resultante del sistema". Hasta esa fecha este documento
enumeraba diez puntos de falla y **ninguno estaba provocado**.

```bash
bash pruebas/falla_checkout.sh
```

Se corre el mismo checkout cinco veces cambiando solo lo que hay debajo. La
linea base con todo vivo no es adorno: sin ella, un escenario que no compra no
prueba nada, porque podria ser que la falla lo impidiera o que el arnes nunca
supiera comprar.

**Vuelta a correr el 2026-10-18, con el carrito en PostgreSQL: 32 OK, 0 FALLA.**

| Escenario | HTTP | Que quedo en PostgreSQL | El carrito |
|---|---|---|---|
| todo vivo | 201, `comprado: true` | pedido, pago, kardex, stock de 15 a 14 | se vacia |
| Redis parado | **201, `comprado: true`** | pedido, pago, kardex, stock de 14 a 13 | se vacia |
| MongoDB parado | 201, `comprado: true` | pedido, pago, kardex, stock de 13 a 12 | se vacia |
| PostgreSQL parado | **503** "No se pudo conectar con PostgreSQL" | intacto | entero |
| todo vivo otra vez | 201, `comprado: true` | stock de 12 a 11 | se vacia |

El escenario A cambio de regla: hasta el 2026-10-17 se EXIGIA que con Redis
parado no comprara (el carrito vivia solo ahi); ahora se exige que compre.
Ninguna caida cobro a medias, y el candado quedo suelto en todas.

Lo de abajo es la historia de la primera corrida.

**Resultado del 2026-09-06: 31 OK, 0 FALLA, y un hallazgo para declarar.**

| Escenario | HTTP | Que quedo en PostgreSQL | El carrito |
|---|---|---|---|
| todo vivo | 201, `comprado: true` | pedido, pago, kardex, stock de 7 a 6 | se vacia, como debe |
| Redis parado | no compro | intacto | entero |
| MongoDB parado | no compro | intacto | entero |
| PostgreSQL parado | **503** "No se pudo conectar con PostgreSQL" | intacto | entero |
| todo vivo otra vez | 201, `comprado: true` | vuelve a vender, stock de 7 a 6 | se vacia |

**Ninguna caida cobro a medias.** En los tres escenarios PostgreSQL quedo con
los mismos pedidos, los mismos pagos, el mismo kardex y el mismo stock que
antes de intentarlo. Y en los tres el candado de Redis quedo suelto, o sea que
la cuenta puede reintentar de inmediato sin esperar a que venza.

### El hallazgo, que este documento no decia

> **MongoDB parado impide comprar, y esa base NO participa del COMMIT.**

La seccion 2 de aqui arriba dice que lo atomico son las tres escrituras de
PostgreSQL, y que Mongo solo aporta nombres para la pantalla. De ahi se seguiria
que con Mongo caido la compra deberia salir igual, quiza sin algun nombre. **No
sale.**

No es un fallo de consistencia -- no se cobro nada y no quedo nada a medias, que
es lo importante -- pero **es una dependencia que no estaba escrita**, y una
dependencia no escrita es la que tumba un sistema el dia que esa base se cae de
verdad. Desde el 2026-09-11 es la fila 11 de la seccion 3, con lo que midio
Jose David y las tres salidas que quedan por decidir.

**Vuelta a correr el 2026-09-11: 31 OK y 0 FALLA, con el mismo OJO.** Los tres
escenarios de caida contestaron 503 con el nombre de la base que faltaba ("No
se pudo conectar con Redis", "con MongoDB", "con PostgreSQL"), y PostgreSQL
quedo igual en los tres: 42 pedidos, 42 pagos, 5666 filas de kardex. Esa corrida
dejo los pedidos 119 y 120.

`docker stop` es una parada ORDENADA, con SIGTERM y cierre limpio de archivos.
Un corte de luz es mas bruto y puede dejar cosas que esto no toca. Lo que si
cubre, que es lo que pide la entrega, es la vista desde el checkout: la base no
esta, y que hace el sistema con eso.

**Esta prueba compra de verdad** y deja pedidos, pagos y movimientos de stock
que no se deshacen. Borrarlos a mano dejaria el kardex mintiendo, que es peor
que un pedido de mas. El arnes imprime al terminar los `id_pedido` que creo.

---

## 5. Como se comprueba todo esto

No se pide creer nada de lo de arriba. Son doce arneses y estos son los que
tocan este flujo:

```
bash pruebas/carrito.sh            el carrito de punta a punta, y que
                                   PostgreSQL quede igual tras las pruebas
bash pruebas/falla_checkout.sh     LA PRUEBA DE FALLA: para Redis, MongoDB y
                                   PostgreSQL a la hora de pagar, una por una
bash redis/prueba_carrito.sh       que el carrito venza sin dejar nada colgando
bash redis/prueba_concurrencia.sh  1000 solicitudes, 50 clientes a la vez,
                                   100 unidades, y el contador no baja de 0
bash neo4j/correr_fraude.sh        las cinco consultas del grafo
```

`falla_checkout.sh` **para contenedores**, asi que no se corre a la vez que
ningun otro. Su `trap` los devuelve aunque se corte con Ctrl+C, y ese `trap` se
registra antes del primer `docker stop` justamente porque el que no se registra
a tiempo es el que no corre cuando hace falta.

El de concurrencia es el que sostiene la seccion 3: **sin sobreventa, sin
candados, sin reintentos y sin compensar**, porque el `.lua` de la reserva es
atomico del lado de Redis.

Y hay una regla del proyecto que aplica a este documento: **antes de creerle a
un arnes, se rompe el codigo a proposito y se comprueba que falla.** Aqui ya
aparecio un arnes que validaba copias pegadas de las consultas en vez de las
consultas de la entrega.
