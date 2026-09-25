# Solape entre reglas de período de la misma oferta

**Fecha:** 2026-09-24, tercera pieza del día (después del bug del TTL y la
exclusión mutua entre los cuatro mecanismos) de la preparación para
construir los workers de descuento -- ver
`elementos Generales/plan pendiente/reglas-descuento-periodos.md`.
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## El problema

`regla_descuento_periodo` permite varias reglas activas a la vez sobre la
misma oferta (decisión original: un período fijo de Black Friday y uno
recurrente mensual pueden convivir), pero solo tiene sentido si sus rangos
de días **nunca coinciden en un mismo día real** -- si dos reglas activas
aplicaran el mismo día, no hay ningún criterio definido de cuál gana. Hasta
esta ronda, nada impedía crear dos reglas que sí se pisaran.

## La solución

Un helper nuevo, `helpers/solape-regla-descuento-periodo.ts`
(`reglasDePeriodoSeSolapan()`), que representa el rango de día/mes de una
regla como una máscara de 12×31 casillas y compara dos máscaras, más un
chequeo de "año compartido" (dos reglas con año fijo distinto nunca se
solapan, sin importar el rango de día/mes; una regla recurrente sin año
comparte todos los años). El detalle completo del algoritmo y sus
supuestos (las reglas "con año" no cruzan al año siguiente) está en el
comentario de cabecera del archivo y en la sección dedicada de
`endpoints/endpoints-vendedores.md`.

## Qué se hizo

| Archivo | Qué cambió |
|---|---|
| `src/helpers/solape-regla-descuento-periodo.ts` | nuevo -- `reglasDePeriodoSeSolapan()` y sus tipos |
| `src/services/reglas-descuento-periodo/reglas-descuento-periodo.service.ts` | nuevo método privado `exigirSinSolapeConOtrasActivas()`, llamado desde `crear()` (siempre) y desde `editar()` (cada vez que la regla queda activa después de la edición, con el rango FINAL mezclado) |
| `elementos Generales/endpoints/endpoints-vendedores.md` | nueva sección dedicada + actualizadas las menciones de "todavía no está construida" en la sección de exclusión de mecanismos y en `POST /vendedor/reglas-descuento-periodos` |

No se tocó ningún esquema ni migración -- es lógica de aplicación pura.

## Probado -- unitario y en vivo, 2026-09-24

**Unitario** (18 casos, corridos con un script de scratchpad contra el
helper compilado directamente, sin pasar por el servidor): rangos de solo
día con y sin *wrap* de fin de mes (28-3), rangos de mes con y sin *wrap*
de fin de año (nov-feb), año exacto vs año exacto (mismo año se solapan,
distinto no), año exacto vs recurrente sin año (la recurrente sí aplica en
ese año), y combinaciones cruzadas día-solo vs mes-rango. Un caso reveló
un error en mi propia expectativa de prueba, no en el algoritmo (esperaba
que "nov 20 - feb 10" NO cubriera "enero 11-14", pero sí lo cubre: enero
entero cae dentro de ese rango que cruza el fin de año) -- corregido el
caso de prueba, no el código. Los 18 en verde.

**En vivo** contra el servidor y la base real (`ventas_norte`, ofertas
18/27/31/35):

| Caso | Resultado |
|---|---|
| Crear regla A (día 1-5) → crear regla B (día 3-10, se solapan) sobre la misma oferta | 201, luego 409 |
| Crear regla C (día 10-15, no se solapa con A) sobre la misma oferta | 201 -- conviven sin problema |
| `PATCH` regla C a `dia_inicio: 4` (ahora se solapa con A) | 409; la fila no cambió |
| Mes 1-3 → mes 3-5 (se solapan en marzo) → mes 6-8 (no se solapa) | 201, 409, 201 |
| Año 2026 dic 20-31 → mismo rango año 2027 → mismo rango año 2026 de nuevo | 201, 201, 409 |
| Crear D (día 1-5) → pausarla → crear E (día 3-8, se solapa con D) mientras D está pausada | 201, 200, 201 |
| Reactivar D con E ya activa y solapada | 409 |
| `npx tsc --noEmit` y `eslint` sobre el repo completo | limpios |

Teardown: las ocho reglas de prueba se borraron a mano de Postgres.

## Lo que queda pendiente

Con esto, las dos piezas de diseño que le faltaban a `regla_descuento_periodo`
(exclusión de mecanismos y solape entre reglas propias) están resueltas.
Sigue pendiente el disparador real de las dos reglas (worker que revise
ClickHouse / la fecha de hoy) y la atribución de
`precio_historial.id_usuario_modifico` cuando quien escribe es un worker
sin usuario detrás -- ambos mencionados ya en los `cambio_propuestas`
anteriores de hoy.
