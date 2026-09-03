# Cambio propuesto: chequeo de precio y stock al pagar el carrito

**Fecha aproximada:** 2026-09-03, tarde.
**Alcance:** solo `backend/` (`src/dto/comprar-carrito.ts`,
`src/services/carrito/carrito.service.ts`,
`src/controllers/carrito/carrito.controller.ts`,
`src/helpers/constantes.ts`). No requirió tocar Postgres, Mongo, ni ninguna
migración — es lógica pura del backend sobre datos que ya existían.

## Por qué

El profe pidió que, al pagar el carrito, si el precio o el stock que el
comprador vio cambiaron mientras tanto, la compra se cancele y se le avise
del cambio en vez de cobrarle algo distinto a lo que vio. El carrito vive
en Redis como un simple `Map<id_oferta, cantidad>` (ver
`endpoints-carrito.md`) y **a propósito no guarda** nombre, precio ni
stock — esos datos se resuelven al vuelo contra Postgres/Mongo. Este
cambio decide cómo se hace el chequeo sin romper esa decisión de diseño.

## Qué cambió

### 1. Disponibilidad (stock 0, stock insuficiente, oferta pausada/retirada, id inventado)

Sin cambios de comportamiento hacia el comprador: sigue rechazando la
compra completa con **409** y la lista de qué línea es el problema. Lo
nuevo es un interruptor en el código,
`QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR` (`src/helpers/constantes.ts`, hoy
en `false`), que decide si además esas líneas se borran del carrito en
Redis antes de responder, o si el carrito queda intacto para que el
comprador decida qué hacer. No es un parámetro de la petición — es una
constante que hay que tocar y redesplegar para cambiar. Se dejó en `false`
porque es el comportamiento menos sorprendente por defecto (nada
desaparece del carrito sin que el comprador lo pida).

### 2. Precio (nuevo: aviso en vez de cobrar el precio equivocado)

`POST /carrito/comprar` acepta ahora un campo opcional
`lineas_precio_visto: [{ id_oferta, precio_visto }]`. El backend compara,
por línea, ese precio contra el precio actual de la oferta:

- Si coinciden (o no se manda el campo): la compra sigue normal, cobrando
  el precio de hoy — igual que antes de este cambio.
- Si alguno no coincide: **no se compra nada** (ni se toca Redis, ni
  Postgres, ni Mongo). La respuesta trae `comprado: false` y una lista de
  `avisos` con el precio visto y el precio actual de cada línea afectada.
- El comprador puede reenviar la misma petición con
  `confirmar_cambios: true` para aceptar el precio nuevo y completar la
  compra.

Es el mismo patrón que ya existía en `POST /comprador/pedidos/:id/comprar`
(`PedidosCompradorService.revisarCambiosAntesDeComprar`), reutilizado aquí
para que ambos endpoints se comporten igual.

Detalle completo, con ejemplos de petición/respuesta, en
`elementos Generales/endpoints-carrito.md` (sección `POST /carrito/comprar`).

## Lo que le toca al FRONTEND a partir de este cambio

Esto es lo importante para quien conecte la UI, porque cambia una
responsabilidad que antes no existía:

1. **Guardar el precio visto, del lado del frontend** (`localStorage` o
   equivalente — nunca en Redis, eso no cambió). Cada vez que
   `GET /carrito` devuelve el carrito, el frontend debería quedarse con el
   `precio` de cada línea que le mostró al usuario.
2. **Mandarlo de vuelta al pagar.** Al llamar `POST /carrito/comprar`, el
   frontend arma `lineas_precio_visto` con esos precios guardados.
3. **`GET /carrito` sigue siendo la fuente de la verdad "de hoy".** Cada
   vez que el usuario vuelve a ver el carrito (o el frontend lo refresca),
   los precios y el stock que trae son los actuales — el frontend debe
   actualizar lo que tiene guardado con eso.
4. **Si `POST /carrito/comprar` responde `comprado: false`**, el frontend
   tiene que avisarle al usuario que algo cambió antes de cobrar —un popup
   o mensaje similar, mostrando `avisos[].precio_visto` vs.
   `avisos[].precio_actual`— y dejarlo decidir si confirma (reenviando con
   `confirmar_cambios: true`) o ajusta el carrito primero.
5. Lo mismo aplica, sin campo nuevo de por medio, para el **stock**: si el
   409 de disponibilidad llega, el mensaje ya trae qué línea es el
   problema; el frontend lo muestra y dejamos que el usuario ajuste
   cantidad o quite la línea — nada se quita solo (con el interruptor en
   `false`).

Esto no está implementado en el frontend todavía — lo lleva otra persona
del equipo (ver memoria `solo-backend`); este documento es la especificación
de lo que el backend ya soporta para que se conecte.
