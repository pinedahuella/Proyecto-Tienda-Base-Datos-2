# Bug corregido: el descuento se quedaba pegado cuando una venta relámpago vencía sola

**Fecha:** 2026-09-24, encontrado al diseñar los workers de las reglas de
descuento automático (ClickHouse) y por período (calendario) -- ver
`elementos Generales/plan pendiente/reglas-descuento-periodos.md` y
`descuentos-oferta.md`. No es parte de esas dos reglas: es un bug real en
código ya existente desde el 2026-09-04.
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## El bug

`InventarioLimitadoService.revisarVencidas()` (el `@Interval` de cada
minuto que corrige `oferta.es_inventario_limitado` cuando una venta
relámpago vence sola por el TTL de Redis, sin pasar por un `DELETE
.../venta-limitada` manual) solo apagaba esa columna. `oferta.
porcentaje_descuento` no lo tocaba nadie más: `revertir()` tampoco lo hace,
y `OfertasVendedorService.quitarDescuento()` ni siquiera se puede llamar
mientras `es_inventario_limitado` sigue en `true` (responde 409, "cierra
la venta relámpago primero").

Resultado: una venta relámpago que vencía por su cuenta dejaba el
descuento activo **para siempre**, sin ninguna ruta para quitarlo salvo
tocar la base a mano -- ni un `DELETE` (ya estaba cerrada), ni el `DELETE
.../descuento` (bloqueado por el 409 de arriba, que revisaba
`es_inventario_limitado` como estaba en Postgres ANTES de que el worker la
apagara). El panel del vendedor no mostraba "en venta relámpago" (correcto)
pero tampoco mostraba el descuento como algo que alguien puso a propósito
-- era un estado sin dueño.

## El arreglo

La revisión ahora apaga `es_inventario_limitado` **y** `porcentaje_descuento`
en la misma sentencia, y al final de la corrida llama a
`ProductosService.recalcularCamposCalculados()` en lote para las ofertas
que tocó (los mismos campos que recalcula
`OfertasVendedorService.quitarDescuento()`: `hay_descuento`,
`precio_tienda`, `precio_desde` en Mongo).

**Se movió el método completo de `InventarioLimitadoService` a
`VentasLimitadasService`.** La versión corregida necesita `ProductosService`
para el recálculo de Mongo, y `ProductosService` ya inyecta
`InventarioLimitadoService` (para `estado()`, el `stock_disponible` de la
ficha) -- inyectar `ProductosService` de vuelta en `InventarioLimitadoService`
habría sido una dependencia circular. `VentasLimitadasService` ya inyectaba
`InventarioLimitadoService` y `RegistroOfertasRedisService`; solo hizo
falta sumarle `ProductosService` (sin ciclo: `ProductosService` no depende
de `VentasLimitadasService`).

## Qué se hizo

| Archivo | Qué cambió |
|---|---|
| `src/services/inventario-limitado/inventario-limitado.service.ts` | se quitó `revisarVencidas()`, sus dos campos privados, el import de `Interval` y el párrafo del doc de clase que lo mencionaba |
| `src/services/vendedores/ventas-limitadas.service.ts` | `revisarVencidas()` agregado aquí, extendido para apagar las dos columnas y recalcular Mongo; constructor gana `ProductosService` |
| `elementos Generales/endpoints/endpoints-vendedores.md` | actualizada la sección del worker (nueva ubicación, el bug, la prueba en vivo) y la mención en la sección del registro de Redis |

No se tocó ningún controlador, ruta ni esquema -- es una corrección interna
de un worker que ya existía.

## Probado en vivo -- 2026-09-24

Contra el servidor y las bases reales (`ventas_norte`, oferta 3):

| Caso | Resultado |
|---|---|
| Aplicar 20% de descuento, abrir venta relámpago con `duracion_segundos: 6` | 201 los dos; Postgres: `porcentaje_descuento: 20.00`, `es_inventario_limitado: true` |
| A los 6 s | las dos claves de Redis (`mesh:oferta:3`, `mesh:oferta:3:reservas`) ya no existen (`EXISTS` → `0`) |
| Al siguiente tick del worker (≤ 60 s) | log `"1 oferta(s) apagada(s) y su descuento quitado (vencieron solas)"`; Postgres: `porcentaje_descuento: NULL`, `es_inventario_limitado: false` |
| `precio`/`stock` de la oferta | sin tocar (`5840.00`/`24`) -- el bug y su arreglo nunca tocan estas dos columnas |
| `precio_historial` | fila nueva con `porcentaje_descuento: NULL`, el trigger disparó igual que con un `quitarDescuento()` manual |
| Mongo (`productos._id: 1`) | `hay_descuento` vuelve a `false`; `precio_tienda`/`precio_desde`/`stock_tienda` sin cambios |
| `npx tsc --noEmit` y `eslint` sobre el repo completo | limpios |

## Lo que queda sin resolver, encontrado en el camino (no es parte de este arreglo)

El `UPDATE` de este worker sigue disparando `oferta_registrar_precio()`,
que guarda la fila de `precio_historial` con `id_usuario_modifico` = el
dueño de la oferta (`NEW.id_usuario`, porque `current_setting('mesh.
id_usuario')` nunca lo setea el backend). Es decir, esta limpieza
automática queda atribuida al vendedor como si él la hubiera hecho a mano.
Es el mismo problema, ya existente, que un admin actuando como la tienda
tiene con esa misma columna (ver memoria `atribucion-usa-el-id-real`) --
no se corrigió aquí porque no era lo que se pidió esta ronda; queda
anotado para cuando se decida la atribución de las reglas de descuento
automático/período.
