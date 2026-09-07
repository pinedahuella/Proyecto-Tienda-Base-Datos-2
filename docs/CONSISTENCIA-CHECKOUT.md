# Estrategia de consistencia del flujo de checkout

**Mesh -- Bases de Datos 2, Universidad del Istmo. Entrega 3.**

Fecha: 2026-09-04. Todo lo que dice este documento sale de codigo que corre hoy
y de mediciones contra la base viva. Donde algo no esta resuelto, se dice que no
lo esta.

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
2  verCarrito      lee Redis + Mongo (nombres) + PostgreSQL (precio y stock)
3  leerLineasConReserva   lee los tickets vivos ANTES de tocar nada
4  bloqueantes     lineas que ya no se pueden comprar
5  precio          compara lineas_precio_visto contra el precio de hoy
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
| 2 | El precio cambio entre ver y pagar | se compara `lineas_precio_visto` y se rechaza pidiendo confirmacion | rechazo explicito |
| 3 | Se acabo el stock entre ver y pagar | `comprar_pedido` lanza excepcion, no se escribe nada | todo o nada |
| 4 | Falla la compra con reservas tomadas | `devolverReservas` las suelta ya, sin esperar el TTL | **compensacion** |
| 5 | La compra sale bien y falla Redis al confirmar | se sigue, la venta esta cerrada | ventana aceptada |
| 6 | El proceso muere entre el COMMIT y el vaciado del carrito | el carrito vence solo por TTL | ventana aceptada |
| 7 | Dos compras a la vez sobre la misma oferta | `FOR UPDATE` con orden fijo | serializacion |
| 8 | Los numeros del catalogo de Mongo quedan viejos | se recalculan al final, y el ETL los rehace | ventana aceptada |
| 9 | El grafo de Neo4j queda viejo | cola `evento_grafo` + worker cada 10 s | **reintento idempotente** |
| 10 | El indice de busqueda queda viejo | se reconstruye entero con el ETL | ventana aceptada |

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

Lo que si se hace es no cobrarlo en silencio. El cliente manda con el checkout
el precio que tenia en pantalla, por linea (`lineas_precio_visto`,
`migrations/013_precio_del_carrito.sql`). El backend lo compara con el precio de
hoy **dentro de la misma peticion que cobra**, y si alguno cambio contesta sin
cobrar. La compra pasa solo si se reenvia con `confirmar_cambios: true`.

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

**Resultado: 31 OK, 0 FALLA, y un hallazgo para declarar.**

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
verdad. Queda anotada aqui y en `docs/PENDIENTES.md`.

`docker stop` es una parada ORDENADA, con SIGTERM y cierre limpio de archivos.
Un corte de luz es mas bruto y puede dejar cosas que esto no toca. Lo que si
cubre, que es lo que pide la entrega, es la vista desde el checkout: la base no
esta, y que hace el sistema con eso.

**Esta prueba compra de verdad** y deja pedidos, pagos y movimientos de stock
que no se deshacen. Borrarlos a mano dejaria el kardex mintiendo, que es peor
que un pedido de mas. El arnes imprime al terminar los `id_pedido` que creo.

---

## 5. Como se comprueba todo esto

No se pide creer nada de lo de arriba. Son ocho arneses y estos son los que
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
