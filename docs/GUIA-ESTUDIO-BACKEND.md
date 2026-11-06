# Guia de estudio, el backend de Mesh

Para Jose David y para la presentacion final. Dice donde esta cada cosa del
backend, con el archivo y la linea, y como se conecta con la pagina y con las
bases. Las lineas se revisaron el 6 de noviembre contra el repositorio. Si
alguien mueve codigo, se abre el archivo y se busca el nombre de la funcion.

Las otras dos guias van mas a fondo en lo suyo, `docs/GUIA-ESTUDIO-VECTORES.md`
y `docs/GUIA-ESTUDIO-ACL.md`.

## 1. En una frase

El backend es NestJS sobre Fastify, en TypeScript. Recibe las peticiones de la
pagina y de Postman, revisa quien es y que puede hacer, y es el unico que habla
con las seis bases. No usa ORM, cada consulta esta escrita a mano.

## 2. Las carpetas, para que sirve cada una

Todo vive en `backend/src/`.

| Carpeta | Que hay | Ejemplo |
|---|---|---|
| `main.ts` | Arranca el servidor | Fastify en el puerto 3000, linea 54 |
| `app.module.ts` | La lista de todo lo que existe | Controllers en la linea 167, servicios en la 223 |
| `controllers/` | Las rutas, lo que la pagina llama | `carrito/carrito.controller.ts` |
| `services/` | Lo que hace cada ruta, la logica y las consultas | `carrito/carrito.service.ts` |
| `guards/` | Los porteros, quien eres y que puedes | `sesion.guard.ts`, `permiso.guard.ts` |
| `database/` | Una conexion por base | `postgres.ts`, `redis.ts` |
| `helpers/` | Piezas que usan todos | `respuesta.ts`, `token.ts`, `cortacircuitos.ts` |
| `dto/` y `models/` | La forma de lo que entra y de lo que sale | `dto/buscar-hibrida.ts` |

La regla es siempre la misma. El controller recibe, el servicio trabaja y la
base guarda. Un controller casi no tiene logica.

## 3. El viaje de una peticion, de principio a fin

Ejemplo, la compradora da clic en **Agregar** en una ficha.

1. **La pagina** llama `PUT /api/carrito/lineas/:idOferta`, desde
   `frontend/src/routes/producto/[id]/+page.svelte:683`.
2. **Vite**, el que sirve la pagina en el 5173, le quita el `/api` y la pasa al
   backend en el 3000. Esta en `frontend/vite.config.ts:53`.
3. **Fastify** la recibe, `backend/src/main.ts:34`. Con `trustProxy` guarda la
   IP real de quien llego, no la del paso de en medio.
4. **El controller** de esa ruta es
   `backend/src/controllers/carrito/carrito.controller.ts:60`. Arriba de la
   clase, en la linea 41, dice `@UseGuards(SesionGuard, PermisoGuard)` y en la
   42 `@Permiso('carrito.usar')`.
5. **SesionGuard**, `backend/src/guards/sesion.guard.ts:71`, lee la cookie
   `mesh_token` y la verifica. Sin cookie o vencida, 401.
6. **PermisoGuard**, `backend/src/guards/permiso.guard.ts:41`, pregunta a la
   tabla `rol_permiso` si el rol tiene `carrito.usar`. Si no, 403.
7. **El servicio**, `definirCantidad()` en
   `backend/src/services/carrito/carrito.service.ts:236`, guarda la linea en
   PostgreSQL y su copia rapida en Redis.
8. **La respuesta** sale siempre con la misma forma, `ok`, `mensaje` y
   `payload`, armada por `exito()` y `fallo()` de
   `backend/src/helpers/respuesta.ts:19` y `:29`.

Postman hace lo mismo desde el paso 3, sin la pagina.

## 4. Las conexiones a las bases

Una por archivo, en `backend/src/database/`. Cada una trae su cortacircuitos.

| Base | Archivo | Lo que se exporta | Entra como |
|---|---|---|---|
| PostgreSQL | `postgres.ts` | `pool`, linea 18 | `mesh_backend` |
| MongoDB | `mongo.ts` | `mongoClient` y `mongoDb`, lineas 31 y 39 | `mesh_backend` |
| Redis | `redis.ts` | `redis`, linea 44 | `backend` |
| Neo4j | `neo4j.ts` | `neo4jDriver`, linea 33 | `neo4j`, community no trae roles |
| ClickHouse | `clickhouse.ts` | `clickhouse`, linea 72 | `mesh_backend` |
| Elasticsearch | `elastic.ts` | opciones y cortacircuitos, lineas 55 y 63 | `mesh_backend` |
| Ollama | `ollama.ts` | `OLLAMA_URL` y el modelo, lineas 16 y 17 | No tiene usuario, solo escucha en la PC |

**El cortacircuitos** es `backend/src/helpers/cortacircuitos.ts:27`. Si una
base falla, la pausa 15 segundos (`pausaMs = 15_000`, linea 40) y mientras
tanto la tienda contesta sin ella o con su respaldo, en vez de quedarse
esperando en cada peticion.

## 5. La seguridad del backend

| Que | Donde | En corto |
|---|---|---|
| El token de la sesion | `backend/src/helpers/token.ts` | HS256 (linea 6), se firma en `firmarToken()` (48) y se revisa en `verificarToken()` (63) |
| La cookie | `token.ts:14` y `:25` a `:29` | Se llama `mesh_token`, `httpOnly`, la pagina no la puede leer |
| La contrasena | `backend/src/helpers/contrasena.ts` | `hashearContrasena()` (17) y `compararContrasena()` (31), nunca se guarda en claro |
| Entrar | `backend/src/services/usuario.service.ts:120`, `iniciarSesion()` | La consulta va con parametros, `$1`, en la linea 137 |
| Poner la cookie | `backend/src/controllers/usuario.controller.ts:170` | Despues de un login bueno |
| Quien eres | `SesionGuard`, `backend/src/guards/sesion.guard.ts:71` | 401 si no |
| Que puedes | `PermisoGuard`, `backend/src/guards/permiso.guard.ts:41` | 403 si no, y el intento queda anotado |
| Que puedes con esa oferta | `PermisoOfertaGuard`, `backend/src/guards/permiso-oferta.guard.ts:42` | 404 si no tiene ninguna entrada, 403 si le falta esa |

El detalle de los permisos esta en `docs/GUIA-ESTUDIO-ACL.md`.

## 6. Donde esta cada parte de la tienda

| Parte | Controller | Servicio | Base principal | Pantalla |
|---|---|---|---|---|
| Cuentas y sesion | `controllers/usuario.controller.ts` | `services/usuario.service.ts` | PostgreSQL | **Iniciar sesion**, **Crea una** |
| Buscador | `controllers/buscador/` | `services/buscador/` | Elasticsearch, y PostgreSQL para el significado | El buscador de arriba y `/buscar` |
| Catalogo y fichas | `controllers/productos/` | `services/productos/` | MongoDB | La ficha de producto |
| Carrito y pago | `controllers/carrito/` | `services/carrito/` | PostgreSQL, con copia en Redis | **Tu carrito**, **Confirmar la compra** |
| Pedidos | `controllers/compradores/` | `services/compradores/` | PostgreSQL | **Mis pedidos** |
| Ofertas del vendedor | `controllers/vendedores/` | `services/vendedores/` | PostgreSQL | Panel del vendedor, **Ofertas** |
| Venta relampago | `controllers/vendedores/` | `services/inventario-limitado/` | Redis con un script Lua | **Abrir venta relampago** |
| Ofertas compartidas | `controllers/compartidas/` | `services/acl/` | PostgreSQL | **Compartidas** |
| Resenas | `controllers/resenas/` | `services/resenas/` | PostgreSQL, y Neo4j para el fraude | La pestana **Resenas** de la ficha |
| Recomendaciones | `controllers/productos/` | `services/productos/` | Neo4j, ClickHouse y PostgreSQL | **Parecidos a este**, **Quienes lo compraron tambien llevaron** |
| Tendencias y dashboard | `controllers/admin/`, `controllers/dashboards/` | `services/admin/`, `services/dashboards/` | ClickHouse y PostgreSQL | Admin, **Tendencias** y **Dashboard** |
| Fraude | `controllers/fraude/`, `controllers/admin/` | `services/fraude/`, `services/fraude-login/` | Neo4j, Elasticsearch y PostgreSQL | Admin, **Fraude** |
| Permisos | `controllers/admin/admin-permisos.controller.ts` | `services/acl/permisos.service.ts` | PostgreSQL | Admin, **Permisos** |

## 7. Los flujos que mas se preguntan

**Entrar.** `POST /usuario/login`,
`backend/src/controllers/usuario.controller.ts:154`. El servicio
`iniciarSesion()` (`usuario.service.ts:120`) busca la cuenta por correo o
usuario con un parametro, compara la contrasena, firma el token, y el
controller pone la cookie en la linea 170.

**Buscar con errores.** `buscar()` en
`backend/src/services/buscador/facetado.service.ts:99` arma la consulta a
Elasticsearch con `fuzziness`, que perdona letras de mas o de menos, y con las
facetas que dan los numeros de cada filtro. La busqueda por frase es
`buscar()` de `backend/src/services/buscador/hibrida.service.ts:128`, que junta
la de palabras con la de significado por vectores.

**Parecidos a este.** `obtener()` en
`backend/src/services/productos/similares.service.ts:60`. Primero los de su
misma categoria y despues el resto, los dos ordenados por el vector en
PostgreSQL con pgvector. El detalle esta en `docs/GUIA-ESTUDIO-VECTORES.md`.

**Quienes lo compraron tambien llevaron.** `obtener()` en
`backend/src/services/productos/tambien-compraron.service.ts:59`, un recorrido
de dos saltos en Neo4j, de este producto a quien lo compro y de ahi a lo que
tambien compro.

**Pagar.** `POST /carrito/comprar`,
`backend/src/controllers/carrito/carrito.controller.ts:124`, con el permiso
`carrito.comprar` en la 123. El servicio es `comprarCarrito()`,
`backend/src/services/carrito/carrito.service.ts:628`. Todo va en una sola
transaccion de PostgreSQL, que empieza con el `BEGIN` de la linea 677 y
bloquea las ofertas con `FOR UPDATE` para que dos personas no se lleven la
misma unidad. Si todo sale bien, `COMMIT` en la 685. Si algo falla, `ROLLBACK`
en la 704 y no se cobra nada.

**Cancelar.** `POST /comprador/pedidos/:id/cancelar`,
`backend/src/controllers/compradores/pedidos.controller.ts:80`.
`cancelarPedido()` en `backend/src/services/compradores/pedidos.service.ts:247`
devuelve las unidades a la oferta y deja el pago reembolsado.

**Venta relampago.** `reservar()` en
`backend/src/services/inventario-limitado/inventario-limitado.service.ts:540`
llama a un script Lua dentro de Redis, `redis/inventario_limitado.lua` en la
raiz del repo. Redis corre el script entero sin que nadie se meta en medio, asi
que nunca se venden mas unidades de las que hay.

**Permisos.** `tiene()` en `backend/src/services/acl/permisos.service.ts:106`
es la pregunta que hace `PermisoGuard` en cada peticion. Lee la tabla en ese
momento, asi que quitar un permiso vale en la peticion siguiente.

## 8. Lo que corre solo, de fondo

Son 31 tareas con `@Interval`, cada una en su servicio. Las que mas se
preguntan.

| Tarea | Cada cuanto | Que hace | Donde |
|---|---|---|---|
| Indice del buscador | 10 s | Lleva a Elasticsearch los productos que cambiaron en MongoDB | `services/buscador/buscador-sync.service.ts:39` |
| Vectores | 10 s | Pasa por Ollama el texto de cada producto que cambio y guarda su vector | `services/productos/vectores-sync.service.ts:77` |
| Grafo de resenas | 10 s | Lleva a Neo4j cada resena tocada | `services/grafo/grafo-sync.service.ts:90` |
| Grafo de compras | 10 s | Lleva a Neo4j cada compra | `services/grafo/grafo-compras-sync.service.ts:97` |
| Ofertas al buscador | 5 s | Indexa las ofertas tocadas y revisa los avisame | `services/vendedores/evento-oferta-sync.service.ts:93` |
| Producto en MongoDB | 5 s | Recalcula precio, stock y nota del producto que cambio | `services/productos/evento-producto-sync.service.ts:57` |
| Detector de anillos | 15 min | Busca resenas en circulo en Neo4j | `services/fraude/anillos-detector.service.ts:39` |
| Mas vendidos | 10 min | Recalcula el estante desde ClickHouse y lo deja en Redis | `services/productos/mas-vendidos-sync.service.ts:117` |
| Combos | 30 min | Recalcula **Se compran juntos** | `services/productos/combos-sync.service.ts:74` |
| Carritos vencidos | 10 min | Borra los carritos sin tocar hace 24 horas | `services/carrito/carrito-barrido.service.ts:37` |
| Descuento automatico | 1 min | Mira las ventas recientes y aplica la regla | `services/reglas-descuento-automatico/disparador-reglas-automatico.service.ts:85` |
| Venta relampago | 10 s | Rehace el contador de Redis desde PostgreSQL si se perdio | `services/inventario-limitado/reservas-venta-relampago-sync.service.ts:58` |

Todas trabajan con una cola en PostgreSQL, por ejemplo `evento_grafo` o
`evento_oferta`. El cambio se anota primero ahi, en la misma transaccion, y la
tarea lo lleva a la otra base despues. Si la otra base esta caida, la cola
espera y no se pierde nada.

## 9. Si se cae una base

- PostgreSQL es la verdad. Sin el no se puede comprar, pero la tienda se puede
  mirar y lo dice con un aviso.
- Sin Redis, el carrito sale de PostgreSQL.
- Sin MongoDB, la tienda usa la copia del catalogo en PostgreSQL,
  `producto_catalogo` y `variante_catalogo`.
- Sin Elasticsearch, el buscador cae a PostgreSQL, `helpers/buscador-respaldo.ts`.
- Sin Neo4j o ClickHouse, los estantes usan su respaldo,
  `helpers/recomendaciones-respaldo.ts`.
- Cada base tiene su `manejar-error-*.ts` en `helpers/`, que convierte el error
  en un mensaje claro y no en un 500 sin explicacion.

La prueba es `node pruebas/caidas.mjs`, 51 comprobaciones con cada base apagada
y otras 51 congelada.

## 10. Como se prueba el backend

| Que | Comando | Resultado |
|---|---|---|
| Permisos por rol | `bash pruebas/permisos_rol.sh` | 171 en verde |
| Usuarios de cada base | `bash seguridad/prueba_acceso.sh` | 93 en verde |
| ACL por oferta | `bash pruebas/acl_ofertas.sh` | 85 en verde |
| Recomendacion por vectores | `python pruebas/recomendacion_semantica.py` | 21 en verde |
| Caidas | `node pruebas/caidas.mjs` | 51 y 51 |
| Todo lo del control de acceso, llamando directo | La coleccion de Postman, `presentacion-final/postman/` | 64 en verde |

## 11. Preguntas probables

**Por que no hay ORM.** Porque cada base habla distinto y las consultas
importantes, como la compra con `FOR UPDATE` o el vector con pgvector, se
quieren ver y controlar enteras.

**Como sabe el backend quien es.** Por la cookie `mesh_token`, un token firmado
que dura 2 horas. `SesionGuard` lo verifica en cada peticion y ademas lee de la
base si la cuenta sigue activa y cual es su rol de hoy.

**Que pasa si dos compran la ultima unidad a la vez.** La compra bloquea la
oferta con `FOR UPDATE` dentro de la transaccion. El segundo espera, ve que ya
no hay y no se le cobra.

**Por que la pagina no habla directo con las bases.** Porque el backend es el
que revisa sesion y permiso. Si la pagina hablara con las bases, cualquiera
podria saltarse el control.

**Donde se agregaria una ruta nueva.** Un metodo en el controller de su area,
con su `@Permiso`, la logica en el servicio, y el permiso en la tabla
`rol_permiso`. Una ruta sin `@Permiso` se niega sola,
`backend/src/guards/permiso.guard.ts:55`.
