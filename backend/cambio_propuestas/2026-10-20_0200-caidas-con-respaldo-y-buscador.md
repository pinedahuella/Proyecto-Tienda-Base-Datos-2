# La tienda sigue con una base caida, el buscador filtra en la consulta y nunca sale vacio

**Fecha:** 2026-10-20 (madrugada). Meme dio permiso para tocar `backend/` y las
bases de la PC de José David para esto. Los tres puntos que pidió el profesor
(audios del 19-10): apagar una base y que la aplicación siga con las que quedan,
los filtros de Elasticsearch en la consulta y no después en los agregados, y que
una búsqueda sin sentido traiga al menos un producto.
**Commits:** 812172a, 099857c, 708e783, d9a1a96 y los de pruebas y documentos.
**Migración:** `048_buscador_respaldo.sql`, ya aplicada en la base de José David.
**Para ver qué hace cada base caída:** `docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md`.

## 1. Cortacircuitos en las seis bases (`helpers/cortacircuitos.ts`)

El molde de `conRespaldoDeMongo` de anoche, llevado a todas. Después de ver una
base caída, durante 15 s no se le pregunta y el que llama recibe el fallo al
instante; al pasar la pausa, la siguiente consulta vuelve a probar. Cada entrada
y salida deja una línea `[Cortacircuitos] X no responde (...)` / `X volvio`, y
`GET /db/cortacircuitos` (solo admin: el motivo trae hosts y puertos internos)
cuenta lo que vio de cada una.

Dónde va cada uno, sin cambiar nada del resto del backend:

| Base | Dónde | Límites nuevos |
|---|---|---|
| PostgreSQL | `pool.query` y `pool.connect` (la forma con callback pasa directo: la usa el pool por dentro) | `max` 20, `connectionTimeoutMillis` 10 s, `query_timeout` 120 s (solo una red para la conexión congelada). `consultaCorta()` con 3 s para la sesión |
| MongoDB | `cortacircuitosMongo`, el de `conRespaldoDeMongo` | `socketTimeoutMS` 20 s (antes 0, sin límite) |
| Redis | `redis.sendCommand` (por ahí pasa todo, también `multi` y scripts). Los comandos de conexión pasan siempre | `commandTimeout` 3 s (antes 10). Un comando vencido fuerza la reconexión, así el cliente deja de estar `ready` y `esRedisInalcanzable()` lo ve |
| Neo4j | `consultarGrafo` y `ejecutarGrafo` | 20 s por consulta (antes ninguno para una conexión ya abierta), 3 s las de la página (`LIMITE_CONSULTA_PAGINA_MS`) |
| ClickHouse | `query`, `insert`, `command`, `exec` por un `Proxy` del cliente | los 8 s de siempre |
| Elasticsearch | los métodos de arriba (`search`, `mget`, `bulk`...) por un `Proxy` | `maxRetries` 0 (con 1, avisaba a los 22 s), 3 s las búsquedas de la página (`OPCIONES_BUSQUEDA`) |

**Ojo, falso positivo encontrado y arreglado.** El cortacircuitos de
PostgreSQL se abre solo con `esCaidaDePostgres`, que es `esFalloDeConexion`
menos dos casos que dan 503 pero no son la base caída: esperar turno con el pool
lleno (pg-pool: "timeout exceeded when trying to connect") y una consulta que
pasa el `query_timeout`. En la batería de pruebas, con `query_timeout` en 30 s y
contándolo como caída, 60 logins a la vez se esperaron en la misma fila de
`senal_fraude`, uno pasó los 30 s y la tienda se quedó 15 s sin PostgreSQL con la
base sana. `consultaCorta` solo da la base por caída si el pool no tenía a nadie
esperando.

Por qué hacía falta: medido el 19-10 apagando bases en tu PC, cada sección de la
página que tocaba la base caída esperaba su límite entero (3 s Mongo, 8 s Neo4j y
ClickHouse, 10 s Redis, 22 s Elasticsearch, ~21 s una conexión nueva a
PostgreSQL), una y otra vez. Y con una base congelada (la red cortada: acepta y no
contesta) una conexión ya abierta de pg, Neo4j o Mongo esperaba para siempre.

## 2. Respaldo de cada base

- **Redis.** Los cuatro rankings (`mas-vendidos`, `mas-vistos`, `combos`,
  `tambien-vieron`): cada worker expone su cálculo (`calcular()`,
  `calcularUno()`) y el servicio de lectura lo usa en vivo si Redis no atiende,
  guardado 60 s (`Memoria`). El orden de los empates es el de `ZREVRANGE`
  (`ordenarComoRedis`). Las tarjetas las arma una sola función,
  `helpers/tarjetas-producto.ts` (antes la misma consulta a Mongo estaba
  copiada en tres workers), con respaldo de la copia en PostgreSQL. Las ofertas
  destacadas se arman desde `oferta` (`RegistroOfertasRedisService.desdePostgres`).
  Comparado: las 8 vitrinas iguales con y sin Redis.
- **Hallazgo arreglado.** La copia de las ofertas destacadas en Redis no se
  refrescaba con una compra (el stock cambia sin pasar por `ofertas.service.ts`):
  la oferta 520 decía 27 unidades en Redis y 26 en PostgreSQL. Ahora la refresca
  `EventoOfertaSyncService` con cada evento de `evento_oferta`, y la
  reconciliación de 10 minutos refresca también las que ya estaban.
- **PostgreSQL.** `SesionGuard` se cree al token firmado SOLO si PostgreSQL no
  contesta (un `ErrorConexion` que no es de Redis); si contesta que la cuenta está
  suspendida, corta como siempre. `/usuario/yo` sale de una copia del perfil en
  Redis (`helpers/perfil-sesion.ts`: lo público, sin la contraseña, vence con el
  token) que se escribe al iniciar sesión y en cada `/usuario/yo`. La ficha sale
  sin ofertas y con `ofertas_no_disponibles: true` en vez de 503. Iniciar sesión
  sin PostgreSQL NO se hace, a propósito.
- **Elasticsearch.** `helpers/buscador-respaldo.ts`: la búsqueda sobre la copia
  del catálogo con la regla de texto del índice (048: `mesh_normalizar` sin
  tildes y en minúsculas como `espanol_llano`, `mesh_coincide` con la tolerancia
  de `fuzziness: AUTO`, la palabra rara pesa más). La usan la facetada (con las
  facetas contadas igual), la simple, la del admin, la híbrida, la de intención y
  las sugerencias al escribir. Comparado: totales y facetas idénticos. Sin
  respaldo, a propósito: el buscador de ofertas del vendedor (la lista normal
  sigue) y crear un avisame (el percolator vive en Elasticsearch).
- **Neo4j.** `helpers/recomendaciones-respaldo.ts`: los dos Cypher de para ti y
  también compraron, en SQL sobre `pedido_producto` de pedidos comprados,
  enviados o entregados, que es exactamente lo que `GrafoComprasSyncService`
  lleva al grafo. Comparado: 8 de 8 iguales, con el mismo porqué.
- **MongoDB.** El de anoche, ahora sobre el cortacircuitos común.
- **ClickHouse.** Sin respaldo: las vistas solo viven ahí. Los rankings ya
  calculados siguen en Redis.

## 3. Las facetas filtran en la consulta (`services/buscador/facetado.service.ts`)

Los filtros elegidos van en el `filter` del `bool` junto con el de activo, y las
agregaciones van sueltas, sobre lo que quedó. Antes iban en `post_filter` y cada
faceta se envolvía con los filtros de las otras. La contra, aceptada: con una
categoría elegida las demás salen del panel. Los rangos y la lectura de lo
elegido viven en `helpers/facetas-buscador.ts`, compartidos con el respaldo.
`elastic/pruebas/facetas.py` cambió igual: 24 OK contra tu PC.

## 4. Una búsqueda sin resultados trae sugeridos (`services/buscador/sugeridos.service.ts`)

Con 0 resultados y sin filtros, la respuesta trae `sugeridos` aparte: los más
cercanos por vector (pgvector, sin umbral), o lo más vendido, o los más reseñados.
`total` sigue en 0 y así se registra en ClickHouse: el reporte de búsquedas sin
resultados no cambia. Ollama tiene 3 s para el vector (frío tarda ~8 s).

## Pruebas

- `pruebas/caidas.mjs` (nueva, en `correr_todas.sh`): cada base apagada y
  congelada, con el interruptor de `remoto/interruptor.cjs`. 46 OK, 0 FALLA en las
  dos formas contra tu PC.
- `tsc`, eslint y `svelte-check` limpios.
- `pruebas/correr_todas.sh` en modo remoto: ver `docs/TRASPASO.md`.
