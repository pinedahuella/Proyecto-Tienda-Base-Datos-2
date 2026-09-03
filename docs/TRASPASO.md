# TRASPASO -- Mesh (Bases de Datos 2)

**Para quien retome el proyecto: leete esto entero antes de tocar nada.**
Son cinco minutos y te ahorra el dia.

Ultima actualizacion: **2026-09-03**.

---

## Pegale esto a la IA que vaya a trabajar

> Proyecto Mesh, de Bases de Datos 2 (Universidad del Istmo). El repo esta en
> `C:\Users\memit\OneDrive - Universidad del Istmo\BASE DE DATOS 2\Proyecto-Tienda-Base-Datos-2`.
>
> **Antes de proponer nada, lee en este orden:**
> 1. `docs/TRASPASO.md` -- que esta hecho y como se levanta (empieza aqui)
> 2. `docs/PENDIENTES.md` -- lo que falta, con su urgencia
> 3. `docs/BACKEND-PENDIENTE.md` -- lo que le toca a Jose David
> 4. `docs/base-de-datos.md` -- por que el modelo es como es
> 5. `migrations/README.md` -- las reglas de las migraciones
>
> **REGLAS QUE NO SE ROMPEN:**
> - Yo (Meme) hago `frontend/`, `migrations/`, `etl/`, `mongo/`, `neo4j/`,
>   `redis/`, `pruebas/`, `docs/` y `arrancar.ps1`. Jose David hace `backend/`.
>   **NUNCA toques `backend/`, ni un comentario.** Leelo: es la fuente de verdad.
> - Todo en `main`, sin ramas. No commitees ni pushees si yo no lo pido.
> - **NUNCA firmes un commit con `Co-Authored-By: Claude` ni menciones IA.**
>   Mensajes de una linea, planos.
> - `migrations/README.md` manda: una migracion ya corrida no se edita (se hace
>   la siguiente), ningun id se escribe a mano (todo por nombre o correo), y el
>   SQL va en ASCII puro.
> - Ninguna contrasena real en un archivo que se suba. Salen del `.env`.
>
> **Antes de decir que algo funciona, MIDELO.** Este proyecto tiene arneses:
> `bash pruebas/resenas.sh`, `bash pruebas/carrito.sh`,
> `bash redis/prueba_concurrencia.sh`, `bash neo4j/correr_fraude.sh`,
> `.\mongo\demostracion_indices.ps1`.
> Y antes de creerle a un arnes, **rompe el codigo a proposito y comprueba que
> falla**: aqui ya aparecio un arnes que validaba copias pegadas de las
> consultas en vez de las consultas de la entrega.

---

## Que es esto

Tienda multi-vendedor con arquitectura poliglota. **Cuatro entregas
acumulativas: 5 + 10 + 15 + 20 pts.** Equipo de tres: Meme (frontend, datos,
migraciones), Jose David (`backend/`) y zapatoazul.

**El modelo, en una linea:** un producto describe una cosa del mundo y **no es
de nadie**; quien lo vende, a que precio y con cuanto stock es una fila de
`oferta`. `tienda@mesh.com` oferta todo y su precio es el que se ensena.

---

## Como se levanta

```powershell
.\arrancar.ps1              # los 7 contenedores, migraciones, semilla y ETL
.\arrancar.ps1 -Reiniciar   # desde cero (borra los volumenes)
```

Despues, en dos terminales:

```
cd backend  ; npm run start:dev     # :3000
cd frontend ; npm run dev           # :5173
```

**Si `arrancar.ps1` se queja de variables que faltan**, tu `.env` es tuyo y no
viene en el pull: copia de `.env.example` las que falten. Y ojo, **son DOS
`.env`**: el de la raiz (contenedores) y `backend/.env` (la aplicacion).

### Puertos

| | Puerto | |
|---|---|---|
| PostgreSQL | 5432 | pgAdmin en **5050** |
| MongoDB | **27018** | dbgate en **3001** |
| Redis | 6379 | RedisInsight en **5540** |
| Neo4j | 7687 (bolt) | Browser en **7474** |
| backend / frontend | 3000 / 5173 | |

Mongo es 27018 por fuera a proposito: Windows puede tener un MongoDB de servicio
ocupando el 27017, y ese contestaria primero con una base vacia.

---

## Que esta HECHO y probado

### Entrega 1 -- cerrada

Las **42 tablas** del diagrama, el catalogo en MongoDB con su ETL, el historial
por eventos, los indices y las agregaciones. El informe lo hizo el equipo.

### Entrega 2 -- lo construido

| Pieza | Estado | Como se comprueba |
|---|---|---|
| **Carrito sobre Redis** | funcionando de punta a punta | `bash pruebas/carrito.sh` (25 OK) |
| **Resenas, comentarios y likes** | 7 rutas, pantalla completa | `bash pruebas/resenas.sh` (15 OK) |
| **Inventario limitado (Lua)** | escrito y probado, **falta enchufarlo** | `bash redis/prueba_concurrencia.sh` |
| **Grafo de fraude (Neo4j)** | ETL + 5 consultas | `bash neo4j/correr_fraude.sh` |
| **Panel de fraude, de punta a punta** | `GET /admin/fraude/anillos` + `PanelFraude.svelte` | entra como `admin@mesh.com` a `/panel` |
| **Reportes de admin** | ventas y reservaciones + `PanelReportes.svelte` | lo mismo |
| **Los indices de Mongo, demostrados** | 4 pasos, 12 comprobaciones | `.\mongo\demostracion_indices.ps1` |
| **El pedido reconstruido, completo** | modal con lo pagado + precio y stock de ese dia | entra como `compradora.norte@` a `/pedidos` |
| **La nota en el catalogo de Mongo** | `resenas_promedio` y `resenas_total` en cada documento, con su indice | `.\arrancar.ps1 -Etl` y mirar un producto en Mongo |
| **Generador incremental de productos** | lotes reproducibles por semilla | `.\arrancar.ps1 -Productos 300 -Semilla 7` |

### La nota del producto, embebida en el catalogo

Cada documento de MongoDB trae ahora dos campos mas, que calcula `etl/extraer.sql`
desde la tabla `resena` de PostgreSQL:

```
resenas_promedio   la nota media, 0 cuando no tiene ninguna resena
resenas_total      cuantas resenas la sostienen
```

**Son el sexto y el septimo numero derivado que se embebe**, y existen por lo
mismo que los cinco de precio y stock que ya estaban: la lista del catalogo los
necesita en cada tarjeta, y sin ellos habria que consultar PostgreSQL una vez por
producto de la pagina. Comparten tambien su contrapartida, que es una copia que
envejece hasta la proxima corrida del ETL.

Van **dos campos y no uno** por una razon que no es obvia: `calificacion` es
`CHECK BETWEEN 1 AND 5`, asi que un promedio real nunca puede dar 0. El 0
significa "no tiene resenas", y quien filtre por nota minima tiene que exigir
ademas `resenas_total > 0` o los productos sin opiniones se ordenarian por debajo
de los de una estrella.

El indice es `catalogo_rating` y esta en `mongo/002_resenas.js`. Su gracia, y es
lo que conviene saber contar: como el RANGO y el ORDEN caen sobre el mismo campo,
el indice sirve para las dos cosas y **no aparece etapa SORT**. En
`catalogo_precio` no se pudo, porque ahi el rango cae sobre `precio_desde` y el
orden sobre `_id`, que son dos campos distintos.

Medido con el catalogo en 406 productos: filtrando por nota en una categoria,
2 documentos examinados para 2 devueltos con el indice, contra 406 sin ninguno.

**El filtro del catalogo todavia no existe**: el campo esta y el indice esta,
pero ninguna ruta del backend lo consume. El contrato de lo que falta esta en
`docs/BACKEND-PENDIENTE.md`.

### El generador de lotes

`migrations/lote/generar_lote.sql` agrega productos y ofertas **sobre una base ya
cargada**, en cualquier momento. Es lo contrario de `migrations/datos/001_catalogo.sql`,
que solo entra en una base vacia.

```powershell
.\arrancar.ps1 -Productos 300 -Semilla 7
```

Misma semilla, mismo catalogo, en cualquier maquina, sin guardar nada. Cada
producto se genera **clonando** uno del catalogo curado, asi que hereda una
categoria valida, caracteristicas del tipo correcto y una foto que carga. Las
imagenes se reusan por la tabla puente y **no se inserta ni una URL nueva**.

Su documentacion entera esta en `migrations/lote/README.md`, incluido como se
deshace un lote, que son dos mitades: el SQL de PostgreSQL **y un borrado aparte
en MongoDB**, porque correr el ETL no los quita.

Y lo que destapo construirlo esta en el pendiente 5, que es lo mas grave que
salio hoy: **hay dos asignadores de id de producto que no se hablan.**

### Y hay un SEGUNDO generador, por el otro extremo

```powershell
.\arrancar.ps1 -ProductosMongo 200
.\arrancar.ps1 -BorrarMongo 7
```

Crea productos que viven **solo en MongoDB**, sin fila en `productos`. La
diferencia con el otro no es de tamano, es de ORIGEN:

| | `-Productos` (marcador `L`) | `-ProductosMongo` (marcador `M`) |
|---|---|---|
| Nace en | PostgreSQL | MongoDB |
| Fila en `productos` | si | **no** |
| El ETL lo reescribe | en cada corrida | **nunca** |

**El de Mongo es como nacen hoy los productos de verdad.** El backend lo dice
por escrito: *"los productos ya no se registran en PostgreSQL"*. Un vendedor que
publica desde el panel crea exactamente eso, y hasta ahora no habia forma de
tener muchos para probarlo.

Son dos escrituras en dos bases: el documento en Mongo y sus ofertas en
PostgreSQL, porque el descuento de stock tiene que ser atomico (ADR-2). El
precio lo sortea el generador de Mongo y **viaja en un csv** hasta el SQL que
crea las ofertas, en vez de sortearse dos veces con la misma semilla: un dato
compartido no se puede desincronizar, dos implementaciones del mismo azar si.

Todo esta en `mongo/lote/README.md`.

**El carrito ya compra de verdad.** Verificado contra la base: pedido creado,
pago `pagado`, kardex con el motivo `venta`, stock descontado, y la clave de
Redis borrada. Una compra fallida no deja ni un pedido a medias **y no borra el
carrito**.

### Los indices de Mongo, para ensenarlos

```powershell
.\mongo\demostracion_indices.ps1     # mide y abre la pagina
```

Corre los cuatro pasos que Jose David mando al grupo, mide cada uno con
`explain("executionStats")` y **corre cada uno otra vez con
`hint({$natural:1})`**, que obliga a MongoDB a no usar ningun indice. Con eso
arma `demostracion_indices.html` (en la raiz): una pagina suelta, sin internet, con
los dos numeros uno encima del otro.

La comparacion es el punto entero. Un `explain` a secas dice "uso
`catalogo_categoria`" y suena bien, pero no dice cuanto; lo que significa algo
es **cuantos documentos hubo que abrir**:

| Paso | Con indice | Sin ninguno |
|---|---|---|
| 2 -- categoria + orden | 7 | 102 |
| 3 -- rango de precio | 9 | 102 |
| 4 -- categoria + `$or` de caracteristicas | 7 (devuelve 3) | 102 |

**El paso 4 es el que hay que saber contar.** Ese `$or` son cuatro
`$elemMatch` sobre arrays embebidos y **ningun indice puede resolverlo**. Lo
que hace el indice es otra cosa: baja el problema de 102 documentos a los 7 de
la categoria, y el `$or` se evalua solo sobre esos. El indice no contesta la
pregunta, **la hace pequena**.

Dos cosas medidas que conviene no olvidar:

- **`Memoria RAM` solo existe dentro de las VARIANTES**, no en las
  caracteristicas del producto. Las dos primeras ramas del `$or` no encuentran
  nada nunca. Estan escritas igual porque otras caracteristicas (`Marca`,
  `Garantia`) si viven arriba, y la consulta busca en los dos sitios sin tener
  que saber en cual esta cada una.
- **El valor es un entero, no texto.** Con `valor: 8` salen 3 productos; con
  `valor: "8"`, cero y sin ningun error.

El arnes se probo rompiendolo: quitando `catalogo_categoria` a mano, 6 de las
12 comprobaciones se ponen en rojo y el paso 3 -- que usa el otro indice --
sigue en verde. Un arnes que no distingue eso no esta midiendo nada. El indice
se devuelve corriendo `mongo/001_productos.js`, que es idempotente.

La pagina **no se sube al repositorio** (esta en `.gitignore`): sus cifras son
de la base que tenga quien la corra, y una copia versionada envejeceria en
silencio.

### El pedido reconstruido ensena todo

En `/pedidos`, cada linea abre un modal con **lo que se pago** (presentacion,
vendedor, precio unitario, cantidad, subtotal), **el precio y el stock que
tenia esa oferta ese dia**, y el producto reconstruido del catalogo con su
categoria, sus caracteristicas y todas sus presentaciones, marcando la que se
compro.

Los dos precios salen de sitios distintos y **pueden diferir sin que ninguno
este mal**: el de la linea se congelo al comprar, el reconstruido es el ultimo
precio de ese dia. Cuando no coinciden, el modal lo dice.

Ojo con la trampa que tenia esto y que no daba ningun error: el tipo de
`traerProductoEnFecha` declaraba solo `nombre` y `descripcion`, asi que se
guardaban dos campos de los cinco que manda la ruta. El marcado de la
categoria y las caracteristicas ya estaba escrito y **no se ejecutaba nunca**.
Si esa ruta empieza a mandar un campo mas, se agrega en `ProductoEnFecha`
(`frontend/src/lib/pedido.ts`), que es de donde cuelgan las pantallas.

---

## Las cinco cosas que hay que saber, y no son obvias

**1. La resena es de un VENDEDOR sobre un PRODUCTO.** No del producto solo.
`resena(id_usuario, id_usuario_vendedor, id_producto_mongo, ...)`. Colgaba de
`oferta` y se cambio: `oferta` es unica por (usuario, producto, **variante**), y
nadie resena una variante.

**2. No hay FK de `resena` a `pedido`, a proposito.** La resena sin compra es la
senal de fraude mas fuerte; exigir la compra la borra del modelo. Jose David SI
la exige **en la aplicacion** (compra verificada, y **al mismo vendedor**), y eso
es reversible. Desde el 2026-08-30 **la semilla cumple esa regla**: las 86
resenas tienen su compra pagada detras, y las comprobaciones 10 y 11 de
`001_catalogo.sql` fallan la migracion si alguna deja de tenerla. Antes solo 2 la
tenian y el boton de escribir no aparecia casi nunca.

**3. El grafo tiene TRES nodos, no cuatro.** `:Usuario`, `:Resena`, `:Producto`
(mas `:Direccion`). **No hay `:Vendedor`**: en Mesh comprar no pide rol, asi que
partirlo dejaria la misma cuenta como dos nodos y **el anillo nunca cerraria**.
La resena es NODO porque conecta TRES cosas.

**4. El carrito de Redis guarda intencion, no precios.** Es
`id_oferta -> cantidad` y nada mas. El precio, el stock y el nombre se resuelven
al leerlo. **Consecuencia: el precio que se cobra es el de pagar.** Es el
pendiente #1.

**5. La semilla NO es idempotente.** 15 de sus 20 INSERT no tienen guardia, asi
que `001_catalogo.sql` solo carga contra una base vacia.

---

## Las trampas del entorno, que ya mordieron

**Git Bash convierte las rutas** que empiezan con `/` al pasarlas a `docker`.
`docker exec ... -f /migrations/x.sql` falla con una ruta de Windows. Solucion:
`export MSYS_NO_PATHCONV=1`.

**La imagen de Neo4j trata cualquier `NEO4J_*` como ajuste de `neo4j.conf`.** Una
variable `NEO4J_PASSWORD` se traduce al ajuste `PASSWORD`, que no existe, y el
contenedor se reinicia en bucle. Por eso la del healthcheck se llama
`MESH_NEO4J_PASSWORD`.

**El generador es determinista y `azar()` es UNA secuencia global.** Un sorteo
nuevo metido antes de la linea 1718 reescribe las 552 ofertas. La parte social
tiene su propia semilla (`azarSocial`) justamente para no arrastrarse con eso.

**Tras varios recargados de HMR la pestana de Chrome se congela** y
`Runtime.evaluate` da timeout. Se cierra y se abre otra.

**Un `as` de TypeScript es una promesa de quien escribe, no una comprobacion.**
Un cast de las lineas del carrito a `LineaPedido` compilaba limpio y ensenaba
"Pagar QNaN": sumaba un campo que no existia.

---

## Que falta

En `docs/PENDIENTES.md`, con su urgencia. Lo mas grave: **el precio se congela al
pagar y no al agregar** -- un cobro incorrecto silencioso.

Y de la Entrega 2, **2.5 puntos que no dependen de nadie**: la comparativa
grafos vs columnar (incluida la defensa de la NO elegida, que se olvida) y el
diagrama de arquitectura, que no existe. El ER no lo es.

---

## Donde esta cada cosa

```
migrations/          el esquema (013 sera la siguiente) y el generador de datos
etl/                 PostgreSQL -> MongoDB, y PostgreSQL -> Neo4j
neo4j/               el modelo del grafo y las 5 consultas de fraude
redis/               el carrito, el Lua del inventario limitado y sus arneses
pruebas/             arneses de las rutas: resenas.sh y carrito.sh
docs/                base-de-datos.md manda sobre el modelo;
                     GUIA-PRESENTACION.txt es el guion para defenderlo
backend/             de Jose David. NO SE TOCA. Su doc buena esta en
                     "elementos Generales/endpoints-*.md"
```
