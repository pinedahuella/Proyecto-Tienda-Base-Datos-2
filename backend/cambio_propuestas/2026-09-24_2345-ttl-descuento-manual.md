# TTL opcional para el descuento manual puro

**Fecha:** 2026-09-24, cuarta pieza del día. Pedido explícito del usuario,
surgido de la conversación sobre el bug del TTL de la venta relámpago:
"me gustaría que si tuvieran ese TTL de expiración a mano" para el
descuento manual, "solo para nosotros, el backend... se copia la lógica de
expiración de ventas limitadas".
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## Qué se pidió

El descuento manual puro (`POST /vendedor/ofertas/:id/descuento`, sin venta
relámpago) nunca vencía solo -- decisión explícita del 2026-09-23 ("sin
worker nuevo, a propósito"). Esa decisión se reversó hoy: ahora puede tener
un `duracion_segundos` opcional, puramente interno (el cliente no lo ve en
ninguna respuesta), calcado del mismo mecanismo que ya usaba
`POST .../venta-limitada`.

## Cómo se hizo

**Validación compartida.** `validarDuracion()` vivía como método privado
de `VentasLimitadasService`. Se sacó a `helpers/validaciones-oferta.ts`
como `validarDuracionVencimiento()` (mismo rango 0-604800, mismo mensaje)
para que los dos endpoints usen exactamente la misma regla -- no una copia.

**Redis, mismo patrón que la venta relámpago.** Al aplicar un descuento,
`OfertasVendedorService.aplicarDescuento()` siembra
`mesh:oferta:<id>:descuento`: con `EXPIRE` si `duracion_segundos > 0`, sin
él si es `0`. La clave se crea SIEMPRE (con o sin vencimiento) porque la
existencia de la clave es la única señal que usa el worker -- si no se
creara para los descuentos permanentes, el worker los trataría como
vencidos en el primer tick. `quitarDescuento()` borra la clave si el
vendedor lo quita antes de tiempo.

**El worker.** `VentasLimitadasService.revisarVencidas()` (el mismo
`@Interval` de cada minuto) ahora llama a dos revisiones: la de siempre
(`revisarVentasLimitadasVencidas()`, sin cambios de lógica) y una nueva
(`revisarDescuentosVencidos()`) que mira las ofertas con descuento activo
que NO están en venta relámpago, y limpia el descuento si su clave de
Redis ya expiró. Además, `revisarVentasLimitadasVencidas()` ahora también
borra la clave del descuento cuando limpia una venta relámpago vencida --
si no, un descuento de larga duración que quedó debajo de una venta
relámpago más corta dejaría esa clave viva en Redis para siempre (la
oferta deja de aparecer en la consulta de `revisarDescuentosVencidos()` en
cuanto `porcentaje_descuento` queda `NULL`, así que nada más la revisaría).

## Qué se hizo

| Archivo | Qué cambió |
|---|---|
| `src/helpers/validaciones-oferta.ts` | `validarDuracionVencimiento()` nueva, compartida |
| `src/dto/aplicar-descuento.ts` | `duracion_segundos?: number` nuevo |
| `src/services/vendedores/ofertas.service.ts` | `aplicarDescuento()` valida y siembra la clave; `quitarDescuento()` la borra; dos métodos privados nuevos (`claveDescuento`, `sembrarClaveDescuentoSinLanzar`, `borrarClaveDescuentoSinLanzar`) |
| `src/services/vendedores/ventas-limitadas.service.ts` | `revisarVencidas()` pasa a orquestar dos métodos privados (`revisarVentasLimitadasVencidas()`, extraído tal cual del cuerpo anterior, y `revisarDescuentosVencidos()`, nuevo); `validarDuracion()` propio eliminado, usa el helper compartido |
| `elementos Generales/endpoints/endpoints-vendedores.md` | nueva sección dedicada + notas en `POST`/`DELETE .../descuento` |

## Probado en vivo -- 2026-09-24

Contra el servidor y la base real (`ventas_norte`, ofertas 3/18/27):

| Caso | Resultado |
|---|---|
| Descuento con `duracion_segundos: 6` | 201; `TTL` de la clave → `6` |
| Descuento sin duración | 201; la clave existe, `TTL` → `-1` (sin vencimiento) |
| Al vencer los 6 s + el siguiente tick del worker | log de limpieza; descuento quitado, clave ausente |
| El descuento sin duración, mismo tick | intacto |
| `DELETE .../descuento` sobre el que no tenía duración | la clave se borra en el acto |
| Descuento con `duracion_segundos: 300` + venta relámpago con `duracion_segundos: 6` encima, dejar vencer la venta relámpago | se limpian las dos cosas: `porcentaje_descuento`, `es_inventario_limitado`, Y la clave del descuento (que todavía tenía ~294 s de sobra) |
| Mongo, en los tres casos | recalculado correctamente |
| `npx tsc --noEmit` y `eslint` sobre el repo completo | limpios |

Teardown: ninguno hizo falta -- todo volvió solo a su estado original, que
es justamente lo que se estaba probando.

## Lo que queda pendiente (ya anotado en rondas anteriores, no cambia con esto)

La atribución de `precio_historial.id_usuario_modifico` cuando quien limpia
el descuento es un worker sin usuario detrás sigue sin resolverse -- este
cambio no la agrava ni la corrige, solo suma un tercer camino (además del
worker de venta relámpago) que puede llegar a esa misma limitación.
