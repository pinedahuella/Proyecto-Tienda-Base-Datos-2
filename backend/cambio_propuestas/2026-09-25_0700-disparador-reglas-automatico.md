# El disparador de `regla_descuento_automatico` (ClickHouse)

**Fecha:** 2026-09-25. Cierra el segundo de los dos workers que le
faltaban a las reglas de descuento -- el de `regla_descuento_periodo` se
construyó el 2026-09-24 (`cambio_propuestas/2026-09-24_2359-...md`), este
era el que faltaba, bloqueado hasta ahora por el pendiente de "cuándo se
activó" que quedó documentado en varias rondas anteriores.
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## Por qué ya se podía construir

El bloqueo original era que este disparo es de una sola vez con
`duracion_segundos` fija, a diferencia de `regla_descuento_periodo` (una
condición de estado reevaluable sola en cada corrida). Pero
`duracion_segundos` en `regla_descuento_automatico` **nunca puede ser 0**
(`validarDuracionSegundos`, en `helpers/validaciones-regla-descuento.ts`:
"acá la regla siempre tiene que vencer sola") -- la propia regla ya estaba
diseñada para depender de un TTL. Eso significa que toda activación de
este worker usa EXACTAMENTE el mismo mecanismo de TTL de Redis que ya
usan `POST .../descuento` y `POST .../venta-limitada` con
`duracion_segundos`, y `VentasLimitadasService.revisarVencidas()` (el
worker que ya existía desde el 2026-08, sin ningún cambio en esta ronda)
es quien la apaga sola cuando vence. No hace falta guardar "cuándo se
activó" en Postgres: la cuenta regresiva vive en Redis, no acá.

## Diseño

`DisparadorReglasAutomaticoService` (`@Interval`, 60 s,
`src/services/reglas-descuento-automatico/disparador-reglas-automatico.service.ts`):

1. Trae toda regla `activa = true` cuya oferta tenga
   `porcentaje_descuento IS NULL` -- mientras esa columna esté llena, la
   exclusión mutua (`exigirSinOtroMecanismoActivo`) garantiza que esta
   MISMA regla es su única dueña (`UNIQUE(id_oferta)` en
   `regla_descuento_automatico`), así que no hace falta gastar una
   consulta a ClickHouse por ella en cada corrida.
2. Por cada una, consulta ClickHouse (`compra_producto`, filtrando
   `lote = 'real'`, mismo patrón que `MasVendidosSyncService`): unidades
   vendidas de esa oferta en los últimos `ventana_minutos`.
3. Si llegan a `umbral_unidades`: `OfertasVendedorService.aplicarDescuento()`
   con `mecanismo: 'regla_automatica'` (el mismo parámetro que ya existía,
   agregado para el disparador de período -- no hizo falta tocar
   `ofertas.service.ts` ni `ventas-limitadas.service.ts` para nada de
   esto) y el `duracion_segundos`/`porcentaje_descuento` de la regla; si
   `es_venta_relampago`, `VentasLimitadasService.abrir()` con el mismo
   `duracion_segundos` y mecanismo, inmediatamente después.

Nunca desactiva nada -- a diferencia de `DisparadorReglasPeriodoService`,
no tiene ningún `quitarEfecto()`: el TTL de Redis es la única vía de
apagado, y ya existe.

## Hallazgo real de diseño, encontrado probando (no es un bug de código)

**Si `duracion_segundos` de la regla es MENOR que su `ventana_minutos`, la
oferta "parpadea".** El TTL apaga el descuento, pero las mismas ventas que
lo dispararon siguen dentro de la ventana en el siguiente tick del
disparador, así que se vuelve a activar de inmediato -- un ciclo de
encendido/apagado que se repite hasta que esas ventas salgan de la
ventana de detección.

Confirmado en vivo con `duracion_segundos: 8` y `ventana_minutos: 10`
(oferta 31, `ventas_norte`): se reactivó tres veces seguidas, cada vez que
`VentasLimitadasService.revisarVencidas()` la apagaba (cada ~60 s, su
intervalo real), hasta que se pausó la regla a mano para cortar el ciclo.

En el uso normal esperado -- `duracion_segundos` MAYOR que
`ventana_minutos` (ej. "2 horas de oferta" disparadas por "30 minutos de
ventas rápidas") -- esto no pasa: para cuando el TTL vence, las ventas que
lo motivaron ya salieron de la ventana de detección, y la regla solo se
reactiva si de verdad siguieron vendiendo rápido durante todo ese tiempo,
que es el comportamiento deseado ("mientras siga vendiendo rápido, sigue
en oferta"). Confirmado también en vivo: con `duracion_segundos: 90` y
`ventana_minutos: 1` (oferta 34, `ventas_sur`), al vencer el TTL la oferta
se apagó sola sin reactivarse.

**No se corrigió en código** porque no es un bug -- es una consecuencia
matemática esperable de esa combinación de parámetros, y la corrección
"natural" (excluir de la ventana las ventas que ya causaron una activación
anterior) es una decisión de producto que nadie pidió y que complicaría el
disparador sin necesidad. Queda anotado como algo a explicar al
configurar una regla (recomendar `duracion_segundos` > `ventana_minutos`
salvo que se quiera ese parpadeo a propósito), no como pendiente técnico.

## Otra decisión encontrada probando: pausar una regla no apaga su efecto ya activo

A diferencia de `DisparadorReglasPeriodoService` (que si reconcilia una
regla pausada con efecto pegado, ver su propio `cambio_propuestas`), acá
`PATCH { activa: false }` sobre una regla mientras su descuento/venta
relámpago sigue activo **no lo apaga de inmediato** -- se deja que el TTL
de Redis termine su curso normal. Es consciente: el mecanismo entero de
esta regla está construido sobre "el TTL manda"; agregar una segunda vía
de apagado (forzada, por fuera del TTL) no resuelve ningún problema real,
porque lo peor que pasa sin ella es que el descuento dure hasta el resto
de su duración ya configurada, nunca más de eso.

## Qué se hizo

| Archivo | Qué cambió |
|---|---|
| `src/services/reglas-descuento-automatico/disparador-reglas-automatico.service.ts` | nuevo -- el worker completo |
| `src/app.module.ts` | registra el servicio nuevo |
| `src/models/regla-descuento-automatico.ts` | comentario de cabecera actualizado (ya no dice "todavía no existe") |
| `src/services/reglas-descuento-automatico/reglas-descuento-automatico.service.ts` | comentario de cabecera actualizado |
| `src/services/reglas-descuento-periodo/reglas-descuento-periodo.service.ts` | comentario de cabecera corregido (estaba desactualizado desde antes: decía que el disparador de período tampoco existía) |
| `src/services/reglas-descuento-periodo/disparador-reglas-periodo.service.ts` | comentario de cabecera actualizado (ya no dice que el de automático está bloqueado) |
| `elementos Generales/endpoints/endpoints-vendedores.md` | nueva sección dedicada + la mención vieja de "sigue sin el suyo, bloqueado" corregida |

No se tocó `ofertas.service.ts` ni `ventas-limitadas.service.ts`: el
parámetro `mecanismo` que este worker necesitaba ya era genérico (se
agregó pensando también en este caso cuando se construyó el disparador de
período), y el worker de apagado por TTL ya existía completo.

## Probado en vivo -- 2026-09-25

Contra el servidor y las bases reales (`ventas_norte` oferta 31,
`ventas_sur` oferta 34; Postgres, ClickHouse y Redis reales), con el
intervalo bajado a 5 s solo para la prueba (repuesto a 60 s después):

| Caso | Resultado |
|---|---|
| Regla creada (umbral 3, ventana 10 min, 15% descuento), sin ventas sembradas | nunca se toca |
| 2 unidades sembradas en `compra_producto` (bajo el umbral) | sigue sin tocarse |
| 1 unidad más (total 3, cruza el umbral) | se activa sola en el siguiente tick: `porcentaje_descuento: 15.00`; fila nueva en `precio_historial` con `id_usuario_modifico` = el id real del vendedor dueño (4, `ventas_norte`), no un id de sistema; `GET /vendedor/ofertas` muestra `precio_final: 7598.15` (8939 × 0.85) |
| `POST .../descuento` manual sobre la misma oferta mientras el automático está activo | 409 "Esta oferta ya tiene un descuento activo" |
| Regla con `es_venta_relampago: true` (umbral 5, ventana 1 min, duración 90 s, 20%) + 5 unidades sembradas (oferta 34, `ventas_sur`) | se activan las dos cosas en el mismo tick: `porcentaje_descuento: 20.00`, `es_inventario_limitado: true`; `precio_final: 4757.60` (5947 × 0.8), `stock_disponible: 17`; Redis: HASH `mesh:oferta:34` sembrado con el stock real de Postgres (17), TTL de `mesh:oferta:34` y `mesh:oferta:34:descuento` sincronizados (~76-77 s) |
| Al vencer el TTL de 90 s (ventana de 1 min ya quedó atrás) | se apaga sola (`revisarVentasLimitadasVencidas`), sin reactivarse |
| Pausar la regla de la oferta 31 (`activa: false`) mientras el efecto seguía activo | el efecto ya activo NO se apagó de inmediato (siguió su TTL); sin la pausa, ya se había reactivado 3 veces seguidas (ver el hallazgo del parpadeo) -- confirmado con un monitor de 40+ ticks que, tras pausar, dejó de reactivarse y quedó limpio en el siguiente vencimiento del TTL |
| ClickHouse real caído (`docker stop mesh-clickhouse`), con la regla de la oferta 31 reactivada y sin ventas sembradas | `WARN` en el log por cada intento ("no se pudo consultar ClickHouse..."), la app y el resto de rutas HTTP siguieron respondiendo `200` normal, ninguna activación falsa, Postgres sin tocar |
| ClickHouse recuperado (`docker start mesh-clickhouse`) | la corrida siguiente (tras un par de reintentos con `ECONNRESET` durante el arranque del contenedor) volvió a consultar limpio; sin ventas reales, no se activó (comportamiento correcto) |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo, antes y después de reponer el intervalo a 60 s | limpios los dos |

Teardown: las dos reglas de prueba (ids 6 y 7) se borraron a mano de
Postgres; las filas sembradas en `compra_producto` se borraron con
`ALTER TABLE compra_producto DELETE WHERE id_pedido IN (...)` (ClickHouse
no tiene transacciones, es mutación real); las ofertas 31 y 34 quedaron
sin descuento ni venta relámpago activa y sin ninguna clave de Redis
residual (`KEYS mesh:oferta:31*`/`34*` vacío al terminar).

## Lo que queda pendiente

La atribución de `precio_historial.id_usuario_modifico` cuando quien
activa es un worker sin usuario detrás **no aplica a este caso**: el
disparador siempre pasa el id real del vendedor dueño de la oferta (nunca
un id de sistema), así que la atribución sale correcta -- confirmado en
vivo (ver la tabla de arriba). El pendiente de atribución sigue siendo
solo el de las limpiezas automáticas por TTL vencido (ya anotado en
`cambio_propuestas/2026-09-24_2200-bug-ttl-descuento-pegado.md` y
`2026-09-24_2345-ttl-descuento-manual.md`), sin cambios por esta pieza.

Con esto, las 4 formas de descuento/venta relámpago (manual, venta
relámpago manual, regla de período, regla automática) tienen su mecanismo
de activación Y desactivación completos.
