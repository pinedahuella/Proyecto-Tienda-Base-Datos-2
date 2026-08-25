# Plan: crear/editar productos y ofertas

Estado al 25 de agosto de 2026. Los puntos 1 y 2 **ya están construidos y
probados**, ver `endpoints-vendedores.md`. Los puntos 3 a 5 siguen siendo
plan, no código.

**El punto 2 no se implementó tal como está escrito abajo.** En vez de dos
rutas separadas (`PATCH /vendedor/ofertas/:id` para precio/estado, `POST
/vendedor/ofertas/:id/stock` aparte), se fusionó todo en un solo `PATCH
/vendedor/ofertas/:id` que admite `precio`, `estado` y `ajuste_stock`
(entero con signo) juntos o por separado. El punto 3 de abajo, tal como
está escrito, ya no aplica — lo que hacía (`reponer_stock` con
`'reposicion'`/`'ajuste'`) quedó cubierto por `ajuste_stock` del PATCH.

**Decisión pendiente de retomar, no descartada:** se había discutido que
crear/editar una oferta pasara por una aprobación de la tienda (nace
`pausada`, la tienda la activa). El profesor dio una fecha límite nueva a
mitad de sesión y no alcanzó el tiempo para resolver el diseño completo
(qué marca "pendiente de aprobar" sin romperse con `reponer_stock`, quién
puede activar qué, etc. — quedó discutido pero sin cerrar). Se decidió
seguir con creación directa (nace `activa`, tal como estaba en este plan
desde el principio) para no perder tiempo, y retomar la aprobación después
como su propio cambio.

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

## 4. Rediseñar `POST`/`PATCH /vendedor/productos` de verdad

Hoy es un parche mínimo (ver la nota al inicio de
`services/vendedores/productos.service.ts`): sigue aceptando `precio` y
`stock_inicial` por variante y los tira a la basura silenciosamente
(los guarda como `null`/`0` fijo). Hay que limpiarlo:

1. **Quitar `precio` de `VarianteCreacionPeticion`** (`dto/crear-producto.ts`)
   y de `EditarProductoPeticion` si aplica — ya no es un dato que se
   pida, el precio es de la oferta.
2. **Quitar `validarPrecioObligatorio` del flujo de crear/editar producto**
   (`services/vendedores/productos.service.ts`, función
   `construirVariantes`) — ese validador se **reusa** para el `precio` de
   `POST /vendedor/ofertas` (punto 1), no se borra el helper, solo se dejan
   de llamar desde aquí.
3. **Quitar `stock_inicial` y toda la lógica de
   `crearInventariosIniciales`** — ya no tiene sentido: crear un producto
   del catálogo no crea ninguna oferta, así que no hay nada a lo que
   ponerle stock todavía. Con esto se puede quitar también la dependencia
   de `InventarioVendedorService` en este archivo.
4. La restricción de "solo tienda" (`exigirTienda`) ya está — no tocar.
5. Los cuatro campos calculados siguen naciendo en `null`/`0` al crear
   (correcto: sin ofertas, no hay nada que calcular).

---

## 5. Borrar lo que ya no existe: las rutas viejas de `/inventario`

Confirmado que `inventario` ya no existe en Postgres (las rutas de
`InventarioVendedorService` están rotas en tiempo de ejecución, aunque
compilan). Al terminar los puntos 1–3 de arriba (que las reemplazan),
borrar:

- `GET /vendedor/productos/inventario`
- `GET /vendedor/productos/inventario/motivos-ajuste`
- `GET /vendedor/productos/:id/inventario`
- `POST /vendedor/productos/:id/inventario`
- `PATCH /vendedor/productos/:id/inventario`

Y sus archivos: `services/vendedores/inventario.service.ts`,
`dto/inventario-vendedor.ts`, `dto/ajustar-inventario-vendedor.ts`, más
las cuatro rutas correspondientes en
`controllers/vendedores/productos.controller.ts` y su registro en
`app.module.ts`. **`helpers/validaciones-inventario.ts` NO se borra
completo** — `validarCantidadMovimiento` y `validarStockInicial` se
siguen usando (pedidos, y el punto 1 y 3 de este plan); revisar cuál de
las funciones del archivo queda huérfana antes de tocarlo.

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
