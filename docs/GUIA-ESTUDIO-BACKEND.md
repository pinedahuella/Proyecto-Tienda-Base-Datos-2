# Guia de estudio, el backend de Mesh

Para Jose David y para la presentacion final. Dice donde esta cada cosa del
backend, con el archivo y la linea, y como se conecta con la pagina y con las
bases. Las lineas se revisaron el 6 de noviembre contra el repositorio. Si
alguien mueve codigo, se abre el archivo y se busca el nombre de la funcion.

Va primero lo que mas se va a preguntar, los vectores, el control de acceso y el
panel del admin, cada uno con su consulta real. Despues el mapa del resto del
backend. Los usuarios de cada base estan en `docs/GUIA-ESTUDIO-ACL.md`, y la
medicion de los vectores en `docs/GUIA-ESTUDIO-VECTORES.md`.

## 1. En una frase

El backend es NestJS sobre Fastify, en TypeScript. Recibe las peticiones de la
pagina y de Postman, revisa quien es y que puede hacer, y es el unico que habla
con las seis bases. No usa ORM, cada consulta esta escrita a mano.

## 2. Vectores, la recomendacion por significado

**La idea en tres frases.** Cada producto se convierte en una lista de 768
numeros que representa de que trata. Dos productos que hablan de lo mismo
quedan cerca, aunque no compartan palabras. PostgreSQL guarda esas listas con
pgvector y busca las mas cercanas con un indice.

### 2.1 De donde sale el vector

1. **El texto.** `construirTexto()` en
   `backend/src/services/productos/vectores-sync.service.ts:42` arma
   `nombre. Categoria X. descripcion`, leido de MongoDB. Es el mismo formato
   del ETL, para que un producto que no cambio no se vuelva a calcular.
2. **Ollama.** `pedirVectores()` en `backend/src/helpers/vectores-ollama.ts:33`
   hace `POST /api/embed` a Ollama, en la misma PC, con el modelo
   `paraphrase-multilingual` (`backend/src/database/ollama.ts:17`). Manda los
   textos de 32 en 32 (`LOTE_VECTORES`, linea 8) y espera hasta 30 segundos
   (linea 14). `keep_alive` en -1 (linea 19) deja el modelo cargado, para que la
   primera busqueda no espere a que arranque.
3. **Solo si cambio.** El worker guarda el md5 del texto (linea 144). Si el md5
   es el mismo que ya tiene, no llama a Ollama. Corre cada 10 segundos,
   `@Interval` de la linea 77.
4. **El grupo.** Tambien guarda el md5 de categoria y descripcion sin el nombre
   (linea 145). Las copias del mismo producto, como `Laptop Lienzo 15` y
   `Laptop Lienzo 15 L1-0149`, comparten grupo y no se recomiendan entre si.
5. **Se guarda** en `guardar()`, linea 273, con
   `INSERT ... ON CONFLICT (id_producto_mongo) DO UPDATE` en la 278, asi que
   recalcular reemplaza.

### 2.2 La tabla y el indice

`migrations/040_vectores_en_postgres.sql:40`, la tabla `vector_producto`.

| Columna | Que guarda |
|---|---|
| `id_producto_mongo` | El `_id` del producto en MongoDB, con llave foranea a `producto_catalogo` |
| `vector` | `vector(768)`, el de Ollama |
| `texto_hash` | md5 del texto, para saber si cambio |
| `grupo` | md5 sin el nombre, para no recomendar copias |
| `activo` | Si el producto esta activo, solo esos se recomiendan |
| `modelo` | Con que modelo se calculo |

El indice esta en la linea 69, `USING hnsw (vector vector_cosine_ops)`. HNSW es
un grafo de vecinos que encuentra los mas cercanos sin comparar contra todos, y
`vector_cosine_ops` dice que la distancia es la del coseno.

### 2.3 La consulta de Parecidos a este

`obtener()` en `backend/src/services/productos/similares.service.ts:60`. Saca
6 parecidos (`LIMITE`, linea 9) en dos bloques.

**Bloque 1, su misma categoria**, linea 111.
```sql
SELECT v.id_producto_mongo, v.grupo, 1 - (v.vector <=> $1::vector) AS similitud
  FROM vector_producto v
  JOIN producto_catalogo pc USING (id_producto_mongo)
 WHERE v.activo AND v.id_producto_mongo <> $2 AND v.grupo <> $3
   AND pc.id_categoria = $4
 ORDER BY v.vector <=> $1::vector
 LIMIT $5
```

**Bloque 2, todo el catalogo**, linea 128, la misma sin el `JOIN` ni la
categoria, para que el `ORDER BY` use el indice HNSW.

- `<=>` es la distancia coseno de pgvector. `1 - distancia` es el parecido, de
  0 a 1.
- `$1` es el vector del producto, que va como parametro y no como subconsulta.
  Con subconsulta PostgreSQL no usa el indice.
- `v.grupo <> $3` saca las copias del mismo producto.
- Se piden 200 candidatos (`CANDIDATOS`, linea 12) y se llena en orden, primero
  los de su categoria y despues el resto (lineas 170 y 171). Cada uno sale con
  `misma_categoria`.

**El ajuste del indice**, `buscarCercanos()` en
`backend/src/helpers/vectores-pgvector.ts:41`. Antes de la consulta, en la
linea 50, pone `hnsw.ef_search` en el doble de candidatos y
`hnsw.iterative_scan` en `strict_order`. Con los valores de fabrica el indice
mira solo 40 candidatos, y con el filtro de categoria quedaban menos de 6.

### 2.4 La busqueda por frase, hibrida

`buscar()` en `backend/src/services/buscador/hibrida.service.ts:128` hace dos
busquedas y las junta.

1. **Por palabras** en Elasticsearch, con `multi_match` y `fuzziness: 'AUTO'`
   en las lineas 201 a 204.
2. **Por significado.** La frase pasa por Ollama (linea 171, con 8 segundos de
   limite, `LIMITE_MS_OLLAMA` en la 42) y se busca su vector en
   `vector_producto` en la linea 260. Solo pasan los que llegan a 0,4 de
   parecido (`UMBRAL_COSENO`, linea 39, filtro en la 276).
3. **Las junta con RRF**, `combinar()` en la linea 352. Cada lista aporta
   `1 / (60 + posicion)` a cada producto, con `RRF_K = 60` en la linea 33, y se
   suman. Un producto que sale arriba en las dos queda primero. RRF junta por
   posicion y no por puntaje, porque el puntaje de Elasticsearch y el coseno no
   se pueden comparar.
4. **Si Ollama no contesta**, responde solo por palabras y lo dice,
   `modo: 'solo_texto'` en la linea 141.

**Lo que cuentan otros compradores** es la busqueda por intencion,
`buscar()` en `backend/src/services/buscador/intencion.service.ts:108`. Compara
la frase con el vector de cada resena, en `vector_comentario` (linea 202), y
pide al menos 0,45 de parecido (linea 34).

### 2.5 Preguntas probables de vectores

**Por que 768.** Es lo que da el modelo `paraphrase-multilingual`. No se elige,
viene del modelo.

**Por que coseno y no distancia normal.** El coseno mide hacia donde apunta el
vector, no su largo. Dos textos sobre lo mismo apuntan parecido aunque uno sea
mas largo.

**Que pasa si se cae Ollama.** Los productos que ya tienen vector se siguen
recomendando, porque el vector esta guardado en PostgreSQL. Lo que no se puede
es calcular el de un producto nuevo ni buscar por frase, que cae a solo
palabras.

## 3. Control de acceso, por dentro del backend

**La idea en tres frases.** Hay dos porteros en cada ruta. El primero dice
quien eres, el segundo si tu rol puede hacer esa accion. Para las ofertas
compartidas hay un tercero que mira si esa persona tiene permiso sobre esa
oferta.

### 3.1 Quien eres, SesionGuard

`backend/src/guards/sesion.guard.ts:71`.

1. Lee la cookie `mesh_token`. Si no hay, 401 `No hay sesion activa`.
2. Verifica la firma y que no haya vencido, `verificarToken()` de
   `backend/src/helpers/token.ts:63`. Si falla, 401.
3. En la linea 94 pregunta a PostgreSQL si la cuenta sigue activa y cual es su
   rol **de hoy**, con `estadoDeSesion()`. Si el admin la bloqueo o le cambio el
   rol, vale desde esta misma peticion, sin esperar a que venza el token de 2
   horas.

### 3.2 Que puedes, PermisoGuard

`backend/src/guards/permiso.guard.ts:41`.

1. Lee el `@Permiso` de la ruta, por ejemplo `@Permiso('usuarios.ver')`.
2. **Si la ruta no declara permiso, se niega**, linea 55. Asi una ruta nueva
   que alguien olvide proteger no queda abierta.
3. Pregunta `tiene()`, `backend/src/services/acl/permisos.service.ts:106`.

```sql
SELECT EXISTS (
  SELECT 1
    FROM rol_permiso rp
    JOIN permiso p ON p.id_permiso = rp.id_permiso
    JOIN modulo_permiso m ON m.id_modulo_permiso = p.id_modulo_permiso
   WHERE rp.id_rol_usuario = $1
     AND m.modulo_permiso_nombre = $2
     AND p.permiso_nombre = $3
) AS tiene
```

   `usuarios.ver` se parte en el modulo `usuarios` y la accion `ver`.
4. Si no lo tiene, anota el intento con `registrarNegado()` (linea 176) en
   `auditoria_permiso`, con quien, su rol, el permiso, el metodo y la ruta, y
   contesta 403 `No tienes permiso para hacer esto (falta usuarios.ver)`.
5. **Si PostgreSQL no contesta**, usa la ultima copia de la matriz que leyo
   entera (linea 132). Se relee al arrancar y cada minuto, `@Interval` de la
   linea 70.

### 3.3 Las tablas de los permisos

`migrations/050_permisos_por_rol.sql`.

| Tabla | Linea | Que guarda |
|---|---|---|
| `modulo_permiso` | 43 | Los 17 modulos, como `ofertas` o `fraude` |
| `permiso` | 55 | Los 38 permisos de la 050, cada uno de un modulo. Con los 4 de la 051 a la 054, 42 |
| `rol_permiso` | 70 | Que rol tiene que permiso, 80 filas (76 de la 050). Llave primaria rol y permiso, linea 78 |
| `auditoria_permiso` | 93 | Cada intento negado, y cada permiso dado o quitado |

Quitar una fila de `rol_permiso` vale en la peticion siguiente, porque
`tiene()` lee la tabla en cada peticion. No hay que compilar ni reiniciar.

### 3.4 Los permisos que no se pueden quitar

`protegidoPara()` en `backend/src/services/acl/permisos.service.ts:35`.
`cuenta.ver` no se le quita a nadie, porque sin el no abre la sesion, y
`permisos.ver` y `permisos.administrar` no se le quitan al admin, porque nadie
podria devolverselos. `revocar()` lo revisa en la linea 350, antes del
`DELETE` de la 359, y contesta 409 sin borrar nada. Postman lo prueba en la
carpeta 4.

### 3.5 Una oferta, por persona, PermisoOfertaGuard

`backend/src/guards/permiso-oferta.guard.ts:42`, en las rutas de
`compartidas/ofertas`. Pregunta a `comprobar()`,
`backend/src/services/acl/acl-ofertas.service.ts:83`.

```sql
SELECT o.id_usuario::text AS id_dueno,
       array_agg(t.tipo_permiso_oferta_nombre::text) AS permisos
  FROM permiso_oferta p
  JOIN oferta o ON o.id_oferta = p.id_oferta
  JOIN tipo_permiso_oferta t ON t.id_tipo_permiso_oferta = p.id_tipo_permiso_oferta
 WHERE p.id_oferta = $1 AND p.id_usuario = $2
   AND (p.fecha_vencimiento IS NULL OR p.fecha_vencimiento > now())
 GROUP BY o.id_usuario
```

- Trae los permisos vigentes de esa persona sobre esa oferta, `ver`, `editar` o
  `descuento`. El que ya vencio no cuenta, linea 106.
- **Sin ninguna entrada, 404** en la linea 132, el mismo de una oferta que no
  existe. Asi no se confirma ni que la oferta existe.
- **Con entrada pero sin ese permiso, 403** en la linea 134.
- Cada negativa queda en `auditoria_permiso_oferta`.

La tabla es `permiso_oferta`, `migrations/049_acl_ofertas.sql:61`. Sus reglas
estan en la misma tabla, la fecha de vencimiento despues de la de otorgado, no
darse permiso a uno mismo, y un solo permiso igual por persona y oferta.

### 3.6 Preguntas probables de control de acceso

**Por que el rol se lee de la base y no del token.** Porque el token dura 2
horas. Si el rol viniera solo del token, quitarle el admin a alguien tardaria
hasta 2 horas en valer.

**Por que 404 y no 403 en una oferta ajena.** Con 403 se confirmaria que la
oferta existe. Con 404 quien no tiene nada no sabe ni eso.

**Donde se ve todo lo negado.** En el panel del admin, **Permisos**, abajo, **Lo
ultimo que paso**, que lee `auditoria_permiso`.

## 4. El panel del admin, pestana por pestana

Todas las rutas del admin estan protegidas en la clase de su controller, con
`@UseGuards(SesionGuard, PermisoGuard)` y su `@Permiso`. Un comprador que las
llame recibe 403.

### 4.1 Dashboard

`backend/src/controllers/dashboards/dashboard-general.controller.ts:57`, con
`@Permiso('dashboard.ver')` en la 59. Tiene una ruta por cuadro, de `resumen`
(linea 67) a `pedidos` (156), mas las de **Exportar**.

- `resumen()`, `backend/src/services/dashboards/dashboard-general.service.ts:81`,
  calcula las cifras del periodo elegido y las del periodo anterior, con
  `Promise.all`, para mostrar cuanto subio o bajo. Ademas cuenta lo
  de hoy en PostgreSQL, productos activos, vendedores con ofertas activas,
  cuentas y pedidos sin pagar.
- `ventas()` en la linea 139 da **Ventas en el tiempo**.
- Todo sale de PostgreSQL, que es donde estan el dinero y los pedidos.

### 4.2 Reportes

`backend/src/controllers/admin/admin-reportes.controller.ts:22`, con
`@Permiso('reportes.ver')` en la 24. `GET /admin/reportes/ventas` (linea 40) y
`GET /admin/reportes/reservaciones` (29). `ventas()` en
`backend/src/services/admin/admin-reportes.service.ts:109` da **Pedidos**,
**Pagos** y **Como pagan**, desde PostgreSQL.

### 4.3 Cuentas

`backend/src/controllers/admin/admin-usuarios.controller.ts:20`.
`GET /admin/usuarios` (linea 27) pide `usuarios.ver`, y
`PATCH /admin/usuarios/:id` (43) pide `usuarios.editar` (42).

- `actualizar()`, `backend/src/services/admin/admin-usuarios.service.ts:70`,
  cambia el rol (`id_rol_usuario`) o el estado (`id_estado_usuario`) de una
  cuenta, por ejemplo **Bloquear**.
- No deja editar la propia cuenta, linea 80, para que el admin no se bloquee a
  si mismo.
- El cambio vale en la peticion siguiente de esa cuenta, porque `SesionGuard`
  lee el estado y el rol de la base en cada peticion.

### 4.4 Permisos

`backend/src/controllers/admin/admin-permisos.controller.ts:30`.

| Ruta | Linea | Permiso | Que hace |
|---|---|---|---|
| `GET /admin/permisos` | 37 | `permisos.ver`, en la 32 | La matriz, 3 roles y 42 permisos, con `roles` y `protegido_para` de cada uno |
| `GET /admin/permisos/registro` | 47 | `permisos.ver` | Lo ultimo de `auditoria_permiso` |
| `POST /admin/permisos/:idRol/:idPermiso` | 61 | `permisos.administrar`, en la 60 | Darle el permiso al rol |
| `DELETE /admin/permisos/:idRol/:idPermiso` | 86 | `permisos.administrar`, en la 85 | Quitarselo, 409 si esta protegido |

Lo que significan `roles` y `protegido_para` esta en la seccion 3.4.

### 4.5 Fraude

Cuatro sub pestanas, todas con `fraude.ver`.

| Sub pestana | Ruta | Donde |
|---|---|---|
| **Casos** | `GET /admin/fraude/casos` | `backend/src/controllers/admin/admin-casos-fraude.controller.ts:36`. Resolver un caso pide `fraude.resolver` (58) |
| **Intentos de entrada** | `GET /admin/fraude/alertas-login` | `backend/src/controllers/fraude/fraude.controller.ts:29` |
| **Resenas en anillo** | `GET /admin/fraude/alertas-resenas` | `backend/src/controllers/admin/admin-fraude-anillos.controller.ts:47` |
| **Compras y navegacion** | Los hallazgos de ClickHouse | Se guardan como senales en `senal_fraude` |

**El anillo**, la consulta mas preguntada, es el Cypher de
`backend/src/services/fraude/anillos-detector.service.ts:268`.

```
MATCH camino = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)
```

Busca un camino que sale de una cuenta y vuelve a ella pasando por resenas,
entre 4 y 8 relaciones. Cuatro saltos son un par de cuentas que se califican
entre si, seis un triangulo, ocho un cuadrado. Corre cada 15 minutos
(`@Interval` de la linea 39) y tambien al momento cuando llega una resena. No
prueba un fraude, senala cuentas para que una persona las revise.

### 4.6 Tendencias

`backend/src/controllers/admin/admin-tendencias.controller.ts:38`, con
`@Permiso('tendencias.ver')` en la 40. Todo sale de ClickHouse.

**Resumen**, los rankings. Cada cuadro llama una ruta, `vista` (linea 48),
`carrito` (59), `compra` (70), `devolucion` (81) y `busqueda` (96). Todas usan
`consultarRanking()`,
`backend/src/services/admin/admin-tendencias.service.ts:253`.

```sql
SELECT id_producto AS clave, <metrica> AS total
  FROM <tabla>
 WHERE fecha >= now() - INTERVAL {dias:UInt32} DAY
   AND lote = 'real'
 GROUP BY id_producto
 ORDER BY total DESC
 LIMIT {limite:UInt32}
```

La metrica cambia segun lo que se cuenta, y es lo que se suele preguntar.

| Cuadro | Tabla | Metrica | Linea | Por que |
|---|---|---|---|---|
| **Lo mas visto** | `vista_producto` | `count(DISTINCT sesion)` | 68 | Personas distintas, no clics. Uno que recarga 40 veces cuenta 1 |
| **Lo que mas llevan al carrito** | `carrito_producto` | `count(DISTINCT id_usuario)` | 78 | Cuentas distintas |
| **Lo mas vendido** | `compra_producto` | `sum(cantidad)` | 86 | Unidades, sin los pedidos devueltos |
| **Lo mas devuelto** | `devolucion_producto` | `sum(cantidad)` | 94 | Unidades devueltas |

- `lote = 'real'` deja fuera los eventos sembrados para las pruebas.
- Los numeros van como parametros de ClickHouse, `{dias:UInt32}`. La tabla y la
  metrica salen de una lista fija del codigo, nunca del texto que llega.

**Para revisar**, lo que esta creciendo de verdad. `GET /admin/eventos/tendencias`,
`backend/src/controllers/admin/admin-tendencias-avanzadas.controller.ts:34`, y
`enAscenso()` en `backend/src/services/admin/admin-tendencias-avanzadas.service.ts:93`.

- Lee `vistas_por_producto_dia`, un resumen por dia que ClickHouse va sumando
  solo. Por eso contesta rapido aunque haya millones de vistas.
- Compara las vistas por dia de los ultimos dias contra las de antes, `veces`.
- Pide al menos 20 vistas (`T1_MIN_VISTAS`, linea 27) y que haya crecido 1,5
  veces (`T1_MIN_CRECIMIENTO`, linea 28).
- Calcula `vistas_por_persona` con `uniqMergeIf(sesiones)`. Un producto inflado
  por una sola persona con muchos clics sale con un numero alto ahi y se
  distingue de una tendencia real.

**Por que ClickHouse y no PostgreSQL para esto.** ClickHouse guarda cada columna
por separado. Contar vistas de un periodo solo lee las columnas `fecha` y
`id_producto`, no la fila entera, y por eso agrupa millones de eventos en
milisegundos.

### 4.7 Las demas pestanas del admin

| Pestana | Que es | Donde |
|---|---|---|
| **Ofertas**, **Compartidas**, **Reglas** | Las mismas del vendedor, con lo que vende la tienda | `backend/src/controllers/vendedores/`, `backend/src/controllers/compartidas/` y `backend/src/controllers/reglas-descuento-*` |
| **Catalogo** | Publicar, editar, ver el historial y retirar productos | `backend/src/controllers/vendedores/`, con el permiso `catalogo.editar` |
| **Propuestas** | Aprobar o rechazar lo que proponen los vendedores | `backend/src/controllers/vendedores/`, con `catalogo.revisar` |


## 5. Las carpetas, para que sirve cada una

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

## 6. El viaje de una peticion, de principio a fin

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

## 7. Las conexiones a las bases

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

## 8. La seguridad del backend

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

## 9. Donde esta cada parte de la tienda

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

## 10. Los flujos que mas se preguntan

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

## 11. Lo que corre solo, de fondo

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

## 12. Si se cae una base

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

## 13. Como se prueba el backend

| Que | Comando | Resultado |
|---|---|---|
| Permisos por rol | `bash pruebas/permisos_rol.sh` | 171 en verde |
| Usuarios de cada base | `bash seguridad/prueba_acceso.sh` | 93 en verde |
| ACL por oferta | `bash pruebas/acl_ofertas.sh` | 85 en verde |
| Recomendacion por vectores | `python pruebas/recomendacion_semantica.py` | 21 en verde |
| Caidas | `node pruebas/caidas.mjs` | 51 y 51 |
| Todo lo del control de acceso, llamando directo | La coleccion de Postman, `presentacion-final/postman/` | 64 en verde |

## 14. Preguntas probables

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
