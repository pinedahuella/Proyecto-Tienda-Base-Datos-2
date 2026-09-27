# El worker de vencimiento no distinguía "venció" de "se perdió"

**Estado (2026-09-27): CERRADO, probado en vivo contra un `FLUSHALL` real.**

## El bug reportado

`VentasLimitadasService.revisarVencidas()` (cada minuto) decidía si un
descuento o una venta relámpago ya habían vencido preguntándole a Redis
"¿existe la clave?" -- y Redis no distingue "venció de verdad" de "se
perdió" (un `FLUSHALL`, un volumen borrado). Un descuento **permanente**
(`duracion_segundos: 0`, sin fecha de vencimiento) también tenía su clave
en Redis, solo que sin `EXPIRE`; si Redis se vaciaba, esa clave
desaparecía igual que una que sí venció, y el worker lo borraba de
PostgreSQL **para siempre**, sin que nadie lo pidiera. Lo mismo aplicaba a
una venta relámpago permanente.

## Decisión de alcance (discutida con el usuario)

Se consideraron y descartaron dos versiones más ambiciosas:

1. **Guardar dos timestamps** (`fecha_vencimiento_descuento` +
   `fecha_vencimiento_venta_limitada`) y además **revivir la clave de
   Redis** si Redis la pierde mientras la oferta todavía debía estar
   activa -- descartado: revivir el contador de stock de una venta
   relámpago (qué stock resembrar, que las reservas en curso se pierden
   sí o sí) es un problema aparte, con sus propias carreras entre el
   worker que cierra y el que "revive". Se decidió no construirlo.
2. **Un solo booleano genérico** (`vence_solo`) compartido entre descuento
   y venta relámpago -- descartado: un vendedor puede aplicar un
   descuento con una duración propia y DESPUÉS abrir una venta relámpago
   con una duración distinta; si se cierra la venta relámpago a mano
   antes de tiempo, hoy el descuento sigue vivo con su propio vencimiento
   intacto (`cerrar()`/`revertir()` nunca tocan `porcentaje_descuento`).
   Un solo booleano compartido perdería esa distinción.

**Lo que se construyó**: dos columnas de fecha (`NULL` = permanente, nunca
vence solo) en vez de banderas o timestamps coordinados con Redis. El
worker deja de preguntarle nada a Redis para decidir -- Postgres es la
única fuente de verdad de "cuándo vence esto". Revivir la clave de Redis
si se pierde **queda fuera a propósito**: con este cambio, en el peor
caso (Redis vaciado a media venta relámpago con tiempo restante) la venta
se "pausa" -- el checkout la trata como oferta normal hasta que venza sola
o el vendedor la reabra a mano -- en vez de perder el descuento para
siempre. Molesto, pero acotado y visible.

## Esquema (`vencimiento-automatico-oferta.sql`, mismo folder)

Dos columnas nullable en `oferta`:

- `fecha_vencimiento_descuento timestamptz NULL`
- `fecha_vencimiento_venta_limitada timestamptz NULL`

Aplicado en LOCAL, idempotente (`IF NOT EXISTS`), probado corriendo el
`.sql` dos veces seguidas sin error. Le toca al compañero integrarlo como
la próxima migración real (hoy la última es `027_similares_con_indice.sql`;
el 026 ya está reservado para casos de fraude, así que esta sería la 028).

## Código tocado (todo en `backend/src/`)

- **`services/vendedores/ofertas.service.ts`**: `aplicarDescuento()`
  calcula `fecha_vencimiento_descuento = now() + duracion_segundos` (o
  `NULL` si `duracion_segundos` es `0`) en el mismo `UPDATE` que ya hacía;
  `quitarDescuento()` la limpia. Se eliminó por completo el mecanismo de
  la clave de Redis del TTL del descuento (`claveDescuento`,
  `sembrarClaveDescuentoSinLanzar`, `borrarClaveDescuentoSinLanzar`) --
  nada más la leía, quedaba vestigial una vez que la decisión pasa a
  Postgres.
- **`services/inventario-limitado/inventario-limitado.service.ts`**:
  `activar()` guarda `fecha_vencimiento_venta_limitada` en el mismo
  `UPDATE` que enciende `es_inventario_limitado` (y en su rollback si
  Redis falla después); `revertir()` la limpia. La clave de Redis
  (`mesh:oferta:<id>`) sigue viva tal cual -- el checkout y el carrito
  siguen usándola (`existeVentaLimitada()`), esto no la reemplaza.
- **`services/vendedores/ventas-limitadas.service.ts`**:
  `revisarDescuentosVencidos()`/`revisarVentasLimitadasVencidas()` ya NO
  le preguntan nada a Redis -- el `WHERE` de cada consulta ahora filtra
  directo por `fecha_vencimiento_... IS NOT NULL AND fecha_vencimiento_... <= now()`.
  `apagarVentaLimitadaVencida()`/`quitarDescuentoVencido()` limpian las
  columnas de fecha correspondientes junto con lo que ya limpiaban.

## Probado en vivo -- 2026-09-27

Contra el servidor y la base real, simulando el bug tal como se reportó
(no una aproximación): cuatro ofertas reales de la tienda, un `FLUSHALL`
de verdad contra Redis (con el usuario ACL `operador`, el único con
permiso) y la corrida real del `@Interval` de un minuto, sin acortar el
intervalo ni llamar nada a mano.

| Oferta | Preparación | Tras el `FLUSHALL` + un tick del worker |
|---|---|---|
| Descuento permanente (sin `duracion_segundos`) | `porcentaje_descuento: 10` | Sigue con `10.00` -- **no se tocó** |
| Descuento temporal (`duracion_segundos: 5`) | `porcentaje_descuento: 20` | `NULL` -- se quitó solo, a tiempo |
| Venta relámpago permanente (descuento 15 + `venta-limitada` sin duración) | `es_inventario_limitado: true` | Sigue `true`, descuento sigue `15.00` -- **no se tocó** |
| Venta relámpago temporal (descuento 25 + `venta-limitada` con `duracion_segundos: 5`) | `es_inventario_limitado: true` | `false`, descuento `NULL` -- se cerró sola, a tiempo |

`redis-cli DBSIZE` en `0` durante todo el tramo de la prueba -- las dos
permanentes sobrevivieron con Redis completamente vacío, y las dos
temporales igual vencieron a tiempo (la decisión ya no depende de Redis
en absoluto).

Regresión sobre los caminos existentes, todavía en verde:
`POST .../descuento` sobre una oferta que ya tiene uno -> `409`;
`DELETE .../descuento` sin descuento activo -> `409`;
`POST .../venta-limitada` sin descuento previo -> `409`.

`npx tsc --noEmit` y `npx eslint` sobre los 7 archivos tocados: limpios.

Teardown: las cuatro ofertas de prueba se devolvieron a su estado original
(sin descuento, sin venta relámpago) por la API real (`DELETE`), no por
SQL directo -- son ofertas reales de la tienda, no datos sembrados para
esta prueba.

## Probado en vivo -- ronda 2, los dos disparadores de reglas (2026-09-27)

`aplicarDescuento()`/`abrir()` son el único punto de entrada que usan
`DisparadorReglasPeriodoService` y `DisparadorReglasAutomaticoService` --
en teoría heredan el arreglo gratis, sin tocarlos. Se confirmó en vivo,
no solo por lectura de código:

1. **Regla por período** (`regla_descuento_periodo`, siempre
   `duracion_segundos: 0`): se creó una regla para HOY sobre una oferta
   real de la tienda. Se reinició el backend para que
   `onApplicationBootstrap()` disparara la regla de inmediato (su
   `@Interval` es de 15 min, muy lento para esperar) -- aplicó el
   descuento con `fecha_vencimiento_descuento: NULL`, como se esperaba.
2. **Regla automática** (`regla_descuento_automatico`, `duracion_segundos`
   siempre > 0): se creó una regla con umbral de 1 unidad y
   `duracion_segundos: 30`, y se sembró una compra sintética en
   ClickHouse (`compra_producto`, `lote: 'real'`) para cruzar el umbral.
   El disparador (su propio `@Interval` de 1 minuto) la activó sola,
   dejando `fecha_vencimiento_descuento` ~30 segundos en el futuro.
3. Con las dos reglas ya disparadas (una permanente, una con 30s por
   delante), **`FLUSHALL` real** de nuevo contra Redis (`DBSIZE 0`
   confirmado) y espera del siguiente tick del worker de vencidos.
   Resultado: la de período sigue con su descuento intacto; la
   automática se quitó sola, justo cuando le tocaba (ni antes por el
   `FLUSHALL`, ni después) -- Redis vacío durante todo el tramo.

Teardown: descuento de la oferta de período quitado, las dos reglas
pausadas (`activa: false`, paso obligatorio antes de poder borrarlas) y
borradas, la compra sintética de ClickHouse eliminada por `id_pedido`.
