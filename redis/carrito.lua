--[[
carrito.lua -- el carrito vive en Redis y vence por INACTIVIDAD.

Hoy el carrito es una fila de `pedido` en estado 'pendiente' en PostgreSQL, con
su id guardado en localStorage. Funciona, y tiene dos problemas que este
archivo resuelve: no vence NUNCA (la tabla junta pedidos pendientes de 2024
para siempre) y obliga a tener cuenta, porque `pedido.id_usuario` es NOT NULL y
apunta a `usuarios`.


POR QUE UN SCRIPT Y NO HSET A SECAS
============================================================
La respuesta facil seria "el backend hace HSET y despues EXPIRE". Son dos
comandos, y ese es exactamente el problema, dos veces:

1. Si el backend se cae, se reinicia o pierde la conexion entre el HSET y el
   EXPIRE, el carrito queda SIN vencimiento. No falla nada, no se ve nada: hay
   una clave inmortal en la base y nadie se entera hasta que la memoria se
   llena. Un carrito inmortal se ve igual que un carrito normal.

2. Sumar cantidad exige leer lo que habia, sumar y volver a escribir. Dos
   pestanas del mismo navegador agregando el mismo producto a la vez leen las
   dos "1", escriben las dos "2", y una de las dos sumas desaparece. Es el
   mismo agujero que el inventario limitado, mas chico.

Con el script, agregar y renovar el vencimiento son un solo paso.


LA FORMA DE LOS DATOS
============================================================
KEYS[1]  mesh:carrito:<id_usuario>   HASH

    l:<id_oferta>  el JSON de la linea, TAL CUAL lo mando el backend
    c:<id_oferta>  la cantidad, como entero suelto

Un HASH y no un JSON en una clave normal: con JSON, cambiar la cantidad de un
producto obliga a leer el carrito entero, modificarlo en el backend y
reescribirlo entero -- que es leer-modificar-escribir, o sea la carrera de
arriba. Con hash, cada linea es un campo y se toca sola, y HGETALL sigue
trayendo el carrito completo en un viaje.

Y por que la cantidad va SEPARADA del JSON, en su propio campo: para poder
sumarla con HINCRBY, que ya es atomico y no necesita que nadie parsee nada. La
alternativa era decodificar el JSON aqui adentro con cjson y volver a
armarlo, y eso tiene una trampa cara: Lua guarda los numeros como coma flotante
de doble precision, asi que cualquier id que pase por cjson.decode se convierte
en un double. Con ids `bigserial` chicos no se nota; el dia que uno pase de
2^53 el id vuelve cambiado y el carrito compra otra cosa. Ademas cjson.encode
reordena las claves, o sea que lo que se guarda deja de ser byte a byte lo que
el backend mando.

Aqui el JSON no se abre nunca. Entra como una cadena y sale como una cadena.


EL VENCIMIENTO: POR INACTIVIDAD, Y NO ES EL MISMO QUE EL DEL JWT
============================================================
El sistema ya tiene un vencimiento: el JWT dura 2 horas FIJAS desde que se
firma. A las 2 horas se cae la sesion aunque la persona haya estado comprando
sin parar los 120 minutos. Eso esta bien para una credencial -- una sesion
robada tiene que morir en algun momento pase lo que pase.

El carrito hace lo contrario: cada toque (agregar, restar, quitar, mirar)
vuelve a poner el TTL en su valor completo. Se mide INACTIVIDAD. Una persona
que compra durante seis horas nunca pierde el carrito; una que lo abandona lo
pierde a las TTL horas del ultimo toque.

Son dos relojes distintos porque miden dos cosas distintas: uno acota el riesgo
de una credencial, el otro acota la vida de un dato que ya no le importa a
nadie. Que el carrito venciera "2 horas despues de entrar" seria hostil, y que
la sesion se renovara sola con cada clic seria una sesion eterna.

El valor concreto y por que, en README.md. Aqui solo importa que el TTL llega
como PARAMETRO y no esta escrito en el script: el que decide cuanto vive un
carrito es la configuracion, no este archivo.


OPERACIONES
============================================================
  agregar   ARGV: op, ttl, id_oferta, cantidad, linea_json   (suma)
  poner     ARGV: op, ttl, id_oferta, cantidad, linea_json   (fija exacto)
  restar    ARGV: op, ttl, id_oferta, cantidad
  quitar    ARGV: op, ttl, id_oferta
  ver       ARGV: op, ttl
  renovar   ARGV: op, ttl
  vaciar    ARGV: op

`agregar` y `poner` son dos porque el boton "+" y la cajita donde se escribe la
cantidad quieren cosas distintas, y hacer que el backend calcule la diferencia
para poder usar solo `agregar` lo obliga a leer primero -- otra vez
leer-modificar-escribir.
]]

local op      = ARGV[1]
local CARRITO = KEYS[1]

-- Renueva el vencimiento y devuelve cuanto quedo.
--
-- Se llama al final de TODAS las operaciones que tocan el carrito, y esa es la
-- unica forma de que la expiracion sea de verdad por inactividad: si alguna
-- ruta se olvidara de renovar, el carrito de esa persona venceria mientras
-- compra.
--
-- Si el hash quedo vacio, Redis ya borro la clave solo (asi funcionan los
-- tipos agregados: sin campos, no hay clave). EXPIRE sobre una clave que no
-- existe devuelve 0 y no la crea, que es justo lo que se quiere -- un carrito
-- vacio no tiene por que ocupar lugar.
local function renovar(ttl)
    if redis.call('EXISTS', CARRITO) == 0 then
        return -2   -- el mismo codigo que usa TTL para "no existe"
    end

    local segundos = tonumber(ttl)
    if not segundos or segundos <= 0 then
        return redis.call('TTL', CARRITO)
    end

    redis.call('EXPIRE', CARRITO, segundos)
    return segundos
end

-- Cuantas lineas distintas tiene el carrito.
--
-- HLEN cuenta CAMPOS, y cada linea usa dos (l: y c:), asi que HLEN/2 es el
-- numero de productos. Se escribe aqui una sola vez para que nadie tenga que
-- acordarse de la division.
local function lineas()
    return math.floor(redis.call('HLEN', CARRITO) / 2)
end


-- ============================================================
-- agregar / poner
-- ============================================================
if op == 'agregar' or op == 'poner' then
    local ttl        = ARGV[2]
    local id_oferta  = ARGV[3]
    local cantidad   = tonumber(ARGV[4])
    local linea_json = ARGV[5]

    if not cantidad then
        return redis.error_reply('cantidad invalida')
    end

    local campo_linea = 'l:' .. id_oferta
    local campo_cant  = 'c:' .. id_oferta
    local total

    if op == 'agregar' then
        -- HINCRBY crea el campo en 0 si no estaba, asi que sirve igual para
        -- "es la primera vez" y para "ya habia tres". Y con cantidad negativa
        -- resta, que es por lo que `restar` de abajo es tres lineas.
        total = redis.call('HINCRBY', CARRITO, campo_cant, cantidad)
    else
        redis.call('HSET', CARRITO, campo_cant, cantidad)
        total = cantidad
    end

    if total <= 0 then
        -- Llegar a 0 es quitar el producto. Dejar el campo en 0 haria que el
        -- carrito mostrara "0 unidades de X", que es una linea que nadie pidio
        -- y que ademas cuenta para `lineas()`.
        redis.call('HDEL', CARRITO, campo_linea, campo_cant)
        return {'QUITADA', 0, lineas(), renovar(ttl)}
    end

    -- La linea se reescribe SIEMPRE, tambien cuando el producto ya estaba.
    --
    -- Es a proposito: el JSON trae el precio y el `id_precio_historial` que la
    -- persona esta viendo AHORA, y ese es el que vale. Si el vendedor subio el
    -- precio entre el primer clic y el segundo, quedarse con el JSON viejo
    -- seria congelar un precio que ya no existe en `precio_historial`, y al
    -- pagar PostgreSQL rechazaria la linea entera.
    redis.call('HSET', CARRITO, campo_linea, linea_json)

    return {op == 'poner' and 'PUESTA' or 'AGREGADA', total, lineas(), renovar(ttl)}


-- ============================================================
-- restar
-- ============================================================
elseif op == 'restar' then
    local ttl       = ARGV[2]
    local id_oferta = ARGV[3]
    local cantidad  = tonumber(ARGV[4])

    if not cantidad or cantidad <= 0 then
        return redis.error_reply('restar: la cantidad tiene que ser > 0')
    end

    -- Si el producto no estaba, HINCRBY lo crea en -cantidad y el bloque de
    -- abajo lo borra en el mismo paso. Queda igual que como estaba, sin dejar
    -- rastro y sin tener que preguntar antes.
    local total = redis.call('HINCRBY', CARRITO, 'c:' .. id_oferta, -cantidad)

    if total <= 0 then
        redis.call('HDEL', CARRITO, 'l:' .. id_oferta, 'c:' .. id_oferta)
        return {'QUITADA', 0, lineas(), renovar(ttl)}
    end

    return {'RESTADA', total, lineas(), renovar(ttl)}


-- ============================================================
-- quitar
-- ============================================================
elseif op == 'quitar' then
    local ttl       = ARGV[2]
    local id_oferta = ARGV[3]

    local borrados = redis.call('HDEL', CARRITO, 'l:' .. id_oferta,
                                                 'c:' .. id_oferta)

    return {borrados > 0 and 'QUITADA' or 'NO_ESTABA', 0, lineas(), renovar(ttl)}


-- ============================================================
-- ver -- y SI renueva el vencimiento
-- ============================================================
-- Que una lectura renueve suena raro hasta que se piensa que abrir el carrito
-- ES actividad: la persona esta ahi, mirando lo que va a comprar. Si mirar no
-- contara, el carrito venceria justo mientras alguien lo tiene abierto
-- decidiendo.
--
-- La consecuencia hay que aceptarla: una pestana abierta que se refresque sola
-- mantiene el carrito vivo para siempre. Se acepta porque el costo de un
-- carrito de mas es unos cientos de bytes, y el costo de un carrito que
-- desaparece delante de la persona es una venta.
--
-- Para MIRAR el TTL sin renovarlo -- que es lo que necesita una prueba, o
-- cualquier panel de diagnostico -- no se usa esto: se usa el comando TTL
-- suelto desde afuera. prueba_carrito.sh hace exactamente eso, porque un
-- instrumento que altera lo que mide no mide nada.
elseif op == 'ver' then
    local ttl = ARGV[2]

    -- Se renueva ANTES de leer para que el TTL que va en la respuesta sea el
    -- que quedo y no el que habia. Es el numero que el frontend pinta en
    -- "tu carrito se vacia en ...", y mostrar el viejo seria mentir por un
    -- ciclo.
    local restante = renovar(ttl)

    return {'CARRITO', lineas(), restante, redis.call('HGETALL', CARRITO)}


-- ============================================================
-- renovar -- el latido
-- ============================================================
-- Para que el frontend mantenga vivo el carrito mientras la persona navega el
-- catalogo sin tocarlo. Es `ver` sin traerse los datos: si el carrito tiene 40
-- lineas, pedirlas enteras cada minuto solo para reiniciar un contador es
-- ancho de banda tirado.
elseif op == 'renovar' then
    return {'RENOVADO', lineas(), renovar(ARGV[2])}


-- ============================================================
-- vaciar
-- ============================================================
-- Se llama despues de que comprar_carrito() salio bien. Si se llamara antes y
-- el pago fallara, la persona se queda sin carrito Y sin compra, y tiene que
-- volver a armarlo producto por producto.
--
-- No hay `vaciar` "por si acaso" al fallar: el carrito que sobrevive a un pago
-- fallido es la unica forma de reintentar.
elseif op == 'vaciar' then
    return {'VACIADO', redis.call('DEL', CARRITO)}

else
    return redis.error_reply('operacion desconocida: ' .. tostring(op))
end
