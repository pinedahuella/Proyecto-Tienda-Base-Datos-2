# Persistencia de F1-F6 (hallazgos de fraude sobre eventos de ClickHouse)

**Estado (2026-09-25, noche): tablas + worker + rutas de admin construidos,
aplicados en local y probados en vivo contra ClickHouse/Postgres reales.
Faltan los consumidores (F1 a tendencias, F4 a venta relámpago, el
agrupador de casos) -- ver "Lo que sigue" al final.**

## De donde sale esto

`docs/fraude-entrega3/03-consultas-clickhouse.md` (el companero) propone
seis consultas de fraude sobre ClickHouse -- F1 vistas infladas, F2 compras
en rafaga, F3 varias cuentas comprando desde la misma IP, F4 carrito
acaparador, F5 devoluciones seriales, F6 granja de registros. Ninguna tenia
donde persistirse: `alerta_fraude` es solo de fraude de login,
`anillo_fraude` es solo de los patrones de Neo4j sobre resenas. Pedido
explicito del usuario: construir la persistencia, simple, reusando lo que
ya existe, sin construir todavia los detectores.

## Diseno: dos tablas, normalizado

**Version actualizada (2026-09-25, tarde): las cuentas involucradas se
normalizaron a una tabla de pivote, `hallazgo_evento_fraude_cuenta`, en vez
de ir en una lista dentro de `detalle` (jsonb) -- decision explicita del
usuario, al notar que `docs/fraude-entrega3/02-reglas-backend.md` ya
proponia exactamente ese patron (`hallazgo_fraude_cuenta`, con `es_nucleo`)
para su version grande, sin construir, del agrupador de casos. La primera
version de esta tabla (sin pivote, cuentas en jsonb) quedo reemplazada.**

**`estado_alerta_fraude` se reusa tal cual** (pendiente/revisada/
descartada) -- mismo criterio que ya aplico `anillo_fraude`: es un
catalogo generico de triage, sin logica propia de ningun dominio.

**Catalogo nuevo, `tipo_hallazgo_evento`** (no se reusa `tipo_alerta_fraude`):
login y eventos son fuentes de deteccion distintas, con su propio ciclo de
vida -- mezclarlas en un solo catalogo obligaria a que cualquier cambio de
uno afecte el codigo del otro sin necesidad.

| id | nombre | consulta | clave | cuentas (pivote) | id_producto_mongo | que va en `detalle` |
|----|--------|----------|-------|-------------------|--------------------|----------------------|
| 1 | `vistas_infladas` | F1 | id de producto (Mongo) | ninguna | el producto | `vistas`, `sesiones`, `vistas_por_sesion` |
| 2 | `compras_en_rafaga` | F2 | id de cuenta | esa cuenta (1 fila) | `NULL` | `pedidos`, `ventana_minutos` |
| 3 | `ip_multicuenta_compras` | F3 | la IP | todas las cuentas (N filas) | `NULL` | `total_cuentas` |
| 4 | `carrito_acaparador` | F4 | `"<id_usuario>-<id_producto_mongo>"` | esa cuenta (1 fila) | el producto | `unidades_carrito`, `unidades_compradas`, `veces` |
| 5 | `devoluciones_seriales` | F5 | id de cuenta | esa cuenta (1 fila) | `NULL` | `unidades_devueltas`, `unidades_compradas`, `tasa` |
| 6 | `granja_de_registros` | F6 | la IP | todas las cuentas (N filas) | `NULL` | `total_cuentas`, `ventana_minutos` |

**`hallazgo_evento_fraude_cuenta`** (`id_hallazgo_evento_fraude, id_usuario,
es_nucleo`, PK compuesta, `ON DELETE CASCADE` desde el hallazgo): una fila
por cada cuenta involucrada, sea uno o varios. `es_nucleo` nace siempre
`true` -- la distincion nucleo/periferia solo tiene sentido al AGRUPAR
varios hallazgos en un caso (seccion 2 de `02-reglas-backend.md`), que
sigue sin construirse; la columna ya existe para cuando llegue ese momento.
Index por `id_usuario` para poder preguntar "en que hallazgos participa
esta cuenta" directo por SQL, sin tocar jsonb.

**`id_producto_mongo` sin FK** -- mismo criterio que `oferta.id_producto_mongo`
(ver memoria `arquitectura-productos-mongo`): el producto vive en Mongo, no
en Postgres, asi que no hay contra que apuntar una FK real. No se
normaliza a su propia tabla de pivote: ningun hallazgo de F1-F6 involucra
mas de un producto a la vez, a diferencia de las cuentas.

**`clave` + `ventana_inicio` + `contador`, igual que `alerta_fraude`**: si
el mismo detector vuelve a encontrar el mismo hallazgo dentro de la misma
ventana, el `UPSERT` suma `contador` en vez de duplicar la fila (ver
`registrarHallazgoEventoFraude()` en el `.ts` de referencia). `ventana_inicio`
es libre para cada detector futuro -- unos truncan a la hora (F2, ventanas
de minutos), otros al dia (F1, F5, ventanas de dias) -- esta tabla no le
impone una granularidad fija, cada detector la define segun su propia
ventana.

**Nunca reabre un caso ya revisado/descartado** -- mismo criterio que
`registrarAlertaFraude`/`registrarAnilloFraude`: el `UPSERT` no toca
`id_estado_alerta_fraude` en el conflicto.

**F1 y F4 NO alimentan ningun agrupador de casos de fraude** (ver
`docs/fraude-entrega3/02-reglas-backend.md`, seccion 6: "F1 va al panel de
tendencias... F4 va a una cola de operaciones de venta relampago"). Esta
tabla los persiste igual que a los otros cuatro -- es la misma forma de
dato, solo que el CONSUMIDOR de cada tipo sera distinto cuando se
construyan los detectores. Esta ronda no construye ningun consumidor.

## Lo que se construyo esta ronda

- `hallazgos-evento-fraude.sql` (este folder): `tipo_hallazgo_evento` +
  `hallazgo_evento_fraude` + `hallazgo_evento_fraude_cuenta` (pivote),
  aplicado en local.
- `src/models/hallazgo-evento-fraude.ts`: los `ID_TIPO_HALLAZGO_EVENTO_*`,
  el tipo union `TipoHallazgoEvento`, `CuentaDeHallazgoEvento`, y la
  interfaz de API `HallazgoEventoFraude`.
- `src/helpers/registrar-hallazgo-evento-fraude.ts`: `registrarHallazgoEventoFraude()`,
  el UPSERT + la insercion transaccional en el pivote -- mismo molde que
  `registrarAlertaFraude`/`registrarAnilloFraude`.

**Probado en vivo (2026-09-25) contra la base local real**: dos llamadas
seguidas con la misma `clave`/`ventana_inicio` pero cuentas distintas (2
cuentas, despues 3) dejaron **una sola fila** en `hallazgo_evento_fraude`
(`contador: 2`, `detalle` refrescado) y exactamente 3 filas en el pivote
(sin duplicar las 2 cuentas que ya estaban) -- confirmado por `psql`. El
`ON DELETE CASCADE` del pivote tambien se confirmo: borrar el hallazgo
borro sus filas de cuenta solas.

## El worker (agregado 2026-09-25, noche)

`HallazgosEventoFraudeDetectorService`
(`src/services/fraude/hallazgos-evento-fraude-detector.service.ts`) corre
las seis consultas de `clickhouse/consultas/F1..F6.sql` **sin tocarles una
coma** (copiadas textuales, umbrales de `parametros.txt`) y llama a
`registrarHallazgoEventoFraude()` por cada fila. Cada consulta corre en su
propio try/catch -- un fallo en una no bloquea a las otras cinco.

**Corre una vez al dia** (`@Interval`, 24h), no cada 15 min como los demas
workers de fraude: F2 y F6 hacen un self-join sobre 30 dias completos de
datos (una consulta bastante mas pesada que un `GROUP BY` simple), y
`dias_ventana=30` es un corte diario, no de minutos -- correr esto mas
seguido no encontraria nada nuevo casi nunca. `ventana_inicio` es el inicio
del dia UTC en que corre: dos corridas del mismo dia (el `@Interval` y una
manual, por ejemplo) suman `contador` en la misma fila; al dia siguiente
nace una fila nueva.

**Probado en vivo (2026-09-25) contra ClickHouse y Postgres reales**: las
seis consultas corrieron limpias contra los datos reales de hoy (la
mayoria sin resultados -- hay muy pocos eventos reales todavia, mismo
hallazgo que ya habia medido el companero en su propio arnes). Para
confirmar el camino completo de punta a punta se sembraron 5 compras
sinteticas de una misma cuenta en 8 minutos (`compra_producto`, `lote:
'real'`) -- F2 las encontro (`pedidos_en_la_peor_rafaga: 5`), las persistio
en `hallazgo_evento_fraude` (una fila, `clave: "4"`, `detalle` con los
numeros correctos) y en `hallazgo_evento_fraude_cuenta` (la cuenta 4,
`es_nucleo: true`). Teardown: las 5 filas sinteticas de ClickHouse y la
fila resultante de Postgres se borraron, las dos tablas quedaron vacias.

## Las rutas de admin (agregadas 2026-09-25, noche)

`AdminFraudeEventosController`/`HallazgosEventoFraudePersistidosService`
(`src/controllers/admin/admin-fraude-eventos.controller.ts` +
`src/services/fraude/hallazgos-evento-fraude-persistidos.service.ts`):
`GET`/`PATCH /admin/fraude/alertas-eventos`, mismo molde exacto que
`alertas-resenas` (paginado, filtros `estado`/`tipo`, marcar
revisado/descartado solo desde `pendiente`) -- la diferencia es que
`cuentas` sale de la tabla de pivote real
(`hallazgo_evento_fraude_cuenta`), no de un `UNION` derivado, y no hay ruta
de detalle (toda la evidencia ya vive en Postgres). Detalle completo,
con la tabla de pruebas en vivo, en
`elementos Generales/endpoints/endpoints-fraude.md`, seccion "Hallazgos de
fraude sobre eventos (F1-F6)".

## Tablas nuevas que necesita la migracion real

Tres tablas, las tres en `hallazgos-evento-fraude.sql` (este folder,
idempotente, ya aplicado en local -- la migracion real solo tiene que
copiar su contenido, sin el `ALTER ... DROP COLUMN` de migracion interna
que ese archivo trae para su propio historial):

1. **`tipo_hallazgo_evento`** -- catalogo, 6 filas fijas (`vistas_infladas`,
   `compras_en_rafaga`, `ip_multicuenta_compras`, `carrito_acaparador`,
   `devoluciones_seriales`, `granja_de_registros`).
2. **`hallazgo_evento_fraude`** -- la tabla principal. FK a
   `tipo_hallazgo_evento` y a `estado_alerta_fraude` (catalogo ya
   existente, no se crea de nuevo). Sin FK a productos (`id_producto_mongo`
   es un `bigint` suelto, el producto vive en Mongo).
3. **`hallazgo_evento_fraude_cuenta`** -- pivote, FK a `hallazgo_evento_fraude`
   (`ON DELETE CASCADE`) y a `usuarios` (`ON DELETE RESTRICT`).

Ninguna de las tres depende de una migracion posterior a la ultima real
existente salvo por el orden -- van despues de esa, como todas las de este
`plan pendiente/`.

## Lo que sigue (fuera de esta ronda)

- **Los consumidores**: F1 hacia el panel de tendencias (marcar un producto
  "en ascenso" como inflado), F4 hacia la cola de venta relampago, F2/F3/F5/F6
  hacia el futuro agrupador de casos de `02-reglas-backend.md` (que tampoco
  esta construido).
- **Le toca al companero (fuera de `backend/`)**: la migracion real
  (siguiente numero despues de la ultima migracion existente), integrada en
  `migrations/README.md` -- mismo workflow de siempre. Las tres tablas que
  necesita estan arriba.
