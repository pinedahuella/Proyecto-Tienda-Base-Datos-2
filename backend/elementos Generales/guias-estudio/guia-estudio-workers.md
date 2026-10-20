# Guía de estudio: los workers del backend

> Todos los trabajos en segundo plano del backend (`@Interval` de
> `@nestjs/schedule`), separados por tipo. Estado al 2026-10-19: 30 workers.
> Las rutas son contra `backend/src/services/`.

## Cómo leer las tablas

- **Cada cuánto**: el `INTERVALO_MS` del worker. Ojo: el `@Interval` de Nest
  **no corre al arrancar**, la primera vez es cuando pasa el primer intervalo.
- **Al arrancar**: "Sí" si además corre una vez al levantar el backend
  (`onApplicationBootstrap()`), para no esperar el primer intervalo.
- **Disparo inmediato**: si el backend lo llama a mano, sin esperar el
  intervalo, cuando pasa algo concreto (una reseña, un login…). Siempre es
  sin `await`: no retrasa la respuesta, y si falla lo recoge el worker en su
  próxima corrida.
- **Tope por corrida**: cuánto procesa como máximo en una pasada; lo que
  sobra queda para la siguiente.

Reglas comunes a todos:

- Tienen una bandera (`procesando`): si la corrida anterior no terminó, la
  nueva se salta. Nunca se pisan dos corridas del mismo worker.
- **No hay ninguna ruta de admin para "correr el worker ahora".** Lo único
  manual son los disparos inmediatos de la tabla y los scripts del ETL (al
  final).
- Las colas (`evento_*`) las llenan triggers de PostgreSQL en la misma
  transacción del cambio; el worker solo las vacía.

---

## 1. Colas y sincronización (PostgreSQL / MongoDB → otra base)

| Worker | Archivo | Qué hace | Cada cuánto | Al arrancar | Disparo inmediato | Tope por corrida |
|---|---|---|---|---|---|---|
| `EventoProductoSyncService` | `productos/evento-producto-sync.service.ts` | Vacía `evento_producto` y recalcula en Mongo precio, stock, ofertas, descuento y nota del producto | 5 s | No | No | 200 (5 intentos por evento) |
| `EventoOfertaSyncService` | `vendedores/evento-oferta-sync.service.ts` | Vacía `evento_oferta` y mantiene el índice `mesh_ofertas` de Elasticsearch | 5 s | No | No | 500 (5 intentos) |
| `EventosAutenticacionSyncService` | `eventos-autenticacion/eventos-autenticacion-sync.service.ts` | Pasa los logins de Mongo (`pendiente_elastic`) al índice `mesh_eventos_autenticacion` | 5 s | No | Sí: `sincronizarAhora()` después de cada registro, login (bueno o fallido) y logout (`usuario.controller.ts`) | 500 |
| `BuscadorSyncService` | `buscador/buscador-sync.service.ts` | Pasa los productos de Mongo (`pendiente_busqueda`) al índice `mesh_productos` | 10 s | No | No | 200 |
| `VectoresSyncService` | `productos/vectores-sync.service.ts` | Calcula con Ollama el vector de los productos con `pendiente_vector` y lo guarda en `vector_producto` | 10 s | No | No | Todos los pendientes, en lotes de 32 |
| `EventoComentarioSyncService` | `resenas/evento-comentario-sync.service.ts` | Vacía `evento_comentario` y calcula con Ollama el vector de cada comentario en `vector_comentario` | 10 s | No | Sí: `procesarAhora()` al escribir una reseña (`chequeo-texto-inmediato.service.ts`) | 200 (lotes de 32, 5 intentos) |
| `ValoracionComentariosService` | `resenas/valoracion-comentarios.service.ts` | Pone `valoracion_texto` y `prob_mala` a cada reseña, desde su vector (sin Ollama) | 30 s | No | Sí: `valorarAhora()` al escribir una reseña, justo después del vector | 200 × 10 pasadas |
| `GrafoSyncService` | `grafo/grafo-sync.service.ts` | Vacía `evento_grafo` y proyecta las reseñas a Neo4j | 10 s | No | Sí: `procesarAhora()` al escribir una reseña (`resenas.service.ts`) | 500 (5 intentos) |
| `GrafoComprasSyncService` | `grafo/grafo-compras-sync.service.ts` | Lleva las compras de PostgreSQL a Neo4j (nodo `:Compra`) | 10 s | No | No | 500 (5 intentos) |

`GET /admin/grafo/conciliacion` no es un disparo: solo compara PostgreSQL
con Neo4j y dice si cuadran.

---

## 2. Vitrinas y recomendaciones (ClickHouse → Redis)

Calculan la consulta pesada una vez y dejan el resultado en Redis; las rutas
solo leen lo ya calculado.

| Worker | Archivo | Qué hace | Cada cuánto | Al arrancar | Disparo inmediato | Tope por corrida |
|---|---|---|---|---|---|---|
| `MasVendidosSyncService` | `productos/mas-vendidos-sync.service.ts` | Ranking de más vendidos | 10 min | Sí | No | — |
| `MasVistosSyncService` | `productos/mas-vistos-sync.service.ts` | Ranking de más vistos (sesiones distintas, 24 h o 7 días) | 10 min | No | No | — |
| `TambienVieronSyncService` | `productos/tambien-vieron-sync.service.ts` | "Quienes vieron esto también vieron" por producto | 15 min | No | No | — |
| `CombosSyncService` | `productos/combos-sync.service.ts` | Grupos de 2 y 3 productos que se compran en el mismo pedido (`mesh:productos:combos`) | 30 min | Sí | No | Pedidos de hasta 30 productos |

---

## 3. Detectores de fraude

| Worker | Archivo | Qué detecta | Fuente | Cada cuánto | Al arrancar | Disparo inmediato |
|---|---|---|---|---|---|---|
| `AnillosDetectorService` | `fraude/anillos-detector.service.ts` | Anillos de reseñas A.1 (ciclos) y A.2 (mismo producto) | Neo4j | 15 min | No | Sí: `detectarInmediato()` al escribir una reseña, después de proyectarla al grafo |
| `PatronesFraudeDetectorService` | `fraude/patrones-fraude-detector.service.ts` | Familia B: satélites, persistente, coordinados, reputación exprés | Neo4j | 15 min | No | Sí: `detectarInmediato()`, igual que el anterior |
| `ResenasRepetidasDetectorService` | `fraude/resenas-repetidas-detector.service.ts` | Una cuenta que repite el mismo texto | pgvector | 15 min | No | Sí: `revisarInmediato()` al escribir una reseña |
| `ResenasParecidasDetectorService` | `fraude/resenas-parecidas-detector.service.ts` | Reseñas casi iguales de otras cuentas sobre un vendedor o producto | pgvector | 15 min | No | Sí: `revisarInmediato()` al escribir una reseña |
| `AnilloDeTextoDetectorService` | `fraude/anillo-de-texto-detector.service.ts` | Varias cuentas con la misma plantilla de texto | pgvector | 15 min | No | Sí: `revisarInmediato()` al escribir una reseña |
| `NotasIncoherentesDetectorService` | `fraude/notas-incoherentes-detector.service.ts` | Nota que contradice el texto (cuenta, producto, vendedor) | pgvector | 15 min | No | Sí: `detectarInmediato()` al escribir una reseña |
| `ResenasCanceladasDetectorService` | `fraude/resenas-canceladas-detector.service.ts` | Reseñar y después cancelar esa misma compra | PostgreSQL | 15 min | No | Sí: `detectarInmediato()` al cancelar un pedido (`pedidos.service.ts`) |
| `FraudeLoginRetrospectivoService` | `fraude-login/fraude-login-retrospectivo.service.ts` | Ataques de login lentos o repartidos y granja de registros | Elasticsearch | 15 min | No | Sí: `evaluarInmediato()` después de cada registro, login y logout |
| `HallazgosEventoFraudeDetectorService` | `fraude/hallazgos-evento-fraude-detector.service.ts` | F1 vistas infladas, F2 compras en ráfaga, F3 IP multicuenta, F5 devoluciones seriales | ClickHouse | 24 h | No | No |
| `AgrupadorFraudeWorkerService` | `fraude/agrupador-fraude-worker.service.ts` | Junta todas las señales en casos de fraude (recalcula todo desde cero) | PostgreSQL | 15 min | Sí | No |

Los cuatro de pgvector se disparan juntos desde
`chequeo-texto-inmediato.service.ts`, después de calcular el vector y la
valoración de la reseña nueva.

Ojo con `HallazgosEventoFraudeDetectorService`: como no corre al arrancar,
la primera detección llega 24 h después de levantar el backend.

---

## 4. Ofertas, descuentos y ventas relámpago

| Worker | Archivo | Qué hace | Cada cuánto | Al arrancar | Disparo inmediato |
|---|---|---|---|---|---|
| `DisparadorReglasAutomaticoService` | `reglas-descuento-automatico/disparador-reglas-automatico.service.ts` | Activa el descuento de una oferta cuando sus ventas recientes (ClickHouse) llegan al umbral de la regla | 1 min | No | No |
| `DisparadorReglasPeriodoService` | `reglas-descuento-periodo/disparador-reglas-periodo.service.ts` | Prende o apaga el descuento según si hoy cae en el periodo de la regla | 15 min | Sí | No |
| `VentasLimitadasService.revisarVencidas()` | `vendedores/ventas-limitadas.service.ts` | Apaga las ventas relámpago y los descuentos que ya vencieron | 1 min | No | No |
| `RegistroOfertasSyncService` | `vendedores/registro-ofertas-sync.service.ts` | Red de seguridad: reconcilia los HASH de Redis de ofertas con descuento y con venta relámpago | 10 min | Sí | No (el camino normal es `RegistroOfertasRedisService.sincronizar()`, que se llama al aplicar o quitar un descuento y al abrir o cerrar una venta relámpago) |

---

## 5. Carrito e inventario

| Worker | Archivo | Qué hace | Cada cuánto | Al arrancar | Disparo inmediato | Tope por corrida |
|---|---|---|---|---|---|---|
| `ReservasVentaRelampagoSyncService` | `inventario-limitado/reservas-venta-relampago-sync.service.ts` | Vence las reservas de venta relámpago y vuelve a cuadrar Redis con PostgreSQL | 10 s | No | No | — |
| `CarritoBarridoService` | `carrito/carrito-barrido.service.ts` | Borra los carritos con más de 24 h sin actividad que nadie volvió a abrir | 10 min | No | No (al leer un carrito vencido, se borra en el acto) | 200 |

---

## 6. Fuera del backend: el ETL (solo manual)

No son workers: no corren solos. Los lanza `arrancar.ps1` al montar la base,
o una persona a mano. Viven en `etl/` (no es parte de `backend/`).

| Script | Qué carga |
|---|---|
| `etl/correr.sh` | El catálogo de PostgreSQL a MongoDB |
| `etl/cargar_busqueda.sh` | El índice de productos de Elasticsearch, desde el catálogo de Mongo |
| `etl/cargar_eventos.sh` | Los logs de login y registro de PostgreSQL a ClickHouse |
| `etl/cargar_compras.sh` | Las compras y devoluciones a ClickHouse (y borra los pedidos quitados) |
| `etl/cargar_grafo.sh` | La carga inicial del grafo de Neo4j |
| `etl/cargar_vectores.ps1` | La carga inicial de `vector_producto` |
