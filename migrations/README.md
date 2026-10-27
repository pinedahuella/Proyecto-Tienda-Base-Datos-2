# Migrations

Los scripts SQL del esquema de Mesh y los conjuntos de datos de prueba.

## Dos clases de archivo

```
migrations/*.sql        el esquema
migrations/datos/*.sql  los datos de prueba
```

El esquema son las tablas, sus indices y los valores de los catalogos de estado.
Los estados son parte del esquema, no datos de prueba: sin ellos no se puede
insertar ni un usuario ni un producto.

Los datos son todo lo demas: las cuentas, las categorias, los productos, sus
variantes, sus caracteristicas, sus ofertas y sus historiales. Sirven para las
consultas de las entregas y para que el ETL tenga algo que llevar a Mongo.

## Como se nombran

```
001_nombre.sql
002_nombre.sql
```

Numero de tres digitos y guion bajo, en las dos carpetas. El numero manda: se
corren en orden y una tabla no puede referenciar otra que todavia no existe.

## En que orden corren

Primero `migrations/*.sql` en orden de nombre, y despues `migrations/datos/*.sql`
en orden de nombre. `arrancar.ps1` hace los dos pasos.

Pero los dos pasos NO se tratan igual, y conviene saberlo antes de tocar nada:
el esquema se reejecuta en cada arranque y los datos **solo entran en una base
vacia**. El por que esta abajo, en "El conjunto de datos solo entra una vez".

## Reglas del esquema

Una migracion ya corrida **no se edita**. Si algo hay que cambiar, se hace un
archivo nuevo con el numero siguiente. Editar una vieja deja tu base distinta a la
de los demas sin que nadie se de cuenta.

Cuidado con una migracion que falla a la mitad. La siguiente corrida la ve como
"ya aplicada" y se la salta, porque su primer `CREATE TABLE` choca con
`already exists` antes de llegar a lo que falto. Se sale borrando las tablas de
ese archivo y volviendo a correrlo.

Ese "ya aplicada" sale solo si la linea del `ERROR` de psql dice
`already exists`. Un `NOTICE` o un `DETAIL` con esas palabras no cuentan, y
cualquier otro error corta el arranque con exit 1.

Cada archivo hace una sola cosa y se puede leer solo.

**La excepcion de la 018 y la 026.** Las dos se editaron despues de corridas,
el 2026-09-30, y es la unica vez. La 033 quita columnas que ellas usan en
indices y llaves, y como el esquema se reejecuta en cada arranque, el arranque
siguiente se cortaba en ellas con `column does not exist`. Ahora esa parte va
dentro de un `\if` de psql que la salta cuando la columna ya no existe. Lo que
crean en una base nueva no cambio. Una migracion que despues quite algo que una
vieja crea fuera de un `IF NOT EXISTS` tiene el mismo problema.

**Una copia de datos dentro del esquema corre una sola vez.** Si una migracion
copia de una tabla vieja a una nueva con `ON CONFLICT DO UPDATE`, en el arranque
siguiente vuelve a pisar la nueva con lo viejo. La 031 y la 032 copian solo
mientras exista la columna que la 033 quita, y ese es su marcador.

## Los cuarenta y nueve archivos de esquema

Este encabezado decia "los doce" y la tabla llegaba hasta la 012. Despues dijo
"los catorce" con quince en la carpeta, "los veinte" con veintiuno, y "los veinticinco" con treinta y tres, "los treinta y tres" con treinta y nueve, "los treinta y nueve" con cuarenta y ocho, y "los cuarenta y ocho" hasta la 049. Es la misma trampa que este documento
avisa mas abajo para las comprobaciones: una lista escrita a mano caduca sin
avisar. Antes de creerle a esta, cuentalos:

```bash
ls migrations/*.sql | wc -l
```

Una linea cada uno, para no tener que abrirlos para saber donde buscar:

| Archivo | Que trae |
|---|---|
| `001_usuarios.sql` | usuarios, sus catalogos y los logs de acceso |
| `002_direcciones.sql` | direcciones, su catalogo de estados y su historial |
| `003_productos.sql` | categorias, productos, variantes, imagenes y sus dos historiales |
| `004_caracteristicas.sql` | las caracteristicas: su definicion, que ofrece cada categoria, que valor pone cada producto |
| `005_ofertas.sql` | `oferta`, `precio_historial` y el trigger que escribe el precio |
| `006_pedidos.sql` | pedido, pago y el kardex de `stock_movimiento` |
| `007_flujo_pedido.sql` | las funciones de armar y comprar: `crear_pedido`, `agregar_linea`, `comprar_pedido`, `cancelar_pedido`... |
| `008_direccion_exacta.sql` | la calle, en la fila viva y en el historial |
| `009_propuesta_productos.sql` | un vendedor propone una entrada del catalogo; `propuesta_producto` y `rechazo_producto` |
| `010_aprobacion_ofertas.sql` | una oferta nace `pendiente`: `fecha_aprobacion`, `id_usuario_aprobo` y `rechazo_oferta` |
| `011_resenas.sql` | la parte social: `comentario`, `resena` y `likes`, mas el trigger que recuenta los votos |
| `012_comprar_carrito.sql` | `comprar_carrito()`: crear el pedido, meterle todas sus lineas y comprarlo en una sola llamada |
| `013_precio_del_carrito.sql` | `agregar_linea()` acepta un `id_precio_historial` y lo usa en vez de buscar el vigente, validando que sea de esa oferta |
| `014_inventario_limitado.sql` | `oferta.es_inventario_limitado`: que ofertas se venden con el mecanismo de Redis en vez del stock con `FOR UPDATE` |
| `015_outbox_grafo.sql` | `evento_grafo` y su trigger sobre `resena`: la cola que mantiene el grafo de Neo4j al dia |
| `016_alerta_fraude.sql` | `alerta_fraude` y sus dos catalogos: las alertas de fraude del login. Y el aviso, en el comentario de `log_login` y `log_registro`, de que ya no se escriben |
| `017_alertas_fraude_extendidas.sql` | amplia `tipo_alerta_fraude` de 3 a 9 filas: las seis senales contra Elasticsearch (`toma_cuenta`, `viaje_imposible` y las tres `_lenta` con su version corta `ip_rotacion_cuenta`) |
| `018_notificacion_fraude.sql` | `notificacion_fraude`: una fila por cuenta afectada por una alerta, con su propia lectura -- lo que ve el usuario en `/perfil/alertas-fraude`, aparte de la revision del admin |
| `019_anillo_fraude.sql` | `anillo_fraude`, `anillo_fraude_resena` y su catalogo: persiste los anillos mutuo/ciclo/reiterado que antes solo detectaba y logueaba `AnillosDetectorService` |
| `020_descuentos_oferta.sql` | `porcentaje_descuento` en `oferta` y en `precio_historial`; el trigger del precio tambien escucha el descuento y `comprar_pedido()` cobra el precio con descuento |
| `021_regla_descuento_automatico.sql` | `regla_descuento_automatico`: una regla por oferta (si se venden N en M minutos, rebajar X% o abrir venta relampago por S segundos). Cuando se escribio solo era configuracion; el disparo llego al backend el 2026-09-25, y el comentario de la tabla que dice lo contrario se queda porque una migracion corrida no se edita |
| `022_regla_descuento_periodo.sql` | `regla_descuento_periodo`: descuento por calendario (dia, mes y anio de inicio y fin; lo que falta amplia la repeticion). Varias por oferta si no se pisan los dias, eso lo vigila el backend |
| `023_anillos_fraude_familia_b.sql` | los tipos 4 a 10 de `tipo_anillo_fraude` (patrones B.1 a B.7) y la unicidad de `anillo_fraude` pasa de `clave` a `(id_tipo_anillo_fraude, clave)` |
| `024_vectores_productos.sql` | la extension `vector`, la tabla `producto_vector` con indice HNSW y la funcion `productos_similares()`, para la recomendacion semantica de la Entrega final. La llena `etl/cargar_vectores.ps1` con Ollama. La columna `grupo` evita recomendar las copias que hace el generador de un mismo producto. Prueba, `python pruebas/recomendacion_semantica.py`, 15 OK |
| `025_hallazgos_evento_fraude.sql` | `tipo_hallazgo_evento` (ids 1 a 6 = F1 a F6), `hallazgo_evento_fraude` y su pivote de cuentas `hallazgo_evento_fraude_cuenta`, donde guarda el detector diario de fraude sobre eventos de ClickHouse. Copia del SQL de referencia del companero con candado de ids |
| `026_casos_fraude.sql` | los casos de fraude del agrupador de Jose David: `caso_fraude`, sus niveles, las reglas R-CASI y su puente, `evidencia_caso_fraude` (una fila por hallazgo real, con tres llaves exclusivas a `anillo_fraude`, `hallazgo_evento_fraude` o `alerta_fraude`) y sus cuentas, `anillo_fraude.detalle` y el estado `confirmada`. Es su SQL de referencia con las tres llaves en `ON DELETE CASCADE` y R-CASI-1 sin A.4 |
| `027_similares_con_indice.sql` | reescribe `productos_similares()` para que use el indice HNSW. La de la 024 comparaba con un JOIN y el indice no le servia; recorria las 3105 filas. Medido sobre los 3103 activos, 3,8 ms por producto contra 32 ms, y los mismos seis en 3099 de 3103. Lleva `enable_seqscan = off` solo mientras corre porque el planificador estimaba mal. La 026 son los casos de fraude |
| `028_vencimiento_oferta.sql` | `oferta.fecha_vencimiento_descuento` y `oferta.fecha_vencimiento_venta_limitada`, NULL es permanente. Desde aqui el vencimiento lo decide PostgreSQL y no una clave de Redis, que un Redis vaciado se llevaba con los descuentos permanentes. SQL de referencia de Jose David (37ad2e6), copiado tal cual |
| `029_catalogo_en_postgres.sql` | Comprar sin MongoDB, la copia del catalogo, del diseno de Jose David (6f89237). `producto_catalogo` (el nombre) y `variante_catalogo` (nombre, estado y portada de cada variante, por el par de ids), para que el carrito y el checkout no lean MongoDB. Mongo sigue mandando: la escribe el backend al editar un producto y el paso 7e de arrancar.ps1 la pone al dia con `etl/extraer_catalogo_postgres.js` |
| `030_evento_producto.sql` | El outbox `evento_producto`, hermano de `evento_grafo`. Triggers sobre `oferta` (precio, descuento, stock y estado) y sobre `resena` anotan el producto en la misma transaccion, una sola fila pendiente por producto, y un worker del backend recalcula sus numeros en MongoDB. Se comprueba a si misma al final |
| `031_senales_fraude.sql` | El refactor de fraude de Jose David (7453ffe). Un solo modelo para las tres familias: `senal_fraude`, una fila por (tipo, clave), con sus catalogos (`familia_senal_fraude`, `fuente_senal_fraude`, `tipo_senal_fraude` con los 25 tipos, `rol_cuenta_senal` autor o victima) y sus pivotes de cuentas, resenas, productos, pedidos e IP (`direccion_ip`). Copia una sola vez lo que habia en `anillo_fraude`, `hallazgo_evento_fraude` y `alerta_fraude` |
| `032_evidencia_y_aviso_por_senal.sql` | `evidencia_caso_fraude` y `notificacion_fraude` ganan `id_senal_fraude` y se enlaza lo que ya existia. Queda una notificacion por (senal, cuenta) y no una por ventana. Corre una sola vez |
| `033_sin_llaves_viejas_de_fraude.sql` | Se quitan las llaves viejas de esas dos tablas e `id_senal_fraude` pasa a NOT NULL. Se detiene si queda una fila sin senal. Las tablas viejas NO se borran, quedan sin escrituras |
| `034_evento_comentario.sql` | La cola `evento_comentario` y sus dos triggers (sobre `comentario` y sobre `resena`), hermana de `evento_producto`: lleva cada resena y cada respuesta, con su vector, al indice `mesh_comentarios` de Elasticsearch. Un like no encola nada. Del SQL de referencia de fa3281c, sin cambios |
| `035_senales_fraude_por_texto.sql` | La fuente `elastic` y los tipos `resenas_repetidas` y `anillo_de_texto`, en la familia `patron_resenas`. Salen del texto de las resenas en `mesh_comentarios` |
| `036_sin_producto_vector.sql` | Retira `producto_vector` y `productos_similares()`: desde fa3281c el vector de cada producto vive en su documento de `mesh_productos`. La 024 y la 027 no se editan; vuelven a crear la tabla vacia en cada arranque y esta la quita justo despues. La extension `vector` se queda |
| `037_senales_notas_incoherentes.sql` | Los tipos `notas_incoherentes_cuenta`, `_producto` y `_vendedor` (3305cf3): resenas cuyas estrellas contradicen su texto segun el clasificador de resenas |
| `038_senales_resenas_parecidas.sql` | Los tipos `resenas_parecidas_vendedor` y `_producto` (3305cf3): muchas resenas con una gemela de otra cuenta |
| `039_senales_resenas_canceladas.sql` | La fuente `postgres` y los tipos `resena_positiva_cancelada` y `resenas_negativas_canceladas_vendedor` (1f1f480): resenar y despues cancelar la compra |
| `040_vectores_en_postgres.sql` | Todos los vectores vuelven a PostgreSQL con pgvector, a pedido del profesor (25f0fe0): `vector_producto` y `vector_comentario`, 1 a 1 con FK y cascada, indice HNSW de coseno. No se llama `producto_vector` porque la 036 la borra en cada arranque. arrancar copia los vectores viejos de Elasticsearch la primera vez |
| `041_grafo_compras.sql` | Las compras al grafo de Neo4j (25f0fe0): la cola `evento_grafo_compra` por cuenta, con triggers en `pedido` y `pedido_producto`. La siembra del final corre una sola vez (con la cola vacia), no en cada arranque como en el SQL de referencia |
| `042_limpieza_fraude.sql` | La limpieza de fraude (25f0fe0): evidencia unica por (caso, senal), fuera `cadena_abierta`, `favor_devuelto`, `carrito_acaparador` y R-CASI-4, la granja de registros a la fuente `elastic`. La 031 y la 026 los vuelven a poner en cada arranque y esta los quita despues; cuesta tres numeros de la secuencia por arranque |
| `043_evento_oferta.sql` | La cola `evento_oferta` del buscador de ofertas (25f0fe0), con triggers en `oferta`, `producto_catalogo`, `variante_catalogo` y `usuarios`. Siembra una sola vez |
| `044_seguimiento_ofertas.sql` | Los "avisame" del comprador (25f0fe0): `seguimiento_oferta`, `aviso_seguimiento_oferta` (un aviso por seguimiento, UNIQUE) y su catalogo de tipos |
| `045_carrito_en_postgres.sql` | Redis nunca es la verdad (25f0fe0): el pedido `pendiente` de cada cuenta es su carrito (`version`, `fecha_ultima_actividad`, sin direccion hasta pagar, uno por cuenta) y `reserva_venta_relampago` con su catalogo de estados |
| `046_pedido_quitado.sql` | La cola `pedido_quitado` (2026-10-18): los quitar.sql de las semillas anotan aqui cada pedido que borran, y el ETL de compras borra sus lineas de `compra_producto` y `devolucion_producto` en ClickHouse. Antes ClickHouse se quedaba con ellas para siempre |
| `047_catalogo_respaldo.sql` | La copia del catalogo alcanza para que la tienda se vea sin MongoDB (2026-10-19): `producto_catalogo` suma `estado`, `id_categoria`, `descripcion` y `fecha_creacion`. Con Mongo caido el backend arma el catalogo, la ficha y las tarjetas desde esta copia (`backend/src/helpers/catalogo-respaldo.ts`); las llena el backend al escribir un producto y el paso 7e de arrancar |
| `048_buscador_respaldo.sql` | El buscador sale de PostgreSQL cuando Elasticsearch no responde (2026-10-20): las extensiones `unaccent`, `fuzzystrmatch` y `pg_trgm`, `mesh_normalizar()` (sin tildes y en minusculas, como el analizador del indice) y `mesh_coincide()` (la tolerancia de `fuzziness: AUTO`), con indices de trigramas sobre los nombres de `producto_catalogo` y `variante_catalogo`. La usa `backend/src/helpers/buscador-respaldo.ts` |
| `049_acl_ofertas.sql` | El ACL de la aplicacion, por oferta (2026-10-26, ADR-24): `tipo_permiso_oferta` (ver, editar, descuento), `permiso_oferta` (oferta, cuenta, permiso, quien lo dio y hasta cuando; uno por los tres, nadie a si mismo) y `auditoria_permiso_oferta`, sin llaves foraneas a proposito porque es un registro. Lo revisa `PermisoOfertaGuard` en `/compartidas/ofertas`; las rutas de lo propio no cambian. El catalogo va con `WHERE NOT EXISTS` para no gastar la secuencia en cada arranque |

**De la 034 a la 039, las senales que no salen del grafo.** Son del 2 al 4 de
octubre y siguen un mismo molde: el backend las detecta y la migracion solo
pone el catalogo (fuente y tipo, con `WHERE NOT EXISTS` para no quemar la
secuencia en cada arranque). Los SQL de referencia de Jose David usaban
`ON CONFLICT DO NOTHING`; es lo unico que cambia. Los ids quedan del 26 al 34
en una base nueva, pero el backend busca los tipos por nombre.

De la 011 a la 015 son de la Entrega 2, la 016 a la 023 de la Entrega 3, la 024 de la Entrega final, la 025 otra vez de la Entrega 3, y merecen una
linea mas de la que caben en la tabla.

**La 011 cierra el diagrama.** Con `comentario`, `resena` y `likes` las 42 cajas
del ER estan construidas; antes eran 39. (La base tiene 43 tablas desde la 015
y 46 desde la 016, pero `evento_grafo` NO es del ER: no modela nada del
negocio, es la cola de sincronizacion con Neo4j. Las tres de la 016 son
negocio y todavia no estan en el diagrama.) Y trae un cambio de modelo que hay que
leer en `docs/base-de-datos.md`: la resena cuelga del **producto y del
vendedor**, no de la oferta como se habia escrito en la Entrega 1.

**La 013 habilita el arreglo del precio congelado, y no lo termina.**
`agregar_linea()` ya acepta un `id_precio_historial` dentro de `p_linea` y lo
usa en vez de buscar el vigente, exigiendo que sea de **esa misma oferta**: sin
ese filtro, mandar el id de una fila de otra oferta seria elegir el precio a
voluntad. La firma no cambio, asi que la 012 no se toco y el campo viaja solo.

No bloquea la compra cuando el precio ya no es el vigente: **cobra el congelado
y lo dice**, con `precio_cambio`, `precio_congelado` y `precio_actual`. La base
informa; la politica la decide la aplicacion. Lo comprueba
`redis/prueba_carrito.sh`, y por las dos mitades: que un id inexistente se
rechace, y que uno valido se respete.

**La 014 es una sola columna con una decision grande detras.**
`oferta.es_inventario_limitado` marca que ofertas se venden con el mecanismo de
venta relampago de Redis en vez del flujo normal de stock. Lleva un indice
PARCIAL porque las consultas preguntan siempre cuales SI lo son, nunca cuales
no: un indice normal sobre un booleano donde casi todas las filas valen false
ocupa una entrada por oferta y el planificador lo descarta.

Que valga true NO significa que haya una venta abierta ahora mismo. Eso solo lo
sabe Redis, y confundir las dos preguntas es el error caro.

**La 015 es una cola, y su valor esta en DONDE se escribe.** `evento_grafo`
guarda que resenas faltan por llevar a Neo4j, y la llena un trigger sobre
`resena` que corre **en la misma transaccion** que la resena. Esa palabra es
todo el diseno: la alternativa obvia -- que el backend le escriba a Neo4j
despues de commitear -- tiene un hueco que no se puede cerrar, porque si el
proceso se cae entre el `COMMIT` y esa escritura la resena existe, no esta en el
grafo, y no queda constancia de que falte.

Tres cosas suyas que parecen errores y no lo son, y estan escritas enteras en la
cabecera del archivo:

- **No tiene llave foranea a `resena`**, y no puede tenerla: el trigger dispara
  tambien en el `DELETE`, o sea que insertaria una fila que apunta a un id
  recien borrado. Con FK, borrar una resena seria imposible. La migracion lo
  comprueba: falla si alguien le agrega una FK.
- **No guarda `entidad` ni `operacion`**, que es lo que proponia
  `docs/PENDIENTE-OUTBOX.md`. `entidad` tendria un solo valor posible; y el alta
  o la baja se INFIEREN releyendo la resena, que es mas robusto que guardar un
  'alta' viejo que puede contradecir a la base.
- **Su indice es PARCIAL** (`WHERE procesado_en IS NULL`), porque lo procesado
  se acumula para siempre y la cola no lo mira nunca.

La cola no se siembra en ningun sitio y no hace falta: esta migracion corre
antes que `migrations/datos/`, asi que cuando la semilla inserta sus resenas el
trigger ya existe y la cola se llena sola. Se vacia con `bash etl/cargar_grafo.sh`,
que al terminar marca como proyectado todo lo que hubiera pendiente.

**La 016 llego despues que el codigo que la usa.** `FraudeLoginService` ya
escribia en `alerta_fraude` y `GET /admin/fraude/alertas-login` ya la leia; la
definicion salio del SQL de referencia del backend
(`backend/elementos Generales/plan pendiente/fraude-login-eventos.sql`),
copiada columna por columna. Tiene que ser identica porque ese SQL ya se corrio
a mano en alguna base, y ahi el `CREATE TABLE IF NOT EXISTS` se salta: una
columna de mas aqui existiria en unas bases y en otras no.

Tres cosas suyas que conviene saber:

- **Es idempotente de verdad**, no por el perdon de "already exists" de
  `arrancar.ps1`: sale con codigo 0 en cada corrida. Medido, dos corridas
  seguidas, las dos `EXIT=0`, y tambien encima del SQL de referencia.
- **Los catalogos se insertan con `WHERE NOT EXISTS` y no solo con
  `ON CONFLICT DO NOTHING`**, porque el segundo quema un `nextval` por fila
  aunque no inserte nada. Medido en una tabla temporal: dos corridas con
  `ON CONFLICT` dejan la secuencia en 6 con tres filas. Con eso cada arranque
  le sumaria tres, y el cuarto tipo que se agregue un dia no saldria con el 4.
- **El backend fija los ids** (1, 2 y 3 en `models/alerta-fraude.ts`) y aqui
  no se escribe ninguno. Lo que cierra ese hueco es un candado al final del
  archivo: busca cada nombre y falla la migracion si su id no es el que el
  backend espera, y tambien si falta el indice unico que necesita el
  `ON CONFLICT` del backend. Sus mensajes no dicen "already exists", porque
  `Correr-Migraciones` perdona el error cuya linea de `ERROR` lo diga. Hasta
  el 2026-09-12 el perdon miraba la salida entera, y ahi estaban siempre los
  `NOTICE: relation ... already exists, skipping` de los `IF NOT EXISTS` del
  mismo archivo: el candado podia disparar y salir en amarillo como "ya
  estaba aplicada", con el arranque en verde. Al de la 015 le pasaba igual.

`log_login` y `log_registro` no se borran: guardan el historico y el ETL de
ClickHouse todavia las lee. Pero desde el 2026-09-10 no reciben filas, y eso se
dice en el comentario de cada tabla, que es lo que ensenan `\d+` y pgAdmin.

**La 020 reemplaza dos cosas que ya existian, y el orden la salva.** Pone
`porcentaje_descuento` (`numeric(5,2)`, NULL si no hay, `CHECK` de `0 < x < 100`)
en `oferta` y en `precio_historial`, y reemplaza el trigger de la 005 y el
`comprar_pedido()` de la 007. Sale del SQL de referencia del backend
(`backend/elementos Generales/plan pendiente/descuentos-oferta.sql`) con los
mismos nombres, porque ese SQL ya se corrio a mano en alguna base.

- **`oferta.precio` no se toca.** Sigue siendo el precio de lista. El precio que
  se ensena y se cobra no se guarda en ningun lado: cada consulta lo calcula con
  `ROUND(precio * (1 - COALESCE(porcentaje_descuento, 0) / 100), 2)`.
- **El trigger escucha `precio` y `porcentaje_descuento`.** Poner o quitar un
  descuento deja su fila en el historial igual que un cambio de precio, y esa
  fila guarda el %: una compra vieja con descuento se sigue leyendo bien.
- **`comprar_pedido()` redondea el precio unitario y despues multiplica** por la
  cantidad. El % sale de la fila de `precio_historial` a la que apunta la linea,
  no de la oferta viva.
- **La 007 se reejecuta en cada arranque** (es todo `CREATE OR REPLACE`) y
  reinstala el `comprar_pedido()` viejo; la 020 corre despues y lo vuelve a
  poner. La 005 no llega a su trigger en una base cargada (muere en su primer
  `CREATE TABLE`). Ninguna posterior toca estas dos funciones. Un candado al
  final falla la migracion si `comprar_pedido()` no menciona
  `porcentaje_descuento`, si hay mas de una, o si el trigger no escucha las dos
  columnas.
- **Es idempotente de verdad**, como la 016: sale con codigo 0 en cada corrida.
  Los `CHECK` se agregan solo si faltan, para no revalidar las tablas en cada
  arranque. Medido sobre una base desechable: esquema nuevo, dos arranques
  seguidos, una base de antes de la 020 con su catalogo cargado, y una con el
  SQL de referencia ya corrido a mano. Las cuatro en `EXIT=0`.

La regla de la venta relampago (no se abre sin descuento, y el descuento no se
quita con la venta abierta) vive en el backend y no aqui: si la venta esta
abierta solo lo sabe Redis.

**La 022 y la 023 salen tal cual de los SQL de referencia del companero**
(`backend/elementos Generales/plan pendiente/reglas-descuento-periodos.sql` y
`anillos-fraude-familia-b.sql`), que ya se corrieron a mano en su base. Por eso
son identicas columna por columna: un `IF NOT EXISTS` que se salta en su base
no puede dejar una columna de mas en la nuestra.

- **La 022 es idempotente** por `IF NOT EXISTS` y el trigger se reemplaza.
  Sin ella fallan con 500 las rutas de reglas por periodo y tambien las de
  descuento manual y venta relampago, porque la exclusion entre descuentos le
  pregunta a esta tabla en cada una.
- **La 023 es idempotente** porque el catalogo entra con `WHERE NOT EXISTS`
  (no quema la secuencia, ver la 016) y el constraint se quita y se pone solo
  si hace falta. Lo unico que se le agrega al SQL del companero es el candado
  del final, igual que el de la 019: falla si un id del 4 al 10 no es el que
  espera `models/anillo-fraude.ts`, o si la unicidad no quedo en
  `(id_tipo_anillo_fraude, clave)`, que es el `ON CONFLICT` del backend.
- **No se probaron contra una base viva** el 2026-09-25: se escribieron sin
  levantar nada. Lo primero del proximo arranque es mirar que las dos salgan en
  verde, y correrlo dos veces para ver que la segunda tambien.

La propuesta de casos de fraude (`docs/fraude-entrega3/02-reglas-backend.md`)
tenia reservada la 022. Paso a la 024, despues a la 025 y queda en la 026, porque la 024 es la
de los vectores de la recomendacion semantica y la 025 la de los hallazgos F1 a F6.

**La 012 no reemplaza a la 007: la COMPONE.** `comprar_carrito()` llama por
dentro a las mismas `crear_pedido`, `agregar_linea` y `comprar_pedido`, en vez
de copiar su contenido, justamente para que no existan dos versiones de las
reglas de negocio que se puedan desincronizar. Existe porque el carrito de la
Entrega 2 vivia en Redis: no habia una fila de `pedido` mientras la persona
compraba, asi que el pedido tenia que nacer entero al pagar. Desde la 045
(2026-10-17) el carrito vuelve a ser el pedido `pendiente` de PostgreSQL, el
backend compra con `comprar_pedido()` y `comprar_carrito()` queda en la base sin
uso. Lo que se paga esta
escrito de frente en su cabecera: con ella el precio se congela en el momento de
PAGAR y no en el de agregar al carrito.

## Los datos los escribe un generador

El archivo `datos/001_catalogo.sql` **no se edita a mano**: lo escribe
`datos/generador.js`.

```bash
node migrations/datos/generador.js
```

El motivo del reparto: el CONTENIDO (que categorias existen, como se llaman los
productos, que caracteristicas ofrece cada hoja, que cambio con el tiempo) se
escribe a mano dentro del generador, porque eso es criterio. El REPARTO (que
vendedor oferta que variante, con cuanto stock, a que precio) es mecanico, y lo
mecanico no se escribe a mano: se calcula.

Es **determinista**. El azar sale de una semilla fija, asi que correrlo dos
veces escribe el mismo archivo. Sin eso, cada corrida cambiaria el conjunto de
datos y nadie podria comparar dos bases.

## El conjunto de datos solo entra una vez

Aqui hay una diferencia de fondo con el esquema, y es un hecho medido, no una
sospecha: **`datos/001_catalogo.sql` NO es idempotente.** Correrlo por segunda
vez sobre una base que ya lo tiene FALLA.

De sus **26 `INSERT` de primer nivel, 17 no llevan ninguna guardia** -- ni
`ON CONFLICT` ni `WHERE NOT EXISTS`. Se recuentan mirando cada `INSERT` entero
y no con un `grep -c "NOT EXISTS"`, que cuenta de mas porque los hay tambien
dentro de los bloques `DO`; el total sale de
`grep -c "^INSERT INTO" migrations/datos/001_catalogo.sql`, que es lo unico que
no caduca. De los 9 guardados, tres son los primeros
(`usuarios`, `direcciones` y `direccion_historial`), y lo estan por otro motivo:
son las tablas que tambien escribe la aplicacion. Los otros seis son los del
tramo del anillo de fraude del final. El bloque social del final
(`DO $social$`) tambien esta guardado, con `NOT EXISTS` y un `ON CONFLICT DO
NOTHING`, y el de las compras que lo precede (`DO $compras$`) reconoce sus
pedidos por la fecha. Todo lo demas -- categorias, caracteristicas, productos,
variantes, imagenes, ofertas, precios y el kardex -- entra a pelo.

Medido sobre una base desechable, esquema completo y el archivo corrido dos
veces seguidas:

```
primera pasada   EXIT=0    102 productos, 202 variantes, 552 ofertas,
                           8 usuarios, 86 resenas, 115 comentarios, 46 likes
                           NOTICE: Conjunto de datos verificado

segunda pasada   EXIT=3
  psql:/migrations/datos/001_catalogo.sql:99: ERROR: duplicate key value
  violates unique constraint "idx_categorias_nombre_raiz"
  DETAIL: Key (nombre)=(Electronica) already exists.
```

Esa medicion es de ANTES del bloque de compras (`DO $compras$`, 2026-08-30) y
sus conteos caducaron con el. Lo que la medicion demuestra -- que la segunda
pasada falla y se deshace entera -- no cambia; los numeros de adentro si, y se
dejan como se midieron para no inventar una medicion que nadie corrio.

Los de hoy, contados contra una base recien creada con `.\arrancar.ps1
-Reiniciar`:

```
102 productos, 202 variantes, 556 ofertas, 11 usuarios,
90 resenas, 118 comentarios (28 de ellos respuestas), 62 likes,
13 pedidos y 101 lineas

  de eso, el anillo de fraude aporta: 3 usuarios, 4 ofertas,
  4 resenas, 3 pedidos, 4 lineas y 1 direccion compartida
```

**Lo que salva la situacion es que el archivo abre con `BEGIN;` (linea 33) y
cierra con `COMMIT;`**, asi que la pasada que falla se deshace ENTERA: tras la
segunda corrida los conteos seguian exactamente en los de la primera. Una
base ya cargada no se ensucia; simplemente no se carga nada. Sin ese
`BEGIN`/`COMMIT` quedaria a medias hasta la linea 99 de mas de cuatro mil, que
es mucho peor que fallar.

Ojo con el codigo de salida, porque cambia segun como se llame:

```bash
psql -f /migrations/datos/001_catalogo.sql                    # sale 0, aunque falle
psql -v ON_ERROR_STOP=1 -f /migrations/datos/001_catalogo.sql # sale 3
```

Sin `ON_ERROR_STOP=1` el error se imprime y psql contesta que todo fue bien. Un
script que no lo ponga no se va a enterar.

**Por eso `arrancar.ps1` se los salta si la base ya tiene productos**, con una
guardia que pregunta a la base misma (`SELECT count(*) FROM productos`) y no a
una tabla de control. Si hay productos, avisa en amarillo y sigue. Para
recargarlos hay que vaciar primero:

```powershell
.\arrancar.ps1 -Reiniciar
```

Y la contrapartida honesta: la guardia es **todo o nada por carpeta**. El dia
que se agregue un `datos/002_*.sql`, ese tampoco se va a correr solo sobre una
base cargada. No es un descuido del script -- estos archivos no se pueden correr
sobre una base con datos, punto. El arreglo de verdad seria ponerles guardias a
los 17 `INSERT`, y eso todavia no esta hecho.

## Ningun id se escribe a mano

Esta es la regla, y ya no tiene excepciones: **todo se busca por nombre o por
correo**.

```sql
INSERT INTO productos (nombre, id_estado_producto, id_categoria)
SELECT v.nombre, ep.id_estado_producto, c.id_categoria
FROM (VALUES ('Laptop Aurora 14', 'activo', 'Laptops')) AS v(nombre, estado, hoja)
JOIN estado_producto ep ON ep.estado_producto_nombre = v.estado
JOIN categorias      c  ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL;
```

Antes los id se escribian a mano y se llevaba la cuenta entre archivos, con una
excepcion para las tablas que tambien escribe la aplicacion (`usuarios`,
`direcciones`). Esa excepcion existia porque un `id_usuario = 9` funciona en la
maquina donde ese usuario existe y revienta en cualquier otra con una violacion
de llave foranea -- y solo se nota corriendo contra una base vacia.

La excepcion se volvio la regla: si escribir un id a mano es peligroso para dos
tablas, lo es para todas. De paso desaparecio el problema de coordinar la
numeracion entre archivos, porque ya no hay numeracion que coordinar.

## El conjunto se comprueba a si mismo

`001_catalogo.sql` termina con **trece** verificaciones dentro de un `DO`, y cada
una **falla la migracion entera** si no cuadra:

1. el saldo de cada oferta es la suma de su kardex
2. el precio de cada oferta es el ultimo de su historial
3. toda variante tiene la oferta de la tienda
4. ninguna oferta `activa` o `pausada` esta sin fecha de aprobacion
5. ninguna oferta `pendiente` o `rechazada` la trae puesta
6. ninguna oferta tiene aprobador sin fecha de aprobacion
7. toda direccion tiene calle, en la fila viva y en su historial
8. toda resena cuelga de un comentario RAIZ (`id_comentario_padre` en NULL)
9. `cantidad_likes` y `cantidad_dislikes` de cada comentario cuadran con `likes`
10. toda resena tiene detras una compra pagada **a ese vendedor**
11. ninguna resena esta fechada antes de la compra que la habilita
12. queda al menos un circulo cerrado de calificaciones (el anillo de fraude)
13. el descuento de cada oferta es el de la ultima fila de su historial

Las 4, 5 y 6 nacieron con la 010, la 7 con la 008, las dos que cierran la
parte social con la **011**, la 12 con el anillo de fraude y la 13 con la
**020**. Aqui decia "seis" y listaba seis, pero le faltaban
tres: las dos de la 011 y, desde antes, la 6. Una lista escrita a mano caduca
sin avisar; el archivo no. Antes de creerle a esta, contalos:

```bash
grep -c "RAISE EXCEPTION" migrations/datos/001_catalogo.sql
```

Las dos de la fecha de aprobacion (4 y 5) siguen siendo las mas importantes: esa
columna es lo que decide si un vendedor puede publicar su oferta sin que la
tienda la vea, asi que una fila mal puesta no es un dato torcido, es un permiso
regalado.

**La 8 y la 9 comprueban justo lo que la 011 NO puede exigir sola**, y por eso
existen:

La 8 es una invariante que ningun `CHECK` puede sostener, porque un `CHECK` no ve
otra fila: `resena.id_comentario` tiene que apuntar a una raiz. Si apunta a una
respuesta, el hilo se dibuja dentro de si mismo y la base no se queja jamas.

La 9 vigila una **copia**. `cantidad_likes` y `cantidad_dislikes` son un dato
derivado de `likes`, y la 011 los sostiene con un trigger que RECUENTA (no suma:
un contador incremental acumula error para siempre). Esta comprobacion no valida
el dato, valida que el trigger de verdad corrio -- que no es lo mismo que
suponer que existe. Cuenta `valor = 1` y `valor = -1` explicitamente, igual que
el trigger: si el candado contara de otra forma, aprobaria o fallaria midiendo
algo distinto de lo que vigila.

**La 10 y la 11 vigilan una regla que vive en el backend**, no en el esquema:
solo se puede calificar a un vendedor al que se le compro y se le pago ese
producto. La base no la puede exigir con una llave foranea -- para llegar del
vendedor calificado a la oferta comprada hay que cruzar `pedido_producto ->
precio_historial -> oferta` -- asi que nada la vigilaba de este lado, y la
semilla llego a tener 86 resenas con 2 compras detras. La 10 copia los `JOIN`
de `exigirCompraPagada()` tal cual, incluidos los dos filtros que es facil
dejarse: que la oferta sea **del vendedor calificado** y que el pedido no este
cancelado. Un candado que comprueba algo distinto de lo que el sistema exige
aprueba en verde datos que la aplicacion despues rechaza.

La 11 existe porque la 10 sola no ve el calendario: una resena de marzo con su
compra en mayo la pasa entera, porque la fila existe. La fecha de la resena vive
en su comentario raiz, y tiene que ir despues de la del pedido.

Un conjunto de datos que no se verifica es un conjunto de datos que miente en
silencio. Vale mas fallar al cargar que descubrirlo tres semanas despues.

## Un trigger se apaga a la mitad, a proposito

El trigger de `005_ofertas.sql` escribe una fila de `precio_historial` cada vez
que nace o cambia una oferta, y le pone `now()`. Eso es lo correcto para la
aplicacion, pero el conjunto de datos necesita fechas del **pasado**: sin ellas
no habria nada que reconstruir y la Entrega 1 se quedaria sin su demostracion.

Por eso el archivo abre con `ALTER TABLE oferta DISABLE TRIGGER`, escribe las
filas de precio con sus fechas, y lo vuelve a encender al final.

## La tienda arranca con descuentos

Para que la etiqueta de descuento se vea sin entrar al panel, el generador le
pone descuento a 13 ofertas de la tienda: un producto de cada ocho, empezando
por el sexto, en la primera variante con unidades, con 10, 15, 20, 25 y 30 por
ciento rotando. No usa `azar()`, para no correr la secuencia de todo lo demas.

- **Van al final del archivo**, despues de todas las compras, para no cambiar
  lo que cobraron los pedidos sembrados.
- **Cada una deja su fila en `precio_historial`** con el mismo precio, el % y
  fecha 2026-09-01, despues de cualquier otro precio del conjunto. La
  comprobacion 13 vigila que esa sea la vigente.
- **Los primeros cinco productos quedan fuera** porque los arneses y las demos
  eligen la primera oferta activa con stock por `id_oferta`, y asi ensenan el
  caso base (precio de lista igual a lo cobrado). Los que miran el precio ya
  usan la formula, asi que no es para que no fallen. Ninguna oferta de `ventas.*@mesh.com` lleva
  descuento sembrado, y ninguna esta en venta relampago.
- **Guardia:** solo se pone donde `porcentaje_descuento` es NULL.

Como todo el conjunto, esto solo entra en una base vacia. Una base que ya
estaba cargada antes de la 020 arranca con cero descuentos, y se ven despues de
un `.\arrancar.ps1 -Reiniciar` o poniendo uno desde el panel del vendedor. En
Mongo, `hay_descuento` y los precios rebajados de la tarjeta los escribe el
ETL (`etl/extraer.sql`), no este archivo.

**Y nacen permanentes.** Este archivo pone el % directo en `oferta`, sin
`fecha_vencimiento_descuento`, asi que desde la 028 son descuentos sin fecha y el
backend no los toca. Hasta el 2026-09-26 el vencimiento lo decidia una clave de
Redis, `mesh:oferta:<id>:descuento`, que este archivo no puede escribir, y
`arrancar.ps1` tenia que crearlas en su paso 5b-2. Ese paso ahora solo comprueba
que ninguno de la semilla tenga fecha.

## Como correrlas

La carpeta esta montada dentro del contenedor en `/migrations`.

```bash
docker exec -i mesh-postgres psql -U $DB_USER -d $DB_NAME -f /migrations/001_usuarios.sql
```

Todas de una, en orden:

```bash
docker exec mesh-postgres sh -c "for f in /migrations/*.sql /migrations/datos/*.sql; do psql -U $DB_USER -d $DB_NAME -f \$f; done"
```

Empezar de cero (borra todo):

```bash
docker compose down -v
docker compose up -d
```

## Comprobar

```bash
docker exec -it mesh-postgres psql -U $DB_USER -d $DB_NAME
```

Dentro de psql:

```
\dt     lista las tablas
\d      describe una tabla
\q      salir
```
