# Plan: crear/editar productos y ofertas

Estado al 25 de agosto de 2026. Los puntos 1, 2 y 4 **ya están construidos
y probados**, ver `endpoints-vendedores.md`. Solo el punto 5 sigue siendo
plan, no código (el 3 quedó absorbido por el 2, ver nota abajo).

**El punto 2 no se implementó tal como está escrito abajo.** En vez de dos
rutas separadas (`PATCH /vendedor/ofertas/:id` para precio/estado, `POST
/vendedor/ofertas/:id/stock` aparte), se fusionó todo en un solo `PATCH
/vendedor/ofertas/:id` que admite `precio`, `estado` y `ajuste_stock`
(entero con signo) juntos o por separado. El punto 3 de abajo, tal como
está escrito, ya no aplica — lo que hacía (`reponer_stock` con
`'reposicion'`/`'ajuste'`) quedó cubierto por `ajuste_stock` del PATCH.

**Decisión pendiente de retomar, no descartada:** ~~se había discutido que
crear/editar una oferta pasara por una aprobación de la tienda~~ —
**resuelto — el backend está completo desde el 2026-08-28**, ver
`plan pendiente/aceptacion-de-ofertas.md`. Creación (`POST`), edición
(`PATCH`), la cola (`GET /vendedor/ofertas/pendientes`), el historial de
rechazos (`GET /vendedor/ofertas/:id/rechazos`) y la revisión
(`PATCH /vendedor/ofertas/:id/revision`) están construidos y probados (179
comprobaciones). Falta solo la migración real en `migrations/` (la lleva
el compañero — hay un `.sql` de referencia aplicado en local).

Contexto que ya existe y hay que reusar, no repensar:

- `models/producto.ts`, `models/oferta.ts`, `dto/producto-con-mis-ofertas.ts`
  ya tienen las formas que hacen falta.
- `ProductosService.recalcularCamposCalculados(idsProductoMongo)` ya
  recalcula `precio_tienda`/`precio_desde`/`stock_tienda`/`stock_total`/
  `total_ofertas` (raíz y por variante) contra Postgres y los deja en Mongo
  con `$set`. **Toda escritura de aquí abajo que cree, edite o borre una
  oferta tiene que terminar llamándola** con el/los `id_producto_mongo`
  afectados.
- `OfertasVendedorService` (`services/vendedores/ofertas.service.ts`) ya
  tiene el patrón de cruzar Postgres (qué es mío) con Mongo (cómo se
  llama) — las rutas nuevas de abajo van en el mismo servicio y el mismo
  controlador (`controllers/vendedores/ofertas.controller.ts`).
- Las funciones de Postgres a usar ya existen y no se tocan
  (`migrations/007_flujo_pedido.sql`): `reponer_stock`. La propia tabla
  `oferta` (`migrations/005_ofertas.sql`) hace el resto sola vía sus dos
  triggers: `trg_oferta_registrar_precio` (escribe `precio_historial` solo,
  en el INSERT y en cada UPDATE de precio) y `trg_oferta_tocar_fecha`
  (mantiene `fecha_actualizacion`).

---

## 1. `POST /vendedor/ofertas` — publicar una oferta

Cualquier vendedor (no solo tienda), sobre una variante que **ya existe**
en el catálogo.

```json
{ "id_producto": 5, "id_producto_variante": 9, "precio": "899.00", "stock_inicial": 10 }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `id_producto` | Sí | El `_id` de Mongo |
| `id_producto_variante` | Sí | Tiene que ser una variante de ese producto |
| `precio` | Sí | Mismo formato/regla que `validarPrecioObligatorio` ya existente en `helpers/validaciones-crear-producto.ts` (reusar, no duplicar) |
| `stock_inicial` | No (por defecto 0) | Entero ≥ 0 — mismo `validarStockInicial` que ya existe en `helpers/validaciones-inventario.ts` |

### Pasos

1. Validar formato de los cuatro campos.
2. Buscar el producto en Mongo (**sin** excluir `inactivo`/`borrador`, para
   dar el mismo mensaje útil "el producto existe pero no está publicado"
   en vez de un 404 genérico — decidir el mensaje exacto). Si no existe,
   404. Si la variante no está en `producto.variantes`, 404 con el mensaje
   ya usado en `PedidosCompradorService.agregarLinea`
   ("No existe una variante con ese id en este producto").
3. **Decisión pendiente:** ¿se puede publicar una oferta sobre un producto
   `inactivo`/`borrador`? Probablemente no debería (nadie más lo ve, y
   `agregar_linea`/`GET /productos/:id` públicos ya excluyen esos estados) —
   pero confirmarlo con el equipo antes de escribir la validación.
4. `INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario, precio, stock, id_estado_oferta) VALUES (..., ..., $idUsuario, $precio, 0, (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre='activa')) RETURNING id_oferta`.
   **Nace siempre con `stock = 0`**, nunca con `stock_inicial` directo:
   el kardex (`stock_movimiento`) tiene que explicar cada unidad, y
   `reponer_stock` es la única puerta que escribe ahí. Meter
   `stock_inicial` directo en el INSERT dejaría el saldo sin kardex que lo
   explique — el mismo problema que el conjunto de datos evita a mano en
   `generador.js`.
5. Si `stock_inicial > 0`, llamar
   `SELECT reponer_stock($idOferta, $stock_inicial, 'reposicion', $idUsuario)`
   justo después, con el `id_oferta` que acaba de nacer.
6. Capturar `23505` (viola el `UNIQUE (id_usuario, id_producto_mongo, id_producto_variante_mongo)`
   de `005_ofertas.sql`) → `ErrorConflicto`: "ya tenés una oferta sobre
   esta variante — para cambiarla usá `PATCH /vendedor/ofertas/:id`, no
   crees otra". El id de esa oferta existente conviene devolverlo en el
   mensaje o buscarlo aparte, para que el frontend pueda redirigir directo
   a editarla.
7. `await productosService.recalcularCamposCalculados([idProducto])`.
8. Responder con la oferta creada — reusar la forma de `OfertaPropia` o
   `OfertaPropiaResumen` de `models/oferta.ts`, la que calce mejor.

**201**, no 200 (Nest ya lo da por defecto en un `@Post` sin `@HttpCode`,
igual que el resto del proyecto).

---

## 2. `PATCH /vendedor/ofertas/:id` — editar precio y/o estado

Solo el dueño de la oferta. `:id` es `id_oferta`.

```json
{ "precio": "950.00", "estado": "pausada" }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `precio` | No | Si viene, mismo formato que al crear |
| `estado` | No | Uno de `activa`/`pausada`/`retirada` |

Al menos uno de los dos tiene que venir (mismo patrón que
`PATCH /vendedor/productos/:id`: "Debes enviar al menos un campo para
actualizar" si los dos faltan).

### Pasos

1. Buscar la oferta por `id_oferta`. Si no existe, o `id_usuario` no es el
   del token, **404 genérico** ("No existe una oferta con ese id") — mismo
   criterio de siempre, nunca 403.
2. Si viene `precio`: `UPDATE oferta SET precio = $1 WHERE id_oferta = $2`
   — el trigger escribe solo la fila nueva de `precio_historial`, no hay
   que tocarlo a mano.
3. Si viene `estado`: `UPDATE oferta SET id_estado_oferta = (SELECT ... WHERE estado_oferta_nombre = $1) WHERE id_oferta = $2`.
   **Decisión pendiente:** ¿se puede reactivar una oferta `retirada`? La
   base no lo prohíbe (no hay ninguna regla en `005_ofertas.sql` que lo
   impida), pero conviene decidirlo como equipo — "retirada" se pensó
   como estado final en la redacción del ER, aunque el esquema no lo
   fuerza.
4. `await productosService.recalcularCamposCalculados([idProducto])` —
   **siempre**, así solo haya cambiado el estado: pausar/retirar cambia
   `stock_tienda`/`stock_total`/`total_ofertas` aunque el precio no se
   haya tocado.
5. Responder con la oferta ya actualizada.

---

## 3. `POST /vendedor/ofertas/:id/stock` — reponer o ajustar stock

Reemplaza lo que iban a ser las rutas viejas de `/inventario`. Solo el
dueño de la oferta.

```json
{ "cantidad": 15, "motivo": "reposicion" }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `cantidad` | Sí | Entero > 0 (`validarCantidadMovimiento`, ya existe) |
| `motivo` | Sí | Solo `"reposicion"` (suma) o `"ajuste"` (resta) — `reponer_stock` rechaza `venta`/`devolucion` con `check_violation` si se manda cualquier otra cosa |

### Pasos

1. Verificar dueño (mismo 404 genérico de siempre).
2. `SELECT reponer_stock($idOferta, $cantidad, $motivo, $idUsuario)`.
   Captura de errores: `23514` (`check_violation`, motivo inválido o el
   ajuste dejaría el stock en negativo) → `ErrorConflicto` reusando el
   mensaje de Postgres tal cual (mismo patrón que
   `PedidosCompradorService`).
3. `await productosService.recalcularCamposCalculados([idProducto])`.
4. Responder con `{ id_oferta, stock }` (lo que ya devuelve
   `reponer_stock` en su jsonb).

---

## 4. Rediseñar `POST`/`PATCH /vendedor/productos` de verdad — HECHO

**Completado y probado en vivo el 25 de agosto de 2026.** Los cinco pasos
de abajo ya están aplicados tal como se habían planeado:

1. ~~Quitar `precio` de `VarianteCreacionPeticion`~~ — hecho, y
   `EditarProductoPeticion` la reusa, así que quedó limpio también ahí sin
   tocarla aparte.
2. ~~Quitar `validarPrecioObligatorio` del flujo de crear/editar
   producto~~ — hecho. El helper sigue vivo, lo reusa `POST
   /vendedor/ofertas`.
3. ~~Quitar `stock_inicial` y `crearInventariosIniciales`~~ — hecho, el
   método entero se borró y `InventarioVendedorService` salió del
   constructor de `ProductosVendedorService`.
4. La restricción de "solo tienda" (`exigirTienda`) — sin tocar, seguía
   funcionando; de paso se notó que la documentación (`endpoints-vendedores.md`)
   decía "cualquier vendedor" cuando el código siempre exigió tienda — ya
   se corrigió el texto.
5. Los cinco campos calculados (no cuatro) siguen naciendo en `null`/`0`
   al crear — confirmado.

Si el cliente manda `precio`/`stock_inicial` de todos modos (formato
viejo), se ignoran en silencio — no rechaza la petición, tampoco los
guarda. Probado: crear sin esos campos, crear mandándolos a propósito,
editar (agregar variante + cambiar nombre) y confirmar los eventos en
`productos_eventos`, reconstruir con `GET .../historial` después del
cambio, y el ciclo completo producto→oferta (crear producto sin precio,
activarlo, ofertarlo con `POST /vendedor/ofertas`, ver que los cinco
campos calculados se activan recién ahí).

**Bug encontrado de paso — corregido y probado el mismo 25 de agosto de
2026, en una sesión aparte inmediatamente después.** `construirVariantes`
reinicializaba `precio_tienda`/`precio_desde`/`stock_tienda`/`stock_total`/
`total_ofertas`, `fecha_creacion` y `estado` de **cada** variante que
viniera en el array de un PATCH, incluida una "conservada" por
`id_producto_variante` sin ningún cambio real — le borraba las ofertas
activas que tuviera, y de paso dejaba la raíz del producto con números que
ya no coincidían con sus propias variantes.

La corrección: cuando una variante se conserva (se encuentra por
`id_producto_variante` entre las que el producto ya tenía),
`construirVariantes` copia esos siete campos de la variante existente en
vez de reinicializarlos — solo una variante genuinamente nueva nace con
los valores por defecto (`activa`, hoy, `null`/`0`). `nombre_variante`,
`descripcion`, `imagenes` y las características siguen viniendo completas
de la petición, como siempre — esos sí los controla quien edita.

Probado contra la base real: producto con oferta activa + edición de
**otra** variante ya no le borra nada a la primera; agregar una variante
nueva junto a las existentes solo inicializa la nueva; editar de verdad
`nombre_variante`/`descripcion` de una variante con oferta cambia esos dos
campos y conserva los demás; una variante con `estado: "inactiva"`
(forzada a mano para la prueba, ninguna ruta la pone hoy) sobrevive varias
ediciones seguidas sin volver a `activa` sola; la reconstrucción de
`GET .../historial` se reprobó después del fix y sigue devolviendo el
estado correcto; el rechazo por id de variante ajena (400) sigue igual.
Documentado con el detalle completo en `endpoints-vendedores.md`, sección
`PATCH /vendedor/productos/:id`.

---

## 5. ~~Borrar lo que ya no existe: las rutas viejas de `/inventario`~~ — hecho

Borradas las cinco rutas:

- `GET /vendedor/productos/inventario`
- `GET /vendedor/productos/inventario/motivos-ajuste`
- `GET /vendedor/productos/:id/inventario`
- `POST /vendedor/productos/:id/inventario`
- `PATCH /vendedor/productos/:id/inventario`

Y sus archivos: `services/vendedores/inventario.service.ts`,
`dto/inventario-vendedor.ts`, `dto/ajustar-inventario-vendedor.ts`,
`models/motivo-movimiento.ts` (quedó huérfano al borrar los dos
anteriores), más las rutas correspondientes en
`controllers/vendedores/productos.controller.ts` y el registro de
`InventarioVendedorService` en `app.module.ts`.
`helpers/validaciones-inventario.ts` **no se borró**: sus cuatro
funciones (`validarIdProducto`, `validarIdProductoVariante`,
`validarStockInicial`, `validarCantidadMovimiento`) se siguen usando
desde `ofertas.service.ts` y `pedidos.service.ts`. `npx tsc --noEmit`
queda limpio. Documentación actualizada en `endpoints-vendedores.md`.

---

## Orden sugerido

1. `POST /vendedor/ofertas` (sin esto no hay nada que editar ni reponer).
2. `PATCH /vendedor/ofertas/:id`.
3. `POST /vendedor/ofertas/:id/stock`.
4. Limpiar `POST`/`PATCH /vendedor/productos` (punto 4) — puede ir en
   paralelo con 1–3, no depende de ellos.
5. Borrar las rutas de `/inventario` (punto 5) — al final, cuando 1–4 ya
   reemplazan todo lo que hacían.

Probar cada uno igual que los GET: contra la base real, con
`npx tsc --noEmit` limpio antes de dar por hecho nada, y con al menos un
caso de éxito y uno de cada error de negocio (409) por ruta.
