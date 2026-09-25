# Plan pendiente — Descuentos en ofertas

> **Estado (2026-09-23, noche): COMPLETO y probado de punta a punta.**
> Pedido del profesor, relayado por el usuario. **Esta es la segunda
> versión de este documento** — la primera guardaba el precio ya con
> descuento directo en `oferta.precio`; el usuario la rechazó
> explícitamente a favor de un diseño normalizado (ver "Por qué esta
> versión y no la anterior"). El esquema, el backend y la función SQL
> `comprar_pedido()` están construidos, aplicados en la base local y
> probados contra el servidor real — ver "Estado de implementación" al
> final.

## El problema

El profesor quiere que las ofertas puedan tener un descuento: un vendedor
le pone un % de descuento a su oferta, eso se ve reflejado al traer la
oferta (ficha, catálogo) y se cobra con descuento al pagar.

## Por qué esta versión y no la anterior

La primera versión de este plan proponía guardar el descuento **ya
aplicado** en `oferta.precio` (el precio de lista se sobrescribía con el
precio final, y una columna `precio_original` guardaba el de antes para
poder revertir). Era la opción de menor cambio de código — reutilizaba tal
cual el mecanismo de `precio_historial` sin tocar ninguna función SQL —
pero el usuario la rechazó explícitamente: quiere `precio` y el descuento
**normalizados**, cada uno su propia columna, sin que uno se sobreescriba
con el otro, y el precio final **calculado en cada consulta**, nunca
guardado — ni como columna normal ni como columna `GENERATED` de Postgres
(se ofreció esa alternativa intermedia y se descartó a propósito).

Es la decisión correcta de diseño relacional — `precio` (el precio de
lista) y `porcentaje_descuento` (si hay descuento y cuánto) son dos hechos
independientes, y guardar uno ya mezclado con el otro es exactamente el
tipo de dato derivado que un esquema normalizado evita. El costo real es
que la fórmula (`precio * (1 - descuento/100)`) se repite en cada consulta
que necesita el precio final, en vez de vivir calculada una sola vez — ver
la lista completa de esas consultas más abajo.

---

## Decisiones tomadas

### 1. Qué guarda cada tabla

- **`oferta.porcentaje_descuento`** (`numeric(5,2)`, nullable) — el
  descuento **vigente ahora mismo**. `NULL` = sin descuento.
  **`oferta.precio` no se toca nunca por esto** — sigue siendo el precio
  de lista, con o sin descuento activo.
- **`precio_historial.porcentaje_descuento`** (`numeric(5,2)`, nullable) —
  la misma idea, pero en el libro: cada fila de `precio_historial` ya es
  un snapshot de "así estaba la oferta en este instante" (ver
  `005_ofertas.sql`), así que también snapshotea el descuento vigente en
  ese instante. Sin esto, el historial olvidaría si una venta vieja tuvo
  descuento — justo el dato que explicaría por qué un pedido de marzo
  costó menos que el precio de catálogo de marzo.
- Las dos columnas son independientes entre sí — no hay ningún `CHECK` que
  las obligue a ir "juntas" con otra cosa. `NULL` simplemente quiere decir
  "sin descuento en ese momento".

### 2. El trigger ahora escucha las dos columnas

`trg_oferta_registrar_precio` (`005_ofertas.sql`) pasa de `AFTER INSERT OR
UPDATE OF precio` a `AFTER INSERT OR UPDATE OF precio, porcentaje_descuento`.
Si un vendedor solo cambia el descuento (sin tocar `precio`), eso tiene que
dejar fila nueva en el historial igual que un cambio de precio — es el
mismo tipo de hecho económico ("desde ahora esta oferta se ve/cobra
distinto"). Probado en la base local: `UPDATE oferta SET
porcentaje_descuento = 15 WHERE id_oferta = 3` (sin tocar `precio`) dejó
una fila nueva en `precio_historial` con `precio: 5840.00, porcentaje_descuento: 15.00`;
quitarlo dejó otra con `porcentaje_descuento: NULL`. `oferta.precio` no se
movió en ningún momento.

### 3. Cómo se aplica / se quita

Dos rutas nuevas, mismo patrón que `POST`/`DELETE
/vendedor/ofertas/:id/venta-limitada`:

- **`POST /vendedor/ofertas/:id/descuento`** — body `{ porcentaje_descuento }`.
  `UPDATE oferta SET porcentaje_descuento = $pct WHERE id_oferta = $id`.
  Nada más — no toca `precio`.
- **`DELETE /vendedor/ofertas/:id/descuento`** — `UPDATE oferta SET
  porcentaje_descuento = NULL WHERE id_oferta = $id`.
- Las dos terminan llamando `recalcularCamposCalculados([idProducto])`,
  igual que cualquier otra escritura sobre `oferta`.
- Aplicar un descuento sobre una oferta que **ya tiene uno** → 409 ("Esta
  oferta ya tiene un descuento activo") — hay que quitarlo primero antes
  de poner otro, no se reemplaza silenciosamente.
- `porcentaje_descuento`: número entre **1 y 90**, hasta 2 decimales
  (mismo estilo que `validarPrecioObligatorio`). 0 no es descuento; ≥100
  dejaría el precio final en 0 o negativo.
- **A diferencia de la primera versión de este plan, `PATCH
  /vendedor/ofertas/:id` con `precio` YA NO necesita ningún candado
  especial** — como `precio` nunca se toca por el descuento, editar el
  precio de lista y tener un descuento activo son cosas independientes que
  conviven sin conflicto. (Sí vale la pena decidir, cuando se construya,
  si el vendedor debería PODER cambiar el precio de lista mientras hay un
  descuento activo, o si eso debería avisar algo — es una decisión de
  producto, no una necesidad técnica como en la versión anterior.)

### 4. Vencimiento automático opcional (reversado el 2026-09-24)

Esta decisión se reversó: el usuario pidió agregar un `duracion_segundos`
opcional a `POST .../descuento`, puramente interno, calcado del mismo
mecanismo de TTL de Redis + worker que ya tenía `POST .../venta-limitada`
(no una `fecha_fin_descuento` en Postgres, como se planteaba acá
originalmente). Ver `elementos Generales/endpoints/endpoints-vendedores.md`,
sección "TTL opcional para el descuento manual puro", y
`cambio_propuestas/2026-09-24_2345-ttl-descuento-manual.md` para el
detalle completo.

### 5. El campo en Mongo — uno solo, simple

**`hay_descuento`** (`boolean`), a nivel de variante y de producto (`bool_or`
de las variantes) — igual que los otros 5 campos calculados. `true` si
cualquier oferta activa de esa variante tiene `porcentaje_descuento`
puesto, sin importar el vendedor (confirmado con el usuario: un solo
campo, sin separar tienda/otros). Se calcula en
`ProductosService.recalcularCamposCalculados()`, junto con
`precio_tienda`/`precio_desde`.

No se toca el buscador (Elasticsearch) — ver la primera versión de este
documento (en el historial de git) para el detalle de por qué; sigue
aplicando igual.

### 6. La fórmula se repite en cada consulta — la lista completa

El precio a cobrar/mostrar es siempre `ROUND(precio * (1 -
COALESCE(porcentaje_descuento,0)/100), 2)`. Nunca se guarda el resultado.
Estos son **todos** los lugares que hoy leen `precio` crudo y van a
necesitar aplicar esta fórmula (confirmado leyendo el código real):

1. **`ProductosService.obtenerOfertasReales()`** (`productos.service.ts:487`)
   — la ficha pública. Hoy `ORDER BY o.id_producto_variante_mongo, o.precio`,
   apoyado en el índice `idx_oferta_catalogo_precio`. Con descuento, el
   orden "la más barata primero" tiene que ser por el precio **con**
   descuento — una expresión, no la columna cruda, así que ese índice deja
   de servir para el `ORDER BY` (sigue sirviendo para el `WHERE`). No es
   grave con el tamaño de catálogo actual (decenas de productos), pero
   toca anotarlo.
2. **`ProductosService.recalcularCamposCalculados()`** (`productos.service.ts:573`)
   — `precio_tienda`/`precio_desde` que se copian a Mongo. Tienen que
   calcularse con la fórmula, no con `o.precio` crudo, si no la tarjeta
   del catálogo seguiría mostrando el precio sin descuento.
3. **`comprar_pedido()`** (SQL, `007_flujo_pedido.sql`) — **esta sí hay que
   tocarla**, es la única función SQL que cambia. Hoy: `v_total :=
   v_total + v_linea.precio * v_linea.cantidad` (leyendo `ph.precio` de
   `precio_historial`). Tiene que pasar a `v_total := v_total +
   ROUND(v_linea.precio * (1 - COALESCE(v_linea.porcentaje_descuento,0)/100), 2)
   * v_linea.cantidad`. `agregar_linea()` **no cambia** — sigue congelando
   el id de la fila de `precio_historial` tal cual, sin importar cuántas
   columnas tenga esa fila; es `comprar_pedido()` la que lee el precio de
   esa fila para totalizar.
4. **`admin-reportes.service.ts`** — las dos consultas que hacen `SUM(ph.precio
   * pp.cantidad)` (`reservaciones()` y `CONSULTA_PEDIDOS_POR_ESTADO`)
   tienen que aplicar la misma fórmula sobre `ph.precio`/`ph.porcentaje_descuento`.
5. **`CarritoService.consultarOfertas()`** (`carrito.service.ts`) — trae
   `precio` de `oferta`; tiene que traer también `porcentaje_descuento` y
   aplicar la fórmula tanto en `construirSnapshot()` (la foto que guarda
   Redis) como en `verCarritoEnVivo()` (el chequeo en vivo del checkout).

**Riesgo real de este diseño, para que quede escrito:** si el día de
mañana aparece un sexto lugar que lee `oferta.precio` y a alguien se le
olvida aplicar la fórmula ahí, ese lugar muestra/cobra el precio sin
descuento sin que nada avise — no hay ningún candado de la base que lo
impida, porque `precio` sigue siendo un valor válido y con sentido por sí
solo. Es el costo consciente de la normalización: se discutió con el
usuario la alternativa de centralizar la fórmula en una sola función SQL
(`precio_efectivo(oferta)`) para que estos 5 lugares la llamen en vez de
repetirla a mano, y quedó **sin decidir** — se puede retomar cuando se
construya el código si la repetición se siente riesgosa en la práctica.

### 7. Lo que NO cambia (confirmado leyendo el código, sigue aplicando igual que en la v1 de este plan)

- Inventario limitado (venta relámpago) — cero concepto de precio, sin
  interacción.
- La aprobación de ofertas — nunca toca `precio` ni `porcentaje_descuento`.
- El buscador (Elasticsearch) — solo espeja `precio_tienda`/`precio_desde`
  desde Mongo.

---

## Lo que necesita la migración (NO lo hacemos nosotros)

> **Aplicado en la base LOCAL el 2026-09-23** — ver `descuentos-oferta.sql`
> en este mismo folder. Idempotente, probado dos veces seguido sin
> diferencia, y probado en vivo que el trigger dispara con un cambio de
> solo `porcentaje_descuento`.

1. **`oferta`** — columna nueva `porcentaje_descuento numeric(5,2)`
   (nullable, sin default), con un `CHECK` de rango sano
   (`0 < porcentaje_descuento < 100` cuando no es `NULL`).
2. **`precio_historial`** — la misma columna nueva,
   `porcentaje_descuento numeric(5,2)` (nullable), mismo `CHECK` de rango.
3. **El trigger `oferta_registrar_precio()`** — hay que reemplazarlo (no
   es un `ALTER`, es un `CREATE OR REPLACE FUNCTION` + recrear el
   trigger) para que: (a) copie `NEW.porcentaje_descuento` al insertar en
   `precio_historial`, y (b) el trigger mismo pase a `AFTER INSERT OR
   UPDATE OF precio, porcentaje_descuento` (antes solo `OF precio`). Texto
   exacto en `descuentos-oferta.sql` de este folder — es un
   copiar-y-pegar, no hace falta rediseñarlo.
4. **`comprar_pedido()`** (`007_flujo_pedido.sql`) — única función que
   necesita un cambio real de lógica, no solo de columnas. Ver el punto 6
   de "Decisiones tomadas" arriba para la fórmula exacta. `agregar_linea()`
   no se toca.
5. **Mongo** — `hay_descuento: boolean` en la raíz de `productos` y en
   cada variante. No hace falta tocar `etl/extraer_busqueda.js` ni
   `mongo/001_productos.js` para esto (no se toca el buscador). El
   generador de datos (`migrations/datos/generador.js`) puede sembrar
   algunos descuentos de ejemplo si se quiere que la demo no salga vacía,
   no es obligatorio.
6. **Índice**: `idx_oferta_catalogo_precio` deja de servir para el
   `ORDER BY` de la ficha (punto 6.1 arriba) — no hace falta un índice
   nuevo todavía (el catálogo es chico), pero si el profesor pide explicar
   el plan de consulta de esa ruta, vale la pena mencionarlo.

Notas para quien haga la migración:

- No hace falta ninguna columna nueva en `pedido_producto` ni en
  `precio_historial` más allá de la de arriba — `agregar_linea()` sigue
  funcionando exactamente igual, solo la fila que congela ahora tiene una
  columna más.

---

## Lo que se hace en el backend (esto sí es nuestro — todavía sin construir)

### Cambios en archivos existentes

1. **`helpers/validaciones-oferta.ts`** — nueva `validarPorcentajeDescuento(valor)`:
   número entre 1 y 90, hasta 2 decimales.
2. **`services/productos/productos.service.ts`**:
   - `obtenerOfertasReales()` — traer `porcentaje_descuento`, calcular el
     precio final en la consulta (o en JS al armar `OfertaVendedor`), y
     ordenar por ese precio final.
   - `recalcularCamposCalculados()`/`recalcularUnProducto()` — aplicar la
     fórmula al calcular `precio_tienda`/`precio_desde`; agregar
     `bool_or(...)` para `hay_descuento` (raíz + por variante).
3. **`services/carrito/carrito.service.ts`** — `consultarOfertas()` trae
   `porcentaje_descuento`; `construirSnapshot()` y `verCarritoEnVivo()`
   aplican la fórmula al armar `precio`.
4. **`services/admin/admin-reportes.service.ts`** — las dos consultas con
   `ph.precio * pp.cantidad` pasan a usar la fórmula con
   `ph.porcentaje_descuento`.
5. **`models/oferta.ts`** — `porcentaje_descuento: string | null` en
   `OfertaVendedor`, `OfertaPropiaResumen`, `FilaOfertaPropia`. Decidir si
   estos modelos también exponen el `precio_final` ya calculado (para que
   el frontend no tenga que repetir la fórmula) — probablemente sí, mismo
   espíritu que `subtotal` en el carrito.
6. **`models/producto.ts`** (Mongo) — `hay_descuento: boolean` en la raíz
   y en cada variante.

### Archivos nuevos

7. **`dto/aplicar-descuento.ts`** — `{ porcentaje_descuento: number }`.
8. **`POST /vendedor/ofertas/:id/descuento`** y **`DELETE
   /vendedor/ofertas/:id/descuento`** — en
   `controllers|services/vendedores/ofertas.controller.ts`/`ofertas.service.ts`.
   Mismo chequeo de dueño que el resto de `/vendedor/ofertas/:id/*` (404
   genérico si es ajena). Cada una termina en
   `recalcularCamposCalculados([idProducto])`.

---

## Documentación que hay que actualizar (dentro de `backend/`)

- **`endpoints-vendedores.md`** — las dos rutas nuevas (mismo formato que
  la sección de venta relámpago).
- **`endpoints-productos.md`** — el campo `hay_descuento` en la respuesta
  de `GET /productos`, `GET /productos/:id` y `GET /productos/mas-vendidos`.

Fuera de `backend/`: `docs/base-de-datos.md` (las columnas nuevas de
`oferta`/`precio_historial`, el cambio en `comprar_pedido()`, el campo
nuevo de Mongo) y el frontend.

---

## Estado de implementación

### Hecho y probado (2026-09-23, noche)

**Esquema** (`descuentos-oferta.sql` de este folder, aplicado y verificado
en la base local, idempotente):
- `oferta.porcentaje_descuento` y `precio_historial.porcentaje_descuento`
  (`numeric(5,2)`, nullable, `CHECK` de rango `0 < x < 100` en las dos).
- El trigger `oferta_registrar_precio()` reemplazado para disparar con
  `AFTER INSERT OR UPDATE OF precio, porcentaje_descuento` y copiar la
  nueva columna al historial.
- `comprar_pedido()` (SQL) reemplazada para cobrar
  `ROUND(precio * (1 - COALESCE(porcentaje_descuento,0)/100), 2) * cantidad`
  por línea, en vez del `precio` crudo. `agregar_linea()` **no** se tocó.

**Backend** (los 8 puntos de "Lo que se hace en el backend" de arriba, más
uno adicional encontrado durante las pruebas):
- `helpers/precio-descuento.ts` (nuevo) — `expresionPrecioFinal(alias)`,
  el fragmento SQL de la fórmula, reutilizado en las 6 consultas/archivos
  de abajo en vez de repetirse a mano.
- `helpers/validaciones-oferta.ts` — `validarPorcentajeDescuento` (1-90,
  hasta 2 decimales).
- `dto/aplicar-descuento.ts` (nuevo).
- `POST`/`DELETE /vendedor/ofertas/:id/descuento` —
  `OfertasVendedorController`/`OfertasVendedorService.aplicarDescuento()`/
  `quitarDescuento()`. Transacción + `SELECT ... FOR UPDATE`, mismo patrón
  que `revisar()`.
- `ProductosService.obtenerOfertasReales()` (ficha) y
  `recalcularCamposCalculados()` (campos de Mongo, + `hay_descuento`
  nuevo, `bool_or` por variante y por producto).
- `CarritoService.consultarOfertas()` / `construirSnapshot()` /
  `verCarritoEnVivo()` — la foto de Redis y el chequeo en vivo del
  checkout ya guardan/leen el precio final.
- `AdminReportesService` — `reservaciones()` y
  `CONSULTA_PEDIDOS_POR_ESTADO` aplican la fórmula sobre
  `precio_historial`. `pago.monto` no necesitó cambios: ya sale correcto
  porque lo escribe `comprar_pedido()`.
- **Encontrado durante las pruebas, fuera de la lista original — el flujo
  manual de pedido (`services/compradores/pedidos.service.ts`), que sigue
  vivo como API aunque el frontend ya no lo use (ver memoria
  `carrito-redis`)**: `listar()` (el total), `obtener()` (el
  `precio_unitario` de cada línea, + `porcentaje_descuento_aplicado`
  nuevo en `DetallePedido`), y `revisarCambiosAntesDeComprar()` (la
  comparación congelado-vs-actual, que sin este cambio hubiera comparado
  precios base en vez de finales). `models/oferta.ts` ganó
  `porcentaje_descuento`/`precio_final` en `OfertaVendedor`,
  `OfertaPropiaResumen`, `OfertaPendiente` y sus filas crudas;
  `models/producto.ts` ganó `hay_descuento` en `Producto` y
  `ProductoVariante`; `models/carrito.ts` ganó `porcentaje_descuento` en
  `CarritoLinea`.

**Probado contra el servidor y las bases reales** (oferta 3, Laptop Ambar
Campus 14, `ventas_norte`):

| Caso | Resultado |
|---|---|
| Aplicar 25% a una oferta de Q5840 | `precio` sigue en 5840.00, `porcentaje_descuento: "25.00"`, `precio_final: "4380.00"` |
| Aplicar un segundo descuento sobre la misma oferta | 409 "ya tiene un descuento activo" |
| `GET /productos/:id` (ficha) | la oferta sale a precio final, **ordenada por precio final** (con el descuento quedó primera de su variante, adelante de una oferta con precio de lista más barato) |
| `GET /productos` / `GET /productos/:id` | `hay_descuento: true` en la variante con el descuento y en la raíz; `false` en la otra variante |
| `PATCH /vendedor/ofertas/:id` con `precio` mientras el descuento está activo | funciona sin restricción (decisión explícita de esta versión); `precio_final` se recalcula sobre el precio nuevo |
| Agregar la oferta descontada al carrito | la foto de Redis guarda el precio **final** (Q4380 → luego Q4500 tras el `PATCH` de precio) |
| `POST /carrito/comprar` | cobra el precio final (`total: "9000.00"` = 4500×2); verificado contra `precio_historial` del pedido: `precio: 6000.00, porcentaje_descuento: 25.00`, `pago.monto: 9000.00` |
| `GET /comprador/pedidos/:id` (flujo manual, el hallazgo extra) | `precio_unitario: "4500.00"`, `porcentaje_descuento_aplicado: "25.00"` |
| `GET /comprador/pedidos` (listado) | `total: "9000.00"` |
| `GET /admin/reportes/ventas` | `pedidos_por_estado[comprado].monto` con la fórmula aplicada (217396.00), verificado contra el cálculo manual sin la fórmula (220396.00, discrepancia de 3000 = el descuento de esta prueba) |
| Quitar el descuento (`DELETE`) | `precio` vuelve exacto (sin arrastre de redondeo), `porcentaje_descuento: null`, `hay_descuento` vuelve a `false` tras recalcular |
| Quitar un descuento que no existe | 409 |
| `porcentaje_descuento` en `0`, `100`, `91`, `-5`, `15.505` (3 decimales), `"20"` (texto) | 400 en los seis casos |
| `90` exacto (límite inclusivo) | 201, aplica bien |
| Aplicar/quitar sobre oferta ajena | 404 genérico |
| Oferta inexistente / sin sesión | 404 / 401 |
| `npx tsc --noEmit` y `eslint` sobre los 14 archivos tocados | limpios |

**Teardown:** oferta 3 devuelta a `precio: 5840.00, stock: 24,
porcentaje_descuento: NULL`; Mongo resincronizado (`hay_descuento: false`,
`precio_tienda`/`precio_desde`/`stock_total` de vuelta a los valores
originales) con un `PATCH` real (no a mano) para que el recálculo pasara
por el código, no por una corrección manual. El pedido 33 (de la prueba de
checkout) queda como registro permanente, igual que en rondas anteriores.

**`reservaciones()` probado en vivo el 2026-09-25** (quedó pendiente de la
ronda original): pedido 34 (`compradora_norte`, oferta 31 con 20% de
descuento, cantidad 2) → `total: "14302.40"` (= 8939 × 0.8 × 2, correcto);
control negativo, pedido 35 (misma compradora, oferta 34 sin descuento,
cantidad 1) → `total: "5947.00"` exacto, sin ninguna deducción indebida.
El resumen agregado sumó bien los dos (`total: "20249.40"`). Teardown: se
quitaron las líneas de los dos pedidos (`DELETE .../detalles/:id`) y el
descuento de prueba; los pedidos 34/35 quedan como cascarones vacíos en la
base (mismo criterio aceptado que el pedido 33 de la ronda original -- un
pedido real no se puede borrar, `ON DELETE RESTRICT`).
