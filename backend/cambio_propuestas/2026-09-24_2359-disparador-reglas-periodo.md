# El disparador de `regla_descuento_periodo`

**Fecha:** 2026-09-24, quinta y última pieza del día. Primero de los dos
workers pendientes de las reglas de descuento -- el de
`regla_descuento_automatico` sigue bloqueado por el pendiente de "cuándo
se activó" (ver `models/regla-descuento-automatico.ts` y la conversación
sobre eso). `regla_descuento_periodo` no tenía ese problema: es una
condición de estado, reevaluable sola en cada corrida.
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## Por qué ya se podía construir

Las dos piezas de diseño resueltas antes hoy mismo (exclusión mutua entre
los cuatro mecanismos, solape entre reglas de período de la misma oferta)
garantizan las dos invariantes que el disparador necesita para no arbitrar
nada: mientras una regla de período está activa, es la única dueña del
`porcentaje_descuento`/`es_inventario_limitado` de su oferta; y a lo sumo
una regla activa de una oferta puede aplicar en un día dado.

## Diseño

`DisparadorReglasPeriodoService` (`@Interval`, 15 min) reusa las rutas ya
existentes (`OfertasVendedorService.aplicarDescuento()`/`quitarDescuento()`,
`VentasLimitadasService.abrir()`/`cerrar()`) en vez de escribir SQL propio
-- así vienen gratis la validación, el recálculo de Mongo, la
sincronización de Redis y el trigger de `precio_historial`. Como esas
rutas piden un actor humano, el disparador pasa el `id_usuario` dueño de
la oferta con rol vendedor (nunca admin).

Algoritmo por oferta con al menos una regla de período (activa o no):
encontrar `reglaHoy` (la activa cuyo rango incluye hoy, a lo sumo una); si
el estado actual ya coincide, no hacer nada; si no coincide pero el estado
no está vacío, reconocerlo contra CUALQUIER regla de la oferta (activa o
no) y, si se reconoce, quitarlo; si `reglaHoy` existe y el estado quedó
vacío, aplicarlo. El detalle completo está en el comentario de cabecera
del archivo y en `endpoints/endpoints-vendedores.md`.

## Dos bugs reales encontrados construyendo esto (no en el diseño de papel)

**El disparador se rechazaba a sí mismo.** `aplicarDescuento()`/`abrir()`
llamaban a `exigirSinOtroMecanismoActivo()` con el mecanismo fijo
(`'descuento_manual'`/`'venta_relampago_manual'`), sin importar quién
llamara. Cuando el disparador los invocaba para aplicar la MISMA regla que
los estaba disparando, el chequeo veía "hay una regla de período activa"
(la propia regla) y respondía 409. Arreglado con un parámetro `mecanismo`
opcional en los dos métodos (por defecto el valor de siempre, para no
tocar a los llamadores HTTP), para que el disparador se identifique como
`'regla_periodo'`.

**Un segundo caso más sutil, mismo origen.** Al aplicar una regla con
venta relámpago, para cuando `abrir()` corre (después de `aplicarDescuento()`),
el `porcentaje_descuento` que la propia regla ACABA de poner ya luce como
"un descuento manual activo" -- `exigirSinOtroMecanismoActivo()` no sabe
quién puso ese valor, solo si la columna está llena. Arreglado: `abrir()`
salta el chequeo por completo cuando `mecanismo` no es
`'venta_relampago_manual'`, confiando en que la exclusividad ya la validó
el `aplicarDescuento()` que la misma regla llamó un instante antes.

## Qué se hizo

| Archivo | Qué cambió |
|---|---|
| `src/services/reglas-descuento-periodo/disparador-reglas-periodo.service.ts` | nuevo -- el worker completo |
| `src/services/vendedores/ofertas.service.ts` | `aplicarDescuento()` gana el parámetro `mecanismo` opcional |
| `src/services/vendedores/ventas-limitadas.service.ts` | `abrir()` gana el mismo parámetro; salta el chequeo de exclusión cuando no es `'venta_relampago_manual'` |
| `src/app.module.ts` | registra el servicio nuevo |
| `elementos Generales/endpoints/endpoints-vendedores.md` | nueva sección dedicada + las menciones de "todavía no existe" del disparador de período, corregidas |

## Probado en vivo -- 2026-09-24

Contra el servidor y la base real (`ventas_norte`, ofertas 3/18/27), con el
intervalo bajado a 8 s solo para la prueba (repuesto a 15 min después):

| Caso | Resultado |
|---|---|
| Regla que cubre hoy en oferta 3 | primer intento: 409 (el bug); después del arreglo, se aplica sola |
| Regla que NO cubre hoy en oferta 18 | nunca se toca |
| Regla que cubre hoy con venta relámpago en oferta 27 | se aplican descuento y venta relámpago en el mismo tick |
| Pausar la regla ya aplicada de la oferta 3 | se quita el descuento solo en el siguiente tick |
| Crear una segunda regla en la oferta 18 que sí cubre hoy | se aplica sin tocar la regla vieja |
| Pausar la regla con venta relámpago de la oferta 27 | se cierra la venta relámpago Y se quita el descuento |
| `npx tsc --noEmit` y `eslint` sobre el repo completo | limpios |

Teardown: reglas de prueba borradas a mano; la oferta 18 quedó con un
descuento huérfano (su regla se borró directo por SQL) que se quitó con el
`DELETE .../descuento` real -- confirma en vivo la limitación conocida
(un descuento que no coincide con ninguna regla existente de su oferta no
se toca solo).

## Lo que queda pendiente

El disparador de `regla_descuento_automatico` (bloqueado por "cuándo se
activó") y la atribución de `precio_historial.id_usuario_modifico` cuando
quien escribe es un worker sin usuario detrás -- ambos ya anotados en
rondas anteriores de hoy, sin cambios por esta pieza.
