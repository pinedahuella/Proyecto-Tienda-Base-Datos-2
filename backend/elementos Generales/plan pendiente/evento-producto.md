# Plan pendiente — Cola de productos por recalcular (`evento_producto`)

> **Estado (2026-10-01): tabla, triggers, worker y retiro de TODAS las llamadas
> directas a `recalcularCamposCalculados` HECHOS y probados en local. Solo
> falta la migración real (le toca a quien lleva `migrations/`).** Sin esa
> migración el worker falla (no existe `evento_producto`).

## El problema

Después de cobrar, el checkout llama con `await` a
`ProductosService.recalcularCamposCalculados()`
(`carrito.service.ts:738`, `pedidos.service.ts:663`), que escribe en Mongo
(`productos.service.ts:733`). Ahí se traga los errores, así que la compra no se
pierde, pero **Mongo sigue bloqueando el tiempo de respuesta**: con Mongo caído
son ~3 s por producto (`serverSelectionTimeoutMS`, `mongo.ts:31`), en serie.
El mismo patrón está en cancelar pedido, en 5 sitios de `ofertas.service.ts`
y en reseñas.

## Decisión: outbox, igual que `evento_grafo`

Que el cambio anote "este producto cambió" en PostgreSQL, en la **misma
transacción**, y que un worker aparte recalcule en Mongo. Mismo diseño y
nombres que `migrations/015_outbox_grafo.sql`. La tarjeta del catálogo (precio,
stock, ofertas, descuento, nota) puede tardar unos segundos; la ficha y el
cobro siguen en vivo contra PostgreSQL, así que nada se vende de más.

## Etapas

### Etapa 1 — Tabla y triggers (HECHA en local)

`evento-producto.sql` (mismo folder). Para quien lleva `migrations/`:
integrarlo como `030_evento_producto.sql` (después de
`029_catalogo_en_postgres.sql`); todo lo que va antes del `COMMIT` del
archivo, más el bloque de verificación del final.

- **`evento_producto`**: `id_evento`, `id_producto_mongo`, `fecha`,
  `procesado_en`, `intentos`, `ultimo_error`. Sin FK, como `evento_grafo`.
- **Una sola fila pendiente por producto** (índice único parcial
  `uq_evento_producto_pendiente`). No es un log: recalcular parte siempre del
  estado actual, así que N cambios seguidos = un recalculo. Diferencia con
  `evento_grafo`, que guarda una fila por cambio.
- **`encolar_evento_producto()`** hace UPSERT y renueva `fecha`.
- **`trg_oferta_al_producto`** sobre `oferta`: INSERT, DELETE y UPDATE solo de
  `precio`, `porcentaje_descuento`, `stock`, `id_estado_oferta` (las columnas
  que entran en los campos calculados).
- **`trg_resena_al_producto`** sobre `resena`: nota media y total.

Probado: dos cambios al mismo producto dejan una sola fila pendiente, y un
`ROLLBACK` no deja nada.

**Ojo con el orden:** `migrations/datos/001_catalogo.sql` solo apaga
`trg_oferta_registrar_precio`, no estos triggers. Como la migración corre
antes que la semilla, una base recién creada queda con una fila pendiente por
producto sembrado, que es lo correcto: el primer paso del worker rehace los
campos calculados de todo el catálogo.

### Etapa 2 — El worker (HECHA: `services/productos/evento-producto-sync.service.ts`)

Servicio con `@Interval` cada 5–10 s, como el de `evento_grafo`:

1. Leer las filas con `procesado_en IS NULL` (con su `fecha`), por `id_evento`.
2. Por cada una, `recalcularCamposCalculados([id_producto_mongo])`. Hoy esa
   función se traga sus errores: para el worker hay que hacer que **diga** si
   falló (devolver `boolean` o lanzar), si no nunca se reintenta.
3. Si salió bien: `UPDATE evento_producto SET procesado_en = now() WHERE
   id_evento = $1 AND fecha = $2` (la `fecha` que leyó). Si el producto
   cambió mientras tanto, `fecha` es otra, no actualiza nada y la fila sigue
   pendiente: se vuelve a hacer.
4. Si falló: `intentos = intentos + 1`, `ultimo_error`; apartarla pasado un
   máximo de intentos para que no frene a las demás.
5. Con Mongo caído, cortar la pasada al primer fallo de conexión en vez de
   esperar 3 s por producto.

### Etapa 3 — Quitar los `await` (HECHA, en todas las rutas)

Quitar `recalcularCamposCalculados` del checkout (carrito y pedidos), y
después, si se quiere, de cancelar, ofertas y reseñas. Mientras el worker no
exista, **no quitar nada**: el recalculo directo es lo único que mantiene
la tarjeta al día.

## Lo que queda declarado

- Ventana de consistencia eventual: de unos segundos (intervalo del worker).
- Si el worker está caído, la tarjeta del catálogo envejece; se ve con
  `SELECT count(*) FROM evento_producto WHERE procesado_en IS NULL` y se puede
  conciliar contra Mongo.
