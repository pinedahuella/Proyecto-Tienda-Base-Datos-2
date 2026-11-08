# La tienda gestiona pedidos, resenas, ofertas y categorias, y la carrera de las banderas

2026-11-07, noche. Para Jose David: lo que cambio en `backend/` y por que. Todo
probado contra las bases de tu PC, con las migraciones 051 a 054 ya aplicadas
alla (respaldo previo `respaldos/david_antes_noche_20261107_2004.dump`).

## Lo que pidio Meme

Que el admin pueda cancelar cualquier pedido y marcarlo enviado o entregado, que
un producto retirado no se venda aunque este en un carrito, que el admin pause o
retire ofertas ajenas y les ajuste las unidades, ocultar una resena sin borrarla
y crear categorias, renombrarlas y agregarles caracteristicas.

## Rutas nuevas, las diez del admin

| Controller nuevo | Rutas | Permiso nuevo |
|---|---|---|
| `controllers/admin/admin-pedidos.controller.ts` | `POST /admin/pedidos/:id/cancelar`, `/enviado`, `/entregado` | `pedidos.administrar` (051) |
| `controllers/admin/admin-resenas.controller.ts` | `PATCH /admin/resenas/:id` | `resenas.moderar` (052) |
| `controllers/admin/admin-ofertas.controller.ts` | `GET /admin/ofertas?producto=`, `PATCH /admin/ofertas/:id` | `ofertas.administrar` (053) |
| `controllers/admin/admin-categorias.controller.ts` | `GET`, `POST /admin/categorias`, `PATCH /admin/categorias/:id`, `POST /admin/categorias/:id/caracteristicas` | `catalogo.categorias` (054) |

Los cuatro codigos estan en `models/permiso.ts` y los cuatro controllers en
`app.module.ts`, mas `AdminCategoriasService` en los providers.

## Servicios que cambiaron

- `compradores/pedidos.service.ts`. `cancelarPedido()` y el nuevo
  `cancelarComoTienda()` pasan por `ejecutarCancelacion()`, que llama a
  `cancelar_pedido_por()` (051) y no a la `cancelar_pedido()` de la 007, que
  sigue en la base sin uso. Si cancela la tienda NO corre
  `resenasCanceladasDetectorService.detectarInmediato()`. `registrarDevolucion()`
  va siempre, a nombre del comprador y con `porLaTienda` (ver abajo, la columna
  de ClickHouse). `marcarEnvio()` llama a `marcar_envio_pedido()`.
  `listar()` suma `cancelado_por_tienda`.
- `fraude/resenas-canceladas-detector.service.ts`. El JOIN a `pedido` exige
  `pe.id_usuario = sm.id_usuario_modifico`: solo cuenta lo que cancelo el mismo
  comprador. Las 228 devoluciones que habia eran todas asi, ninguna deteccion de
  antes cambio.
- `carrito/carrito.service.ts`. `consultarOfertas()` trae `pc.estado` y
  `evaluarDisponibilidad()` niega con `producto_no_disponible` (nuevo en
  `models/carrito.ts`) si el producto no esta `activo`. Pagar da 409.
- `resenas/resenas.service.ts`. `moderar()` llama a `moderar_resena()` (052). La
  lista de la ficha y responder solo ven las publicadas (`id_estado_resena = 1`).
  El chequeo de "ya reseno" sigue viendo todas, a proposito: la oculta no deja
  volver a resenar.
- `productos/productos.service.ts` (el promedio de Mongo), `buscador/intencion.service.ts`,
  `buscador/sugeridos.service.ts` y `dashboards/dashboard-general.service.ts`
  (nota del vendedor): solo las publicadas.
- `fraude/fraude-anillos-persistidos.service.ts`. El detalle del anillo suma
  `estado_en_tienda` de cada resena (`models/anillo-fraude.ts`).
- `dashboards/dashboard-general.service.ts`. El registro de pedidos suma
  `por_la_tienda` y `motivo` del ultimo cambio de estado.
- `vendedores/ofertas.service.ts`. `listarDeProducto()` y `administrar()`: lo
  de `editar()` sin exigir dueno y sin precio; el ajuste queda en el kardex a
  nombre del admin.
- `admin/admin-categorias.service.ts` (nuevo). PostgreSQL es el dueno de la
  paleta; cada cambio se copia a `categorias` de Mongo con la forma del ETL
  DENTRO de la transaccion, antes del COMMIT. Renombrar es un solo `updateMany`
  por `categoria.id_categoria` y marca `pendiente_busqueda` y `pendiente_vector`.

## La devolucion de la tienda en ClickHouse, con su marca

Primero no se mandaba la devolucion cuando cancelaba la tienda, para no culpar al
comprador en F5. Estaba mal por dos lados: mas vendidos, combos y tendencias sacan
de las ventas todo `id_pedido` de `devolucion_producto`, asi que el pedido seguia
contando como venta, y `etl/cargar_compras.sh` la copiaba despues desde
`stock_movimiento` a nombre del comprador, sin marca, y F5 lo culpaba igual.

Ahora `devolucion_producto` tiene `por_la_tienda UInt8 DEFAULT 0`
(`clickhouse/001_esquema.sql`, en ALTER, ya aplicado en tu ClickHouse). El backend
la manda siempre, con `id_usuario` = el comprador y la marca;
`hallazgos-evento-fraude-detector.service.ts` (F5) y el embudo de
`admin-tendencias-avanzadas.service.ts` cuentan solo `por_la_tienda = 0`, igual
que `clickhouse/consultas/F5_*.sql` y `T2_*.sql`. `etl/extraer_compras.sql` pone
la marca leyendo `pedido_cambio_estado` (va pegada a `lote` con un tabulador,
porque el mismo SELECT sirve a `compra_producto`), y `cargar_compras.sh` y
`arrancar.ps1` suman la columna al INSERT solo para devoluciones. La regla
R-CASI-3 (`reglas-casi-confirmado.service.ts`) exige ahora, como el detector de
resenas canceladas, que la devolucion la haya hecho el mismo comprador.

## La carrera de las banderas, en dos workers que ya existian

`buscador/buscador-sync.service.ts` y `productos/vectores-sync.service.ts`
leian los pendientes, los indexaban o les calculaban el vector y despues
bajaban la bandera a ciegas (`$unset`). Si alguien cambiaba el producto
mientras tanto y volvia a poner la bandera, esa bandera se borraba y el cambio
no llegaba nunca. Se vio al renombrar Fragancias ida y vuelta: 20 productos se
quedaron con el nombre de prueba en Elasticsearch. Ahora la bandera se baja con
`findOneAndUpdate(..., { returnDocument: 'before' })` y, si el documento de
antes ya no es lo que se proceso, la bandera vuelve a subir y va en la corrida
siguiente.

## El vaciado que revivia el carrito (ya existia, 08-11 de madrugada)

`carrito/carrito.service.ts`. Agregar escribe en Redis y `programarReplica()`
copia a PostgreSQL por debajo. Un `DELETE /carrito` que llegaba mientras esa
copia escribia leia la version de antes (null o la anterior), borraba la clave
y pedia vaciar PostgreSQL contra esa version. La copia terminaba, dejaba la
linea en PostgreSQL con la version nueva, `marcarSincronizado()` ya no tenia
clave donde anotarla, y el vaciado chocaba: "El carrito de Redis (version
ninguna) no coincide con el de PostgreSQL (version 1)". El siguiente GET
reconstruia Redis desde PostgreSQL y la linea volvia. Con un PUT y en seguida un
DELETE pasaba 12 de 12 veces, y asi `producto_inactivo.mjs` dejaba su linea en el
carrito de compradora.norte (el "producto olvidado" del GUION).

En `replicarUnaVez()`, despues de escribir: si hay un vaciado pendiente y la
version que anoto es la misma de la que partio esta copia, pasa a esperar la que
esta copia acaba de dejar. Si la version es otra, alguien mas toco PostgreSQL y
el choque se queda, que es lo correcto. Despues del cambio, 0 de 12. Prueba
nueva `pruebas/carrito_vaciar.mjs` (en `correr_todas.sh`).

## Como se prueba

`node pruebas/pedidos_tienda.mjs` (32), `resenas_moderar.mjs` (20),
`ofertas_tienda.mjs` (23), `categorias_tienda.mjs` (26), `producto_inactivo.mjs`
(13), `bash pruebas/permisos_rol.sh` (183, ahora 42 permisos) y
`node pruebas/permisos_cobertura.cjs` (146 rutas privadas). Todas en
`pruebas/correr_todas.sh`.
