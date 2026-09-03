# Cambio: el carrito ya reconoce el inventario limitado (Redis)

**Fecha aproximada:** 2026-09-03, tarde/noche.
**Alcance:** `backend/` — nuevo `src/services/inventario-limitado/`, y
cambios en `src/services/carrito/carrito.service.ts`,
`src/models/carrito.ts`, `src/helpers/constantes.ts`, `src/app.module.ts`.
También un cambio de esquema aplicado **solo en local** (ver abajo).

## Qué es esto

Es la pieza de la Entrega 2 que pide "venta de unidades limitadas bajo
alta concurrencia, sin sobreventa, con operaciones atómicas del almacén
clave-valor". El mecanismo de Redis (`redis/inventario_limitado.lua`) ya
estaba hecho y probado por separado; este cambio lo conecta al carrito de
verdad.

Documentación completa del diseño, decisiones y lo que falta:
`elementos Generales/plan pendiente/inventario-limitado.md`.

## Cambio de esquema (aplicado solo en local, no es una migración real)

Una columna nueva en `oferta`:

```sql
ALTER TABLE oferta
  ADD COLUMN es_inventario_limitado boolean NOT NULL DEFAULT false;
```

Marca si una oferta puntual está operando bajo el mecanismo de venta
relámpago. `false` para las 552 ofertas existentes — nada cambia de
comportamiento al aplicarlo. El `.sql` de referencia (idempotente, mismo
criterio que los otros cambios de este folder) está en
`plan pendiente/inventario-limitado.sql`. **La migración real la escribe
quien lleve `migrations/`** — este archivo es solo la forma exacta y una
copia aplicada en la base local para poder desarrollar en paralelo.

## Qué cambió en el carrito

El carrito (`mesh:carrito:<id_usuario>`, el HASH `id_oferta -> cantidad`
de siempre) sigue siendo exactamente eso para una oferta normal — cero
cambios de comportamiento, probado con regresión. La única novedad es
para una oferta marcada `es_inventario_limitado`:

- **`PUT /carrito/lineas/:idOferta`** — en vez del `HSET` ciego de
  siempre, reserva de verdad las unidades en Redis (o redimensiona una
  reserva que ya tenía, en un solo paso atómico — ver la propuesta
  `redimensionar` más abajo). Si no alcanza, 409 antes de tocar nada.
  Esta es la ÚNICA excepción a "agregar al carrito nunca reserva nada".
- **`DELETE /carrito/lineas/:idOferta`** — suelta la reserva antes de
  quitar la línea.
- **`GET /carrito`** — marca `es_inventario_limitado` por línea, y si la
  reserva venció sola, la línea sale `disponible: false, motivo:
  "reserva_vencida"`.

El ticket de cada reserva viaja como un campo compañero DENTRO del mismo
hash del carrito (`t:<id_oferta>`) — no hace falta que el cliente
recuerde ningún ticket, es estado del servidor.

**Lo que todavía NO está conectado** (paso 4 del plan): el checkout
(`POST /carrito/comprar`) no llama `confirmar`/`devolver` todavía. Una
compra de una línea de inventario limitado hoy la pasa por
`comprar_carrito()` de PostgreSQL como siempre, pero el ticket de Redis
se queda "reservado" sin confirmar — se libera solo cuando vence (hasta
15 min), no es un bug de sobreventa, solo una desprolijidad temporal
mientras se conecta esa parte.

## Propuesta para tu revisión: `redimensionar-reserva.lua`

Un script Lua **aparte** (no toca `redis/inventario_limitado.lua`), en
`plan pendiente/redimensionar-reserva.lua`, para el caso de "cambiar la
cantidad de una reserva que ya existe" — hace falta porque
`PUT /carrito/lineas/:idOferta` fija la cantidad ABSOLUTA, y tu archivo
no tiene esa operación. Hacerlo como dos llamadas (`devolver` +
`reservar`) deja un hueco de carrera real, o exige más stock del que
debería. `redimensionar` hace las dos cosas en un solo paso atómico.

Detalle completo, con el razonamiento y la evidencia de prueba (5/5
casos contra Redis real), en
`cambio_propuestas/2026-09-03_1700-redimensionar-reserva-lua.md`.

**Se pide tu revisión**: si te parece razonable, la sumás como una rama
más del `if op == ...` de tu archivo real, y el backend deja de cargar el
script provisional aparte.
