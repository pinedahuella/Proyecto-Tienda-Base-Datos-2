# Cambio: apagar `es_inventario_limitado` cuando la venta relámpago vence sola

**Fecha aproximada:** 2026-09-04, mañana.
**Alcance:** solo `backend/`. Sin migraciones ni cambios de esquema (usa la
columna `es_inventario_limitado` de `014_inventario_limitado.sql`, ya
existente).

Tercer pedido de José (el compañero) de esta ronda, marcado por el usuario
como prioridad **baja** ("al comprador no le pasa nada y se sale con un
clic. Lo que miente es el panel del vendedor") pero decidido a cerrar en
la misma sesión.

## El problema

Cuando `POST /vendedor/ofertas/:id/venta-limitada` abre la venta con
`duracion_segundos`, Redis le pone `EXPIRE` a `mesh:oferta:<id>` (y
`redis/inventario_limitado.lua` sincroniza el `EXPIRE` de su ZSET de
reservas con el mismo TTL, verificado leyendo ese script). Al vencer, las
dos claves **desaparecen solas** en Redis, sin avisarle a nadie.

Pero `oferta.es_inventario_limitado` en PostgreSQL solo se apagaba antes
con `DELETE /vendedor/ofertas/:id/venta-limitada` manual
(`InventarioLimitadoService.revertir()`). Una venta relámpago que vencía
sola (o cualquier configurada con un `duracion_segundos` finito, que nadie
cerró a mano) dejaba esa columna en `true` para siempre: el panel del
vendedor seguía mostrando la oferta "en venta relámpago" cuando ya volvió
a comportarse como una oferta normal. Al comprador no le afectaba en nada
— Redis ya no tenía nada que reservar — así que el impacto real era solo
cosmético, de ahí la prioridad baja.

## El fix

Un `@Interval` nuevo en `InventarioLimitadoService.revisarVencidas()`,
mismo mecanismo que ya usa `GrafoSyncService` para el worker del outbox
del grafo (`@nestjs/schedule`, ya habilitado en `AppModule` con
`ScheduleModule.forRoot()`, sin cambios ahí). Cada 60 segundos:

1. `SELECT id_oferta FROM oferta WHERE es_inventario_limitado = true`.
2. Para cada una, reusa `existeVentaLimitada()` (ya existía, un `EXISTS`
   de Redis sobre `mesh:oferta:<id>`, sin tocar Postgres).
3. Si la clave ya no existe, `UPDATE oferta SET es_inventario_limitado =
   false WHERE id_oferta = $1 AND es_inventario_limitado = true` (el
   segundo `AND` es una guarda de concurrencia barata: si alguien volvió a
   abrir la venta relámpago justo entre el `EXISTS` y este `UPDATE`, no la
   apaga por error).

Nunca borra nada en Redis: si la venta venció sola, las dos claves ya se
fueron solas; si la cerraron con `DELETE`, también. Nunca relanza — es
mantenimiento cosmético, no debe tumbar nada del resto de la app: un
fallo leyendo Postgres o Redis en una corrida se loguea como warning y se
reintenta en la siguiente. Trae el mismo flag de reentrancia
(`revisandoVencidas`) que `GrafoSyncService` usa para que una corrida
lenta no se pise con la siguiente, aunque a esta escala (unas pocas
ofertas en venta relámpago a la vez) es más una formalidad que una
necesidad real.

**No toca** una venta sin vencimiento (`duracion_segundos: 0` o ausente,
`activar()` con TTL 0): esa clave nunca expira (`TTL` devuelve `-1`), así
que el `EXISTS` sigue en `1` para siempre y el worker no la toca — sigue
"en venta relámpago" hasta que alguien la cierre a mano, que es el
comportamiento correcto para ese caso.

Archivo tocado: `src/services/inventario-limitado/inventario-limitado.service.ts`
(un `@Interval` nuevo + dos constantes + un flag de reentrancia).

## Probado en vivo

| Caso | Resultado |
|---|---|
| `POST .../venta-limitada` con `duracion_segundos: 5` | a los 5 s, `EXISTS mesh:oferta:1` y `mesh:oferta:1:reservas` dan `0` (Redis ya las borró solas); `es_inventario_limitado` se queda en `true` hasta el siguiente tick |
| Siguiente tick del worker (≤ 60 s) | `es_inventario_limitado` pasa a `false`; log `"revision de ventas limitadas vencidas: 1 oferta(s) apagada(s) (vencieron solas)"`; `stock` de PostgreSQL sin tocar |
| `POST .../venta-limitada` con `duracion_segundos: 0` | `TTL mesh:oferta:1` da `-1`; dos ticks completos del worker (2 min) sin apagarla, sin log |
| `DELETE .../venta-limitada` manual, antes de que el worker corriera | sigue funcionando exactamente igual que antes — el worker no interfiere con el cierre manual |

`npx tsc --noEmit` limpio. `eslint` no agregó violaciones nuevas (mismo
conteo de `prettier/prettier` preexistentes que en `HEAD`: 1). Finales de
línea CRLF normalizados tras editar. Estado de la oferta de prueba
restaurado al terminar (precio, stock, estado `activa`,
`es_inventario_limitado: false`).

Documentado en `endpoints-vendedores.md`.
