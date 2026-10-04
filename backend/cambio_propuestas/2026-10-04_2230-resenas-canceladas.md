# Detección de reseñar y cancelar la compra

**Fecha:** 2026-10-04.
**Alcance:** `backend/`. Sin campos nuevos. Plan completo en
`elementos Generales/plan pendiente/resenas-canceladas.md`.

## Por qué

Un comprador puede pagar, reseñar y cancelar el pedido (`cancelar_pedido()`, lo que
el sistema llama devolución; solo en `pendiente` o `comprado`) y se le reembolsa. La
reseña se queda aunque la compra ya no exista: infla (4-5 estrellas) o perjudica
(1-2 estrellas) a un vendedor sin costo. Para reseñar solo se pide pago `pagado` y
pedido no `cancelado`, aunque el pedido no haya salido.

## Qué se hizo

- `services/fraude/resenas-canceladas-detector.service.ts`
  (`ResenasCanceladasDetectorService`): cruza el `stock_movimiento` de motivo
  `devolucion` con la reseña del mismo comprador al mismo vendedor por el mismo
  producto; la cancelación debe ser después de la reseña y dentro de 72 horas, y no
  cuenta si el autor tiene otra compra vigente del producto.
- `resena_positiva_cancelada`: una reseña de 4-5 estrellas, **una sola vez ya es
  señal fuerte** (`TIPOS_FUERTES`, 20 puntos, entra a los casos).
- `resenas_negativas_canceladas_vendedor`: 5 o más reseñas de 1-2 estrellas de un
  vendedor; no se enfoca en una oferta ni producto; solo alerta (`TIPOS_SOLO_ALERTA`).
- **Dos disparadores:** al cancelar un pedido (`PedidosService.cancelarPedido` llama a
  `detectarInmediato`, sin esperar) y el worker `@Interval` cada 15 minutos. El
  disparo es la cancelación y no la reseña, porque al escribirla la cancelación
  todavía no ocurrió.
- **Fuente nueva `postgres`:** `FuenteHallazgo`, `EvidenciaCasoFraude.fuente`, el
  mapa del adaptador y el `CASE` de `casos-fraude.service.ts`. Cuenta como un motor
  más en el puntaje.
- `registrarAnilloFraude` acepta `cuentas` con su rol (`autor`/`victima`), para que el
  vendedor de la señal negativa salga como víctima.
- Tipos nuevos en `TipoAnilloFraude`, el filtro `tipo` de
  `GET /admin/fraude/alertas-resenas` y `PUNTOS_BASE`. Sin ruta nueva.
- Documentado en `endpoints-fraude.md`.

## Probado

12 cuentas de prueba y 13 pedidos reales, incluida una cancelación por la API que
creó la señal sola en 500 ms (ver `endpoints-fraude.md`). Todo se borró al terminar,
el stock volvió a su valor y el grafo cuadra.

## Límites

- Detecta, no evita. Exigir que el pedido esté `entregado` para reseñar cerraría el
  fraude de raíz (un pedido entregado no se cancela); queda como mejora posible.
- No hay señal propia de la cuenta para negativas repetidas; esa se ve en la del
  vendedor.

## Pendiente de otros (ver `solo-backend`)

- Migración real con la fuente `postgres` y los dos tipos (`resenas-canceladas.sql`).
- Documentación general y preguntas de sustentación.
