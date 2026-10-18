# Plan pendiente — Las compras en el grafo y "para ti" desde Neo4j

> **Estado (2026-10-16): HECHO en `backend/` y probado en local, con el backend
> corriendo. Falta lo de otros: la migración real (`grafo-compras.sql`, este
> folder), que el ETL del grafo cargue también las compras, y docs — ver "Lo que
> le toca a otros".** Sin la tabla `evento_grafo_compra` el worker queda inactivo
> (lo avisa una vez) y "para ti" devuelve `[]` para todos.

## Por qué

Repartir bien las responsabilidades: cada base resuelve lo que le toca. Neo4j
solo se usaba para el fraude de reseñas, y "para ti" (lo que compraron quienes
compraron lo mismo que tú) es justo la pregunta para la que existe un grafo: un
recorrido de dos saltos desde una cuenta. Hasta hoy "para ti" salía de
ClickHouse (las vistas de las sesiones), recalculado cada 15 minutos y guardado
en Redis.

| Antes | Ahora |
|---|---|
| El grafo solo tenía reseñas | También `(:Usuario)-[:HIZO]->(:Compra)-[:DE]->(:Producto)` y `(:Compra)-[:A_VENDEDOR]->(:Usuario)` |
| "Para ti": ClickHouse (vistas) → worker cada 15 min → Redis → ruta | "Para ti": Neo4j, en vivo, por compras, desde tus `max_productos` compras más recientes |
| — | Nueva: `GET /productos/:id/tambien-compraron` (al agregar al carrito), Neo4j en vivo |

ClickHouse se queda con lo que es suyo (más vistos, también vieron, vistos
recientemente, más vendidos).

## Decisiones

1. **La compra es un nodo, como la reseña:** un `:Compra` por línea de pedido
   (`id` = `id_pedido_producto`), con `id_pedido`, la variante (`id_variante`,
   `variante`), `cantidad`, `precio` y `fecha` como propiedades;
   `[:DE]` al `:Producto` y `[:A_VENDEDOR]` al vendedor real (el de la oferta
   del precio cobrado). La variante no es nodo: para recomendar se trabaja a
   nivel de producto. Así compra y reseña de una cuenta con un vendedor quedan
   en el mismo grafo (sirve también para fraude: reseñas sin compra, cuentas que
   se compran entre sí).
2. **Cuenta como compra un pedido `comprado`, `enviado` o `entregado`.**
   `pendiente` todavía no es compra; `cancelado` ya no (la relación se quita).
3. **La cola va por CUENTA** (`evento_grafo_compra.id_usuario`), no por pedido:
   el worker relee todas las compras de la cuenta y deja sus `:Compra` iguales a
   eso. Un pedido nuevo, uno cancelado o uno borrado a mano se resuelven igual,
   sin guardar "alta" o "baja". Una fila pendiente por cuenta.
4. **Mismo outbox y misma directiva del profesor que las reseñas:** el pedido
   commitea sin esperar a Neo4j, el worker (`GrafoComprasSyncService`, cada
   10 s) proyecta segundos después, y la conciliación compara las dos bases.
   Triggers en `pedido` (alta, baja, cambio de estado o de cuenta) y en
   `pedido_producto` (una línea que entra, sale o cambia).
5. **"Para ti" en vivo, sin caché** (decisión del usuario): la consulta de una
   cuenta tarda milisegundos, y así la recomendación cambia apenas el grafo
   recibe la compra. Se ordena por cuántas cuentas distintas llevan a cada
   producto; solo productos `activo` (filtro en Mongo, como las demás rutas
   públicas).
6. **Los nodos son los de las reseñas.** `:Usuario` con las mismas propiedades y
   `:Producto` con el mismo nombre (mismo relleno "solo en MongoDB"), para que
   un producto no cambie de nombre según quién lo proyecte.

## Lo que hace el backend

| Archivo | Qué hace |
|---|---|
| `services/grafo/grafo-compras-sync.service.ts` (nuevo) | El worker de `evento_grafo_compra` |
| `services/productos/para-ti.service.ts` | La consulta al grafo + el detalle de Mongo |
| `services/productos/para-ti-sync.service.ts` | **Borrado** (era el worker de ClickHouse) |
| `services/productos/tambien-compraron.service.ts` + `controllers/productos/tambien-compraron.controller.ts` (nuevos) | "Quienes compraron esto también compraron" |
| `helpers/recomendaciones-grafo.ts` (nuevo) | Lo común a las dos recomendaciones (enteros de Neo4j, filtro de activos en Mongo) |
| `services/grafo/grafo-sync.service.ts` | La conciliación compara también las compras y trae `cola_compras` |
| `helpers/manejar-error-grafo.ts` | `esFalloDeConexionGrafo`, ahora compartido por los dos workers |
| `models/grafo.ts`, `app.module.ts`, `controllers/productos/para-ti.controller.ts` | Lo de arriba |

La respuesta de `GET /productos/para-ti` cambia de campos (`compradores` y
`porque_compraste` en vez de `puntaje` y `porque_viste`), pero el frontend solo
usa `producto`, que sigue igual. Detalle y pruebas en `endpoints-productos.md`
y `cambio_propuestas/2026-10-16_2300-compras-en-el-grafo.md`.

## Lo que le toca a otros

- **Migración real** con `grafo-compras.sql`: la tabla, el índice, los
  triggers y la siembra del final (encola todas las cuentas con pedidos; con eso
  el worker llena el grafo solo).
- **`etl/cargar_grafo.sh` / `etl/extraer_grafo.sql`:** hoy no cargan compras.
  Después de un `--limpiar` las `:Compra` se pierden hasta que alguien vuelva a
  correr la siembra. Lo ideal es que el ETL las cargue igual que el worker (una
  relación por cuenta y producto, mismos estados), o que al terminar corra la
  siembra. La conciliación lo avisa si pasa.
- **`neo4j/001_esquema.cypher` y `neo4j/README.md`:** documentar la relación
  `:Compra` y su restricción (`CREATE CONSTRAINT compra_id IF NOT EXISTS FOR
  (k:Compra) REQUIRE k.id IS UNIQUE`; en local ya está creada).
- **`clickhouse/`:** la consulta R3 ya no la usa nadie.
- **Docs y sustentación:** `docs/` (ARQUITECTURA, base-de-datos), el reparto de
  responsabilidades por base y las preguntas de sustentación.
