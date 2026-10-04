# Plan pendiente — Señales `resena_positiva_cancelada` y `resenas_negativas_canceladas_vendedor`: reseñar y cancelar la compra

> **Estado (2026-10-04): HECHO y probado en local, con el backend corriendo.
> Falta lo de otros (migración real, ETL, docs) — ver el final.** Sin la fuente
> `postgres` y los dos tipos en el catálogo (`resenas-canceladas.sql`) el detector
> no puede guardar nada.

## El fraude

El comprador **paga, reseña y cancela el pedido** poco después. Cancelar
(`cancelar_pedido()`, lo que este sistema llama devolución) solo se puede mientras
el pedido está `pendiente` o `comprado` (uno `enviado` o `entregado` ya no), y
**reembolsa el pago**: al atacante no le cuesta nada. Para reseñar basta con que
el pago esté `pagado` y el pedido no `cancelado`, aunque todavía no haya salido.
Después de cancelar, la reseña se queda y la compra que la justificaba ya no
existe. Dos usos:

- **Reseña positiva** (4-5 estrellas): infla las reseñas de un vendedor sin comprar
  nada.
- **Reseña negativa** (1-2 estrellas): perjudica a un vendedor en poco tiempo.

Una reseña de 3 estrellas no cuenta nunca.

## Las dos señales

Ambas de la familia `patron_resenas`, con una **fuente nueva, `postgres`** (la
detección sale de pedidos y reseñas de PostgreSQL, sin Elasticsearch ni grafo; el
puntaje la cuenta como un motor aparte).

| Tipo | Qué es | `clave` | Casos |
|---|---|---|---|
| `resena_positiva_cancelada` | una **cuenta** con una reseña de 4-5 estrellas cuya compra canceló poco después. **Una sola vez ya es señal fuerte** (decisión del usuario): está en `TIPOS_FUERTES`, así que la cuenta es núcleo del caso con un solo hallazgo | id de la cuenta | **sí**, 20 puntos |
| `resenas_negativas_canceladas_vendedor` | un **vendedor** con 5 o más reseñas de 1-2 estrellas cuya compra se canceló poco después. Una sola no prueba nada (un comprador honesto y molesto hace lo mismo); por eso es del **vendedor** y no se enfoca en una oferta ni en un producto | id del vendedor | no, **solo alerta** (`TIPOS_SOLO_ALERTA`) |

En la del vendedor, el vendedor entra a `senal_fraude_cuenta` como `victima` y
quienes reseñaron y cancelaron como `autor`
(`registrarAnilloFraude` ahora acepta `cuentas` con su rol).

### Parámetros

| Parámetro | Valor | Dónde |
|---|---|---|
| Lapso entre la reseña y la cancelación | **72 horas**, y la cancelación **después** de la reseña | `HORAS_ENTRE_RESENA_Y_CANCELACION` |
| Negativas que hacen falta para señalar a un vendedor | **5 o más** | `MIN_NEGATIVAS` |
| Positivas que hacen falta para señalar a una cuenta | **1** | — |
| Ventana | **60 días** | `VENTANA_DIAS` |
| Evidencia guardada por señal | las 100 reseñas más recientes | `MAX_EVIDENCIA` |
| Puntos de `resena_positiva_cancelada` | **20** | `PUNTOS_BASE` |
| Intervalo del worker | **15 min** | `INTERVALO_MS` |

No cuenta una reseña cuyo autor tiene **otra compra vigente** (pagada y sin
cancelar) de ese producto a ese vendedor: esa compra sí la justifica.

## Cómo funciona

`ResenasCanceladasDetectorService`
(`services/fraude/resenas-canceladas-detector.service.ts`). Todo sale de
PostgreSQL, **sin campos nuevos**: una devolución deja un `stock_movimiento` de
motivo `devolucion` con su `id_pedido`, `id_oferta` (de ahí salen el producto y el
vendedor) y fecha; se cruza con la reseña del mismo comprador al mismo vendedor por
el mismo producto.

Dos disparadores, **un solo servicio**:

1. **Inmediato:** `PedidosService.cancelarPedido` llama a
   `detectarInmediato(idPedido)` justo después de cancelar un pedido `comprado`,
   sin `await` (igual que el chequeo acotado de los anillos). Es la **cancelación**,
   y no escribir la reseña, lo que completa el patrón: al escribir la reseña todavía
   no pasó. Vuelve a mirar al comprador (y al vendedor) completo, no solo ese pedido.
2. **Periódico:** `@Interval` cada **15 minutos** sobre toda la ventana. Es la red de
   seguridad y el que cuenta las negativas por vendedor desde cero.

Mismo molde que los demás detectores: bandera `procesando`, un error se loguea y no
tumba el proceso.

## Probado (2026-10-04)

Ver `endpoints-fraude.md`, "Pruebas -- hechas el 2026-10-04 (reseñas canceladas)":
12 cuentas de prueba, 13 pedidos reales (`agregar_linea`, `comprar_pedido`,
`cancelar_pedido`), y una cancelación **por la API** que creó la señal sola en
500 ms. Todo se borró al terminar y el stock volvió a su valor.

## Límites

- **No evita** el fraude, lo detecta. Cerrarlo de raíz es exigir que el pedido esté
  `entregado` para reseñar (un pedido entregado ya no se cancela); se dejó fuera
  a propósito para conservar la detección.
- Solo ve cancelaciones de pedidos `comprado` (el único estado con pago que se puede
  cancelar). Un pedido `pendiente` no tiene pago, así que no permite reseñar.
- La negativa por vendedor no distingue una campaña de varios compradores honestos
  molestos; por eso exige 5 o más y es solo alerta.
- La señal de cuenta solo es de las reseñas positivas: una cuenta que repite
  negativas con cancelación se ve en la señal del vendedor, no hay una señal propia
  de la cuenta.
- Cancelar emite el evento de devolución a ClickHouse (`registrarDevolucion`) como
  siempre; este detector no lo usa.

## Pendiente de otros (no tocar, ver `solo-backend`)

- Migración real: `resenas-canceladas.sql` (la fuente `postgres` y los dos tipos).
- Documentación general y preguntas de sustentación.
