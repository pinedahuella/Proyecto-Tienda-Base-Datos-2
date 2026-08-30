# Lo que falta del backend

Para Jose David. Todo lo de abajo es `backend/`, que nadie mas toca.

Lo que YA esta hecho y te espera: las tablas, los datos, los scripts de Redis,
el grafo de Neo4j y las pantallas. Nada de eso hay que escribirlo otra vez.
Lo unico que falta son las rutas HTTP que las unen.

Este documento dice **exactamente** que ruta, que recibe y que devuelve. Las
pantallas ya estan escritas contra estas firmas: si las respetas, funcionan sin
tocar el frontend.

---

## Antes de nada: como comprobar que tienes con que trabajar

```bash
docker ps                        # los 6 contenedores tienen que estar arriba
docker exec -i mesh-postgres psql -U meme -d mesh -tAc "SELECT count(*) FROM resena;"
docker exec mesh-redis    redis-cli -a "$REDIS_PASSWORD" --no-auth-warning PING
docker exec mesh-neo4j    cypher-shell -u neo4j -p "$NEO4J_PASSWORD" "MATCH (n) RETURN count(n);"
```

Credenciales: **todas salen del `.env` de la raiz, que no se sube al repositorio.**
Ninguna esta escrita en este documento a proposito -- si aparecieran aqui estarian
en GitHub. Cargalas antes de correr lo de arriba:

```bash
set -a; . ./.env; set +a
```


| | usuario | contrasena | puerto |
|---|---|---|---|
| PostgreSQL | `DB_USER` del .env | `DB_PASSWORD` del .env | 5432 |
| Redis | -- | `REDIS_PASSWORD` del .env | 6379 |
| Neo4j | `neo4j` (fijo) | `NEO4J_PASSWORD` del .env | 7687 (bolt), 7474 (navegador) |

Visores en el navegador: **RedisInsight** en `localhost:5540` (ensena el TTL de
cada clave contando hacia atras) y **Neo4j Browser** en `localhost:7474` (dibuja
el grafo).

Si te falta `REDIS_PASSWORD` o `NEO4J_PASSWORD` en tu `.env`, copialas de
`.env.example`.

---

# BLOQUE 1 -- Las resenas (Entrega 1, completa el modelo)

Las tres tablas existen desde la migracion `011_resenas.sql`. Hay **86 resenas,
115 comentarios y 46 votos** sembrados. Hoy no hay forma de verlos desde la
aplicacion.

## Lo que hay que saber del modelo antes de escribir la ruta

**La resena es de un VENDEDOR sobre un PRODUCTO.** No del producto solo. El
catalogo es compartido y un producto no es de nadie, asi que la resena apunta a
las dos cosas:

```
resena(id_resena, id_usuario, id_usuario_vendedor, id_producto_mongo,
       calificacion, id_comentario)
```

**El texto NO esta en `resena`.** Esta en su comentario RAIZ. `resena.id_comentario`
apunta a una fila de `comentario` con `id_comentario_padre IS NULL`, y ahi viven
el texto y la fecha. Las respuestas cuelgan de esa raiz.

**Los votos van contra `id_comentario`, no contra `id_resena`.** Asi la misma
tabla sirve para votar una resena y para votar una respuesta.

**Los contadores `cantidad_likes` y `cantidad_dislikes` no se tocan a mano.**
Los mantiene el trigger `trg_likes_recontar`, que RECUENTA en cada insert,
update y delete de `likes`. Si los actualizas desde el backend vas a pelearte
con el trigger. Solo leelos.

## `GET /productos/:id/resenas`

Publica, sin sesion. `:id` es el `id_producto_mongo`.

Pantalla que la consume: `frontend/src/lib/Resenas.svelte`.

```jsonc
{
  "ok": true,
  "mensaje": "Resenas obtenidas",
  "payload": {
    "resenas": [
      {
        "id_resena": 12,
        "id_comentario": 40,          // la RAIZ. es contra este id que se vota
        "calificacion": 5,
        "comentario": "Llego en dos dias y bien empacado.",
        "fecha_publicacion": "2026-04-18T16:02:00.000Z",
        "autor_usuario": "compradora_norte",
        "autor_correo": "compradora.norte@mesh.com",
        "vendedor_usuario": "ventas_norte",
        "vendedor_correo": "ventas.norte@mesh.com",
        "vendedor_nombre": "Carlos Ramirez",
        "voto": { "mio": 1, "a_favor": 3, "en_contra": 0 },
        "respuestas": [
          {
            "id_comentario": 41,
            "autor_usuario": "ventas_norte",
            "autor_correo": "ventas.norte@mesh.com",
            "comentario": "Gracias por la compra.",
            "fecha_publicacion": "2026-04-18T18:02:00.000Z",
            "voto": { "mio": null, "a_favor": 0, "en_contra": 0 }
          }
        ]
      }
    ],
    "resumen": {
      "total": 4,
      "promedio": 4.25,
      "reparto": { "1": 0, "2": 1, "3": 0, "4": 1, "5": 2 }
    },
    "puede_calificar": [
      { "correo": "ventas.sur@mesh.com", "usuario": "ventas_sur", "nombre": "Lucia Morales" }
    ]
  }
}
```

Tres cosas de esa forma que importan:

**`voto.mio`** es lo que voto **quien esta pidiendo**: `1`, `-1` o `null`. Sin
sesion siempre `null`. Es lo que pinta el boton encendido; sin ese campo el
usuario no ve lo que ya voto y vota dos veces.

**`resumen.reparto`** son las barras de la ficha, con las cinco claves `"1"` a
`"5"` **siempre presentes**, aunque valgan 0. Si omites una, la barra
desaparece en vez de salir vacia.

**`puede_calificar`** es la lista de vendedores de ese producto a los que **esta
cuenta todavia no ha calificado**. Es lo que llena el select del formulario.
Sale de restar: los que tienen oferta activa del producto, menos los que ya
tienen una fila en `resena` con este usuario, menos el propio usuario (el CHECK
de la tabla prohibe autocalificarse). Sin sesion, lista vacia.

Consulta de arranque:

```sql
SELECT r.id_resena, r.calificacion, r.id_comentario,
       c.comentario, c.fecha_publicacion, c.cantidad_likes, c.cantidad_dislikes,
       ua.usuario AS autor_usuario, ua.correo_electronico AS autor_correo,
       uv.usuario AS vendedor_usuario, uv.correo_electronico AS vendedor_correo,
       uv.nombre || ' ' || COALESCE(uv.apellido, '') AS vendedor_nombre
FROM resena r
JOIN comentario c ON c.id_comentario = r.id_comentario
JOIN usuarios  ua ON ua.id_usuario   = r.id_usuario
JOIN usuarios  uv ON uv.id_usuario   = r.id_usuario_vendedor
WHERE r.id_producto_mongo = $1
ORDER BY c.fecha_publicacion DESC;
```

## `POST /resenas`

Pide sesion.

```jsonc
// entra
{
  "id_producto": 12,
  "correo_vendedor": "ventas.norte@mesh.com",
  "calificacion": 5,
  "comentario": "Llego en dos dias."
}
```

Son **dos INSERT y tienen que ir en la misma transaccion**: primero el
comentario raiz, y con el id que devuelve, la resena. Si se parten, un fallo en
el segundo deja un comentario huerfano que nadie va a ver nunca.

```sql
WITH raiz AS (
  INSERT INTO comentario (id_usuario, comentario)
  VALUES ($1, $2) RETURNING id_comentario
)
INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo,
                    calificacion, id_comentario)
SELECT $1, $3, $4, $5, raiz.id_comentario FROM raiz;
```

Errores que la base ya rechaza sola, y el mensaje que conviene devolver:

| Lo que pasa | Codigo de PostgreSQL | Que contestar |
|---|---|---|
| Ya calificaste a ese vendedor por ese producto | `23505` unique_violation | 409 "Ya calificaste a este vendedor por este producto" |
| Te estas calificando a vos mismo | `23514` check_violation | 400 "No puedes calificarte a ti mismo" |
| Calificacion fuera de 1..5 | `23514` check_violation | 400 "La calificacion va de 1 a 5" |
| Comentario en blanco | `23514` check_violation | 400 "El comentario no puede estar vacio" |

**Lo que la base NO comprueba y te toca a vos:** que ese vendedor de verdad
venda ese producto. `id_producto_mongo` no tiene llave foranea porque el
catalogo vive en MongoDB -- es el mismo trato que ya tiene `oferta`, y esta
escrito en el comentario de la migracion 011. La comprobacion es:

```sql
SELECT 1 FROM oferta o
JOIN estado_oferta eo USING (id_estado_oferta)
WHERE o.id_usuario = $vendedor
  AND o.id_producto_mongo = $producto
  AND eo.estado_oferta_nombre = 'activa'
LIMIT 1;
```

**Lo que NO hay que exigir: que haya comprado.** No hay FK a `pedido` y es a
proposito -- la resena sin compra detras es la senal de fraude mas fuerte que
existe, y exigir la compra la borraria del modelo. Esta argumentado en la
cabecera de `migrations/011_resenas.sql`.

## `POST /resenas/:id/respuestas`

Pide sesion. **Solo el vendedor calificado puede contestar** (`403` a los
demas). El frontend ya apaga el boton para quien no es, pero el permiso es
tuyo.

```jsonc
{ "comentario": "Gracias por la compra." }
```

```sql
INSERT INTO comentario (id_usuario, id_comentario_padre, comentario)
SELECT $1, r.id_comentario, $2
FROM resena r WHERE r.id_resena = $3;
```

## `PUT /comentarios/:id/voto` y `DELETE /comentarios/:id/voto`

Pide sesion. `:id` es **`id_comentario`**, no `id_resena`.

```jsonc
// PUT
{ "valor": 1 }    // 1 a favor, -1 en contra
```

Cambiar de opinion es un **UPDATE**, no una fila nueva: la llave primaria es
`(id_usuario, id_comentario)`.

```sql
INSERT INTO likes (id_usuario, id_comentario, valor)
VALUES ($1, $2, $3)
ON CONFLICT (id_usuario, id_comentario) DO UPDATE SET valor = EXCLUDED.valor;
```

`DELETE` quita el voto. Los contadores se actualizan solos: el trigger.

**El rango de `valor` lo validas vos.** La columna no tiene CHECK, por decision
del equipo. El trigger cuenta exactamente `1` y `-1`, asi que un valor fuera de
rango no suma en ningun lado en vez de sumar donde no debe -- pero tampoco
tendria por que llegar.

---

# BLOQUE 2 -- Redis: el carrito (1.5 pts)

La capa de Redis esta escrita y probada en `redis/`. Leete `redis/README.md`:
tiene el diseno de claves, el TTL y la explicacion que va al informe.

Lo que falta es cambiar de donde sale el carrito.

## Como funciona hoy, y por que hay que cambiarlo

Hoy el carrito **es una fila de `pedido` en estado `pendiente`** de PostgreSQL,
y su id vive en `localStorage`. Eso tiene dos problemas que la rubrica senala:

1. **No caduca nunca.** El enunciado pide expiracion **por inactividad**. El JWT
   de 2 horas no sirve como respuesta: son 2 horas FIJAS, no inactividad. Un TTL
   de Redis que se renueva en cada toque si es exactamente lo que piden.
2. **Exige tener cuenta.** Sin usuario no hay fila de `pedido`.

## El cambio

| | Hoy | Con Redis |
|---|---|---|
| Abrir carrito | `crear_pedido()` -> fila en `pedido` | una clave en Redis |
| Agregar / quitar | `agregar_linea()` / `quitar_linea()` | operacion sobre la clave + renovar TTL |
| Pagar | `comprar_pedido()` | **`comprar_carrito()`**, con las lineas leidas de Redis |

**`comprar_carrito()` ya existe**, en `migrations/012_comprar_carrito.sql`. Hace
crear + agregar + comprar en **una sola transaccion**, y esta probada: en una
compra fallida por falta de stock no queda ni un pedido a medias (verificado con
conexiones separadas: 27 pedidos antes, error, 27 despues).

```sql
SELECT comprar_carrito(
  $id_usuario,
  $id_direccion_historial,
  $lineas::jsonb,     -- el mismo arreglo que ya recibe agregar_linea
  $metodo_pago
);
```

Devuelve lo mismo que `comprar_pedido` mas `id_pedido`.

**Las tres funciones de la 007 siguen intactas.** `comprar_carrito` las compone,
no las reemplaza: podes migrar cuando quieras y lo viejo sigue andando.

## Lo que hay que documentar del efecto sobre el checkout

Ya esta resuelto y te ahorra trabajo: **agregar al carrito NUNCA reservo stock**
(esta en `docs/base-de-datos.md`). Entonces **cuando un carrito caduca no hay
que liberar nada**. Eso es la respuesta completa a lo que pide el enunciado.

## LA TRAMPA, y hay que decidirla antes de escribir la ruta

`agregar_linea()` **congela el precio en el momento de agregar al carrito**. La
migracion 007 lo dice textual: *"si el vendedor lo sube despues, este pedido
conserva el que se le mostro a la persona"*.

Si el carrito vive en Redis, agregar y comprar pasan en el mismo instante, asi
que **el precio que se congela es el del momento de PAGAR**, no el que la
persona vio. Si el vendedor lo subio en el medio, se le cobra el nuevo, **sin
ningun error y sin que nadie se entere**.

La salida: que el carrito de Redis guarde tambien el `id_precio_historial` de
cada linea, y poder pasarselo a `agregar_linea` en vez de que ella lo busque.
Eso es un cambio en la 007 (mio) y en la ruta (tuyo): **avisame y la escribo**.
No lo dejes para despues: es un cobro incorrecto.

---

# BLOQUE 3 -- Redis: la oferta de inventario limitado (3 pts)

Es lo que mas pesa de la entrega, y es donde el enunciado es mas exigente:
*"operaciones atomicas del almacen clave-valor, con evidencia de que el
mecanismo se sostiene bajo solicitudes concurrentes simuladas y **sin recurrir a
bloqueos a nivel de aplicacion**"*.

## Por que no sirve lo que hay

`comprar_pedido()` usa `SELECT ... FOR UPDATE` (linea 469 de la 007). Funciona
perfecto, pero **es exactamente el bloqueo que el enunciado pide no usar**.

## Lo que hay que hacer

El script Lua esta en `redis/inventario_limitado.lua`, con su prueba de
concurrencia. La idea, para que la puedas defender en la presentacion:

**Comprobar y descontar tienen que ser UN solo paso.** `DECRBY` y despues
compensar si quedo negativo son dos pasos, y en el medio ya vendiste de mas. Un
script Lua corre entero y atomico dentro de Redis: nada se cuela a la mitad. Ese
es el argumento.

Devuelve algo que distinga **vendido** de **agotado**, y la ruta traduce eso a
200 o 409.

## Lo que la rubrica paga es la EVIDENCIA

No el codigo: la prueba. `redis/prueba_concurrencia.sh` pone un stock conocido,
lanza muchas mas solicitudes concurrentes que unidades, y comprueba que se
vendieron exactamente las que habia. **Esa salida va al informe.**

Corrila vos tambien antes de la entrega, para poder contestar preguntas sobre
ella.

---

# BLOQUE 4 -- Neo4j: el panel de fraude (3 pts)

El grafo esta cargado y las consultas escritas. Falta **una sola ruta**.

## El modelo, en tres lineas

```
(:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(:Usuario)
                        (:Resena)-[:SOBRE]->(:Producto)
```

**No hay nodo `:Vendedor`.** Es el mismo `:Usuario`, y es obligatorio: en Mesh
comprar no pide rol, un vendedor tambien compra. Si fueran dos etiquetas, la
misma cuenta serian dos nodos distintos y el anillo **nunca cerraria**.

Las consultas estan en `neo4j/consultas/` y se corren con `bash neo4j/correr_fraude.sh`. Podes verlas dibujadas en
`localhost:7474`.

## `GET /admin/fraude/anillos`

**Solo admin.** No la tienda: la tienda es un vendedor mas, y ensenarle quien lo
esta calificando de forma sospechosa le entrega justo la lista que no deberia
ver.

Pantalla que la consume: `frontend/src/lib/PanelFraude.svelte`.

```jsonc
{
  "ok": true,
  "mensaje": "Analisis completado",
  "payload": {
    "anillos": [
      {
        "id": "ciclo-101-102-103",
        "tipo": "ciclo",              // ciclo | mutuo | reiterado | direccion
        "saltos": 6,
        "cuentas": [
          { "id_usuario": 101, "usuario": "ventas_altiplano",
            "correo_electronico": "ventas.altiplano@mesh.com",
            "nombre": "Rodrigo", "apellido": "Similox" }
        ],
        "productos": [ { "id_producto": 12, "nombre": "Laptop Ambar Campus 14" } ],
        "resenas": [
          { "id_resena": 901, "autor": "ventas_altiplano",
            "vendedor": "ventas_bocacosta", "producto": "Laptop Ambar Campus 14",
            "calificacion": 5, "fecha": "2026-05-11T14:02:00.000Z" }
        ],
        "senales": [
          "Las tres calificaciones son de 5 estrellas",
          "Las tres se escribieron en un intervalo de 13 minutos"
        ]
      }
    ],
    "analizado": { "cuentas": 8, "resenas": 86, "relaciones": 258 }
  }
}
```

## Los dos campos que parecen de adorno y no lo son

**`analizado`** es el denominador, y es obligatorio. Los datos sembrados **no
tienen anillo** (verificado: 0 pares mutuos, 0 autocalificaciones), asi que la
consulta va a devolver **cero**, y eso es lo correcto. Una pantalla que ante
cero dice "no hay datos" hace pensar que esta rota. Con `analizado`, la pantalla
dice *"se recorrieron 8 cuentas, 86 resenas y 258 relaciones sin encontrar
nada"*, que es un resultado y no una duda. **Sin ese campo el panel se ve roto
justo el dia de la presentacion.**

**`senales`** son las frases ya redactadas que explican la sospecha. Las arma el
backend a partir de lo que devuelve la consulta (las notas, las fechas, si hubo
compra). Sin ellas el panel ensena una lista de nombres sin decir por que.

## Para la demostracion

Como no hay anillo real, hay que **sembrar uno a proposito** antes de presentar.
`neo4j/README.md` explica como sembrarlo y como borrarlo despues.

Mientras la ruta no exista, el panel **no se rompe**: dice que el analisis no
esta conectado y tiene un boton "Ver con datos de ejemplo" para revisar el
diseno, con un aviso que no se puede quitar mientras haya datos inventados en
pantalla.

---

# Resumen: 8 rutas

| Ruta | Sesion | Bloque |
|---|---|---|
| `GET /productos/:id/resenas` | no | 1 |
| `POST /resenas` | si | 1 |
| `POST /resenas/:id/respuestas` | si, y ser el vendedor | 1 |
| `PUT /comentarios/:id/voto` | si | 1 |
| `DELETE /comentarios/:id/voto` | si | 1 |
| el carrito sobre Redis (varias) | no hace falta | 2 |
| la oferta limitada sobre Redis | si | 3 |
| `GET /admin/fraude/anillos` | si, admin | 4 |

Si algo de esto no cuadra con como tenes armado el backend, decilo y se cambia
la forma **antes** de que escribas la ruta: cambiar el frontend es barato,
cambiar las dos mitades cuando ya estan hechas no.

---

# BLOQUE 5 -- Resenar desde el pedido (agregado el 2026-08-29)

## Por que

Con la regla de compra verificada, la ficha del producto es un mal sitio para
escribir una resena: se llega ahi ANTES de comprar, y el boton solo aparece
despues. Hay que volver al producto a proposito, que es al reves de como pasa.

El sitio natural es **el pedido**: ahi esta lo que compraste y a quien.

## Lo que hay que agregar: DOS campos, no una ruta

`GET /comprador/pedidos/:id` ya devuelve por linea `id_producto_mongo`,
`id_usuario_vendedor`, `nombre_producto` y `nombre_vendedor`. Eso ya identifica
el par (producto, vendedor), que es lo que se resena. **Solo falta saber si ya
esta escrita.**

Cada objeto de `detalles` suma:

```jsonc
"id_resena": null,        // el id si ya la escribio; null si no
"puede_resenar": true     // true = se le puede ofrecer el boton
```

## El cambio, sobre tu consulta de `pedidos.service.ts`

```sql
 SELECT pp.id_pedido_producto, pp.id_pedido, pp.id_precio_historial,
        pp.id_producto_mongo, pp.id_producto_variante_mongo, pp.cantidad,
        pp.nombre_producto, pp.nombre_variante, pp.nombre_vendedor,
        ph.precio AS precio_unitario, ph.id_oferta,
        o.id_usuario AS id_usuario_vendedor,
+       r.id_resena,
+       (r.id_resena IS NULL AND o.id_usuario <> $2) AS puede_resenar
   FROM pedido_producto pp
   JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
   JOIN oferta o ON o.id_oferta = ph.id_oferta
+  LEFT JOIN resena r
+         ON r.id_usuario          = $2
+        AND r.id_usuario_vendedor = o.id_usuario
+        AND r.id_producto_mongo   = pp.id_producto_mongo
  WHERE pp.id_pedido = $1
  ORDER BY pp.id_pedido_producto
```

y pasarle `[idPedidoParametro, idUsuario]` en vez de solo `[idPedidoParametro]`.

`LEFT JOIN` y no `EXISTS` porque ademas del si/no queremos el `id_resena`.

## Cuatro trampas, y la cuarta es la que muerde

**1. Hay que exigir tambien que el pedido este PAGADO y no cancelado.** Es la
misma condicion que ya aplica tu `puede_calificar`. Sin ella, un pedido
`pendiente` ofreceria el boton y `POST /resenas` lo rechazaria despues: el
frontend habria prometido algo que el servidor niega.

Como el estado del pedido ya lo tienes en la primera consulta, lo mas simple es
calcular un booleano del pedido entero y multiplicarlo por linea al armar la
respuesta -- no hace falta meter el `JOIN pago` a la consulta de detalles.

**2. Nadie se resena a si mismo.** De ahi el `o.id_usuario <> $2`. La tabla
tiene `CHECK (id_usuario <> id_usuario_vendedor)`, asi que sin esto el boton
aparece y el POST revienta.

**3. `$2` es el comprador del PEDIDO, no "el usuario logueado" en abstracto.**
Son el mismo (la ruta ya filtra `p.id_usuario = $2`), pero si algun dia un admin
puede ver pedidos ajenos, `puede_resenar` tiene que seguir siendo "puede el
DUENO del pedido", o le ofreceras a un admin resenar la compra de otro.

**4. LA IMPORTANTE: la resena es del par (producto, vendedor), no de la linea.**
Un pedido puede traer dos lineas del mismo producto y el mismo vendedor -- dos
variantes, dos tallas -- y esas dos lineas comparten UNA sola resena. En el
conjunto de datos ya pasa: el pedido 1 tiene 2 lineas y 1 solo producto.

Con el campo por linea, esas dos lineas dirian las dos `puede_resenar: true`, el
frontend pintaria dos botones para la misma resena, y al usar uno el otro
quedaria mintiendo hasta recargar.

No hace falta que lo arregles en el backend -- el frontend agrupa por
(`id_producto_mongo`, `id_usuario_vendedor`) y pinta un boton por par. Pero
tenlo presente si algun dia devuelves un resumen contado: contar lineas daria de
mas.

## Opcional, si te sobra un rato

En la LISTA `GET /comprador/pedidos`, un `resenas_pendientes: 2` por pedido.
Sirve para poner un aviso en `/pedidos` sin abrir cada uno. Es un `count` con la
misma condicion. Si no esta, la pantalla simplemente no lo muestra.

---

# BLOQUE 6 -- `POST /carrito/comprar` (lo unico que bloquea el frontend)

Las cuatro rutas del carrito estan hechas y probadas (25 comprobaciones en
`pruebas/carrito.sh`). Falta la quinta, y **hasta que exista el frontend no
puede migrar**.

## Por que bloquea

El carrito viejo es una fila de `pedido` en `pendiente`, con el `id_pedido` en
`localStorage`, y el checkout va por ahi. El carrito de Redis **no tiene
id_pedido**. No hay forma de migrar a medias: si el frontend pasa a Redis sin
esta ruta, se llena un carrito que no se puede comprar.

Son ocho archivos del frontend los que cuelgan del carrito viejo, asi que el
cambio se hace de una sola vez, cuando esto exista.

## Lo que hace

```
POST /carrito/comprar
{ "id_direccion_historial": 12, "metodo_pago": "tarjeta" }
```

1. Lee el carrito de Redis (`HGETALL`)
2. Lo arma como el arreglo `p_lineas` que ya recibe `agregar_linea`
3. Llama a **`comprar_carrito()`** -- migracion `012_comprar_carrito.sql`, ya
   existe y esta probada: hace crear + agregar + comprar en UNA transaccion,
   y un intento fallido no deja ni un pedido a medias (verificado con
   conexiones separadas: 27 pedidos antes, error, 27 despues)
4. Si salio bien: `DEL` de la clave del carrito
5. Devuelve el `id_pedido` que trae la funcion

```sql
SELECT comprar_carrito($id_usuario, $id_direccion_historial, $lineas::jsonb, $metodo_pago);
```

Cada elemento de `$lineas` es el mismo objeto que ya usa `agregar_linea`:

```jsonc
{ "id_oferta": 12, "cantidad": 2, "id_producto": 5,
  "id_producto_variante": 9, "nombre_producto": "...", "nombre_variante": "..." }
```

## Tres cosas que decidir antes de escribirla

**1. El `DEL` va DESPUES del COMMIT, nunca antes.** Si se borra el carrito y la
compra falla, la persona pierde el carrito y no compro nada. Al reves -- comprar
y que el `DEL` falle -- solo deja un carrito repetido que se puede vaciar a
mano. De los dos errores posibles, hay que elegir el que se puede deshacer.

**2. Que hacer con las lineas que no se pueden comprar.** `GET /carrito` ya las
marca (`disponible: false`). Al comprar hay dos opciones y hay que elegir una:
rechazar la compra entera diciendo cuales, o comprar las que si y dejar las
otras en el carrito. **Rechazar entera es mas facil de explicar** y no sorprende
a nadie con un total distinto al que vio.

**3. EL PRECIO. Esto no es un detalle.**

`agregar_linea()` congela el precio en el momento de agregar al carrito -- la
007 lo dice textual: *"si el vendedor lo sube despues, este pedido conserva el
que se le mostro a la persona"*.

Con el carrito en Redis, agregar y comprar pasan **en el mismo instante**, asi
que el precio que se congela es el del momento de PAGAR. Si el vendedor lo subio
mientras el carrito esperaba, **se le cobra el nuevo, sin ningun error y sin que
nadie se entere**.

La salida: que el carrito de Redis guarde tambien el `id_precio_historial` de
cada linea y poder pasarselo a `agregar_linea` en vez de que ella lo busque.
Eso es un cambio en la 007 (mio) y en esta ruta (tuyo): **avisame y lo escribo**.

Mientras no se resuelva, `GET /carrito` esta devolviendo un precio que puede no
ser el que se cobre. Es un cobro incorrecto, no un detalle de presentacion.
