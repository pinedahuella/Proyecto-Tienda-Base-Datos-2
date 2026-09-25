# Exclusión mutua entre los cuatro mecanismos de descuento/venta relámpago

**Fecha:** 2026-09-24, segunda pieza (después del bug del TTL) de la
preparación para construir los workers de `regla_descuento_automatico` y
`regla_descuento_periodo` -- ver `elementos Generales/plan pendiente/reglas-descuento-periodos.md`
y `descuentos-oferta.md`.
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## El problema

Los dos workers pendientes (el de la regla automática, que lee ClickHouse,
y el de la regla de período, que revisa la fecha de hoy) y los dos flujos
manuales que ya existían (`POST .../descuento` y `POST .../venta-limitada`)
terminan todos escribiendo las mismas dos columnas de `oferta`:
`porcentaje_descuento` y `es_inventario_limitado`. Sin ninguna regla que
los ordene, un vendedor podía tener, por ejemplo, un descuento manual Y una
regla automática activa sobre la misma oferta al mismo tiempo -- sin que
nada defina cuál manda, ni qué pasa cuando una de las dos se apague.

## La decisión, con el usuario

Los cuatro mecanismos son mutuamente excluyentes: como mucho UNO puede
estar activo a la vez por oferta. "Activo" para las dos reglas es su
columna `activa = true` -- una regla pausada no cuenta y no bloquea nada
(confirmado explícitamente: "un activo en false, significa que no está,
así que no es excluyente").

La única excepción: descuento manual y venta relámpago manual no se
excluyen entre sí, porque la venta relámpago ya exige un descuento puesto
como precondición (código existente, sin tocar) -- son la misma "pista
manual".

Contra su propio tipo, cada regla ya se comportaba distinto (sin tocar en
esta ronda): `regla_descuento_automatico` tiene `UNIQUE(id_oferta)` desde
que se creó; `regla_descuento_periodo` puede tener varias activas a la vez
si sus rangos de días no se solapan -- esa validación de solape es aparte
y **todavía no está construida**, queda para una ronda futura.

## Qué se hizo

| Archivo | Qué cambió |
|---|---|
| `src/helpers/exclusion-mecanismos-descuento.ts` | nuevo -- `exigirSinOtroMecanismoActivo()`, una consulta que trae los cuatro flags de una oferta y una tabla `EXCLUYE` que define contra cuáles choca cada mecanismo al entrar |
| `src/services/vendedores/ofertas.service.ts` | `aplicarDescuento()` llama al chequeo dentro de la misma transacción/`FOR UPDATE` que ya tenía |
| `src/services/vendedores/ventas-limitadas.service.ts` | `abrir()` llama al chequeo (consulta suelta) |
| `src/services/reglas-descuento-automatico/reglas-descuento-automatico.service.ts` | `crear()` lo llama siempre (nace `activa: true`); `editar()` lo llama solo si `datos.activa === true`, con un helper privado nuevo que resuelve el `id_oferta` de la regla primero |
| `src/services/reglas-descuento-periodo/reglas-descuento-periodo.service.ts` | mismo patrón que la automática: `crear()` siempre, `editar()` solo si `activa === true` (ahí ya tenía la fila cargada de antes, no hizo falta un helper aparte) |
| `elementos Generales/endpoints/endpoints-vendedores.md` | nueva sección dedicada + notas en los 409 de los cuatro endpoints existentes |

No se tocó ningún esquema ni migración -- es lógica de aplicación pura,
leyendo columnas/tablas que ya existían.

## Probado en vivo -- 2026-09-24

Contra el servidor y la base real (`ventas_norte`, ofertas 18/27/35/39/42;
`ventas_sur`, oferta 5):

| Caso | Resultado |
|---|---|
| Descuento manual activo → crear regla automática / regla de período sobre la misma oferta | 409 los dos |
| Regla automática activa → aplicar descuento manual sobre la misma oferta | 409 |
| Regla de período activa → crear regla automática sobre la misma oferta | 409 |
| Pausar una regla automática (`activa: false`) → aplicar descuento manual sobre esa oferta | 201 -- ya no bloquea |
| Descuento manual + venta relámpago manual sobre la MISMA oferta | 201 los dos -- la única excepción funciona |
| Reactivar una regla de período pausada (`PATCH activa: true`) mientras hay un descuento manual activo | 409, mismo chequeo que crear() |
| Reactivar una regla automática pausada en las mismas condiciones | 409 |
| Otro vendedor crea una regla sobre su propia oferta, sin nada activo ahí | 201 -- el chequeo es por oferta, no cruza vendedores |
| `npx tsc --noEmit` y `eslint` sobre el repo completo | limpios |

Teardown: se cerraron/quitaron todos los descuentos y ventas relámpago de
prueba, y se borraron a mano de Postgres las filas de reglas creadas para
la prueba. Las seis ofertas tocadas quedaron en su estado original.

## Lo que queda pendiente

- El solape de fechas entre reglas de período de la misma oferta (sin
  resolver, mencionado arriba).
- El disparador real de las dos reglas -- este trabajo es la base para
  poder construirlo con seguridad, pero el worker en sí no se tocó en esta
  ronda.
- La atribución de `precio_historial.id_usuario_modifico` cuando el que
  escribe es un worker sin usuario detrás (mismo hallazgo que en el bug
  del TTL, todavía sin resolver).
