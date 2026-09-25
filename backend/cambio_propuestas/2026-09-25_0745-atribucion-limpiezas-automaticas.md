# Atribución correcta en `precio_historial` cuando limpia el sistema, no el vendedor

**Fecha:** 2026-09-25, continuación directa de la sesión del disparador de
`regla_descuento_automatico`. Cierra la deuda de atribución anotada desde
`cambio_propuestas/2026-09-24_2200-bug-ttl-descuento-pegado.md` y
`2026-09-24_2345-ttl-descuento-manual.md`.
**Alcance:** `backend/`, sin migración ni esquema nuevo -- el mecanismo ya
existía en el SQL (`005_ofertas.sql`/`020_descuentos_oferta.sql`), el
backend nunca lo usaba.

## El problema

Cuando `VentasLimitadasService.revisarVencidas()` apaga sola una venta
relámpago o un descuento que venció por su TTL de Redis, la fila nueva que
deja en `precio_historial` quedaba atribuida (`id_usuario_modifico`) al
**dueño de la oferta** -- como si el vendedor hubiera quitado el descuento
él mismo, cuando en realidad fue el sistema.

## Por qué no hacía falta ninguna migración

`oferta_registrar_precio()` (el trigger que escribe `precio_historial`) ya
resolvía el actor así, desde que se escribió:

```sql
v_actor := COALESCE(
    NULLIF(current_setting('mesh.id_usuario', true), '')::bigint,
    NEW.id_usuario
);
```

Primero mira una variable de sesión (`mesh.id_usuario`); si el backend
nunca la puso, cae al dueño de la oferta. El backend, hasta hoy, nunca la
ponía (`grep` de `mesh.id_usuario`/`SET LOCAL` en `src/` no encontraba
nada) -- por eso siempre caía al dueño.

## Decisión: qué id representa "el sistema"

`precio_historial.id_usuario_modifico` es `bigint NOT NULL` -- no admite
`NULL` ni un valor especial "sistema". Como no existe ninguna cuenta
`sistema`/`bot` en `usuarios` (crear una sería una fila de datos, fuera de
`backend/`), se reusa una cuenta que YA existe: **`tienda@mesh.com`**, la
única cuenta que el proyecto ya trata como especial (blindada, sin
comportarse como un vendedor común). Decisión del usuario, tras explicarle
que no hay ninguna opción "gratis": cualquier id que se use tiene que ser
de una cuenta real ya existente.

## Cómo se hizo

`set_config('mesh.id_usuario', $1, true)` -- el equivalente parametrizado
de `SET LOCAL`, que sí acepta un placeholder (`SET LOCAL` a secas no).
`true` = local a la transacción, igual que `SET LOCAL`. Como
`set_config(..., true)` solo dura mientras dura la transacción que lo
puso, y los dos métodos hacían `pool.query('UPDATE ...')` suelto (sin
transacción), cada apagado por oferta pasó a ser una mini-transacción
(`BEGIN` → `set_config` → `UPDATE` → `COMMIT`), mismo patrón que
`aplicarDescuento()`. El id de la tienda se resuelve **una sola vez por
corrida**, y solo si de verdad hay algo que apagar (`idTienda ??= await
this.obtenerIdTienda()` dentro del `for`, no antes) -- una corrida sin
nada que hacer no gasta esa consulta extra.

**No hizo falta tocar los disparadores de reglas (período/automática):**
esos pasan el id REAL del vendedor a propósito ("opera como si el vendedor
lo hubiera hecho él mismo", decisión ya tomada y documentada) -- ahí la
atribución al vendedor es correcta, no un bug.

## Qué se hizo

| Archivo | Qué cambió |
|---|---|
| `src/services/vendedores/ventas-limitadas.service.ts` | `apagarVentaLimitadaVencida()` y `quitarDescuentoVencido()` nuevos (el `UPDATE` real, ahora en transacción con `set_config`); `revisarVentasLimitadasVencidas()`/`revisarDescuentosVencidos()` resuelven `idTienda` una vez y llaman al método nuevo en vez de `pool.query()` directo; `intentarRollback()` nuevo (mismo patrón que `OfertasVendedorService`); import de `PoolClient` agregado |

No se tocó ningún controlador, ruta ni esquema.

## Probado en vivo -- 2026-09-25

Contra el servidor y las bases reales (`ventas_norte` oferta 31,
`ventas_sur` oferta 34), con `INTERVALO_REVISION_VENCIDAS_MS` bajado a
5 s solo para la prueba (repuesto a 60000 después):

| Caso | Resultado |
|---|---|
| Descuento manual real de `ventas_norte` (id 4) sobre la oferta 31, con `duracion_segundos: 6` | fila de `precio_historial` con `id_usuario_modifico: 4` -- correcto, sí fue el vendedor |
| Al vencer el TTL, `revisarDescuentosVencidos()` lo quita solo | fila NUEVA de `precio_historial` con `id_usuario_modifico: 2` (`mesh_tienda`) -- antes hubiera sido `4` |
| Descuento manual real de `ventas_sur` (id 6) + venta relámpago (`duracion_segundos: 6`) sobre la oferta 34 | fila de `precio_historial` con `id_usuario_modifico: 6` -- correcto |
| Al vencer el TTL, `revisarVentasLimitadasVencidas()` la apaga sola | fila NUEVA con `id_usuario_modifico: 2` (`mesh_tienda`); `es_inventario_limitado` y `porcentaje_descuento` vueltos a su estado normal |
| `GET /productos/7` (público) tras las dos limpiezas | `hay_descuento: false` en la raíz y en las dos variantes -- Mongo recalculado igual que antes del cambio, sin regresión |
| Redis (`KEYS mesh:oferta:31*`/`34*`) tras las limpiezas | vacío en los dos casos -- sin claves residuales |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo, antes y después de reponer el intervalo | limpios los dos |

Teardown: las ofertas 31 y 34 quedaron sin descuento ni venta relámpago
activa. Nota aparte, sin relación con el código: un reinicio rápido de
`nest --watch` en Windows (dos ediciones seguidas del intervalo de prueba)
disparó una falla conocida de `@nestjs/cli` en Windows (`treeKillSync`
fallando al matar el proceso viejo, dejando el puerto 3000 ocupado) --
nada que ver con este cambio, se resolvió matando el proceso a mano.

## Lo que queda pendiente

Nada de esta pieza en particular. Con esto, las dos limpiezas automáticas
por TTL (venta relámpago y descuento manual vencidos) atribuyen
correctamente a la tienda, no al vendedor.
