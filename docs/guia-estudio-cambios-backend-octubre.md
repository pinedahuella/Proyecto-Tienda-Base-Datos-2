# Guía de estudio de los cambios del backend (1 al 18 de octubre)

> Para qué sirve este documento. Es la continuación de las tres guías de
> `backend/elementos Generales/guias-estudio/`, que llegan hasta el 30-09. Aquí
> está todo lo que cambió después, con **qué archivo, qué función y qué líneas**
> repasar para poder explicarlo en la sustentación. Las líneas son contra el
> estado del repo del 18-10 (commit `0b4c123`). Si alguien mueve código,
> confirmalo abriendo el archivo.
>
> Commits del backend que cubre: `fa3281c` (02-10), `3305cf3` y `1f1f480`
> (04-10), `f03636b` (08-10) y `25f0fe0` (17-10, el grande, 126 archivos). Cada
> cambio tiene su nota en `backend/cambio_propuestas/` y su plan en
> `backend/elementos Generales/plan pendiente/`. Esta guía no reemplaza esas
> notas, te dice cuáles leer y en qué orden.
>
> Rutas de archivo relativas a `backend/src/` salvo que se diga otra cosa.

---

## 0. Panorama. Qué hace cada base después de octubre

Tres pedidos del profesor movieron casi todo.

1. **Redis nunca es la fuente de verdad.** El carrito y las reservas de venta
   relámpago pasan a tener su verdad en PostgreSQL (§1).
2. **Las consultas por vectores van en pgvector.** Los vectores estuvieron en
   Elasticsearch del 02-10 al 16-10 y volvieron a PostgreSQL (§2).
3. **Más uso de Elasticsearch, el que le toca.** Buscador de ofertas y
   percolator ("avísame") (§4).

Y una decisión del equipo: **cada base resuelve lo que le toca**. Por eso "para
ti" se fue de ClickHouse a Neo4j y los combos se quedaron en ClickHouse (§5 y §6).

| Motor | Qué hacía el 30-09 | Qué hace ahora |
|---|---|---|
| **PostgreSQL** | Verdad de ofertas, pedidos, pagos, reseñas. Copia del catálogo para comprar sin Mongo (029) | Lo mismo, más la **verdad del carrito** (el pedido `pendiente`), las **reservas de venta relámpago**, los **vectores** (`vector_producto`, `vector_comentario` con pgvector) y cuatro colas nuevas (`evento_grafo_compra`, `evento_oferta`, `pedido_quitado`, más `evento_comentario` de la 034) |
| **MongoDB** | Catálogo, eventos del producto | Igual. Ya no está en la ruta de compra (desde el 30-09) |
| **Redis** | El carrito entero y las ventas relámpago | La **copia rápida** del carrito (se escribe y se lee ahí primero), el script atómico de la venta relámpago, y los JSON que dejan listos los workers (más vendidos, combos) |
| **Neo4j** | Reseñas, para detectar anillos | Reseñas **y compras** (`:Compra`). De ahí salen "para ti" y "también compraron" |
| **Elasticsearch** | Buscador de productos, log de autenticación | Lo mismo, más "quisiste decir", el **buscador de ofertas** (`mesh_ofertas`) y los **seguimientos** con percolator (`mesh_seguimientos`). La granja de registros se detecta aquí |
| **ClickHouse** | Eventos, tendencias, recomendaciones por vistas | Lo mismo, más **combos** y **búsquedas sin resultados** agrupadas por forma de escribir |

**Frase clave para la defensa.** *"PostgreSQL es la verdad de todo lo que
cuesta dinero, el carrito incluido. Redis es la copia rápida, y si se cae la
tienda sigue vendiendo, más lento. Cada base contesta la pregunta para la que
existe: los vecinos por significado en pgvector, los recorridos en Neo4j, los
conteos globales en ClickHouse y la búsqueda de texto y las consultas guardadas
en Elasticsearch."*

### Las migraciones que acompañan (carpeta `migrations/`, fuera del backend)

| Migración | Qué trae | Sección |
|---|---|---|
| 029, 030 | Catálogo copiado a PostgreSQL y cola `evento_producto` (30-09, ya en la guía multibase) | contexto |
| 034 | `evento_comentario`, la cola de comentarios | §2 |
| 035, 037, 038, 039 | Tipos de señal por texto, notas incoherentes, reseñas parecidas, reseñas canceladas | §7 |
| 036 | Quita la `producto_vector` vieja | §2 |
| **040** | `vector_producto` y `vector_comentario` con índice HNSW | §2 |
| **041** | `evento_grafo_compra` y sus triggers | §5 |
| **042** | Limpieza del fraude (evidencia única por caso y señal) | §7 |
| **043** | `evento_oferta` y sus cuatro triggers | §4 |
| **044** | `tipo_seguimiento_oferta`, `seguimiento_oferta`, `aviso_seguimiento_oferta` | §4 |
| **045** | Carrito en PostgreSQL. Un pendiente por cuenta, `version`, `fecha_ultima_actividad`, `reserva_venta_relampago` | §1 |
| **046** | `pedido_quitado`, para que el ETL borre de ClickHouse los pedidos que se quitan | §6 |

---

## 1. El carrito con la verdad en PostgreSQL (lo más importante)

Archivos. `services/carrito/carrito.service.ts` (1662 líneas, la orquestación),
`carrito-postgres.service.ts` (826, la verdad), `carrito-redis.service.ts` (423,
la copia), `carrito-barrido.service.ts` (111), y
`services/inventario-limitado/reservas-venta-relampago-sync.service.ts` (143).
Plan completo en `plan pendiente/carrito-postgres-verdad.md`. Leé la cabecera de
`carrito.service.ts:98-149`, es la clase entera en 50 líneas.

### 1.1 Las dos copias

- **Redis** `mesh:carrito:<id_usuario>`, un HASH. Cada campo `<id_oferta>` es una
  **foto** JSON de la línea (nombre, precio visto, `id_precio_historial`, imagen,
  `reserva_vence`). Además `t:<id_oferta>` guarda el ticket de una reserva
  relámpago, `_v` la versión de PostgreSQL que Redis conoce y `_d` la marca de
  desincronizado.
- **PostgreSQL** el pedido `pendiente` de la cuenta y sus líneas en
  `pedido_producto`. La 045 agrega `pedido.version`, `pedido.fecha_ultima_actividad`,
  el índice único `uq_pedido_pendiente_usuario` (un carrito por cuenta) y el
  `CHECK pedido_direccion_salvo_pendiente` (el pendiente no tiene dirección hasta
  pagar). Las reservas viven en su propia tabla, `reserva_venta_relampago`.

### 1.2 Escribir. Redis contesta, PostgreSQL se copia debajo

`PUT /carrito/lineas/:idOferta` entra por `definirCantidad()` (`carrito.service.ts:236`).

1. Lee la oferta en PostgreSQL una vez para armar la foto. Si no existe, **404**
   (antes se dejaba guardar).
2. `definirEnRedis()` (`:268`) guarda la línea en Redis y contesta.
3. `programarReplica()` (`:980`) lanza la copia a PostgreSQL **sin `await`**. Una
   sola copia a la vez por cuenta. Si llega otra escritura mientras corre, se
   marca `otraVez` y al terminar se copia de nuevo el estado de ese momento.
4. `replicarUnaVez()` (`:1015`) llama a `CarritoPostgresService.escribir()`
   (`carrito-postgres.service.ts:194`) con la versión que Redis conoce.
5. `escribirEnTransaccion()` (`:245`) hace todo en un `BEGIN ... COMMIT`.
   Vence el carrito si pasó las 24 h, compara versiones con `comprobarVersion()`
   (`:463`), aplica **solo las diferencias** (`aplicarLineas()` `:521`, no borra
   y recrea filas), aplica las reservas y sube `version = version + 1` (`:311`).
6. Si sale bien, Redis guarda la versión nueva y quita `_d`. Si choca la versión
   o PostgreSQL falla, Redis queda marcado como desincronizado.

> Para la defensa. Esto es **control de concurrencia optimista** con un número
> de versión. Redis dice "yo conozco la versión 7", y si PostgreSQL tiene la 8
> es que hubo un cambio que Redis no vio, así que no se pisa nada. Si dos
> escrituras crean el carrito a la vez, la segunda choca con el índice único
> (`23505`) y se reintenta una vez (`carrito-postgres.service.ts:202-237`).

### 1.3 Leer

`verCarrito()` (`:196`). Lo normal es Redis puro (`pintarDesdeRedis()` `:1191`).
Si Redis no tiene la clave (venció, se reinició), `calentar()` (`:1114`) la
reconstruye desde PostgreSQL con el TTL que le queda según PostgreSQL. Si Redis no
responde, `verDesdePostgres()` (`:1230`) contesta con `fuente: "postgres"`. El
precio que se muestra es el que la persona vio al agregar, no el de hoy.

### 1.4 Redis caído

`esRedisInalcanzable()` (`helpers/manejar-error-redis.ts`) dice si el cliente no
está `ready`, así ni se intenta. Todo va directo a PostgreSQL con
`definirEnPostgres()` (`:352`) y la cuenta queda en el `Set` `afectados` (`:158`).
Cuando Redis vuelve, `prepararRedis()` (`:1091`) reconstruye ese carrito desde
PostgreSQL antes de usarlo. Más lento, pero **la tienda sigue vendiendo**, también
en venta relámpago.

### 1.5 Desincronizado

`GET /carrito` devuelve `sincronizado: false`, el checkout contesta **409** y
`POST /carrito/sincronizar` (`sincronizar()` `:541`) decide. Con la misma versión
vuelve a copiar Redis a PostgreSQL (la escritura que faltó). Si PostgreSQL es más
nuevo o hay choque, Redis se reconstruye desde PostgreSQL.

### 1.6 Las 24 horas

Las decide PostgreSQL con `fecha_ultima_actividad`. Si no, el carrito nunca
vencería, porque Redis se reconstruiría desde PostgreSQL. Se renueva en cada
escritura y, como mucho cada 5 minutos, al mirar el carrito (`tocar()`
`carrito-postgres.service.ts:331`). Un carrito vencido se borra al leerlo
(`vencer()` `:354`, que pasa sus reservas a `vencida`) o lo borra
`CarritoBarridoService` cada 10 minutos si nadie lo lee. Vaciar el carrito borra
el pedido pendiente, un carrito vacío no existe en ninguna de las dos bases.

### 1.7 El checkout

`comprarCarrito()` (`:628`) envuelve todo en un candado corto de Redis contra el
doble clic (`conCandadoCheckout()` `carrito-redis.service.ts:385`). Si Redis no
está, el `FOR UPDATE` del pedido hace lo mismo. La compra está en
`ejecutarCompraCarrito()` (`:641`) y su comentario (`:602-627`) la cuenta en siete
pasos.

1. Espera la réplica en curso. Si Redis está y lo que dice no coincide con
   PostgreSQL (`coincide()` `:1443`), 409 y desincronizado. **PostgreSQL manda.**
2. Bloquea el pedido y las ofertas con `FOR UPDATE`, en orden de id para no caer
   en un interbloqueo. Vencido o vacío, 409.
3. Disponibilidad en vivo de cada línea.
4. Venta relámpago. Cada línea necesita una reserva viva de la misma cantidad. Si
   no la tiene intenta reservar ahí mismo (`:733-769`).
5. Precio. Si cambió desde que se agregó y no vino `confirmar_cambios`, devuelve
   `{comprado: false, avisos}` y hace `ROLLBACK` (`:782-798`).
6. `cambiar_direccion_pedido()` y `comprar_pedido()` de la migración 007
   (`:808-849`), y las reservas pasan a `confirmada` en **la misma transacción**
   (`:851-868`). Ya no se usa `comprar_carrito()` de la 012.
7. Después del `COMMIT`, `despuesDeComprar()` (`:924`) confirma los tickets en
   Redis y borra el carrito, y `registrarCompra` manda el evento a ClickHouse
   sin `await`. Nada de esto deshace la compra si falla.

### 1.8 La venta relámpago

- Redis sigue siendo **la puerta rápida**. El script atómico `redimensionar` de
  `redis/inventario_limitado.lua` decide primero, sin candados, y rechaza en el
  acto a quien llega tarde (409 en `definirEnRedis()` `:310`).
- La reserva de verdad es una fila de `reserva_venta_relampago`. La única
  comprobación de capacidad en PostgreSQL es `reservarSiHayUnidades()`
  (`carrito-postgres.service.ts:745`), que usa `unidadesLibres()` (`:808`).
  Leela, es una línea de SQL. Stock menos lo que tienen reservado las **otras**
  cuentas (`IS DISTINCT FROM` el pedido propio), activas y sin vencer.
- Si la venta está vigente lo dice PostgreSQL (`venta_vigente`), no el `EXISTS` de
  Redis. Si Redis perdió la venta, `InventarioLimitadoService.restaurar()`
  (`inventario-limitado.service.ts:377`) la reconstruye desde PostgreSQL con el
  stock libre, cada reserva con su ticket y el contador desde el ticket más alto.
- `ReservasVentaRelampagoSyncService` (cada 10 s) restaura al arrancar, cuando
  Redis vuelve, cuando falta una venta vigente o hay reservas sin ticket, y pasa a
  `vencida` las reservas que vencieron.
- Dos bugs reales que salieron en las pruebas de David. El `redimensionar`
  provisional no comprobaba que la venta existiera. Y al reabrir una venta el
  contador de tickets volvía a 0, así que un ticket viejo podía ser el de otra
  persona. Abrir ahora usa `restaurar` y el contador sigue desde el más alto.

### 1.9 Lo que se quitó

Seis rutas de `/comprador/pedidos` que armaban un pedido a mano (crear, agregar,
restar y quitar líneas, cambiar dirección, comprar) y sus cuatro DTO. Pasaban por
encima del carrito y ninguna pantalla las usaba. Ahora dan 404. El controlador
quedó con `GET /`, `GET /metodos-pago`, `GET /:id` y `POST /:id/cancelar`
(`controllers/compradores/pedidos.controller.ts`, 92 líneas). El pedido
pendiente no se lista ni se ve por id, porque es el carrito.

### Límites que conviene saber decir

- `SesionGuard` consulta PostgreSQL en cada petición. Con PostgreSQL caído toda
  ruta con sesión da 503, el carrito también. Ya era así.
- `afectados` vive en memoria. Si el backend se reinicia con Redis caído, al
  volver Redis puede mostrar un carrito viejo hasta la siguiente escritura. El
  checkout lo detecta por la versión, **nunca se compra lo que no es verdad**.

---

## 2. Los vectores en pgvector

Archivos. `helpers/vectores-pgvector.ts` (97 líneas, léelo entero),
`services/productos/vectores-sync.service.ts`, `services/resenas/evento-comentario-sync.service.ts`,
`services/resenas/valoracion-comentarios.service.ts`. Nota
`cambio_propuestas/2026-10-16_2100-vectores-a-pgvector.md` y plan
`plan pendiente/vectores-pgvector.md` (las 10 decisiones están ahí).

### 2.1 La historia, porque te la pueden preguntar

El 02-10 los vectores se **movieron** a Elasticsearch (`dense_vector`, kNN) para
darle más uso a ese motor y poder hacer búsqueda híbrida en una consulta. El 16-10
el profesor pidió que las consultas por vectores se hicieran con pgvector y
volvieron. Las reglas de cada búsqueda y cada señal no cambiaron, solo dónde viven
los vectores.

Lo que se midió al volver (con 1103 productos). pgvector coincidió con el coseno
exacto en 1000 de 1001 casos, el otro era un empate a 4e-8. Elasticsearch
coincidía en 317, porque su índice `int8_hnsw` cuantiza los vectores y se
equivoca hasta 0,016. Es un buen argumento a favor de pgvector.

### 2.2 Las tablas (migración 040)

- `vector_producto` (`id_producto_mongo` con FK a `producto_catalogo`). `vector`,
  `texto_hash`, `grupo` (las copias del generador que solo cambian el nombre),
  `activo`, `modelo`, `fecha_calculo`.
- `vector_comentario` (`id_comentario` con FK a `comentario`). `vector`,
  `texto_hash`, `modelo`, y la valoración del clasificador (`valoracion_texto`,
  `prob_mala`, `valoracion_modelo`).
- Las dos 1 a 1, con `ON DELETE CASCADE` y un índice **HNSW** con
  `vector_cosine_ops`.

Por qué tablas aparte y no una columna en `comentario`. Si el worker escribiera el
vector en la fila de `comentario`, el trigger de esa tabla lo volvería a encolar.
Además un vector pesa unos 3 KB y haría más pesada cada lectura de reseñas.

### 2.3 Las dos funciones que hay que saber explicar

**`buscarCercanos()`** (`vectores-pgvector.ts:41`). Corre un
`ORDER BY vector <=> $1 LIMIT k` dentro de una transacción en la que sube
`hnsw.ef_search` y activa `hnsw.iterative_scan = strict_order` con
`set_config(..., true)`, que solo vale para esa transacción y no ensucia la
conexión del pool. Con los valores por defecto el índice HNSW revisa 40
candidatos, lo que el `WHERE activo` descarta se pierde, y un `LIMIT 200` volvía
con 39 filas.

**`paresParecidos()`** (`:74`). Un self-join de `vector_comentario` que devuelve
los pares con coseno de 0,92 o más. Antes los detectores traían todos los
vectores a Node y comparaban todos contra todos. Ahora **los vectores no salen de
la base**.

Dos detalles que suenan bien en la defensa.

- `<=>` es la **distancia** coseno (0 a 2). El parecido es `1 - distancia`.
- El vector va como **parámetro** (`$1::vector`), nunca como subconsulta. Con
  `ORDER BY vector <=> (SELECT ...)` el planificador no usa el índice HNSW.
  Comentado en `services/productos/similares.service.ts:84-85`.

### 2.4 Quién usa los vectores

| Ruta o servicio | Archivo:línea | Qué hace |
|---|---|---|
| `GET /productos/:id/similares` | `services/productos/similares.service.ts:69` | Los 6 más cercanos, uno por `grupo`, sin el propio |
| `GET /buscador/productos/intencion` | `services/buscador/intencion.service.ts:188` y `:233` | Frase a vector con Ollama, vecinos en reseñas de 4+ estrellas y en productos, devuelve el `motivo` |
| `GET /buscador/productos/hibrida` | `services/buscador/hibrida.service.ts:177`, `:221`, `:308` | Palabras en Elasticsearch, significado en pgvector, se juntan por RRF |
| `POST /vendedor/productos/sugerencias` | `services/vendedores/sugerencias-propuesta.service.ts:113` | Categoría sugerida y posibles duplicados al proponer un producto |
| Detectores de texto | §7.1 | Pares con `paresParecidos()` |

### 2.5 Los workers que llenan los vectores

- `VectoresSyncService` cada **10 s** (antes cada 3 h), porque `activo` decide qué
  sale en las búsquedas. Solo llama a Ollama si cambió el md5 del texto.
- `EventoComentarioSyncService` cada 10 s vacía `evento_comentario`. Respuestas de
  menos de 15 caracteres no llevan vector.
- `ValoracionComentariosService` cada 30 s pone `valoracion_texto` a las reseñas
  raíz desde el vector ya guardado, sin Ollama. La regresión logística está en
  `helpers/valoracion-texto.ts` (`probabilidadMala()` `:98`) con los pesos de
  `backend/modelos/regresion_logistica.json`. Menos de 100 caracteres es `corta`.

---

## 3. Las búsquedas nuevas

### 3.1 "Quisiste decir" (Elasticsearch)

`helpers/correccion-busqueda.ts` (`pedirCorreccion()` `:40`, `textoCorregido()`
`:59`). Un *term suggester* sobre `nombre`, `suggest_mode: missing`, que viaja en
la **misma consulta** de la búsqueda (`services/buscador/productos.service.ts:111`).
Solo reemplaza las palabras mal escritas. Ojo, cambió la forma de la respuesta de
`GET /buscador/productos`, ahora es `{ resultados, quisiste_decir }`.

### 3.2 Búsqueda por intención

"Mi ventana está muy solitaria" encuentra la maceta cuya reseña dice "decora muy
bien la ventana", sin una sola palabra en común. Busca en las **reseñas** porque
hablan como alguien que lo usó y la descripción habla como vendedor. Umbrales 0,45
para reseñas y 0,40 para productos (`intencion.service.ts:30-31`). Sin Ollama, 503.

### 3.3 Búsqueda híbrida y RRF

`combinar()` (`hibrida.service.ts:308`). Cada búsqueda aporta
`1 / (60 + posición)` y se suma por producto. Se junta por **posición** y no por
puntaje, porque el puntaje de BM25 y el coseno no están en la misma escala. Dos
detalles. El `minimum_should_match: '2<70%'` (`:195`) evita que una frase traiga
todo lo que tenga "para" o "algo". Y si Ollama o PostgreSQL fallan contesta solo
con palabras, `modo: "solo_texto"`. La búsqueda principal no se cae por el
servicio de apoyo.

### 3.4 Búsquedas sin resultados (ClickHouse)

`GET /admin/eventos/busquedas-sin-resultados`,
`services/admin/admin-busquedas-sin-resultados.service.ts`.

- Columna nueva `busqueda_realizada.termino_normalizado`, **`MATERIALIZED`**
  (minúsculas, sin tildes, sin espacios de más). ClickHouse la calcula al
  insertar, el término original no se toca.
- Solo cuentan búsquedas sin filtros (`FILTRO_SIN_RESULTADOS` `:171`), porque con
  un filtro el cero puede ser culpa del filtro.
- Los errores de tecleo los junta `editDistanceUTF8` en un `CROSS JOIN` de los 300
  términos más buscados (`terminos()` `:110`). La distancia permitida depende del
  largo, 0 hasta 4 letras, 1 hasta 8 y 2 desde 9.
- `agruparPorTecleo()` (`:186`) une cada término al más buscado que tenga cerca,
  sin encadenar.

Se descartó Elasticsearch para esto. Su análisis une formas de escribir, no
agrupa términos entre sí, y contar eventos es trabajo de ClickHouse.

---

## 4. Elasticsearch. Buscador de ofertas y "avísame" con percolator

### 4.1 La cola de ofertas (migración 043)

Mismo patrón **outbox** que `evento_producto` y `evento_comentario`. La cola
`evento_oferta` se llena con cuatro triggers en la misma transacción que el cambio.

| Tabla | Cuándo encola |
|---|---|
| `oferta` | alta, baja, cambio de precio, descuento, stock o estado |
| `producto_catalogo` | alta o cambio de nombre, encola todas sus ofertas |
| `variante_catalogo` | alta o cambio de nombre o estado |
| `usuarios` | cambio de usuario, nombre o estado, encola las ofertas del vendedor |

`EventoOfertaSyncService.sincronizar()` (`services/vendedores/evento-oferta-sync.service.ts:92`)
corre cada 5 s, toma hasta 500 eventos y los manda en **un solo `bulk`**. Existe,
`index`. Ya no existe, `delete`. Marca procesado solo si `fecha` no cambió mientras
trabajaba. El mapping es `dynamic: strict`, un campo de más hace fallar la oferta
y queda en `ultimo_error` en vez de inventar un campo.

No se colgó de `evento_producto` porque esa cola es por producto y su worker
escribe en Mongo. Si Mongo se cae, se frenaría también el índice de ofertas.

### 4.2 `GET /vendedor/ofertas/buscar`

`services/vendedores/buscar-ofertas.service.ts`. Texto difuso sobre producto,
variante y vendedor, y un `resumen` hecho con **agregaciones** (`aggs` `:149`) de
todo lo que cumple la búsqueda, no solo de la página. Cuántas por estado, con
descuento, agotadas, rango de precios y los vendedores con más ofertas. Un
vendedor solo ve las suyas porque el filtro `id_vendedor` va fijo en el código, no
sale de un parámetro.

### 4.3 Seguimientos con percolator (migración 044)

Una búsqueda normal guarda documentos y les lanza consultas. **El percolator
guarda consultas y les lanza cada documento nuevo** para ver a quién le interesa.
Es lo que usan las alertas de empleo o el "avísame cuando llegue".

Dos tipos. `busqueda` (no encontró nada, avísame cuando llegue, con o sin precio
máximo) y `baja_precio` (avísame cuando esta variante baje, de la tienda o de
cualquiera).

- La consulta guardada la arma `consultaDelSeguimiento()`
  (`services/compradores/seguimientos-oferta.service.ts:542`). Siempre exige
  oferta activa, con stock, variante activa y vendedor activo.
- **Crear** (`crear()` `:120`) es PostgreSQL sin `COMMIT`, luego Elasticsearch,
  luego `COMMIT`. Si Elasticsearch falla, `ROLLBACK`. Si el `COMMIT` falla, se
  borra la consulta de Elasticsearch (compensación). Tope de 20 vivos por cuenta.
- **Disparar.** El worker de ofertas llama a `percolar()`
  (`percolar-seguimientos.service.ts:38`) con todas las ofertas indexadas del lote
  **antes** de marcarlas procesadas (`evento-oferta-sync.service.ts:174-176`). Si
  percolar falla, la corrida se repite y no se pierde ningún aviso.
- **Un solo disparo.** `cumplir()` (`:93`) hace `UPDATE ... WHERE fecha_cumplido
  IS NULL` y el `INSERT` del aviso en una transacción, y `aviso_seguimiento_oferta.id_seguimiento`
  es `UNIQUE`. Si dos ofertas coinciden en el mismo lote se avisa la más barata.
  Después se borra la consulta del percolator.

Rutas en `controllers/compradores/seguimientos-oferta.controller.ts` bajo
`/comprador/seguimientos`. `POST`, `GET`, `GET /avisos`, `PATCH /avisos/:id`
(leído o no leído con `fecha_leida`) y `DELETE /:id`.

---

## 5. Neo4j. Las compras en el grafo (migración 041)

Archivos. `services/grafo/grafo-compras-sync.service.ts`,
`services/productos/para-ti.service.ts`, `services/productos/tambien-compraron.service.ts`,
`helpers/recomendaciones-grafo.ts`. Plan `plan pendiente/grafo-compras.md`.

### 5.1 El modelo

```
(:Usuario)-[:HIZO]->(:Compra)-[:DE]->(:Producto)
(:Compra)-[:A_VENDEDOR]->(:Usuario)
```

Un nodo `:Compra` por línea de pedido, con la variante, cantidad, precio y fecha
como propiedades. Es un nodo y no una relación por la misma razón que la reseña, así
compra y reseña de una cuenta quedan en el mismo grafo (sirve también para fraude,
reseñas sin compra o cuentas que se compran entre sí). Cuenta como compra un pedido
`comprado`, `enviado` o `entregado` (`ESTADOS_DE_COMPRA` `:11`).

### 5.2 La cola va por cuenta

`evento_grafo_compra.id_usuario`, una fila pendiente por cuenta, triggers en
`pedido` y `pedido_producto`. El worker (cada 10 s, `procesarUnEvento()` `:141`,
con `FOR UPDATE SKIP LOCKED`) relee **todas** las compras de la cuenta y deja el
grafo igual. Así un pedido nuevo, uno cancelado o uno borrado a mano se resuelven
igual, sin guardar si fue alta o baja.

El Cypher (`CYPHER_PROYECTAR_COMPRAS` `:318`) en una sentencia borra las `:Compra`
que sobran (`DETACH DELETE`), vuelve a una fila por cuenta con `WITH DISTINCT u` y
hace `MERGE` de las que sí están. `MERGE` necesita la restricción de unicidad
`compra_id` para no duplicar.

### 5.3 "Para ti" y "también compraron"

```
// para ti (para-ti.service.ts:141)
MATCH (yo:Usuario {id: $id})-[:HIZO]->(k:Compra)-[:DE]->(comun:Producto)
... tus compras más recientes ...
MATCH (comun)<-[:DE]-(:Compra)<-[:HIZO]-(otro:Usuario) WHERE otro <> yo
MATCH (otro)-[:HIZO]->(:Compra)-[:DE]->(rec:Producto)
WHERE NOT (yo)-[:HIZO]->(:Compra)-[:DE]->(rec)
WITH rec, count(DISTINCT otro) AS compradores ...
```

Traducción. Lo que compraron las cuentas que compraron lo mismo que tú, sin lo que
ya tienes, ordenado por cuántas cuentas distintas llevan a cada producto. Es un
recorrido de dos saltos, justo la pregunta para la que existe un grafo. Va **en
vivo, sin caché**, porque tarda milisegundos y así cambia apenas llega la compra.
Antes salía de ClickHouse por vistas, cada 15 minutos, y se borró `ParaTiSyncService`.

"También compraron" (`tambien-compraron.service.ts:94`) es lo mismo partiendo de
un producto. Se muestra en la ficha.

La conciliación del grafo (`GrafoSyncService.conciliar()` `grafo-sync.service.ts:347`)
compara también las compras de PostgreSQL con las `:Compra` de Neo4j.

---

## 6. ClickHouse. Combos

`GET /productos/combos`, `services/productos/combos-sync.service.ts`. Los grupos de 2
y 3 productos que más se compran en el mismo pedido. Es un **conteo global, sin un
producto de partida**, así que va en ClickHouse. La versión con un producto de
partida es un recorrido y ya existe en Neo4j ("también compraron").

La consulta (`consultarCombos()` `:139`) vale la pena leerla.

1. `canastas`. Por pedido, `arraySort(groupUniqArray(id_producto))`, de los últimos
   180 días, lote `real`, sin pedidos devueltos y con 2 a 30 productos.
2. Todos los pares y tríos de cada canasta con `ARRAY JOIN` sobre `arrayMap` y
   `range`.
3. `GROUP BY grupo HAVING pedidos >= 2`.

Después `quitarParesDentroDeTrios()` (`:238`) quita un par que está dentro de un
trío con los mismos pedidos o más, porque no dice nada nuevo. Mismo patrón que más
vendidos. El worker (cada 30 minutos y al arrancar) deja el JSON listo en Redis
(`mesh:productos:combos`) y la ruta solo lee Redis.

**Lo que se hizo fuera del backend el 18-10.** La semilla `semilla-combos/` (8
cuentas, 18 pedidos de 8 combos con sentido, sin disparar fraude) y la migración
046 `pedido_quitado`. Cuando un `quitar.sql` borra pedidos de PostgreSQL los anota
ahí, y el ETL de compras los borra de `compra_producto` y `devolucion_producto` con
`ALTER TABLE ... DELETE`. Desde psql no se llega a ClickHouse, por eso la cola.

---

## 7. Fraude

### 7.1 Las señales por el texto de las reseñas

Todas comparan vectores con `paresParecidos()` (§2.3), y dos reseñas son
**gemelas** con coseno de 0,92 o más. En las de vendedor, producto y anillo además
tienen que ser de cuentas distintas y de no más de 30 días de diferencia. Fuente
`elastic` en el catálogo de señales (se quedó con ese nombre aunque los vectores
volvieron a PostgreSQL, cambiarlo pedía migración y frontend).

| Señal | Servicio | Regla | Puntos | ¿Forma caso? |
|---|---|---|---|---|
| `resenas_repetidas` | `resenas-repetidas-detector.service.ts` | Una cuenta con 5+ reseñas con gemela y 30 %+ de las suyas | 15 | sí |
| `anillo_de_texto` | `anillo-de-texto-detector.service.ts` | 3+ cuentas con reseñas casi iguales sobre el mismo vendedor | 25 | sí |
| `resenas_parecidas_vendedor` / `_producto` | `resenas-parecidas-detector.service.ts` | 5+ con gemela de otra cuenta y 20 % / 40 % | | solo alerta |
| `notas_incoherentes_cuenta` | `notas-incoherentes-detector.service.ts` | 5+ reseñas con el texto contrario a las estrellas y 20 %+ | 10 | sí |
| `notas_incoherentes_producto` / `_vendedor` | el mismo | 40 % / 20 % | | solo alerta |

Lo que se mide es el largo después de `trim()`, mínimo 100 caracteres para todas.

**Notas incoherentes en SQL** (`buscarCandidatos()` `notas-incoherentes-detector.service.ts:232`).
`count(*) FILTER (WHERE ...)` para las contradictorias, y el porcentaje en el
`HAVING`. La contradicción (`SQL_CONTRADICTORIA` `:70`) es texto `mala` con 4-5
estrellas o `buena` con 1-2. El 3 no cuenta. Antes era una agregación `terms` +
`bucket_selector` de Elasticsearch.

**Por qué las de producto y vendedor solo alertan** (`TIPOS_SOLO_ALERTA`
`hallazgo-fraude-adaptador.service.ts:44`). Un vendedor con muchas reseñas raras
puede ser quien las compra o la víctima de una campaña en contra. No suma puntos a
nadie, lo mira el admin.

**El chequeo inmediato** (`chequeo-texto-inmediato.service.ts:53`). Al crear una
reseña, `ResenasService.crear` lo lanza con `void` (`resenas.service.ts:334`), sin
hacer esperar la respuesta. Indexa, valora y evalúa solo esa reseña en las cuatro
señales. Cada detector corta pronto si la reseña nueva no puede cambiar nada. Las
señales aparecen a los 2 o 3 segundos y `POST /resenas` sigue respondiendo en 15 a
32 ms. Lo que falle lo recoge la pasada de cada 15 minutos.

**El largo de las reseñas** (`helpers/validaciones-resena.ts:12` y `:18`). Reseña de
40 a 350 caracteres, respuesta hasta 350 sin mínimo. El clasificador se entrenó con
textos largos y uno muy corto no es confiable.

### 7.2 Reseñar y cancelar la compra (fuente `postgres`)

`resenas-canceladas-detector.service.ts`, consulta en `consultar()` (`:152`). Cruza
el `stock_movimiento` de motivo `devolucion` con la reseña del mismo comprador al
mismo vendedor por el mismo producto, con la cancelación **después** de la reseña y
dentro de 72 horas, y sin otra compra vigente del producto (`NOT EXISTS`).

- `resena_positiva_cancelada`, una reseña de 4-5 estrellas. Una sola vez ya es
  **señal fuerte** (`TIPOS_FUERTES` `agrupador-fraude.service.ts:18-25`), 20 puntos.
- `resenas_negativas_canceladas_vendedor`, 5+ de 1-2 estrellas sobre un vendedor.
  Solo alerta, y el vendedor sale como **víctima**.
- El disparo es la cancelación, no la reseña, porque al escribirla todavía no se
  canceló. `cancelarPedido` llama a `detectarInmediato()` sin `await`
  (`services/compradores/pedidos.service.ts:301`).

### 7.3 La limpieza del 17-10 (migración 042)

Plan `plan pendiente/limpieza-fraude.md`. Seis cambios.

1. **Las señales de login ya no unen casos, tampoco al guardar.** Una IP compartida
   es un indicio, no una prueba. La evidencia pasó a ser única por **(caso, señal)**
   (`ON CONFLICT (id_caso_fraude, id_senal_fraude)` en
   `persistencia-caso-fraude.service.ts:336-338`), así una señal de login puede
   estar en varios casos con solo las cuentas de cada uno. Antes `127.0.0.1` juntaba
   los cuatro anillos de prueba en un solo caso. Es el C1 que estaba pendiente.
2. **Fuera `cadena_abierta`.** En A→B→C la reputación no se concentra en nadie, y las
   8 cadenas de los datos eran pedazos de anillos que ya salían por otro tipo.
3. **`favor_devuelto` se fusionó en `mutuo`.** Ahora es un bono por las horas entre la
   ida y la vuelta (`bonoIdaYVuelta()` `puntaje-fraude.service.ts:133`), +20 en menos
   de 1 h, +12 en menos de 24 y +8 en menos de 72.
4. **Fuera `carrito_acaparador` (F4).** Con el carrito en PostgreSQL una oferta normal
   no reserva nada y la venta relámpago reserva 15 minutos.
5. **La granja de registros (F6) pasa a Elasticsearch.** En ClickHouse nunca podía
   dispararse, `evento_registro` estaba vacía desde el 10-09. Ahora
   `evaluarGranjaDeRegistros()` (`services/fraude-login/fraude-login-retrospectivo.service.ts:496`)
   agrupa por IP en `mesh_eventos_autenticacion` y `peorVentana()` (`:590`) busca 5+
   cuentas en 60 minutos. Esta sí une cuentas en un caso, nacer juntas desde una IP es
   más que compartir el wifi.
6. **Reglas R-CASI.** Se quitaron la rama "comparten casa" de R-CASI-1 y R-CASI-4 (las
   olas de B.4 nunca se guardaban, no se podía cumplir).

### 7.4 Las fuentes ahora salen del catálogo

`FUENTE_POR_CATALOGO` (`hallazgo-fraude-adaptador.service.ts:63`). `neo4j` es `grafo`,
`clickhouse` es `eventos`, y además `login`, `elastic` y `postgres`. Cada fuente
cuenta como un **motor** distinto en el puntaje (dos motores ×1,3, tres ×1,6). La
excepción es la familia `compras_navegacion`, siempre `eventos`, para que la granja
(que ahora sale de Elasticsearch) no se confunda con el texto de reseñas en R-CASI-3.

---

## 8. Tabla de workers (los nuevos y los que cambiaron)

| Worker | Cada | Lee | Escribe |
|---|---|---|---|
| `CarritoBarridoService` | 10 min | `pedido` pendiente vencido | lo borra en PostgreSQL y Redis |
| `ReservasVentaRelampagoSyncService` | 10 s | `reserva_venta_relampago` | Redis (restaura), vence reservas |
| `VectoresSyncService` | 10 s (antes 3 h) | Mongo `pendiente_vector` | `vector_producto` |
| `EventoComentarioSyncService` | 10 s | `evento_comentario` | `vector_comentario` |
| `ValoracionComentariosService` | 30 s | `vector_comentario` | su valoración |
| `GrafoComprasSyncService` | 10 s | `evento_grafo_compra` | `:Compra` en Neo4j |
| `EventoOfertaSyncService` | 5 s | `evento_oferta` | `mesh_ofertas` y percola `mesh_seguimientos` |
| `CombosSyncService` | 30 min y al arrancar | ClickHouse + Mongo | Redis `mesh:productos:combos` |
| Detectores de texto, canceladas, notas | 15 min (y al instante) | PostgreSQL | señales de fraude |
| `FraudeLoginRetrospectivoService` | 15 min | Elasticsearch | señales de login y granja |
| `ParaTiSyncService` | **borrado** | | |

Todos con el mismo molde. `@Interval`, una bandera o promesa para que no se pisen
dos corridas, y un error de conexión que se loguea sin tumbar el proceso y deja todo
pendiente **sin sumar intentos**.

---

## 9. Guion de repaso de 15 minutos

1. **`carrito.service.ts:98-149`**, la cabecera. Las dos copias y quién manda.
2. **`carrito-postgres.service.ts:245-324`** y `comprobarVersion()` `:463`. La versión
   y las diferencias.
3. **`carrito.service.ts:602-916`**, el checkout en siete pasos.
4. **`carrito-postgres.service.ts:808-825`**, `unidadesLibres()`. La venta relámpago
   en una consulta.
5. **`helpers/vectores-pgvector.ts`** entero. `buscarCercanos` y `paresParecidos`.
6. **`hibrida.service.ts:308-357`**, RRF.
7. **`grafo-compras-sync.service.ts:318-338`** y **`para-ti.service.ts:141`**. El
   modelo del grafo y la recomendación.
8. **`combos-sync.service.ts:139-186`**. Pares y tríos en ClickHouse.
9. **`percolar-seguimientos.service.ts:38-124`**. El percolator y el disparo único.
10. **`notas-incoherentes-detector.service.ts:232-266`** y
    **`resenas-canceladas-detector.service.ts:152-208`**. Fraude en SQL.

### Preguntas que probablemente te hagan

- *¿Por qué no dejar el carrito solo en Redis, si es más rápido?* Porque Redis no
  garantiza durabilidad ni integridad, y el carrito termina en dinero. Redis sigue
  contestando primero, PostgreSQL se escribe debajo sin hacer esperar a nadie, y si
  no coinciden manda PostgreSQL.
- *¿Qué pasa si Redis se cae a mitad de una venta relámpago?* PostgreSQL reserva solo
  con `FOR UPDATE` sobre la oferta y la misma cuenta de unidades libres. No vende de
  más. Cuando Redis vuelve se reconstruye desde PostgreSQL.
- *¿Y si Redis dice que sí y PostgreSQL dice que no?* El carrito queda
  desincronizado, el checkout da 409 y no se compra hasta sincronizar.
- *¿Cómo evitan que dos pestañas pisen el carrito?* Con la versión del pedido, control
  optimista. La que llega con una versión vieja no escribe.
- *¿Por qué los vectores en PostgreSQL y no en Elasticsearch?* Lo pidió el profesor,
  y medido da el coseno exacto (1000 de 1001) frente a 317 de Elasticsearch por la
  cuantización. Además los detectores ya no sacan vectores de la base.
- *¿Qué es `ef_search` y por qué lo tocan?* Cuántos candidatos revisa el índice HNSW.
  Con 40 por defecto, un filtro puede dejar la consulta con menos filas de las pedidas.
- *¿Qué es el percolator?* Consultas guardadas a las que se les lanza el documento. Al
  revés de una búsqueda normal.
- *¿Por qué "para ti" en Neo4j y combos en ClickHouse?* "Para ti" parte de una cuenta y
  recorre dos saltos, es un grafo. Los combos cuentan todos los pedidos de la tienda,
  es una agregación columnar.
- *¿Cómo llegan las compras al grafo sin hacer lenta la compra?* Outbox. Un trigger
  encola la cuenta en la misma transacción, el pedido hace `COMMIT` sin esperar a
  Neo4j y un worker proyecta segundos después. La conciliación compara las dos bases.
- *¿Por qué una señal de login ya no une casos?* Una IP compartida (una oficina, un
  wifi) es un indicio débil. Unía cuentas reales con anillos de prueba que no tenían
  nada en común.
- *¿Por qué la reseña positiva cancelada es fuerte con una sola vez?* Porque no tiene
  explicación inocente fácil. Pagar, reseñar con 5 estrellas y cancelar en menos de
  72 horas es inflar a un vendedor gratis.
