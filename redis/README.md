# La capa de Redis

El almacen clave-valor de Mesh: el carrito con expiracion por inactividad y la
oferta de inventario limitado que no se sobrevende.

Esta carpeta es una pieza SUELTA y a proposito. No hay rutas HTTP aqui: el
backend es de otra persona y no se toca. Lo que hay es el diseno, los dos
scripts Lua y las dos pruebas que demuestran que funciona, de modo que
enchufarlo sea llamar a `EVALSHA` desde donde corresponda.

| Archivo | Que es |
|---|---|
| `carrito.lua` | Operaciones del carrito. Un solo paso: escribir y renovar el vencimiento. |
| `inventario_limitado.lua` | Comprobar y descontar EN UN SOLO PASO. Lo que la rubrica pide. |
| `prueba_carrito.sh` | Evidencia del TTL por inactividad, y de que al vencer no hay nada que liberar. |
| `prueba_concurrencia.sh` | Evidencia de que 1000 solicitudes sobre 100 unidades venden 100. |

```
bash redis/prueba_carrito.sh          # unos 50 segundos
bash redis/prueba_concurrencia.sh     # unos 60 segundos
```

No hace falta instalar nada. `redis-cli` y `redis-benchmark` vienen dentro del
contenedor `mesh-redis`, y los scripts Lua los corre Redis. Las pruebas leen
PostgreSQL con el `psql` del contenedor `mesh-postgres` y **no le escriben
nada**: la unica compra que hacen esta envuelta en `BEGIN ... ROLLBACK`.

Todas las claves que las pruebas crean empiezan con `prueba:` y se borran al
terminar. Se comprueba con un `--scan` al final, porque "ya limpie" sin medirlo
es como no haberlo dicho.


---

# 1. El carrito

## Que habia antes

El carrito es hoy una fila de `pedido` en estado `pendiente` en PostgreSQL, con
su id guardado en `localStorage`. Tiene dos problemas:

- **No vence nunca.** La tabla `pedido` acumula carritos abandonados para
  siempre, y cada uno arrastra sus filas de `pedido_producto`.
- **Exige tener cuenta.** `pedido.id_usuario` es `NOT NULL` y apunta a
  `usuarios`, asi que no hay forma de que alguien meta algo al carrito antes de
  registrarse.

## Las claves

```
mesh:carrito:<id_usuario>        HASH
    l:<id_oferta>   el JSON de la linea, tal cual lo mando el backend
    c:<id_oferta>   la cantidad, como entero suelto
```

**Por que un HASH y no un JSON en una clave normal.** Con un JSON, cambiar la
cantidad de un producto obliga a leer el carrito entero, modificarlo en el
backend y reescribirlo entero. Eso es leer-modificar-escribir: dos pestanas del
mismo navegador agregando a la vez leen las dos lo mismo, escriben las dos lo
mismo, y una de las dos sumas desaparece sin que nadie se entere. Con un hash,
cada linea es un campo que se toca solo, y `HGETALL` sigue trayendo el carrito
completo en un viaje.

**Por que la cantidad va separada del JSON.** Para poder sumarla con `HINCRBY`,
que ya es atomico. La alternativa era abrir el JSON dentro de Lua con `cjson`,
y eso tiene una trampa cara: Lua guarda los numeros como coma flotante de doble
precision, asi que cualquier id que pase por `cjson.decode` vuelve convertido en
un `double`. Con ids `bigserial` chicos no se nota; el dia que uno pase de 2^53
el id vuelve cambiado y el carrito compra otra cosa. Ademas `cjson.encode`
reordena las claves, o sea que lo guardado deja de ser byte a byte lo que el
backend mando. **Aqui el JSON nunca se abre: entra como cadena y sale como
cadena.**

**Por que un script Lua y no `HSET` + `EXPIRE` desde el backend.** Son dos
comandos, y si el backend se cae o pierde la conexion entre uno y otro, el
carrito queda SIN vencimiento. No falla nada y no se ve nada: una clave inmortal
se ve exactamente igual que una normal, y nadie se entera hasta que la memoria
se llena.

## El vencimiento: explicito, y por INACTIVIDAD

Una clave de Redis sin `EXPIRE` vive para siempre; `TTL` devuelve `-1`. El
vencimiento aqui **esta puesto a proposito y con un numero**, y se vuelve a
poner entero en cada toque: agregar, restar, quitar, mirar y el latido.

**Valor propuesto: 86400 segundos (24 horas) de inactividad.** No sale de una
tabla: 24 horas es el hueco entre "lo dejo para pensarlo" y "se olvido". Mas
corto castiga a quien arma el carrito de noche y paga a la manana; mas largo
guarda carritos con precios que ya no existen, que al pagar fallan con un error
que la persona no entiende. Tiene que llegar como configuracion
(`MESH_CARRITO_TTL`), no escrito en el codigo: el TTL entra a los scripts como
ARGV justamente para que se pueda cambiar sin tocarlos.

### Y no es el mismo reloj que el del JWT

Es el criterio que hay que justificar, asi que va de frente:

| | JWT de sesion | Carrito en Redis |
|---|---|---|
| Cuenta desde | que se firma | el ultimo toque |
| Usarlo | no lo alarga | lo devuelve entero |
| Dura | 2 horas fijas | 24 horas de inactividad |
| Que mide | cuanto vive una credencial | cuanto le importa a alguien un dato |

Una persona que compra sin parar durante seis horas pierde la sesion a las dos
y **no** pierde el carrito. Una que abandona el carrito lo pierde a las 24 horas
del ultimo clic, tenga la sesion viva o no.

Son dos relojes distintos porque miden dos cosas distintas. Una credencial
robada tiene que morir en algun momento pase lo que pase, y por eso el JWT es
fijo. Un carrito que venciera "2 horas despues de crearse" seria hostil, y una
sesion que se renovara sola con cada clic seria una sesion eterna.

**La consecuencia que se acepta:** una pestana abierta que se refresque sola
mantiene el carrito vivo para siempre. Se acepta porque un carrito de mas cuesta
unos cientos de bytes, y un carrito que desaparece delante de la persona cuesta
una venta.

## El efecto sobre el checkout

**Cuando un carrito vence, no hay NADA que liberar.** `docs/base-de-datos.md`
lo dice textual: *"Mientras el pedido esta pendiente, el stock NO esta
reservado"*. Agregar al carrito nunca reservo nada -- `agregar_linea()`
comprueba que haya stock pero no lo descuenta, y la propia funcion lo llama
"una cortesia para avisar temprano, no una garantia". Un carrito que se evapora
no deja stock retenido, ni un pedido pendiente, ni una fila que alguien tenga
que ir a limpiar. No hace falta ningun proceso que vaya venciendo reservas,
porque no hay reservas.

`prueba_carrito.sh` no lo afirma: lo mide. Toma `sum(stock)` de `oferta` y
`count(*)` de `pedido` antes de crear el carrito y despues de que vence, y
comprueba que sean iguales.

**Al pagar**, el carrito de Redis se le pasa entero a `comprar_carrito()`
(migrations/012), que crea el pedido, le mete todas las lineas y lo compra
dentro de UNA transaccion. Si algo falla, no queda ni el pedido ni las lineas.
El formato de `p_lineas` es un arreglo de los mismos objetos que recibe
`agregar_linea`, y el backend lo arma juntando el campo `l:` con el campo `c:`:

```
[{"id_oferta":3,"id_producto":1,"id_producto_variante":13,
  "id_precio_historial":3,"precio_visto":5840.00,
  "nombre_producto":"Laptop Ambar Campus 14","nombre_variante":"variante 13",
  "cantidad":2}, ...]
```

El orden es: `comprar_carrito()` primero, `vaciar` despues. Nunca al reves. Si
se vaciara primero y el pago fallara, la persona se queda sin carrito y sin
compra, y tiene que armarlo producto por producto otra vez.

## LA CONSECUENCIA QUE HAY QUE MIRAR DE FRENTE: el precio congelado

`agregar_linea()` congela el precio **en el momento de agregar al carrito**. La
007 dice por que, textual: *"si el vendedor lo sube despues, este pedido
conserva el que se le mostro a la persona"*. Lo congela guardando el
`id_precio_historial` de la fila vigente, que no se actualiza nunca.

Con el carrito en Redis eso se pierde. Agregar y comprar pasan en el mismo
instante -- el instante de PAGAR -- asi que `agregar_linea()` busca el precio
vigente en ese momento, no el que la persona vio cuando puso el producto en el
carrito. **Si el vendedor lo subio en el medio, se le cobra el nuevo, en
silencio y sin ningun error.** La 012 ya dejo escrita esta deuda; aqui es donde
se cobra.

**La salida, y es lo que este diseno hace:** el carrito de Redis guarda tambien
el `id_precio_historial` de cada linea, junto con el `precio_visto`. Es el campo
que se ve en el JSON de arriba, y `prueba_carrito.sh` comprueba que este --
y ademas mide que PostgreSQL todavia lo descarta, que es la otra mitad de la
verdad.

Guardarlo es la mitad barata. La otra mitad **no esta hecha y no se puede hacer
desde aqui**, porque vive en `backend/` y en `migrations/`:

1. `agregar_linea()` tiene que aceptar un `id_precio_historial` en `p_linea` y
   usarlo en vez de buscar el vigente. Es un cambio en la 007.
2. Y tiene que **validar** que ese id sea de esa oferta. Sin eso, el backend
   podria mandar el id de un precio viejo -- o de otra oferta -- y comprarse la
   laptop al precio de un cable. Confiar en un id que llega del cliente es un
   agujero de autorizacion, no una comodidad.
3. Falta decidir que pasa cuando el precio cambio: cobrar el viejo, o avisar
   ("este producto subio de precio, confirmas?"). Las dos son defendibles; lo
   que no es defendible es cobrar el nuevo sin decirlo, que es lo que pasa hoy.

Mientras eso no exista, el `id_precio_historial` viaja en el carrito y nadie lo
mira. Esta guardado desde ya para que el dia que se conecte no haya que migrar
carritos vivos, y `prueba_carrito.sh` lo comprueba **midiendo el resultado**:
manda un id inexistente, la compra sale igual, y lo que queda en
`pedido_producto` es el vigente. Cuando eso deje de ser cierto, el arnes se pone
rojo y obliga a actualizar esta seccion.

## De regalo: el carrito de invitado

La clave es `mesh:carrito:<id_usuario>`, pero Redis no obliga a que ese
identificador sea una fila de `usuarios`: puede ser un id de sesion anonima. Al
registrarse, el carrito de invitado se funde con el de la cuenta llamando
`agregar` por cada linea, y se borra el de invitado. Eso en PostgreSQL era
imposible sin cambiar el esquema, porque `pedido.id_usuario` es `NOT NULL` con
llave foranea.

No esta implementado -- la fusion es del backend -- pero el diseno de la clave
ya lo permite y no cuesta nada dejarlo dicho.


---

# 2. La oferta de inventario limitado

## El problema

`comprar_pedido()` (migrations/007) impide la sobreventa con
`SELECT ... FOR UPDATE` sobre la fila de `oferta`. Funciona, y es exactamente
lo que la Entrega 2 pide **no** usar: quiere operaciones atomicas del
clave-valor y **sin bloqueos a nivel de aplicacion**.

## Por que no alcanza con que Redis sea de un solo hilo

Es la confusion que hay que sacarse de encima primero, porque suena a que el
problema no existe. Redis atiende un comando a la vez: eso hace atomico cada
comando SUELTO, no una DECISION que necesita dos.

**Forma ingenua 1 -- leer y despues descontar.**

```
GET  stock      -> "1"     (cincuenta clientes leen "1")
DECRBY stock 1             (los cincuenta descuentan)
```

Los dos comandos fueron atomicos. La decision no. Termina en -49.

**Forma ingenua 2 -- descontar y compensar.** `DECRBY`, y si quedo negativo
`INCRBY` para devolverlo. El stock queda bien al final, pero entre los dos
comandos el contador estuvo en negativo y cualquiera que leyera en ese hueco vio
un numero que no era. Y si el proceso que iba a compensar se cae, la unidad se
pierde para siempre. Son dos pasos: es justo lo que el enunciado prohibe.

**Forma ingenua 3 -- un candado.** `SET lock NX PX 3000`, hacer el `GET` y el
`DECRBY` tranquilo, `DEL`. Funciona y esta prohibido por el enunciado, con
razon: el que toma el candado y se muere deja a todos esperando el `PX`; el que
tarda mas que el `PX` cree que todavia lo tiene y ya no; y hay que elegir un
tiempo de espera que nadie sabe cuanto es. Es reimplementar un gestor de
transacciones a mano y mal.

## Lo que hace un script Lua

Redis corre el script **entero** como si fuera un solo comando. Nadie se mete en
el medio, no hay hueco entre el "comprobar" y el "descontar", y no hace falta
ningun candado porque no hay nada que proteger: la decision entera es un paso.

Ese es el argumento, y la seccion 3 lo mide en vez de prometerlo.

Un detalle que no es estetico sino la garantia: dentro de `reservar`, **todas**
las salidas por rechazo estan ANTES del primer `HINCRBY` sobre el stock. Redis
no deshace lo que un script ya escribio, asi que un `return` despues de haber
descontado dejaria unidades desaparecidas.

## Las claves

```
mesh:oferta:<id_oferta>            HASH
    stock      unidades que todavia se pueden tomar
    reservado  unidades tomadas y sin confirmar
    vendidas   unidades confirmadas (el pago paso en PostgreSQL)
    rechazos   intentos que se fueron con las manos vacias
    ticket     ultimo numero de ticket entregado
    r:<ticket> cantidad de esa reserva
    u:<ticket> quien la tiene

mesh:oferta:<id_oferta>:reservas   ZSET
    miembro = ticket, puntaje = milisegundo en que vence
```

Son **dos** claves y no cinco porque un script Lua solo puede tocar claves que
esten en `KEYS` si algun dia esto corre en Redis Cluster, y ademas todas tienen
que caer en el mismo nodo. Meter el detalle de cada reserva como campos del
MISMO hash, en vez de una clave por reserva, es lo que evita tener que declarar
N claves que no se conocen de antemano -- que es justo lo que un script no puede
hacer. Para Cluster faltaria envolver el id en llaves (`mesh:oferta:{3}`) para
que las dos caigan en la misma ranura; con una sola instancia no hace falta y no
se hizo.

**Por que un ZSET de vencimientos y no un `EXPIRE` por reserva.** Cuando una
reserva vence hay que DEVOLVER la unidad al contador, y el `EXPIRE` de Redis
borra la clave sin avisarle a nadie. Se podria escuchar el evento de expiracion
del keyspace, pero esos avisos se pierden si nadie esta suscrito en ese momento
-- y el stock se perderia en silencio, que es la peor forma de perderlo. Con el
ZSET, el vencimiento se cosecha dentro del **mismo paso atomico** de la reserva
siguiente: sin proceso de fondo, sin suscripcion, y sin que nadie pueda ver el
estado intermedio en el que las unidades ya volvieron pero todavia no se
entregaron.

La cosecha tiene tope (100 por llamada) porque el script corre con Redis entero
detenido: liberar 50 000 reservas de un tiron dejaria al servidor sin atender a
nadie, y el sintoma seria "Redis se congela cada tanto sin motivo".

## El ciclo de vida

```
  reservar  -> VENDIDO + ticket     el stock baja YA
      |
      +-- confirmar   el pago paso: reservado -> vendidas. El stock NO se toca.
      +-- devolver    el pago fallo: las unidades vuelven al stock.
      +-- (nada)      vence solo, y la reserva siguiente lo cosecha.
```

`confirmar` se llama **despues** de que `comprar_carrito()` devolvio bien, nunca
antes. Si se llamara antes y el pago fallara, la unidad quedaria vendida sin
cobrar y solo un humano se daria cuenta.

`devolver` y el vencimiento hacen lo mismo y los dos hacen falta: uno libera en
el acto (el que cancela) y el otro cubre al que cerro el navegador.

**Reserva propuesta: 900 segundos (15 minutos).** Suficiente para escribir una
tarjeta con calma, corto para que una unidad no quede secuestrada media hora por
alguien que ya se fue. Como el TTL del carrito, entra por parametro
(`MESH_RESERVA_TTL`) y no esta escrito en el script.

## Como se lleva con el `FOR UPDATE` de PostgreSQL

El `SELECT ... FOR UPDATE` de `comprar_pedido()` **no se quita y no se toca**.
Es el libro contable: ahi el stock tiene que cuadrar con `stock_movimiento` pase
lo que pase.

Lo que cambia es **quien decide**. Con Redis delante, PostgreSQL ya no recibe
1000 compras peleandose por 100 unidades: recibe 100 compras que ya ganaron. El
`FOR UPDATE` deja de ser el portero -- que es donde se hacia lento, con 900
transacciones sentadas esperando una fila -- y pasa a ser lo que siempre debio
ser, la ultima comprobacion de que el libro cuadra.

**La parte incomoda, dicha de frente:** son DOS contadores del mismo stock, y
dos contadores se pueden separar. Se separan si una reserva gana en Redis y
despues el pago falla; para eso estan `devolver` y el vencimiento. Se separan
tambien si el vendedor cambia el stock directamente en PostgreSQL, o si Redis se
reinicia sin haber alcanzado a persistir. La reconciliacion real -- contar
tickets confirmados contra `stock_movimiento` y resembrar -- **no esta hecha**;
esta en la lista de la seccion 5, no inventada como si existiera.


---

# 3. La evidencia

Salida real, de la maquina donde corre el proyecto. Redis 8.10.1 en el
contenedor `mesh-redis`.

## La concurrencia se simula con `redis-benchmark`

Viene dentro del contenedor. Abre N conexiones de verdad y les manda el mismo
comando: son 50 sockets hablando a la vez, no un bucle rapido. Un `for` en bash
mandaria una solicitud, esperaria la respuesta y mandaria la siguiente -- nunca
habria dos en el aire y jamas encontraria la carrera.

Como `redis-benchmark` solo informa velocidad y no que contesto cada solicitud,
**el conteo se hace dentro del script Lua**, en el mismo paso atomico que
decide. Y para que ese contador no sea el acusado midiendose a si mismo, se
compara contra tres numeros escritos en lugares distintos: el `ZCARD` del ZSET
(lo llena `ZADD`), el campo `reservado` (lo llena `HINCRBY`) y el `stock`, que
tiene que haber bajado exactamente lo mismo. Un agujero en el script no podria
hacer que los cuatro mintieran igual.

Cada solicitud llega ademas con un `id_usuario` distinto: `redis-benchmark`
reemplaza el testigo `__rand_int__` por un numero al azar. Son 1000 compradores
peleandose, no uno reintentando.

## 1000 solicitudes, 50 clientes a la vez, 100 unidades

```
  evalsha ... reservar __rand_int__ 1 0: 19607.84 requests per second, p50=1.639 msec

  stock final      0
  reservado        100
  tickets dados    100
  reservas vivas   100   (ZCARD, contador independiente)
  rechazos         900

  OK    reservas entregadas = 100
  OK    unidades reservadas = 100
  OK    stock final = 0
  OK    rechazos = 900
  OK    ZCARD contra contador de tickets = 100
  OK    conservacion: stock + reservado = 100
  OK    sin sobreventa: el stock nunca bajo de 0
  OK    se entregaron 100 reservas y no cabia ninguna mas
  OK    solicitudes contestadas (reservas + rechazos) = 1000
```

**100 vendidas de 100 unidades. Exactamente.** Nunca 101, nunca un contador
negativo.

## La misma carga, pero cada uno pide 3 unidades

```
  evalsha ... reservar __rand_int__ 3 0: 38461.54 requests per second, p50=1.039 msec

  stock final      1
  reservado        99
  tickets dados    33
  reservas vivas   33
  rechazos         967
```

Esta ronda existe por un error concreto. Un script que comprobara `stock > 0` en
vez de `stock >= cantidad` daria **34** reservas y dejaria el contador en **-2**:
con 2 unidades y un pedido de 3, la comprobacion pasa. El 33 con 1 que sobra es
el numero que ese error no puede producir.

## Cinco veces mas carga

```
  UNIDADES=250 SOLICITUDES=5000 CLIENTES=200 RONDAS=1

  evalsha ... reservar __rand_int__ 1 0: 25906.73 requests per second, p50=6.271 msec

  stock final      0      reservado 250    tickets 250
  reservas vivas   250    rechazos  4750
```

250 de 250. Sigue exacto con 200 conexiones simultaneas.

## El control: la misma carga, la forma ingenua

```
  decrby prueba:oferta:3:ingenuo 1: 71428.57 requests per second, p50=0.319 msec
  contador ingenuo al final: -900
```

`DECRBY` **es** un comando atomico de Redis, y sobrevende igual. Por eso el
argumento no es "Redis es de un solo hilo" sino "la comprobacion tiene que estar
dentro del mismo paso que el descuento".

**Lo que esta ronda NO demuestra, y este README decia que si.** Aqui estaba
escrito: *"si la carga estuviera mal armada y no hubiera concurrencia real, el
control tampoco se romperia y su -900 seria un 0"*. Es falso. `DECRBY` no lleva
comprobacion adentro, asi que 1000 `DECRBY` sobre un contador en 100 terminan en
-900 **aunque se ejecuten uno detras de otro**. Medido:

```
  redis-benchmark -c 1 -n 1000 decrby adv:ingenuo 1
  -> contador en -900, con UNA sola conexion y cero concurrencia
```

Y el arnes entero corrido con `CLIENTES=1 SOLICITUDES=300` daba **20 OK, cero
FALLA**, incluida una linea que afirmaba por escrito que hubo concurrencia. La
evidencia de los 3 puntos descansaba en una comprobacion que no podia fallar.

## La concurrencia ahora se MIDE, no se deduce

Cada carga lee `total_connections_received` de `INFO stats` antes y despues: la
resta dice cuantos **sockets** abrio. `redis-benchmark` abre `-c` conexiones y
las sostiene todas durante la corrida, con una peticion en el aire en cada una,
asi que ese numero es la concurrencia simulada.

```
  OK    la carga abrio 50 conexiones simultaneas (se pidieron 50): concurrencia real
```

Separa los dos casos sin ambiguedad y sin instalar nada: **52 conexiones nuevas
con `-c 50` y 3 con `-c 1`** (dos de esas tres son las lecturas de `INFO` que
hace el propio arnes, y se restan).

Son dos preguntas y hacen falta las dos:

1. **Se pidio concurrencia?** Con `CLIENTES=1` no hay nada que probar y el arnes
   ahora **falla** diciendolo, en vez de aprobar afirmando lo contrario.
2. **Se consiguio?** Que `redis-benchmark` abriera de verdad los sockets
   pedidos. Si algun dia serializara, o si el `-c` se perdiera, se ve aqui.

## Las reservas abandonadas vuelven solas

```
  2 unidades, tres personas, reservas que vencen en 6 segundos:
    VENDIDO 1 1
    VENDIDO 2 0
    AGOTADO 0 0
  nadie paga; esperando 8 segundos a que las reservas venzan...
  el que llega tarde ahora SI encuentra unidades:
    VENDIDO 3 1
  OK    unidades recuperadas (stock + reservado) = 2
```

## Confirmar, devolver, y confirmar dos veces

```
  tickets 1 (va a pagar) y 2 (se le cae el pago)
  CONFIRMADO 2
  DEVUELTO 2 3
  OK    stock (1 que sobraba + 2 devueltas) = 3
  OK    vendidas = 2
  OK    reservado = 0
  confirmar dos veces el mismo ticket:
  SIN_TICKET 0
  OK    vendidas despues del reintento (no se duplica) = 2
```

## El ticket es de su dueno, y antes no lo era

Los tickets salen de `HINCRBY`: empiezan en 1 y suben de uno en uno. **No son
secretos, son consecutivos** -- adivinar los tickets vivos de una venta es
contar. Y ni `confirmar` ni `devolver` miraban de quien era el que recibian: el
campo `u:<ticket>` se escribia y no se leia en ninguna rama del script.

Reproducido: `sembrar 3`; tres personas se llevan los tickets 1, 2 y 3 y la
oferta queda agotada. Un cuarto llamador, que no reservo nada, corre
`devolver 1`, `devolver 2`, `devolver 3` y recibe `DEVUELTO` en las tres. La
venta entera vuelve a estar disponible. Y cuando la primera paga en PostgreSQL y
llama a `confirmar`, recibe `SIN_TICKET`: **ya pago y se quedo sin unidad**, y
solo un humano lo nota.

Arreglado: las dos operaciones reciben el `id_usuario` como `ARGV[2]` y lo
comparan contra `u:<ticket>` **antes de tocar nada** -- ese orden es la garantia,
porque Redis no deshace lo que un script ya escribio. Contestan `TICKET_AJENO`,
que se distingue de `SIN_TICKET` a proposito: uno es "rehace la reserva" y el
otro es "estas tocando la reserva de otro".

```
  victima reserva 3 unidades y se lleva el ticket 1
  un tercero, que no reservo nada, intenta devolver ese ticket:
  TICKET_AJENO 0 2
  OK    devolver un ticket ajeno = TICKET_AJENO
  y confirmarlo:
  TICKET_AJENO 0
  OK    confirmar un ticket ajeno = TICKET_AJENO
  OK    el stock no se movio con los dos intentos ajenos = 2
  OK    la reserva de la victima sigue en pie = 3
  la victima si puede con el suyo:
  CONFIRMADO 3
  OK    vendidas tras confirmar la propia = 3
```

Un ticket al azar en vez de un contador ayudaria, pero no reemplaza esto: la
pregunta no es "adivinaste el numero" sino "es tuyo".

## Las dos claves vencen juntas, y antes el ZSET era inmortal

`sembrar` hacia `DEL CLAVE RESERVAS` y despues `EXPIRE RESERVAS ttl` sobre una
clave que **acababa de borrar**: `EXPIRE` devuelve 0 y no crea nada. El ZSET
recien nace en el primer `ZADD` de `reservar`, que no hereda ningun TTL, asi que
quedaba sin vencimiento **para siempre**.

Medido: con `sembrar 5 4` y dos reservas, a los 6 segundos `EXISTS` del hash da
0 (vencio) y `EXISTS` del ZSET da 1, con `TTL -1` y los dos tickets adentro. Cada
venta limitada con fecha de cierre dejaba una clave permanente -- y como la
seccion 4 exige `maxmemory-policy noeviction` a proposito, esas claves no se
desalojan nunca: cuando la memoria se llene, Redis rechaza **todas** las
escrituras y se cae tambien el carrito.

Arreglado moviendo el vencimiento al final de `reservar`, que es donde la clave
existe de verdad, copiandole al ZSET el TTL que le queda al hash:

```
  OK    TTL del ZSET justo despues de sembrar (aun no existe) = -2
  tras la primera reserva: TTL del hash 298, TTL del ZSET 298
  OK    el ZSET tiene vencimiento (298 s), no quedo inmortal
  OK    las dos claves vencen juntas (se llevan 0 s de diferencia)
```

## El carrito

```
  PostgreSQL antes: stock de las ofertas 3,6 = 40, pedidos de compradora.norte@mesh.com = 13
  OK    TTL recien creado = 14 (esperado entre 13 y 15)
  OK    lineas en el carrito = 4
  OK    TTL despues de 6 s quieto = 6
  OK    TTL despues del toque = 14
  OK    el TTL subio de 6 a 14: se renovo
  toque 1, vivo hace 6s, TTL ahora 14
  toque 2, vivo hace 12s, TTL ahora 14
  toque 3, vivo hace 18s, TTL ahora 14
  OK    el carrito sigue vivo tras 18s con TTL de 15s = 1
  OK    el carrito de Redis es aceptado por comprar_carrito()
  OK    cada linea GUARDADA EN REDIS lleva su id_precio_historial
  OK    EXISTS del carrito = 0
  OK    TTL del carrito = -2
  OK    stock de las ofertas que uso el carrito = 40
  OK    pedidos del comprador de prueba = 13
```

Vivio 18 segundos con un TTL de 15: si el vencimiento fuera un plazo fijo desde
la creacion, ahi ya no estaria. Esa linea es la que separa las dos politicas.

Y las dos ultimas son la prueba de que al vencer no hay nada que liberar.

**Estan acotadas a lo que la prueba controla**, y esa es una correccion: antes
comparaban `sum(stock)` de **todas** las ofertas y `count(*)` de **toda** la
tabla `pedido`, con casi un minuto entre las dos lecturas, asi que cualquier
compra ajena hecha en ese rato hacia fallar la prueba y le echaba la culpa al
carrito. No es hipotetico: en tres corridas seguidas, dos fallaron
(`FALLA stock total en oferta = 8292 (se esperaba 8302)`), y la causa quedo en la
base -- una compra de otro usuario commiteada mientras el script dormia sus
`sleep`. El carrito vive en Redis con prefijo `prueba:carrito:` y nunca escribe
en `oferta` ni en `pedido`: esas dos lineas no median nada de lo que la prueba
construye.

## El `id_precio_historial` viaja, y hoy PostgreSQL lo tira

Aqui estaba publicado como evidencia este renglon:

```
  OK    cada linea lleva su id_precio_historial (la salida al precio congelado)
```

Y lo unico que hacia era un `grep` sobre la cadena que el propio arnes acababa de
construir tres lineas antes. Miraba su **entrada**, no el sistema -- la misma
trampa del instrumento que el TTL evita leyendose con `TTL` y no con `ver`.

Lo que de verdad pasa esta en `migrations/007_flujo_pedido.sql:165`:
`agregar_linea()` hace su **propio** `SELECT id_precio_historial ... ORDER BY
fecha_creacion DESC LIMIT 1` e inserta ese, nunca el del JSON. El campo viaja y
no sirve, todavia.

Ahora el arnes lo mide contra el resultado, mandando un id que no existe en toda
la base y leyendo lo que quedo guardado, dentro de la misma transaccion:

```
    guardado=3 vigente=3 enviado=999999999
    guardado=793 vigente=793 enviado=999999999
  OK    comprar_carrito() acepto un id_precio_historial inexistente: el parametro se descarta
  OK    el id guardado en pedido_producto es el VIGENTE, no el que mando el carrito (2 linea/s)
```

Y es un **mecanismo, no un aviso**: el dia que alguien haga que
`agregar_linea()` respete el parametro, ese bloque se pone rojo -- la compra
fallara por llave foranea, o el id guardado dejara de ser el vigente -- y
obligara a actualizar el arnes y este README en vez de dejarlos mintiendo. El
pendiente sigue siendo el punto 6 de la lista de abajo.

**El TTL se lee siempre con el comando `TTL` suelto, nunca con la operacion
`ver`,** porque `ver` renueva. Medirlo con `ver` daria siempre el valor completo
y la prueba pasaria aunque la renovacion estuviera rota. Un arnes que mira lo
que el mismo acaba de tocar no mide nada.

Las dos pruebas se corrieron **dos veces cada una** y dan los mismos numeros.


---

# 4. La configuracion de Redis que sostiene esto

Ya esta puesta en `docker-compose.yml`, pero conviene saber por que importa:

- **`appendonly yes`.** Si Redis se reiniciara sin persistir, los carritos se
  perderian -- y eso se ve *exactamente igual* que un TTL mal puesto, que es una
  tarde de depurar el bug equivocado. Peor para el inventario limitado: el
  contador volveria al valor sembrado y se venderian las unidades otra vez.
- **`maxmemory-policy noeviction` (y `maxmemory 0`).** Es el valor por omision y
  aqui hay que dejarlo. Con `allkeys-lru`, Redis puede tirar un carrito **antes**
  de su TTL cuando le falta memoria, y podria tirar el contador de una venta
  limitada en la mitad de la venta. Con `noeviction` las claves solo desaparecen
  por su vencimiento; si la memoria se llena, Redis rechaza las escrituras -- que
  es ruidoso y por lo tanto mejor.
- **`requirepass`.** El 6379 es de los puertos mas barridos que hay.

Los scripts se cargan con `SCRIPT LOAD` y se llaman con `EVALSHA`. El backend
tiene que estar listo para recibir `NOSCRIPT` -- Redis puede vaciar la cache de
scripts en un reinicio o con `SCRIPT FLUSH` -- y volver a cargarlos. Es el unico
error de esta capa que hay que manejar a mano.


---

# 5. Lo que falta para enchufarlo

Nada de esto se puede hacer desde esta carpeta: vive en `backend/` o en
`migrations/`.

**Del backend, para el carrito:**

1. Cargar los dos `.lua` con `SCRIPT LOAD` al arrancar, guardar los SHA, y
   recargar si Redis contesta `NOSCRIPT`.
2. Cambiar las rutas del carrito para que llamen a `carrito.lua` en vez de a
   `crear_pedido` / `agregar_linea` / `restar_linea` / `quitar_linea`.
3. Al pagar: leer el carrito, armar el arreglo de lineas juntando `l:` con `c:`,
   llamar a `comprar_carrito()`, y **solo si salio bien**, `vaciar`.
4. **Comprobar el stock al pintar el carrito.** Redis no sabe si una oferta se
   agoto o se desactivo; el carrito puede tener algo que ya no se puede comprar.
   Hoy esa comprobacion la hacia `agregar_linea` en cada toque.
5. Fusionar el carrito de invitado con el de la cuenta al iniciar sesion.

**De `migrations/`, para el precio congelado** (seccion 1, y es lo que de verdad
falta):

6. Que `agregar_linea()` acepte un `id_precio_historial` en `p_linea` y lo use
   en vez de buscar el vigente -- **validando** que sea de esa oferta.
7. Decidir que se hace cuando el precio cambio entre agregar y pagar: cobrar el
   viejo, o avisar y pedir confirmacion.

**Del backend, para el inventario limitado:**

8. Decidir **que ofertas** son de inventario limitado. Hoy `oferta` no tiene
   como decirlo: haria falta una columna o una tabla aparte. Mientras no exista,
   esta capa se aplica a la oferta que se siembre a mano.
9. Sembrar el contador de Redis desde `oferta.stock` cuando la venta se abre, y
   llamar a `confirmar` despues de `comprar_carrito()` y a `devolver` si fallo.
   Las dos reciben el `id_usuario` como `ARGV[2]` y el ticket como `ARGV[3]`: el
   script compara contra `u:<ticket>` y contesta `TICKET_AJENO` si no coincide,
   asi que el backend tiene que mandar el usuario de la sesion y no confiar en
   que el ticket sea secreto.
10. **La reconciliacion.** Un trabajo periodico que compare los tickets
    confirmados con `stock_movimiento` y resiembre el contador de Redis desde
    PostgreSQL. Es lo que cubre el caso de que Redis se reinicie, o de que el
    vendedor toque el stock por su lado. No esta hecho.
11. Que el frontend entienda `AGOTADO` como respuesta normal y no como error:
    son 900 de cada 1000 solicitudes en una venta limitada.


---

# 6. Lo que esta capa NO hace

Dicho para que nadie lo suponga:

- **No hay limite por persona.** Con `__rand_int__` cada solicitud es un usuario
  distinto, asi que la prueba no lo habria detectado igual. Un "maximo 2 por
  cuenta" es un `HINCRBY` mas dentro del mismo script y una comprobacion antes
  de descontar; no se escribio porque no se pidio.
- **No hay cola ni orden justo.** Gana el que llega primero al servidor, y con
  50 conexiones eso lo decide la red. Para una venta donde el orden importe
  haria falta una lista y otra conversacion.
- **No reconcilia con PostgreSQL** (punto 10 de arriba).
- **No corre en Redis Cluster** tal como esta: faltan las llaves de ranura en
  los nombres de clave (seccion 2).
