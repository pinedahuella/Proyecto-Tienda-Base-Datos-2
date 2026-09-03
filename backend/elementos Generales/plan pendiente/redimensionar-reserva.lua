--[[
redimensionar-reserva.lua -- PROVISIONAL, escrito por Claude (el asistente
del backend), NO por quien lleva redis/inventario_limitado.lua. Ver
`inventario-limitado.md` (mismo folder) para el plan completo.

POR QUE EXISTE
============================================================
redis/inventario_limitado.lua (el archivo real, del companero) tiene
sembrar/reservar/confirmar/devolver/estado, pero no una forma de cambiar
la CANTIDAD de una reserva que ya existe. Hace falta porque
`PUT /carrito/lineas/:idOferta` fija la cantidad ABSOLUTA (no +1/-1): si
alguien ya tenia 2 unidades reservadas y pide 3, hay que resolver eso en
un solo paso, no como "reservar 3 nuevas" (le pediria 3 unidades AJENAS
libres, sin contar las 2 que ya eran suyas) ni como "devolver las 2 y
despues reservar 3" en dos llamadas separadas (deja un hueco real donde
otro comprador se puede llevar el stock que se acaba de soltar, y la
persona podria terminar con 0 en vez de con sus 2 originales).

Esta operacion hace las DOS cosas -- acreditar lo viejo y pedir lo nuevo
-- en UN SOLO paso atomico. Sin hueco: nadie se puede meter en el medio,
igual que el resto del archivo original.

QUE NO ES
============================================================
No reemplaza ni modifica redis/inventario_limitado.lua. Es un script
APARTE que el backend carga ademas del original, mientras se decide si se
suma como una rama mas del `if op == ...` de ese archivo. El dia que
quien lleva esa carpeta la revise y la sume alla, este archivo se borra y
el backend apunta al de el. Repite a proposito los mismos helpers
(`ahora_ms`, `campo`, `cosechar`) del archivo original -- no los importa
de ahi porque un script Lua de Redis no puede requerir otro archivo.

FORMA
============================================================
KEYS[1]  mesh:oferta:<id_oferta>            (el mismo HASH de siempre)
KEYS[2]  mesh:oferta:<id_oferta>:reservas   (el mismo ZSET de siempre)

ARGV[1]  'redimensionar' (fijo -- por si el dia de manana esto se pega
         dentro del archivo grande junto a las demas operaciones)
ARGV[2]  id_usuario
ARGV[3]  ticket_viejo -- el ticket que la persona ya tenia para esta
         oferta, o cadena vacia '' si es la primera vez que reserva (ahi
         se comporta exactamente como `reservar`)
ARGV[4]  cantidad_nueva -- la cantidad ABSOLUTA que quiere ahora
ARGV[5]  ttl_reserva_segundos de la reserva NUEVA (0 = sin vencer)

Devuelve, primer elemento una palabra, igual criterio que el resto del
archivo:
  REDIMENSIONADO  ticket_nuevo  restante
  AGOTADO         0             stock_efectivo   (ver mas abajo que es)
  TICKET_AJENO    0

TICKET_AJENO solo puede pasar si ticket_viejo no es vacio y es de OTRO
usuario -- se comprueba antes de tocar nada, para que nadie pueda usar
esto para redimensionar (y de paso robar) la reserva de otra persona.
]]

local op       = ARGV[1]
local CLAVE    = KEYS[1]
local RESERVAS = KEYS[2]

if op ~= 'redimensionar' then
    return redis.error_reply('este script provisional solo tiene la operacion redimensionar')
end

-- Mismo tope y mismo motivo que en inventario_limitado.lua: cosechar sin
-- limite dejaria a Redis entero sin atender a nadie si una oferta junta
-- miles de reservas vencidas de golpe.
local TOPE_COSECHA = 100

-- Copiado tal cual del archivo original -- ver ahi la razon completa de
-- por que el reloj sale de Redis y no de un ARGV.
local function ahora_ms()
    local t = redis.call('TIME')
    return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end

local function campo(nombre)
    local v = redis.call('HGET', CLAVE, nombre)
    if not v then return nil end
    return tonumber(v)
end

local function cosechar(ahora)
    local vencidos = redis.call('ZRANGEBYSCORE', RESERVAS, '-inf', ahora,
                                'LIMIT', 0, TOPE_COSECHA)
    for i = 1, #vencidos do
        local ticket = vencidos[i]
        local cantidad = campo('r:' .. ticket)
        if cantidad then
            redis.call('HINCRBY', CLAVE, 'stock', cantidad)
            redis.call('HINCRBY', CLAVE, 'reservado', -cantidad)
            redis.call('HDEL', CLAVE, 'r:' .. ticket, 'u:' .. ticket)
        end
        redis.call('ZREM', RESERVAS, ticket)
    end
end

local id_usuario     = ARGV[2]
local ticket_viejo   = ARGV[3]
local cantidad_nueva = tonumber(ARGV[4])
local ttl_res        = tonumber(ARGV[5])

if not cantidad_nueva or cantidad_nueva <= 0 then
    return redis.error_reply('redimensionar: la cantidad tiene que ser > 0')
end

local ahora = ahora_ms()
cosechar(ahora)

-- Paso 1: si hay ticket viejo, comprobar que EXISTA y sea del MISMO
-- usuario, antes de tocar nada. Mismo orden-como-garantia que
-- confirmar/devolver del archivo original: Redis no deshace lo que el
-- script ya escribio, asi que cualquier rechazo tiene que decidirse
-- antes del primer HINCRBY.
--
-- Si el ticket viejo ya no existe (vencio, o ya se cosecho), NO es un
-- error: no hay nada que acreditar, y esto se comporta como una reserva
-- nueva de una.
local cantidad_vieja = nil
if ticket_viejo ~= nil and ticket_viejo ~= '' then
    cantidad_vieja = campo('r:' .. ticket_viejo)
    if cantidad_vieja then
        local dueno = redis.call('HGET', CLAVE, 'u:' .. ticket_viejo)
        if dueno ~= id_usuario then
            return {'TICKET_AJENO', 0}
        end
    end
end

-- Paso 2: comparar contra el stock EFECTIVO, no el de ahora mismo --
-- sumandole lo que la reserva vieja va a liberar. Es la parte que
-- resuelve el problema real: la persona no necesita `cantidad_nueva`
-- unidades ajenas libres, solo la diferencia contra lo que ya tenia.
local stock_actual   = campo('stock') or 0
local stock_efectivo = stock_actual + (cantidad_vieja or 0)

if cantidad_nueva > stock_efectivo then
    redis.call('HINCRBY', CLAVE, 'rechazos', 1)
    return {'AGOTADO', 0, stock_efectivo}
end

-- Paso 3: a partir de aca todo pasa. Soltar lo viejo (si habia) y pedir
-- lo nuevo, LAS DOS COSAS dentro del mismo paso atomico -- a diferencia
-- de llamar devolver y despues reservar por separado, aca nadie se
-- puede meter en el medio de las dos escrituras.
if cantidad_vieja then
    redis.call('ZREM', RESERVAS, ticket_viejo)
    redis.call('HDEL', CLAVE, 'r:' .. ticket_viejo, 'u:' .. ticket_viejo)
    redis.call('HINCRBY', CLAVE, 'reservado', -cantidad_vieja)
    redis.call('HINCRBY', CLAVE, 'stock', cantidad_vieja)
end

local ticket_nuevo = redis.call('HINCRBY', CLAVE, 'ticket', 1)
local restante      = redis.call('HINCRBY', CLAVE, 'stock', -cantidad_nueva)
redis.call('HINCRBY', CLAVE, 'reservado', cantidad_nueva)
redis.call('HSET', CLAVE, 'r:' .. ticket_nuevo, cantidad_nueva, 'u:' .. ticket_nuevo, id_usuario)

if ttl_res and ttl_res > 0 then
    redis.call('ZADD', RESERVAS, ahora + (ttl_res * 1000), ticket_nuevo)
else
    redis.call('ZADD', RESERVAS, '+inf', ticket_nuevo)
end

-- Mismo criterio que reservar: el vencimiento del ZSET se copia del que
-- le queda al hash, para que las dos claves de la oferta desaparezcan
-- juntas.
local ttl_oferta = redis.call('TTL', CLAVE)
if ttl_oferta > 0 then
    redis.call('EXPIRE', RESERVAS, ttl_oferta)
end

return {'REDIMENSIONADO', ticket_nuevo, restante}
