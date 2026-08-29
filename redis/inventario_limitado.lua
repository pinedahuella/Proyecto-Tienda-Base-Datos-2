--[[
inventario_limitado.lua -- comprobar y descontar EN UN SOLO PASO.

Este archivo es la respuesta al punto de la Entrega 2 que pide "operaciones
atomicas del almacen clave-valor, sin bloqueos a nivel de aplicacion". Todo lo
demas de esta carpeta se apoya en el.


POR QUE NO ALCANZA CON QUE REDIS SEA DE UN SOLO HILO
============================================================
Es la confusion que hay que sacarse de encima primero, porque suena a que el
problema no existe. Redis atiende un comando a la vez, si. Eso hace que cada
comando SUELTO sea atomico. No hace atomica una DECISION que necesita dos.

La forma ingenua es esta:

    GET  oferta:12:stock      -> "1"     (el cliente ve que queda una)
    DECRBY oferta:12:stock 1  -> 0       (y la toma)

Entre esas dos lineas caben otros cincuenta clientes. Los cincuenta leyeron
"1", los cincuenta creyeron que les tocaba, y los cincuenta descontaron. El
contador termina en -49 y hay 50 personas con la misma unidad. Los dos comandos
fueron atomicos; la decision no.

La segunda forma ingenua es peor porque parece lista:

    DECRBY oferta:12:stock 1  -> -3      (descuento primero y despues miro)
    si quedo negativo: INCRBY oferta:12:stock 1  (lo devuelvo)

Aqui el stock SI queda bien al final, pero entre el DECRBY y el INCRBY el
contador estuvo en negativo, y cualquier otro cliente que haya leido en ese
hueco vio un numero que no era. Peor todavia: si el proceso que iba a compensar
se cae, la compensacion no ocurre nunca y la unidad se pierde para siempre. Es
exactamente el patron que el enunciado prohibe -- dos pasos.

La tercera forma ingenua es la que hay que nombrar porque es la que la gente
escribe: un candado. SET oferta:12:lock NX PX 3000, hago mi GET y mi DECRBY
tranquilo, DEL el candado. Funciona y esta PROHIBIDO por el enunciado, que pide
"sin bloqueos a nivel de aplicacion". Y con razon: el que toma el candado y se
muere deja a todos los demas esperando el PX; el que tarda mas que el PX cree
que todavia lo tiene y ya no; y hay que decidir un tiempo de espera que nadie
sabe cuanto es. Es reimplementar un gestor de transacciones a mano y mal.


LO QUE HACE UN SCRIPT LUA
============================================================
Redis corre el script ENTERO como si fuera un solo comando. Nadie se mete en el
medio, no hay hueco entre el "comprobar" y el "descontar", y no hace falta
ningun candado porque no hay nada que proteger: la decision entera es un paso.
Si el script falla a la mitad y no escribio nada, no queda nada a medias; si ya
escribio, termina (Redis no deshace, y por eso abajo TODAS las comprobaciones
van ANTES de la primera escritura -- ese orden no es estetico, es la garantia).

Ese es el argumento completo, y es el que la evidencia de
prueba_concurrencia.sh comprueba: 1000 solicitudes con 50 clientes a la vez
sobre 100 unidades venden 100, exactamente.

El mismo archivo mide la forma ingenua a proposito, para que el numero no sea
una promesa: con DECRBY pelado el contador termina en -900.


COMO SE LLEVA CON EL FOR UPDATE DE POSTGRESQL
============================================================
`comprar_pedido()` (migrations/007) usa SELECT ... FOR UPDATE sobre la fila de
`oferta`. Eso NO se quita y no se toca -- es el libro contable, y ahi el stock
tiene que cuadrar con `stock_movimiento` pase lo que pase.

Lo que cambia es QUIEN decide. Con esto delante, PostgreSQL ya no recibe 1000
compras peleando por 100 unidades: recibe 100 compras que ya ganaron. El
FOR UPDATE deja de ser el portero (que es donde se hacia lento, porque 900
transacciones se sentaban a esperar una fila) y pasa a ser lo que siempre
debio ser, la ultima comprobacion de que el libro cuadra.

Dicho de frente, porque es la parte incomoda: son DOS contadores del mismo
stock, uno en Redis y uno en PostgreSQL, y dos contadores se pueden separar.
Se separan si una reserva gana en Redis y despues el pago falla. Para eso esta
`devolver`, y para eso las reservas VENCEN solas: una reserva que nadie confirma
regresa su unidad al contador. La reconciliacion real (contar tickets
confirmados contra `stock_movimiento`) queda pendiente y esta escrita como tal
en README.md; no se invento aqui un proceso que nadie va a correr.


LA FORMA DE LOS DATOS
============================================================
KEYS[1]  mesh:oferta:<id_oferta>            HASH
             stock      unidades que todavia se pueden tomar
             reservado  unidades tomadas y sin confirmar
             vendidas   unidades confirmadas (el pago paso en PostgreSQL)
             rechazos   intentos que se fueron con las manos vacias
             ticket     ultimo numero de ticket entregado
             r:<ticket> cantidad de esa reserva
             u:<ticket> quien la tiene

KEYS[2]  mesh:oferta:<id_oferta>:reservas   ZSET
             miembro = ticket, puntaje = milisegundo en que vence

Son dos claves y no cinco a proposito. Un script Lua solo puede tocar claves
que estan en KEYS si algun dia esto corre en Redis Cluster, y ademas las dos
tienen que caer en el mismo nodo; con el nombre de la oferta compartido y un
`{}` alrededor del id (hash tag) eso se resuelve el dia que haga falta. Meter
el detalle de cada reserva como campos del MISMO hash, en vez de una clave por
reserva, es lo que evita tener que declarar N claves que no se conocen de
antemano -- que es justo lo que un script no puede hacer.

Por que un ZSET y no una clave por reserva con su propio EXPIRE: porque cuando
una reserva vence hay que DEVOLVER la unidad al contador, y el EXPIRE de Redis
borra la clave sin avisarle a nadie. Se podria escuchar el evento de
expiracion, pero esos avisos se pierden si nadie esta escuchando en ese
momento, asi que el stock se perderia en silencio. Con el ZSET el vencimiento
se cosecha aqui adentro, en el mismo paso atomico de la reserva siguiente, y no
hace falta ningun proceso de fondo ni ninguna suscripcion.


OPERACIONES
============================================================
  sembrar    ARGV: op, stock, ttl_segundos
  reservar   ARGV: op, id_usuario, cantidad, ttl_reserva_segundos
  confirmar  ARGV: op, id_usuario, ticket
  devolver   ARGV: op, id_usuario, ticket
  estado     ARGV: op

El id_usuario va SEGUNDO en las cuatro operaciones que actuan, y en `confirmar`
y `devolver` no es adorno: es lo que impide que un ticket ajeno se toque. Esta
contado abajo, en `confirmar`.

Todas devuelven un arreglo cuyo PRIMER elemento es una palabra: VENDIDO,
AGOTADO, SIN_OFERTA, CONFIRMADO, DEVUELTO, SIN_TICKET, TICKET_AJENO. Distinguir "vendido" de
"agotado" con una palabra y no con un numero o con un error es lo que hace que
el que llama no tenga que adivinar: un stock que quedo en 0 despues de vender
la ultima y un intento rechazado devuelven los dos un 0, y son cosas opuestas.

Y "agotado" NO es un error de Redis. Si lo fuera, cada rechazo levantaria una
excepcion en el backend y en la prueba de carga, que son 900 de cada 1000
solicitudes: es el camino NORMAL de una venta limitada, no una falla.
]]

local op       = ARGV[1]
local CLAVE    = KEYS[1]
local RESERVAS = KEYS[2]

-- Cuantas reservas vencidas se devuelven como maximo en una sola llamada.
--
-- Tiene tope porque el script corre con Redis entero detenido: si una oferta
-- junta 50 000 reservas vencidas, cosecharlas todas de un tiron deja al
-- servidor sin atender a nadie durante ese rato, y el sintoma seria "Redis se
-- congela cada tanto sin motivo". Con tope, la cosecha se reparte entre las
-- llamadas siguientes; lo unico que se pierde es que unas pocas unidades
-- tarden un intento mas en volver a estar disponibles.
local TOPE_COSECHA = 100

-- El reloj sale de Redis y NO de un parametro.
--
-- La tentacion es recibir `ahora` como ARGV, porque hace la prueba mas comoda
-- (se puede adelantar el tiempo sin esperar). El problema es que el
-- vencimiento de las reservas pasaria a depender de un numero que manda quien
-- llama: mandando un valor enorme, una sola llamada vence las reservas de
-- TODOS los demas y les roba las unidades. El reloj del servidor no se le
-- pregunta al cliente.
--
-- TIME es un comando "no determinista" y en versiones viejas de Redis no se
-- podia usar antes de escribir. Desde que la replicacion es por efectos (Redis
-- 5 en adelante; aqui corre 8.10) si se puede, porque a la replica se le manda
-- lo que el script HIZO y no el script.
local function ahora_ms()
    local t = redis.call('TIME')
    return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end

local function campo(nombre)
    local v = redis.call('HGET', CLAVE, nombre)
    if not v then return nil end
    return tonumber(v)
end

-- Devuelve al stock las unidades de las reservas que ya vencieron.
--
-- Corre al principio de `reservar` y no en un proceso aparte: asi el que llega
-- a comprar es el mismo que libera lo que quedo colgado, y no hace falta que
-- nadie recuerde levantar un demonio. La cosecha y la reserva pasan dentro del
-- MISMO script, o sea que nadie puede ver el estado intermedio en el que las
-- unidades ya volvieron pero todavia no se entregaron.
local function cosechar(ahora)
    local vencidos = redis.call('ZRANGEBYSCORE', RESERVAS, '-inf', ahora,
                                'LIMIT', 0, TOPE_COSECHA)
    local devueltas = 0

    for i = 1, #vencidos do
        local ticket = vencidos[i]
        local cantidad = campo('r:' .. ticket)

        -- Si el detalle no esta, el ticket igual se saca del ZSET. No devuelve
        -- unidades porque no se sabe cuantas eran, y inventar un numero aqui
        -- seria fabricar stock. Solo puede pasar si alguien borro campos del
        -- hash a mano.
        if cantidad then
            redis.call('HINCRBY', CLAVE, 'stock', cantidad)
            redis.call('HINCRBY', CLAVE, 'reservado', -cantidad)
            redis.call('HDEL', CLAVE, 'r:' .. ticket, 'u:' .. ticket)
            devueltas = devueltas + cantidad
        end

        redis.call('ZREM', RESERVAS, ticket)
    end

    return devueltas
end


-- ============================================================
-- sembrar -- el vendedor abre la venta limitada
-- ============================================================
-- Borra lo que hubiera y deja el contador en el numero de unidades que se
-- ponen a la venta. Es destructivo a proposito: "abrir la venta" y "seguir la
-- venta que ya estaba" son cosas distintas, y que sembrar sumara al stock
-- anterior convertiria un doble clic del vendedor en el doble de unidades.
--
-- ttl_segundos = 0 deja la oferta sin vencimiento. Cualquier otro valor es
-- cuando la venta CIERRA: pasado eso las claves desaparecen solas y no queda
-- basura de una promocion de hace tres meses ocupando memoria.
if op == 'sembrar' then
    local stock = tonumber(ARGV[2])
    local ttl   = tonumber(ARGV[3])

    if not stock or stock < 0 then
        return redis.error_reply('sembrar: el stock tiene que ser >= 0')
    end

    redis.call('DEL', CLAVE, RESERVAS)
    redis.call('HSET', CLAVE,
               'stock', stock, 'reservado', 0,
               'vendidas', 0, 'rechazos', 0, 'ticket', 0)

    if ttl and ttl > 0 then
        redis.call('EXPIRE', CLAVE, ttl)
    end

    -- AQUI NO SE LE PONE EXPIRE AL ZSET, Y LA LINEA QUE FALTA ES A PROPOSITO.
    --
    -- Antes estaba, justo debajo, y no hacia NADA: la linea de arriba acaba de
    -- hacer DEL de RESERVAS, y EXPIRE sobre una clave que no existe devuelve 0
    -- y no crea nada. Medido: despues de `sembrar 5 30`, TTL del hash 29 y TTL
    -- de las reservas -2 (no existe). El ZSET recien nace en el primer ZADD de
    -- `reservar`, que no hereda ningun vencimiento, asi que quedaba INMORTAL:
    -- con `sembrar 5 4` y dos reservas, a los 6 segundos el hash ya no estaba
    -- (EXISTS 0) y el ZSET seguia ahi con TTL -1 y sus dos tickets adentro,
    -- para siempre.
    --
    -- Y no es basura inofensiva: cada venta limitada con fecha de cierre dejaba
    -- un ZSET permanente, y el README pide `maxmemory-policy noeviction` a
    -- proposito, o sea que esas claves no se desalojan solas. Cuando la memoria
    -- se llene, Redis rechaza TODAS las escrituras y se cae tambien el carrito.
    --
    -- El vencimiento del ZSET se pone en `reservar`, que es donde la clave
    -- existe de verdad. Ahi si las dos vencen juntas.
    return {'SEMBRADA', stock}


-- ============================================================
-- reservar -- EL PASO UNICO: comprobar y descontar
-- ============================================================
-- Esta es la operacion que la rubrica pide. Todo lo que sigue pasa sin que
-- nadie mas pueda meterse: se cosecha lo vencido, se mira el stock, se compara
-- con lo que se pide y se descuenta. Un solo paso.
--
-- El orden importa y no es casual: TODAS las salidas por rechazo estan antes
-- del primer HINCRBY sobre el stock. Redis no deshace lo que un script ya
-- escribio, asi que un `return` despues de haber descontado dejaria unidades
-- desaparecidas.
elseif op == 'reservar' then
    local id_usuario = ARGV[2]
    local cantidad   = tonumber(ARGV[3])
    local ttl_res    = tonumber(ARGV[4])

    if not cantidad or cantidad <= 0 then
        return redis.error_reply('reservar: la cantidad tiene que ser > 0')
    end

    local ahora = ahora_ms()
    cosechar(ahora)

    local stock = campo('stock')

    -- El hash no existe: o la venta nunca se abrio, o ya cerro y vencio. Se
    -- distingue de "agotado" porque son dos problemas distintos para quien
    -- llama: agotado es "llegaste tarde", sin oferta es "esta oferta no vive
    -- en Redis, preguntale a PostgreSQL".
    if not stock then
        return {'SIN_OFERTA', 0, 0}
    end

    -- La comparacion es contra la CANTIDAD pedida, no contra cero.
    --
    -- `if stock > 0 then descontar` es el error clasico: con 2 unidades y un
    -- pedido de 3 pasa la comprobacion y el contador queda en -1. Por eso la
    -- prueba de concurrencia corre una ronda entera con cantidad 3 sobre 100
    -- unidades: 33 reservas y 1 unidad que sobra, que es el numero que ese
    -- error no puede producir.
    if cantidad > stock then
        redis.call('HINCRBY', CLAVE, 'rechazos', 1)
        return {'AGOTADO', 0, stock}
    end

    local ticket   = redis.call('HINCRBY', CLAVE, 'ticket', 1)
    local restante = redis.call('HINCRBY', CLAVE, 'stock', -cantidad)
    redis.call('HINCRBY', CLAVE, 'reservado', cantidad)
    redis.call('HSET', CLAVE, 'r:' .. ticket, cantidad, 'u:' .. ticket, id_usuario)

    -- La reserva vence sola. Sin esto, el que abandona el carrito se queda con
    -- la unidad para siempre y la venta limitada termina "agotada" con la
    -- mitad de las unidades sin cobrar.
    --
    -- ttl_res = 0 significa que no vence: sirve para la prueba de carga, donde
    -- hace falta que ninguna reserva se libere en el medio o el conteo final
    -- dejaria de ser comprobable.
    if ttl_res and ttl_res > 0 then
        redis.call('ZADD', RESERVAS, ahora + (ttl_res * 1000), ticket)
    else
        -- Puntaje infinito: entra al ZSET (asi `confirmar` y `devolver` lo
        -- encuentran) pero la cosecha nunca lo alcanza.
        redis.call('ZADD', RESERVAS, '+inf', ticket)
    end

    -- El vencimiento del ZSET se pone AQUI y no en `sembrar`, y va DESPUES del
    -- ZADD: es la primera linea de todo el script en la que la clave RESERVAS
    -- existe. En `sembrar` el EXPIRE caia sobre una clave recien borrada,
    -- devolvia 0 y dejaba el ZSET sin vencimiento para siempre.
    --
    -- El numero no se inventa: se le copia el que le queda al hash, para que las
    -- dos claves de la oferta desaparezcan juntas. Si venciera solo el hash, el
    -- ZSET quedaria con tickets que apuntan a un detalle que ya no existe y la
    -- cosecha devolveria unidades a un stock que ya no esta.
    --
    -- TTL devuelve -1 si la clave no vence y -2 si no existe; en los dos casos
    -- no hay nada que copiar y el ZSET se queda sin vencimiento, que es lo
    -- correcto: una oferta sin fecha de cierre no cierra.
    --
    -- Se repite en cada reserva y no una sola vez, y eso es lo que lo hace
    -- barato de sostener: no hay que acordarse de en que rama nace la clave.
    local ttl_oferta = redis.call('TTL', CLAVE)
    if ttl_oferta > 0 then
        redis.call('EXPIRE', RESERVAS, ttl_oferta)
    end

    return {'VENDIDO', ticket, restante}


-- ============================================================
-- confirmar -- el pago paso en PostgreSQL
-- ============================================================
-- El stock NO se toca aqui: ya se desconto al reservar. Lo unico que cambia es
-- que esas unidades dejan de estar "reservadas" (podrian volver) y pasan a
-- estar "vendidas" (ya no vuelven).
--
-- Se llama DESPUES de que comprar_carrito() devolvio bien, nunca antes. Si se
-- llamara antes y el pago fallara, la unidad quedaria vendida sin cobrar y
-- solo un humano podria darse cuenta.
--
--
-- POR QUE PIDE EL id_usuario, Y POR QUE ESA COMPROBACION NO ES OPCIONAL
-- ============================================================
-- Los tickets salen de HINCRBY: empiezan en 1 y suben de uno en uno. No son
-- secretos, son CONSECUTIVOS -- adivinar los tickets vivos de una venta es
-- contar. Y hasta hace poco ni `confirmar` ni `devolver` miraban de quien era
-- el que recibian.
--
-- Reproducido contra este mismo Redis: `sembrar 5`; `reservar victima 3` da el
-- ticket 1 y el hash guarda u:1 = victima; acto seguido, una llamada que no
-- pasaba ningun usuario, `devolver 1`, contestaba DEVUELTO y liberaba las tres
-- unidades de la victima para cualquiera. Con tres compradores y tres tickets,
-- un cuarto llamador devolvia los tres seguidos y la venta entera volvia a
-- estar disponible. Peor: si a la victima le liberan la reserva y despues su
-- comprar_carrito() sale bien, su `confirmar` contesta SIN_TICKET -- ya pago y
-- se quedo sin unidad, y solo un humano lo nota.
--
-- El campo u:<ticket> estaba escrito exactamente para esto y no se consultaba
-- en ninguna rama. Ahora si, y la comprobacion cae ANTES de la primera
-- escritura, que es el orden que este script se impone en todas partes: Redis
-- no deshace lo que un script ya escribio.
--
-- Un ticket al azar en vez de un contador ayudaria, pero no reemplaza esto: la
-- pregunta no es "adivinaste el numero" sino "es tuyo".
elseif op == 'confirmar' then
    local id_usuario = ARGV[2]
    local ticket     = ARGV[3]
    local cantidad   = campo('r:' .. ticket)

    -- Sin ticket son dos casos y los dos se contestan igual: o nunca existio,
    -- o vencio y sus unidades ya volvieron al stock. En los dos, el que llama
    -- tiene que rehacer la reserva, no reintentar la confirmacion.
    if not cantidad then
        return {'SIN_TICKET', 0}
    end

    -- TICKET_AJENO y no SIN_TICKET, aunque los dos rechacen: son problemas
    -- distintos para quien llama. Sin ticket es "rehace la reserva"; ajeno es
    -- "estas tocando la reserva de otro", que es un bug del que llama o un
    -- intento de robarla, y merece verse distinto en el log.
    local dueno = redis.call('HGET', CLAVE, 'u:' .. ticket)
    if dueno ~= id_usuario then
        return {'TICKET_AJENO', 0}
    end

    redis.call('ZREM', RESERVAS, ticket)
    redis.call('HDEL', CLAVE, 'r:' .. ticket, 'u:' .. ticket)
    redis.call('HINCRBY', CLAVE, 'reservado', -cantidad)
    redis.call('HINCRBY', CLAVE, 'vendidas', cantidad)

    return {'CONFIRMADO', cantidad}


-- ============================================================
-- devolver -- se cayo el pago, o la persona se arrepintio
-- ============================================================
-- Lo contrario de confirmar: las unidades vuelven al stock y quedan
-- disponibles para el siguiente. Es la salida rapida; si nadie la llama, la
-- reserva vence sola y `cosechar` hace lo mismo. Tener las dos no es
-- duplicacion: una libera en el acto (el que cancela) y la otra cubre al que
-- cerro el navegador.
--
-- Pide el id_usuario por lo mismo que `confirmar`, y aqui el agujero era peor:
-- devolver una reserva ajena no solo se la quita a su dueno, ademas suelta sus
-- unidades para que las tome cualquiera. Esta contado entero arriba.
elseif op == 'devolver' then
    local id_usuario = ARGV[2]
    local ticket     = ARGV[3]
    local cantidad   = campo('r:' .. ticket)

    if not cantidad then
        return {'SIN_TICKET', 0, campo('stock') or 0}
    end

    local dueno = redis.call('HGET', CLAVE, 'u:' .. ticket)
    if dueno ~= id_usuario then
        return {'TICKET_AJENO', 0, campo('stock') or 0}
    end

    redis.call('ZREM', RESERVAS, ticket)
    redis.call('HDEL', CLAVE, 'r:' .. ticket, 'u:' .. ticket)
    redis.call('HINCRBY', CLAVE, 'reservado', -cantidad)
    local restante = redis.call('HINCRBY', CLAVE, 'stock', cantidad)

    return {'DEVUELTO', cantidad, restante}


-- ============================================================
-- estado -- para mirar, y sobre todo para que la prueba compruebe
-- ============================================================
-- No cosecha ni renueva nada: es de solo lectura a proposito. Una prueba que
-- cambia lo que esta midiendo no sirve como evidencia, y una pantalla de
-- vendedor que se refresca sola no deberia mover reservas de nadie.
--
-- Devuelve tambien `pendientes` (cuantos tickets vivos hay) porque es la
-- COMPROBACION INDEPENDIENTE del contador `reservado`: los dos se escriben en
-- lugares distintos del script y tienen que contar la misma historia. Si
-- alguna vez no coinciden, el bug esta aqui adentro.
elseif op == 'estado' then
    return {
        'ESTADO',
        campo('stock')     or -1,
        campo('reservado') or -1,
        campo('vendidas')  or -1,
        campo('rechazos')  or -1,
        campo('ticket')    or -1,
        redis.call('ZCARD', RESERVAS),
        redis.call('TTL', CLAVE)
    }

else
    return redis.error_reply('operacion desconocida: ' .. tostring(op))
end
