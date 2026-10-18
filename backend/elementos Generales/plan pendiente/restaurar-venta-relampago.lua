--[[
restaurar-venta-relampago.lua -- PROVISIONAL, escrito por Claude (el asistente
del backend), NO por quien lleva redis/inventario_limitado.lua. Mismo caso que
redimensionar-reserva.lua (este folder): un script APARTE sobre las MISMAS dos
claves, que el backend carga ademas del original. Ver carrito-postgres-verdad.md.

POR QUE EXISTE
============================================================
El profesor pidio que Redis nunca sea la fuente de verdad. Las reservas de una
venta relampago ahora viven en PostgreSQL (`reserva_venta_relampago`), y Redis
es la puerta rapida que decide primero. Hace falta poder RECONSTRUIR el estado
de Redis desde PostgreSQL en tres momentos:

  1. Al ABRIR la venta. `sembrar` (del original) reinicia el contador de
     tickets en 0, y un carrito que guardaba el ticket 3 de una venta
     anterior chocaba con el ticket 3 de otra persona en la venta nueva
     (TICKET_AJENO, o peor). Aqui el contador arranca en `ticket_base`, que
     es el ticket mas alto que esa oferta repartio en toda su historia.
  2. Cuando Redis PERDIO la venta (se reinicio, un FLUSHALL) y PostgreSQL
     dice que sigue abierta.
  3. Cuando hubo reservas hechas solo en PostgreSQL (Redis estaba caido) y
     Redis no las conoce.

En los tres casos se borra lo que habia y se escribe de nuevo, en un solo paso
atomico: stock libre, cada reserva viva con SU ticket y SU vencimiento, y el
contador de tickets.

KEYS[1]  mesh:oferta:<id_oferta>            HASH   (igual que el original)
KEYS[2]  mesh:oferta:<id_oferta>:reservas   ZSET   (igual que el original)

ARGV
  1  'restaurar'
  2  stock_libre      unidades que se pueden tomar (oferta.stock - reservas vivas)
  3  ttl_segundos     cuando cierra la venta (0 = sin vencimiento)
  4  ticket_base      el contador arranca aqui (nunca reparte uno ya usado)
  5  vendidas         el contador informativo de vendidas
  6  n                cuantas reservas vienen detras
  7.. de a cuatro:    ticket, id_usuario, cantidad, vence_ms

Devuelve {'RESTAURADA', stock_libre, ultimo_ticket, t1, t2, ...}: despues del
ultimo ticket, el ticket que recibio CADA reserva, en el mismo orden en que
llegaron. Un ticket que llega en 0 es una reserva hecha solo en PostgreSQL (no
tenia): se le reparte uno nuevo, y quien llama lo guarda en PostgreSQL.

Todas las comprobaciones van ANTES de la primera escritura, como en el
original: Redis no deshace lo que un script ya escribio.
]]

local CLAVE    = KEYS[1]
local RESERVAS = KEYS[2]

if ARGV[1] ~= 'restaurar' then
    return redis.error_reply('operacion desconocida: ' .. tostring(ARGV[1]))
end

local stock_libre = tonumber(ARGV[2])
local ttl         = tonumber(ARGV[3])
local base        = tonumber(ARGV[4])
local vendidas    = tonumber(ARGV[5])
local n           = tonumber(ARGV[6])

if not stock_libre or stock_libre < 0 then
    return redis.error_reply('restaurar: el stock libre tiene que ser >= 0')
end
if not ttl or ttl < 0 or not base or base < 0 or not vendidas or vendidas < 0 then
    return redis.error_reply('restaurar: ttl, ticket_base y vendidas tienen que ser >= 0')
end
if not n or n < 0 or #ARGV ~= 6 + n * 4 then
    return redis.error_reply('restaurar: la lista de reservas no cuadra con n')
end

-- Se valida la lista entera antes de escribir nada.
local reservado = 0
local maximo = base
for i = 0, n - 1 do
    local ticket   = tonumber(ARGV[7 + i * 4])
    local cantidad = tonumber(ARGV[9 + i * 4])
    local vence    = tonumber(ARGV[10 + i * 4])
    if not ticket or ticket < 0 or not cantidad or cantidad <= 0 or not vence then
        return redis.error_reply('restaurar: reserva ' .. (i + 1) .. ' invalida')
    end
    if ticket > maximo then
        maximo = ticket
    end
    reservado = reservado + cantidad
end

redis.call('DEL', CLAVE, RESERVAS)
redis.call('HSET', CLAVE,
           'stock', stock_libre, 'reservado', reservado,
           'vendidas', vendidas, 'rechazos', 0, 'ticket', maximo)

-- Las que llegaron sin ticket se numeran DESPUES del mas alto, para no chocar
-- con ninguno de los que si traian.
local siguiente = maximo
local asignados = {}
for i = 0, n - 1 do
    local ticket     = tonumber(ARGV[7 + i * 4])
    local id_usuario = ARGV[8 + i * 4]
    local cantidad   = tonumber(ARGV[9 + i * 4])
    local vence      = tonumber(ARGV[10 + i * 4])
    if ticket == 0 then
        siguiente = siguiente + 1
        ticket = siguiente
    end
    redis.call('HSET', CLAVE, 'r:' .. ticket, cantidad, 'u:' .. ticket, id_usuario)
    redis.call('ZADD', RESERVAS, vence, ticket)
    asignados[#asignados + 1] = ticket
end
redis.call('HSET', CLAVE, 'ticket', siguiente)

-- Las dos claves vencen juntas (mismo criterio que `reservar` del original).
if ttl > 0 then
    redis.call('EXPIRE', CLAVE, ttl)
    if n > 0 then
        redis.call('EXPIRE', RESERVAS, ttl)
    end
end

local respuesta = {'RESTAURADA', stock_libre, siguiente}
for i = 1, #asignados do
    respuesta[#respuesta + 1] = asignados[i]
end
return respuesta
