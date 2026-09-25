# DELETE de reglas de descuento, arranque del disparador de período, y B.4 fuera de alcance

**Fecha:** 2026-09-25, sexta pieza del día. Corrige tres puntos reales de
una lista de pendientes que trajo un compañero del equipo, verificados
contra el código antes de tocar nada (ver la conversación: dos de los
cuatro puntos de esa lista ya estaban resueltos o mal diagnosticados, estos
tres sí eran reales).
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## 1. B.4 (anillo en el tiempo) -- marcado FUERA DE ALCANCE

`plan pendiente/anillos-fraude-familia-b.md` decía "queda sin construir
por ahora" y dejaba la puerta abierta a construirlo después. Decisión
explícita del usuario: queda fuera de alcance, sin plan de construirse. El
id 7 del catálogo (`anillo_en_el_tiempo`) sigue reservado (no se reutiliza
para otro tipo), pero el documento ya no lo lista como pendiente.

## 2. `DisparadorReglasPeriodoService` corre también al arrancar

**El problema real**: el `@Interval` de Nest no dispara de inmediato, solo
después del primer intervalo (15 min). Si el backend estuvo apagado un día
en que una regla de período debía prenderse o apagarse, el estado quedaba
desincronizado hasta 15 minutos después de reiniciar.

**La corrección**: la clase implementa `OnApplicationBootstrap` y llama a
la misma `revisar()` una vez, apenas Nest termina de inicializar todos los
módulos -- antes incluso de que el servidor empiece a escuchar peticiones.
No es lógica nueva, es la misma función ya probada, disparada una vez más.

**Nota de alcance, aclarada con el usuario en la misma conversación**: el
otro disparador (`DisparadorReglasAutomaticoService`) NO tiene este
problema -- su activación depende de un TTL de Redis que sigue corriendo
aunque el backend esté apagado, y `VentasLimitadasService.revisarVencidas()`
(cada 60s) lo reconcilia solo apenas arranca, sin importar cuánto tiempo
pasó. Por eso el fix es solo para el disparador de período.

## 3. `DELETE` de reglas de descuento (automático y por período)

**El problema real**: no existía ninguna ruta para borrar una regla; las
pruebas la borraban directo en Postgres.

**La decisión de diseño**: rechazar con 409 (`"Pausa la regla (activa:
false) antes de borrarla"`) si la regla está `activa`. No es una validación
gratuita -- es la misma limitación que ya estaba documentada y hasta
REPRODUCIDA en vivo en `endpoints-vendedores.md` (ronda del
2026-09-24: borrar una regla activa por SQL directo dejó un descuento
huérfano en una oferta, sin ninguna fila que lo justificara ni ningún
worker que pudiera volver a verla). El `DELETE` real, a diferencia del SQL
directo de las pruebas, cierra esa puerta: para borrar hay que pasar primero
por `PATCH { "activa": false }`, que ya deja al disparador (o al TTL de
Redis, en el caso automático) limpiar el efecto sobre la oferta antes de
que la fila desaparezca.

Mismo patrón en los dos servicios (`ReglasDescuentoPeriodoService.eliminar()`,
`ReglasDescuentoAutomaticoService.eliminar()`): valida el id, confirma
dueño (mismo 404 genérico de siempre si es ajena o no existe), lee `activa`
y rechaza si es `true`, borra con `DELETE ... USING oferta ...` para que la
comprobación de dueño sea parte de la misma operación.

## Qué se hizo

| Archivo | Qué cambió |
|---|---|
| `elementos Generales/plan pendiente/anillos-fraude-familia-b.md` | B.4 marcado como fuera de alcance, ya no "por ahora" |
| `src/services/reglas-descuento-periodo/disparador-reglas-periodo.service.ts` | implementa `OnApplicationBootstrap`, llama a `revisar()` al arrancar |
| `src/services/reglas-descuento-periodo/reglas-descuento-periodo.service.ts` | `eliminar()` nuevo |
| `src/controllers/reglas-descuento-periodo/reglas-descuento-periodo.controller.ts` | `DELETE /vendedor/reglas-descuento-periodos/:id` nuevo |
| `src/services/reglas-descuento-automatico/reglas-descuento-automatico.service.ts` | `eliminar()` nuevo, mismo patrón |
| `src/controllers/reglas-descuento-automatico/reglas-descuento-automatico.controller.ts` | `DELETE /vendedor/reglas-descuento/:id` nuevo |
| `elementos Generales/endpoints/endpoints-vendedores.md` | documenta los dos `DELETE`, el arranque del disparador, y actualiza la limitación conocida |

## Probado en vivo -- 2026-09-25

Contra el servidor y la base real (`ventas_norte`, oferta 251, sin ningún
otro mecanismo activo antes de cada prueba).

| Caso | Resultado |
|---|---|
| Regla de período insertada directo en Postgres (simulando "cambió con el backend apagado"), rango cubre hoy, `activa: true` | `oferta.porcentaje_descuento` sigue `NULL` -- nadie la aplicó |
| Reiniciar el backend, revisar Postgres a los pocos segundos | log del disparador **antes** de "Nest application successfully started"; `porcentaje_descuento` ya en `20.00` |
| `DELETE /vendedor/reglas-descuento-periodos/:id` sobre esa regla, todavía `activa` | 409 `"Pausa la regla (activa: false) antes de borrarla"` |
| `PATCH { "activa": false }` + `DELETE` sobre la misma regla | 200, la fila desaparece; `DELETE` de nuevo → 404 |
| `POST /vendedor/reglas-descuento` (automático) sobre la misma oferta, con el descuento huérfano todavía puesto (por borrar la regla de período mientras estaba activa, vía SQL en una prueba anterior de esta misma ronda) | 409 "ya tiene un descuento manual activo" -- reproduce la limitación conocida documentada, no un bug nuevo |
| `DELETE /vendedor/ofertas/251/descuento` para limpiar ese huérfano | 200, `porcentaje_descuento` vuelve a `NULL` |
| `POST /vendedor/reglas-descuento` de nuevo, sobre la oferta ya limpia | 201 |
| `DELETE /vendedor/reglas-descuento/:id` sobre esa regla automática, `activa: true` | 409 |
| `PATCH { "activa": false }` + `DELETE` | 200; `DELETE` de nuevo → 404 |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

Teardown: oferta 251 y las dos tablas de reglas quedaron vacías/limpias,
confirmado contra Postgres.
