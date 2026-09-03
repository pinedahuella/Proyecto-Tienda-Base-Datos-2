# Propuesta: operación `redimensionar` para inventario_limitado.lua

**Fecha aproximada:** 2026-09-03, tarde.
**Para:** el compañero que lleva `redis/`. Este documento es una PROPUESTA,
no un aviso de cambio ya hecho sobre su archivo — su `.lua` real no se
tocó.
**Alcance:** `backend/elementos Generales/plan pendiente/redimensionar-reserva.lua`
(archivo nuevo, provisional) + este documento. Ningún archivo de `redis/`
ni de `migrations/` se modificó.

## El problema que resuelve

`redis/inventario_limitado.lua` tiene `sembrar` / `reservar` / `confirmar`
/ `devolver` / `estado`, pero ninguna forma de **cambiar la cantidad de
una reserva que ya existe**.

Hace falta porque en el backend, `PUT /carrito/lineas/:idOferta` fija la
cantidad **absoluta** de una línea del carrito (no es un `+1`/`-1`: mandás
`{"cantidad": 5}` y esa pasa a ser la cantidad final, reemplace lo que
hubiera). Para una oferta de inventario limitado, "cambiar la cantidad de
la línea" significa "cambiar cuántas unidades tengo reservadas" — y ahí
aparece el problema.

Con las operaciones que ya existen, la única forma de lograrlo es en DOS
llamadas separadas:

```
devolver(ticket_viejo)   -- suelta las unidades viejas
reservar(cantidad_nueva) -- pide las nuevas
```

Y eso tiene dos fallas reales, no solo de estilo:

1. **Deja un hueco entre las dos llamadas.** No son atómicas juntas —
   cada una lo es por separado. Entre que se sueltan las unidades viejas
   y se piden las nuevas, otro comprador puede llevarse justo esas
   unidades. Si eso pasa, la persona que estaba redimensionando su
   reserva se queda con **0**, habiendo tenido algo segundos antes.
2. **Si se hace al revés (reservar primero, devolver después)** para
   evitar el hueco de arriba, aparece un problema distinto y peor: como
   la reserva vieja sigue "reservada" (no vuelve al `stock`) mientras se
   pide la nueva, el sistema exige que existan **tantas unidades libres
   como la cantidad nueva completa**, sin contar las que la persona ya
   tenía. Alguien que tenía 2 apartadas y quiere 3 necesitaría que
   aparecieran **3 unidades ajenas libres**, cuando en realidad con que
   aparezca **1 más** ya le alcanza. Es más restrictivo de lo que
   debería, y le puede negar una compra válida sin motivo real.

## La solución propuesta

Una operación nueva, `redimensionar`, que hace las dos cosas — acreditar
lo viejo y pedir lo nuevo — **en un solo paso atómico**, dentro del mismo
script Lua. Nadie se puede meter en el medio, así que no hay hueco que
explotar; y la comparación es contra "lo que hay libre **más** lo que se
va a liberar", así que solo exige la diferencia real, nunca la cantidad
completa de cero.

### Forma

```
KEYS[1]  mesh:oferta:<id_oferta>
KEYS[2]  mesh:oferta:<id_oferta>:reservas

ARGV[1]  'redimensionar'
ARGV[2]  id_usuario
ARGV[3]  ticket_viejo  -- el que la persona ya tenía, o '' si es la
                            primera vez (se comporta como `reservar`)
ARGV[4]  cantidad_nueva -- la cantidad ABSOLUTA que quiere ahora
ARGV[5]  ttl_reserva_segundos de la reserva nueva
```

Devuelve `REDIMENSIONADO ticket_nuevo restante`, `AGOTADO 0 stock_efectivo`,
o `TICKET_AJENO 0` — mismo criterio de "primera palabra distingue el
resultado" que el resto del archivo.

El detalle completo, con el razonamiento línea por línea (por qué el
orden de las comprobaciones es el que es, por qué un ticket vencido no es
un error, etc.), está en los comentarios del propio archivo:
`plan pendiente/redimensionar-reserva.lua`.

### Probado en vivo, contra Redis real (no simulado) — 5/5 casos

Sembrada la oferta 10 con `stock = 12`:

| # | Caso | Resultado |
|---|---|---|
| 1 | Reserva nueva (sin ticket viejo), pide 2 | `REDIMENSIONADO 1 10` — igual que `reservar` |
| 2 | Ya tenía 2 (ticket 1), redimensiona a 3 | `REDIMENSIONADO 2 9` — **solo pidió 1 unidad de más, no 3**; el ticket 1 desapareció solo, quedó únicamente el ticket 2 con cantidad 3 |
| 3 | Pide 13 (más que el efectivo = 12) | `AGOTADO 0 12` — el `12` es `stock + lo que se iba a liberar`; **nada se tocó**, la reserva del ticket 2 sigue intacta |
| 4 | Un usuario distinto intenta redimensionar el ticket 2 (ajeno) | `TICKET_AJENO 0` — nada se tocó |
| 5 | Ticket viejo que no existe (vencido/inventado) | Se comporta como reserva nueva, sin acreditar nada — no es un error |

## Qué se pide

Que se revise esta propuesta y, si parece razonable, se sume como una
rama más del `if op == ...` de `redis/inventario_limitado.lua` (el
archivo real). Mientras eso no pase, el backend carga
`redimensionar-reserva.lua` como un script **aparte**, sin tocar el
archivo original — el día que se sume allá, este archivo provisional se
borra y el backend apunta al de siempre.

No se necesita ningún cambio de esquema en Postgres para esto — es pura
lógica de Redis.
