# TRASPASO -- Mesh (Bases de Datos 2)

**Para quien retome el proyecto: leete esto entero antes de tocar nada.**
Son cinco minutos y te ahorra el dia.

Ultima actualizacion: **2026-09-20**.

**Tambien el 2026-09-20: Kibana, dos campanas, el panel de fraude en pestanas, graficas de Tendencias, la demo de
Redis y el archivo de preguntas.** Nada de esto toca `backend/`.

```
Kibana               Servicio `kibana` 8.15.3 en docker-compose.yml, la misma version que Elasticsearch. Puerto
                     127.0.0.1:5601 (solo en local), NODE_OPTIONS con tope de 640 MB y mem_limit de 1 GB (gasta
                     cerca de 0.7 GB reales). Ahora son 11 contenedores: 10 corriendo y mesh-kibana-vistas.
mesh-kibana-vistas   Contenedor de un solo uso (servicio kibana-vistas) que corre docker/kibana/vistas.sh en cada
                     docker compose up: espera a Kibana y a los indices, crea las vistas de datos Productos
                     (mesh_productos) y Eventos de autenticacion (mesh_eventos_autenticacion, campo fecha) y
                     deja el rango de Discover en 60 dias. Termina en Exited (0), es lo esperado. Es idempotente.
                     arrancar.ps1 tiene el paso 9c "Vistas de Kibana" (espera hasta 3 min y muestra su log) y el
                     resumen final imprime http://localhost:5601. Las vistas viven en el volumen de
                     Elasticsearch: `-Reiniciar` las borra y se recrean solas
Dos campanas         La general, NotificacionesFraude.svelte, es de todas las cuentas: alertas de login de la
                     propia cuenta (GET /perfil/alertas-fraude, con Marcar leida). La del admin,
                     NotificacionesAdmin.svelte (escudo, "Avisos de admin"), solo sale con sesion de admin: lista
                     los anillos de resenas pendientes (GET /admin/fraude/alertas-resenas?estado=pendiente) con
                     enlace Revisar a /panel?s=fraude&t=resenas. No tiene Marcar leida: un anillo deja de contar
                     al marcarlo revisado o descartado. Leida por admin pide una tabla nueva, pedida en
                     docs/BACKEND-PENDIENTE.md
PanelFraude.svelte   Dos pestanas, Intentos de entrada y Resenas en anillo. Se ve una a la vez, las dos siguen
                     montadas y conservan filtro y pagina. El select de tipo esta agrupado en Por IP, Por cuenta
                     y Ubicacion y acceso (el backend sigue filtrando un solo tipo). /panel?s=fraude&t=resenas
                     abre directo en los anillos, y demo-anillo-resenas.ps1 abre ese enlace. Se quito la pestana
                     Demo del panel del admin (la de DemoFraude.svelte, mas abajo): las demos estan en la pestana
                     Comandos de las cuentas desarrollador
TendenciasAuto       Cada fila lleva insignia de puesto (los tres primeros tenidos), nombre en una linea con el
                     texto completo al pasar el cursor, cifra y barra medida contra el mayor de la tarjeta. La
                     unidad va en el subtitulo. En Compras en ascenso la barra es el periodo actual y una marca
                     vertical el anterior, con "nuevo" o "N veces". Sin ruta nueva
demo-redis-sin-ttl   .ps1 con -Accion crear, ver o borrar. Crea mesh:demo:sin_ttl:contador (string 42, TTL -1),
                     mesh:demo:sin_ttl:configuracion (hash, sin TTL) y mesh:demo:con_ttl:carrito_de_prueba (hash,
                     TTL de 600 s). ver lista todas las mesh:* con tipo y TTL, borrar solo quita las mesh:demo:*.
                     Son tres comandos nuevos del grupo Demo de Redis: el panel de comandos tiene 29 en cinco
                     grupos (comandos.txt)
PREGUNTAS-SUSTENTACION.md  En la raiz. 118 preguntas y respuestas para la sustentacion, con el archivo y las
                     lineas de cada cosa
```

**Al editar.** `panel-comandos/servidor.mjs` se carga en memoria: despues de editarlo, `.\panel-comandos.ps1 -Parar` y
luego `.\panel-comandos.ps1`, y recargar la pagina completa (la pestana guarda la lista al abrirse). El frontend se sirve
compilado: despues de editar un `.svelte`, Reiniciar el frontend en el panel o
`panel-comandos\servicios.ps1 -Accion frontend`.

**Verificado el 2026-09-20**, uno por uno y todos pasan: `pruebas/carrito.sh` (25 OK, 0 FALLA),
`redis/prueba_carrito.sh` (todo bien), `redis/prueba_concurrencia.sh` (1000 solicitudes con 50 clientes sobre 100
unidades, sin sobreventa), `neo4j/correr_fraude.sh` (10 OK), `pruebas/resenas.sh` (15 OK) y `pruebas/tendencias.sh`
(50 OK). Corridos con la API viva, las pruebas de login desde la misma IP subieron las alertas de multi cuenta por IP
del panel: es un efecto conocido, no un fallo.

**Lo del 2026-09-20, para Jose David: la alerta de viaje imposible no podia saltar y ya salta. No tienes que cambiar
nada.** Las consultas de `fraude-login/*.service.ts` (viaje imposible, toma de cuenta y las retrospectivas) piden
`id_usuario.keyword`, `tipo.keyword`, `resultado.keyword`, `ip.keyword`... y el indice
`mesh_eventos_autenticacion` tenia esos campos como `keyword` puro (y `ip` como tipo `ip`), asi que devolvian CERO
resultados sin ningun error. Se vio con un login real desde Singapur y otro desde Alemania: los dos estaban en el
indice, con su pais, y la consulta exacta del servicio daba 0. La plantilla `elastic/002_eventos_autenticacion.json`
es ahora version 2 y le pone un subcampo `.keyword` a esos campos (probado antes en un indice aparte); las consultas
sin `.keyword` siguen funcionando. **Al correr `.\arrancar.ps1` despues de jalar esto, tu indice se rehace solo desde
Mongo** (los eventos se vuelven a copiar, unos segundos). Con eso saltaron `viaje_imposible` (9943 km, 52 550 km/h) y
`toma_cuenta`. El detalle y las alertas estan en `docs/DEMO-OTRO-PAIS.md` y `elastic/README.md`. Lo mismo de otra
manera, si prefieres quitar el `.keyword` de tus consultas, vale y los subcampos sobran sin estorbar.
Ademas: `demo-entrar-otro-pais.ps1` (una ventana de Chrome por Tor para iniciar sesion desde otro pais), la demo de
otro pais que ya no apaga el backend, y el panel de comandos (`.\panel-comandos.ps1`, ver `comandos.txt`).
**Mesh tiene direccion publica: https://mesh.ledkid.com** (`.\mesh-publico.ps1`), por un tunel de Cloudflare nuevo y
aparte del de LEDKID, con su config en `~\.cloudflared\config-mesh.yml` (no va al repo). Solo publica la tienda; las
visitas se registran con su IP real. Va con las cuentas de prueba tal como estan (admin incluido), a proposito para
demostrar: ciérrala cuando no se use (`-Accion apagar`). La pestana Comandos del panel es solo para cuentas `desarrollador*`.

**Lo de la madrugada del 2026-09-19: el informe de la Entrega 2, el ER y el diagrama de arquitectura.**
Se corrieron `bash pruebas/etl_mongo.sh` (21 OK) y `.\arrancar.ps1` (termina en Listo). El informe se
rehizo entero, y con el salieron dos diagramas nuevos y tres cosas que hay que saber.

```
docs/generar-er.py            dibuja docs/diagrama-general.drawio y .png LEYENDO la base viva (information_schema
                              y pg_constraint). 50 cajas y 66 lineas. Falla si una tabla no tiene caja, si una
                              llave no tiene linea o si dos cajas se pisan. `--modulo fraude` saca la vista
                              recortada del informe. El ER de la Entrega 1 quedo en diagrama-general-entrega1.*
docs/generar-arquitectura.py  dibuja docs/diagrama-arquitectura.drawio y .png: seis motores y ocho rutas de datos
                              numeradas. `--informe` es la variante compacta para el Word y `--grafo` el modelo de
                              Neo4j. El del 2026-09-03 quedo como diagrama-arquitectura-2026-09-03.drawio
docs/informe-entrega2/        los .drawio y .png que usa el Word
```

**Lo que se descubrio al medir para el informe.** (1) Al borrar una resena el nodo `:Producto` queda huerfano en
Neo4j (52 contra 51 tras correr `pruebas/resenas.sh`), y el arranque solo se queja si el grafo tiene MENOS. No
afecta a ninguna consulta. `.\arrancar.ps1 -ReiniciarGrafo` lo reconstruye y se hizo al final. (2) El panel de
Tendencias rankea por ventana de dias y NO compara contra el periodo anterior: la consulta de ascenso vive solo
en la consola de ClickHouse. Esta pedida como ruta en `docs/BACKEND-PENDIENTE.md`. (3) `alertas-resenas` esta vacia
porque el anillo sembrado (marzo de 2026) queda fuera de la ventana de 60 dias del detector. La demostracion es
`neo4j/correr_fraude.sh`, que no usa ventana. Tambien se cerro el pendiente 18 (el ER).

**Y el mismo dia, tres pedidos del equipo que se hicieron en `frontend/` (2026-09-19).**

```
TendenciasAuto.svelte    NUEVO. El panel de Tendencias abre ahora en "Automaticas y mis consultas": los seis
                         rankings de 30 dias y "Compras en ascenso" se calculan SOLOS al abrir. Debajo, un
                         constructor de consulta propia (que medir, dias, cuantos, orden, comparar) que se puede
                         GUARDAR como automatica (localStorage, no la base). La pestana "Rankings" es la de antes.
                         Sin ruta nueva: todo sale de las seis de GET /admin/eventos/*
BloquearCuenta.svelte    NUEVO. Boton "Bloquear" junto a cada cuenta de las alertas de login y de los anillos, con
                         confirmacion en la misma linea y "Deshacer". Es PATCH /admin/usuarios/:id con
                         id_estado_usuario 3 (suspendido) y 1 (activo). No sale en la cuenta propia
AlertasFraudeUsuario     "Cambiar mi contrasena ahora" (cabecera y por alerta): abre Mi cuenta con el formulario de
                         contrasena ya abierto y el foco en el primer campo
PanelAdmin.svelte        Cuentas ahora tiene un BUSCADOR general (usuario, correo, nombre, rol, estado e id; sin
                         importar mayusculas ni tildes; varias palabras se piden todas). Se quito el aviso "la cuenta
                         de la tienda no se edita": la fila sigue con sus selects apagados, sin texto
demo-anillo-resenas.ps1  NUEVO. Arma un anillo de resenas de 2, 3 o 4 cuentas (registra, pasa a
                         vendedor, publica y aprueba una oferta, compra real y resena). Probado dos
                         veces, ciclo de 3 y par mutuo de 2, y detectado por AnillosDetectorService
                         en menos de 10 s las dos. Con el mismo -Prefijo es reentrante: no repite la
                         resena (409) ni la aprobacion. NO ES REVERSIBLE, deja pedidos y kardex reales
DemoFraude.svelte        NUEVA pestana Demo en el panel del admin (/panel?s=demo). Version visual de
                         demo-evento-fraude.ps1 y de la mitad de lo de arriba: dispara los tres
                         ataques de login por fetch, y crea (via GET /admin/usuarios + POST
                         /usuario/registro, NUNCA login) las cuentas de un anillo, sin tocar la sesion
                         del admin que esta usando la pagina -- ese era el riesgo real, POST
                         /usuario/login pone LA cookie de quien la llame. El resto del anillo (rol,
                         oferta, compra, resena) sigue siendo el .ps1: reescribirlo en el navegador
                         seria una segunda copia de la misma logica de negocio, que no es de este
                         lado. Cargar productos con semilla solo arma el comando para copiar, porque
                         una pagina no puede lanzar un proceso local
Cabecera (buscador)      El buscador de la cabecera es el MISMO para el admin: ruta publica (solo lo activo), con
                         `sesion` y registrando el clic en busqueda-clic. Antes usaba la de admin y no registraba nada,
                         por eso sus busquedas no subian en Tendencias. El catalogo del admin no se toco
Cabecera + panel/+page   "Admin" y "Mi perfil" ya son DOS cosas para el admin. El header trae un boton "Admin"
                         (solo en cuentas de admin) que abre /panel?s=reportes (Reportes, Ofertas, Catalogo,
                         Propuestas, Cuentas, Fraude, Tendencias), y "Mi perfil" abre /panel?s=cuenta (solo Alertas y
                         Mi cuenta). El ambito sale de la seccion que se mira, sin estado nuevo. Comprador y vendedor
                         no cambian. Los enlaces de Checkout y de la ficha a "agregar direccion" van a ?s=cuenta
```

**Lo que hay que saber de la comparacion.** La ruta solo entiende "los ultimos N dias", asi que el periodo anterior
se saca RESTANDO (ventana 2N menos ventana N) y solo es exacto cuando el total SUMA: compras y devoluciones. Las
vistas, el carrito y las busquedas cuentan sesiones o cuentas distintas y no se pueden restar, por eso no se ofrece
comparar ahi (la consulta que si lo hace esta en `clickhouse/README.md` y pedida como ruta en
`BACKEND-PENDIENTE.md`). Con los datos reales de hoy todo sale "nuevo" (0 a 45 la laptop) porque no hubo ventas en
el periodo anterior, y es correcto. Probado con Chrome sin ventana (protocolo de depuracion, Node 24 sin instalar
nada): las tarjetas cargan solas, el constructor consulta y guarda, lo guardado sobrevive a recargar, y bloquear y
deshacer cambio el estado de la cuenta a 3 y de vuelta a 1 (suspendida, el login da 401). `svelte-check` 0 errores.

**Lo de hoy (2026-09-18, sesion larga, varios pulls seguidos).** Jose David
amplio el catalogo de `tipo_alerta_fraude` a nueve senales (Redis + las
retrospectivas de Elasticsearch: `toma_cuenta`, `viaje_imposible` y las tres
`_lenta`), construyo la persistencia de los anillos de fraude en resenas
(`anillo_fraude`/`anillo_fraude_resena`), y el mismo dia elimino el panel EN
VIVO viejo (`GET /admin/fraude/anillos`) por redundante y renombro
`anillos-persistidos` a **`alertas-resenas`**. Del lado de aqui: migraciones
`017`-`019`, `PanelFraude.svelte` con las nueve senales y sin la seccion en
vivo, una campanita de alertas de seguridad en `Cabecera.svelte` (para
CUALQUIER cuenta, no solo admin -- `GET`/`PATCH /perfil/alertas-fraude`), y
dos scripts de demo (`demo-fraude-login.ps1` visual con SendKeys en modo
incognito, `demo-evento-fraude.ps1` por HTTP directo, mas rapido y confiable
para clase).

**Y despues, la misma sesion:** seis eventos nuevos de producto/buscador en
ClickHouse (`vista_producto`, `carrito_producto`, `compra_producto`,
`devolucion_producto`, `busqueda_realizada`, `busqueda_clic`) -- ver
`backend/elementos Generales/endpoints/endpoints-eventos.md`. El primer pull
de esta pieza llego ROTO (referenciaba 5 archivos nunca commiteados,
`npx tsc --noEmit` lo destapo con 8 errores); el segundo pull los trajo. Aqui
se formalizaron las cinco tablas nuevas en `clickhouse/001_esquema.sql`, se
creo el "sesion" analitico del navegador (`sesionAnalitica.ts`,
`sessionStorage`, NO es la cookie de login) y se engancharon los tres eventos
que si necesitan aviso del frontend (vista, agregar al carrito, clic en
busqueda) en sus pantallas. Probado en vivo con trafico real, no simulado.

**Y al final del dia, el ultimo pull (`3255560`), que cambio la respuesta a lo
anterior.** Las seis rutas `GET /admin/eventos/vista|carrito|compra|devolucion|busqueda|busqueda-clic`
dejaron de ser un explorador de filas crudas: David las reescribio como
**rankings** (`dias`, `limite`, `direccion`), y agrego
`GET /productos/mas-vendidos` (publica, un worker recalcula un ZSET de Redis
cada 10 minutos desde `compra_producto`). Las dos rutas que el panel de
tendencias esperaba desde hace semanas (`/admin/eventos/tendencias` y
`/admin/eventos/fraude/ip`) **ya no van a existir**: el panel se reescribio
contra los seis rankings, y el fraude por IP lo cubre la pestana Fraude.

Lo que se hizo de este lado, todo medido con el backend vivo:

```
frontend PanelTendencias.svelte   reescrito: seis pestanas, ventana, cuantos y orden
frontend routes/+page.svelte      el estante "Lo mas vendido ahora" arriba del catalogo
                                  (solo sin filtros), con la tarjeta pasada a un snippet
pruebas/tendencias.sh             el arnes numero 13, 45 OK
pruebas/etl_mongo.sh              el 14, 21 OK. El ETL de Mongo sobre una COPIA de la base
pruebas/etl_compras.sh            el 15, 22 OK. El ETL de compras a ClickHouse
redis/mas_vendidos.sh              ver el ranking de mas vendidos y reconstruirlo ya, sin esperar
                                  los 10 minutos del worker. Documentado en redis/README.md, 2b
```

**La corrida final de los quince arneses, 2026-09-19, en serie y de uno en uno.** 322 comprobaciones
contadas y 0 FALLA, con los tres que no imprimen un numero (`redis/prueba_carrito.sh`,
`redis/prueba_concurrencia.sh` y `neo4j/correr_fraude.sh`) en verde:

```
resenas 15        carrito 25         notas 10           busqueda 13        ofertas_paginadas 40
alertas_login 52  eventos 31         tendencias 50      etl_compras 22     etl_mongo 21
mongo/demostracion_indices 12        falla_checkout 31 (con su 1 "para declarar en la entrega")
```

No salio verde a la primera, y las dos causas eran de mi lado:

**1. `alertas_login.sh` se paro en el terreno.** Comparaba el catalogo `tipo_alerta_fraude` contra TRES
filas copiadas dentro del arnes, y desde el 2026-09-18 David lo tiene en nueve. Decia que la base estaba mal
cuando el viejo era el arnes. Ahora lee los ids de `backend/src/models/alerta-fraude.ts` y no los copia:
52 OK.

**2. ClickHouse rechazaba consultas por falta de memoria, y `eventos.sh` dio rojo dos veces.** Medido:
105 MiB de memoria rastreada contra 1.09 GiB residente, y `system.errors` con 68099 veces
`MEMORY_LIMIT_EXCEEDED`. El tope de 1 GiB se mide contra la residente, y la llenaban los logs de sistema del
propio ClickHouse: `trace_log` 17.5 millones de filas (319 MiB), `text_log` 3.8 millones (169 MiB),
`asynchronous_metric_log` 52 millones, mas que todos los datos de eventos. Arreglo de raiz en
`clickhouse/config.d/limites.xml`: se apagan siete logs de sistema (`remove="1"`) y se dejan `query_log`,
`part_log` y `error_log`. Se valido antes en un contenedor desechable contra un control (el control crea los
nueve logs, con la config nueva quedan dos), porque un elemento mal puesto tumba el arranque sin mensaje.
Aplicado: el contenedor paso de 1.28 GiB a 306 MiB, los datos intactos, y `eventos.sh`, `tendencias.sh` y
`etl_compras.sh` en verde. **Una base hecha antes necesita reiniciar `mesh-clickhouse` para tomar el
archivo**, y borrar a mano los logs viejos (`DROP TABLE system.trace_log` y los otros seis) o seguiran ocupando
disco.

Dos cosas que hay que decir. `falla_checkout.sh` hizo compras reales (deja pedidos, pagos y movimientos de
stock; su cabecera lo avisa). Y el lote `generado-42` de ClickHouse ya no existe: una ejecucion de
`-BorrarVistas 42` a las 22:19 lo borro sin que yo la haya lanzado (probablemente un proceso paralelo de esta
sesion). Como desde el 2026-09-19 ninguna pantalla lee lo sembrado, no se volvio a sembrar.

**El pull del 2026-09-19: cuatro decisiones de David que tocaron mis capas.**

```
GET /vendedor/ofertas/paginado   el filtro `activo` (true/false) se reemplazo por `estado` (uno de los cinco).
                                 Con el, total_ofertas da el total EXACTO de cada estado. OfertasVendedor.svelte
                                 ya pagina de verdad (20 por pagina) y sus seis pestanas salen de seis peticiones
                                 de UNA oferta. pruebas/ofertas_paginadas.sh adaptado: 40 OK, tres mutantes
trustProxy: 'loopback'           agregado en main.ts. copia-backend.ps1 ya lo preveia (si el repo lo trae, la copia
                                 no parcha nada). Cierra el pendiente 19
rankings y mas vendidos          solo lote 'real', sin parametro (ver "Los hallazgos" abajo, el 1). Adaptados:
                                 redis/mas_vendidos.sh (y su candado), PanelTendencias, pruebas/tendencias.sh (50 OK)
comprarPedido                    David lo evaluo y lo descarta: es codigo viejo que ninguna pantalla usa. No se
                                 engancha, y BACKEND-PENDIENTE ya no se lo pide
```

**Lo unico del panel de ofertas que sigue sin resolverse de raiz es el buscador por texto.** El backend no
busca por texto (los nombres viven en Mongo), asi que cuando se escribe algo el panel pide la lista completa
(1.2 MB con las 2243 ofertas de la tienda) y filtra en el navegador; al vaciar la caja vuelve a las paginas sin
pedir nada. Es una concesion, y la peticion de un `q` en la ruta paginada esta escrita en
`docs/BACKEND-PENDIENTE.md`. Probado en el navegador con la tienda: pagina 1 y 2 distintas, pestana vacia con su
mensaje, busqueda de "laptop" da 159 de 2243.

**Y despues, la misma noche: el ETL y las demos que arrancaban en cero.** Se pidio revisar
si el ETL reflejaba lo que David cambio y si la base columnar se podia llenar de forma nativa.
La respuesta a la primera fue **no**, y la revision destapo tres cosas. Todo esta en
`etl/README.md` (seccion "Lo que cambio el 2026-09-18"); aqui va lo que hay que saber.

```
etl/cargar.js            ya no reemplaza los productos que edito la aplicacion (el backend edita SOLO
                         en Mongo y el replaceOne deshacia la edicion y borraba sus eventos), y marca
                         pendiente_busqueda para que el worker reindexe. Probado sobre una copia
etl/cargar_notas.js      lo mismo: marca solo cuando la nota cambio
etl/cargar_compras.sh    NUEVO. Copia stock_movimiento a compra_producto y devolucion_producto:
                         141 ventas en PostgreSQL contra 2 filas en ClickHouse. Cuadra, no duplica
clickhouse/lote/         NUEVO generar_actividad.sql: carrito, compra, devolucion, busquedas y clics,
                         derivados de las vistas. Antes 4 de las 6 tablas estaban en cero
clickhouse/reparar_orden_compras.sh   reconstruye la clave de ordenacion (ver abajo)
arrancar.ps1             corre el gemelo de compras en cada arranque, y -Vistas siembra tambien la actividad
redis/mas_vendidos.sh    ver y reconstruir el ranking sin esperar los 10 minutos del worker
```

**Cuatro hallazgos que no son obvios.**

**1. Lo sembrado YA NO se ve en Tendencias, por decision de David (2026-09-19).** Las seis rutas de
`/admin/eventos/*` y el ranking de mas vendidos cuentan SOLO `lote = 'real'`, fijo y sin parametro. Lo que
siembra `clickhouse/lote` (lote `generado-N`) no aparece en ninguna de esas pantallas ni en el estante de la
portada. Lo que si las llena son datos reales: las ventas que copia `etl/cargar_compras.sh` desde PostgreSQL
(143 lineas de venta con fechas desde enero) y todo lo que se haga usando la app. Medido ese dia, eventos
reales por ventana de 7 / 30 / 365 dias: compras 5 / 45 / 143, devoluciones 3 / 7 / 7, vistas 22, carrito 12,
busquedas 0 y clics de busqueda 0. Por eso el panel de Tendencias abre en **30 dias** y no en 7 (con 7 se ve
pobre). Las busquedas estan en cero DE VERDAD y solo se llenan buscando en la caja de la cabecera y abriendo un
resultado. `generar_actividad.sql` y `-Vistas` siguen funcionando, pero hoy ninguna pantalla los lee: sirven
para consultar ClickHouse a mano en http://localhost:8123/play.

**2. La clave de ordenacion de las tablas de compra perdia unidades.** Con `(id_producto, fecha,
id_pedido)`, dos ofertas del mismo producto en el mismo pedido se colapsaban: el pedido 121 tenia
3 lineas y ClickHouse guardaba 2. Ahora lleva `id_oferta`. Las bases hechas antes necesitan
`bash clickhouse/reparar_orden_compras.sh` (arrancar.ps1 lo hace solo).

**3. El backend solo anota las compras del carrito.** Lo comprado antes del 2026-09-06, la semilla y los
pedidos pendientes que se pagan despues (`comprarPedido`) nunca llegaban a ClickHouse. Pedido a David en
`BACKEND-PENDIENTE.md`. Mientras tanto `cargar_compras.sh` lo compensa, pero solo cuando corre.

**4. La copia de logueos escribia en UTC y ClickHouse lee en Guatemala**: 6 horas corrida (el login 359,
de las 16:53, salia a las 22:53). Nadie lo veia porque esa copia esta congelada. Ya se arreglo: la fecha
viaja como epoca y las 334 filas se recopiaron, ver `etl/README.md`, seccion 4.

**Tres salvedades honestas.** (a) El dano de `cargar.js` era estructural, no hecho: hoy ningun producto
de PostgreSQL esta editado desde la aplicacion, y los 16 eventos de modificacion de Mongo coinciden con
PostgreSQL. (b) En mi prueba del gemelo PowerShell borre tambien el pedido 121 del destino y las dos filas que
el backend habia escrito para el se recuperaron desde PostgreSQL con IP `::` en vez de la local: dato de
desarrollo, pero una perdida real. (c) `pruebas/eventos.sh` dio 1 FALLA una vez, justo despues de otra prueba, y
tres corridas seguidas despues dieron 31 OK: no se reprodujo y no se pudo explicar.

**La metrica NO es la misma en las seis pestanas**, y es lo primero que dice la
pantalla: vista y busquedas cuentan sesiones DISTINTAS, carrito cuentas
DISTINTAS y compra y devolucion SUMAN unidades. El arnes siembra duplicados a
proposito para que un `COUNT(*)` dificilmente pase por bueno: vistas de una
misma sesion, dos filas de la misma cuenta, cantidades de 5 y 3.

**Tres cosas que no son obvias.**

**1. Estas rutas cuentan SOLO `lote = 'real'`** (desde el 2026-09-19, decision de Jose David, sin
parametro para pedir lo contrario). El panel lo dice en una nota. Antes contaban tambien lo sembrado y esta
nota decia lo contrario: un ranking que mezcla lo medido con lo sembrado tiene forma de hallazgo, y David lo
cerro por el lado bueno.

**2. Un producto borrado sale sin id.** La ruta contesta `producto: null` y el
id se pierde por el camino, asi que la fila se pinta como "Producto que ya no
existe en el catalogo", con su total y sin enlace.

**3. Sembrar a mano en ClickHouse pide `--database`.** `clickhouse-client`
entra a `default`, donde las seis tablas TAMBIEN existen: el `INSERT` sale
bien y el backend, que mira `mesh_eventos`, no ve ni una fila. Paso midiendo
esto (los rankings salian vacios con datos "sembrados") y se perdio un rato
creyendo que era la ruta. Ya limpiado; el arnes lo lleva puesto.

Antes de eso, el 2026-09-10 al 2026-09-12: Jose David mudo el log de inicio
de sesion a MongoDB, lo copia a Elasticsearch y detecto tres senales de
fraude con Redis (commit `e38e9a3`). Esa ronda sigue en la seccion "El fraude
del inicio de sesion" mas abajo, con sus cifras del 09-12 (ya superadas por
las nueve senales de hoy, pero el razonamiento de fondo no cambio).

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
> 6. `docs/CONSISTENCIA-CHECKOUT.md` -- que pasa si algo falla al cobrar
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
> **Antes de decir que algo funciona, MIDELO.** Este proyecto tiene DIECIOCHO arneses:
> `bash pruebas/resenas.sh`, `bash pruebas/carrito.sh`, `bash pruebas/notas.sh`,
> `bash pruebas/busqueda.sh`, `bash pruebas/eventos.sh`,
> `bash pruebas/alertas_login.sh`, `bash pruebas/ofertas_paginadas.sh`,
> `bash pruebas/tendencias.sh`, `bash pruebas/etl_mongo.sh`, `bash pruebas/etl_compras.sh`,
> `bash pruebas/falla_checkout.sh`, `bash redis/prueba_carrito.sh`,
> `bash redis/prueba_concurrencia.sh`, `bash neo4j/correr_fraude.sh`,
> `.\mongo\demostracion_indices.ps1`, y los tres que PASAN POR EL BACKEND (20 de
> septiembre), `bash pruebas/carrito_vencimiento.sh`, `bash pruebas/oferta_limitada.sh`
> y `bash pruebas/anillos.sh`.
>
> De los que prueban Redis y Neo4j, `redis/prueba_carrito.sh`,
> `redis/prueba_concurrencia.sh` y `neo4j/correr_fraude.sh` NO pasan por el backend,
> hablan directo con las bases, y cada uno lo dice en su cabecera con el que si pasa.
> `oferta_limitada.sh` y `anillos.sh` crean cuentas y `anillos.sh` deja compras reales.
>
> Los dos nuevos tambien van de uno en uno, y los dos lo dicen en su cabecera:
> `alertas_login.sh` mide contadores por IP, y en local la IP es la misma para
> todo; `ofertas_paginadas.sh` necesita que la lista no se mueva mientras la
> recorre.
>
> **`falla_checkout.sh` PARA CONTENEDORES a proposito**, asi que no se corre a la
> vez que ningun otro. Y compra de verdad: deja pedidos, pagos y movimientos de
> stock que no se deshacen. Su cabecera lo dice y los imprime al terminar.
>
> Y ojo con correr dos arneses A LA VEZ. Paso el 2026-09-06 sin querer, con dos
> sesiones tocando `pruebas/eventos.sh` al mismo tiempo: dio 8 FALLA, todos por
> pares (una fila donde se esperaba una, dos donde se esperaba una), y ninguno
> era del codigo. Un rojo de un arnes solo vale si era el unico corriendo.
>
> Y `prueba_concurrencia.sh` mide TIEMPOS con 50 clientes a la vez: en una
> maquina ahogada de memoria da rojo sin que nada este roto. Si sale mal,
> correlo solo antes de creerle.
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
.\arrancar.ps1              # los 8 contenedores, migraciones, semilla y ETL
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
| ClickHouse | **8123** HTTP, 9010 nativo | consola en **8123/play**, sin instalar nada |
| PostgreSQL | 5432 | pgAdmin en **5050** |
| MongoDB | **27018** | dbgate en **3001** |
| Redis | 6379 | RedisInsight en **5540** |
| Neo4j | 7687 (bolt) | Browser en **7474** |
| Elasticsearch | **9200** | sin contrasena, solo en local |
| backend / frontend | 3000 / 5173 | |

Mongo es 27018 por fuera a proposito: Windows puede tener un MongoDB de servicio
ocupando el 27017, y ese contestaria primero con una base vacia.

---

## Que esta HECHO y probado

### Entrega 1 -- cerrada

Las **42 tablas** del diagrama (43 desde la migracion 015, que agrega
`evento_grafo` y NO esta en el ER porque no es del modelo de negocio: es la cola
de sincronizacion con Neo4j; y 46 desde la 016, cuyas tres tablas de alertas SI
son negocio y todavia no estan dibujadas), el catalogo en MongoDB con su ETL, el historial
por eventos, los indices y las agregaciones. El informe lo hizo el equipo.

### Entrega 2 -- lo construido

| Pieza | Estado | Como se comprueba |
|---|---|---|
| **Carrito sobre Redis** | funcionando de punta a punta | `bash pruebas/carrito.sh` (25 OK) |
| **Resenas, comentarios y likes** | 7 rutas, pantalla completa | `bash pruebas/resenas.sh` (15 OK) |
| **Inventario limitado (Lua)** | **enchufado de punta a punta** | `bash redis/prueba_concurrencia.sh` |
| **Venta relampago, el interruptor** | boton en el panel del vendedor | entra como `ventas.norte@` a `/panel` |
| **Grafo de fraude (Neo4j)** | ETL + 5 consultas | `bash neo4j/correr_fraude.sh` |
| **Panel de fraude, de punta a punta** | `GET /admin/fraude/anillos` + `PanelFraude.svelte` | entra como `admin@mesh.com` a `/panel` |
| **Reportes de admin** | ventas y reservaciones + `PanelReportes.svelte` | lo mismo |
| **Los indices de Mongo, demostrados** | 4 pasos, 12 comprobaciones | `.\mongo\demostracion_indices.ps1` |
| **El pedido reconstruido, completo** | modal con lo pagado + precio y stock de ese dia | entra como `compradora.norte@` a `/pedidos` |
| **La nota en el catalogo de Mongo** | `resenas_promedio` y `resenas_total` en cada documento, con su indice | `.\arrancar.ps1 -Etl` y mirar un producto en Mongo |
| **La nota alcanza a los de Mongo, y se apaga** | tercera etapa del ETL, con `--notas` | `bash pruebas/notas.sh` (10 OK) |
| **Resenar desde el pedido** | boton en `/pedidos`, lleva a la ficha con el formulario abierto | entra como `compradora.norte@` a `/pedidos` y abre un pedido pagado |
| **El buscador de la Entrega 3** | Elasticsearch, indice y ETL. Falta su ruta | `bash pruebas/busqueda.sh` (11 OK) |
| **Documento de consistencia del checkout** | los 5 puntos de la Entrega 3, escritos | `docs/CONSISTENCIA-CHECKOUT.md` |
| **El choque de los dos repartidores de id, visible** | un paso mas en el arranque | sale solo en `.\arrancar.ps1` |
| **Generador incremental de productos** | lotes reproducibles por semilla | `.\arrancar.ps1 -Productos 300 -Semilla 7` |

### La venta relampago, ya completa de punta a punta

Cerrada el **2026-09-03 por la noche**, y son tres piezas de tres personas
distintas que por fin encajan:

```
migrations/014_inventario_limitado.sql   la columna oferta.es_inventario_limitado
redis/inventario_limitado.lua            sembrar / reservar / redimensionar /
                                         confirmar / devolver, todo atomico
backend  POST|DELETE /vendedor/ofertas/:id/venta-limitada   el interruptor
frontend OfertasVendedor.svelte          el boton que lo pulsa
```

Hasta esa noche faltaba el interruptor, y sin el las otras tres no servian de
nada: el mecanismo entero estaba escrito y probado y **no habia forma de
encenderlo desde la aplicacion**. Jose David escribio las dos rutas (su
propuesta esta en `backend/cambio_propuestas/2026-09-03_2300-venta-relampago-rutas-vendedor.md`)
y de paso agrego `es_inventario_limitado` a los tres GET de ofertas, que es el
campo sin el cual el panel no podria saber si pintar "Abrir" o "Cerrar".

**Como se ve:** entra como `ventas.norte@mesh.com` a `/panel`. Cada oferta
activa tiene un boton naranja "Abrir venta relampago". Al pulsarlo se despliega
un panel con el numero de unidades que se van a apartar y un campo de duracion;
al abrirla, la fila se marca con la pastilla "Venta relampago abierta" y el
boton pasa a "Cerrar la venta".

**Medido en el navegador, y comprobado contra las dos bases:**

```
antes                PG es_inventario_limitado = false   Redis EXISTS = 0
abrir con 3600 s     PG = true   Redis stock 8, reservado 0, TTL 3578
                     la fila se marca y el boton cambia solo
cerrar               PG = false  Redis sin ninguna clave  stock intacto en 8
```

Tres cosas de esta pantalla que no son obvias y que costaron:

**1. Cerrar descarta las reservas en curso.** El `DELETE` borra las dos claves
de Redis de la oferta. Las unidades no se pierden (vuelven al stock de
PostgreSQL), pero quien tuviera unidades apartadas se queda sin ellas, y cerrar
**no confirma** ninguna compra. Por eso el boton no cierra directo: pide un clic
mas y lo dice antes, en el propio panel.

**2. El plazo de la venta y el plazo del comprador son cosas distintas.**
`duracion_segundos` es cuando cierra la venta ENTERA (0 es sin vencimiento, tope
7 dias). Lo que cada persona tiene apartado antes de pagar son 15 minutos y es
fijo. Se confunden solos, y confundirlos sale caro: quien quiere "quince
minutos" escribe 900 pensando en lo segundo y cierra su propia venta en quince
minutos. El panel lo dice con todas sus letras debajo del campo.

**3. Abrir con stock 0 es una bomba de tiempo, y el backend NO lo impide.**
`sembrar` acepta un stock de cero y contesta 201. Lo que se siembra es una FOTO
del stock en ese instante y ya no se vuelve a mirar PostgreSQL, asi que si
despues se reponen existencias con Editar, PostgreSQL sube y Redis se queda en
cero: la oferta pasa a ser incomprable **sin ningun error, sin ninguna marca y
sin nada que lo explique**. Salio pulsando el boton sobre una oferta agotada de
la tienda. El panel lo corta antes de llamar.

**4. Una venta que vence sola deja la columna marcada para siempre.** Es un
hallazgo del 2026-09-03 y no estaba escrito en ningun sitio. Medido:

```
abrir con duracion_segundos 5   PG es_inventario_limitado = true   Redis TTL 2
esperar a que venza             claves de Redis = 0
                                PG es_inventario_limitado = TRUE   <-- sigue marcada
                                y el panel sigue diciendo "Venta relampago abierta"
```

La razon es de una linea: **Redis no puede escribir en PostgreSQL**. El `EXPIRE`
se lleva las dos claves y nadie apaga la columna. El resultado es una oferta que
el panel ensena como en venta relampago cuando esa venta ya no existe.

Lo que **no** rompe, y conviene saberlo antes de asustarse: al comprador no le
pasa nada. `CarritoService` decide el camino con `existeVentaLimitada()`, que es
un `EXISTS` contra **Redis** y no la columna, asi que sin claves la oferta se
compra por el flujo normal de PostgreSQL. El que miente es el panel del vendedor.

Y se sale del atasco con el mismo boton: pulsar "Cerrar la venta" sobre una
oferta en ese estado contesta 200 y deja la columna en `false`. Medido. O sea que
hay recuperacion y no hace falta tocar la base a mano.

El arreglo de fondo no es del frontend: o la columna se deduce de Redis en vez de
guardarse, o alguien tiene que apagarla al vencer. Queda anotado.

**Y el boton esta en las DOS vistas del panel**, no solo en la lista. Un
vendedor normal entra por "Mis ofertas"; la tienda y el admin entran por "Tus
ofertas, por producto", que es otra rama del marcado. Ponerlo solo en la lista
habria dejado a la cuenta con mas ofertas sin poder abrir ni una. Las dos
comparten el mismo `{#snippet panelRelampago}`, que es el primer snippet del
proyecto y existe para que no haya dos copias que corregir.

Lo unico que queda del bloque, y nunca fue del alcance, es la activacion
automatica por "calor" que propuso el profesor.

### El stock de verdad ya llega a la pantalla

**Hecho el 2026-09-03, y arregla una mentira que se veia en la ficha.**

Mientras una venta relampago esta abierta, `oferta.stock` de PostgreSQL **queda
congelado** en el valor que tenia al abrirla: quien manda es el contador de
Redis. La ficha ensenaba el de PostgreSQL, asi que decia "7 unidades" con el
boton Agregar habilitado y al pulsarlo contestaba "pediste 1 y hay 0
disponibles". La persona no hacia nada mal.

Jose David agrego **`stock_disponible`** a los tres GET de ofertas
(`/productos/:id`, `/vendedor/ofertas` y `mi_oferta`), leido con la operacion
`estado` del `.lua`. Es un campo APARTE y no pisa a `stock`, que es lo correcto:
si un dia Redis no contesta, un `7` a secas no diria de cual de los dos numeros
viene.

El frontend ya lo consume, y son dos pantallas:

```
la ficha        el numero sale de unidades(), que es stock_disponible ?? stock
                y lleva la insignia naranja "Venta relampago"
el panel        "2 de 7 sin vender", los DOS numeros: con cuantas abrio la venta
                y cuantas le quedan
```

Medido en el navegador con la venta abierta y 5 de 7 apartadas: la ficha pasa a
decir **2 unidades** en vez de 7, y el boton se deshabilita solo al llegar a 0.

`stock_disponible` es `null` en TRES casos que se tratan igual a proposito --
oferta normal, venta ya cerrada, y Redis sin contestar -- porque en los tres el
numero bueno es el de PostgreSQL. Un `??` los cubre los tres sin distinguirlos.

### La ficha del producto ahora tiene pestanas

**Hecho el 2026-09-03.** Era una sola columna larguisima: foto, precio,
detalles, presentaciones, y las resenas hasta el fondo. El sintoma de que estaba
mal es que alguien del propio equipo abrio la pagina y **no encontro las
resenas**.

Ahora son tres pestanas, con las mismas clases que las del panel del vendedor
para que se reconozcan: `Comprar` (por defecto), `Detalles` y `Resenas`, cada
una con su numero.

Dos decisiones que no son obvias:

**"Comprar" es la primera y sale por defecto.** Es a lo que se entra a un
producto, y meterla detras de un clic seria arreglar un problema creando otro
peor.

**Las tres se MONTAN siempre y se esconden con `hidden`, no con `{#if}`.** Es lo
que hace posible el numero de la pestana de resenas: con un `{#if}` la seccion
no existiria hasta el primer clic, o sea que el contador solo aparecia DESPUES
de entrar, justo cuando ya no sirve para invitarte a entrar. Y de paso cambiar
de pestana no vuelve a pedir nada.

El numero de resenas lo reporta la propia seccion (`alContar`), que lo cuenta
contra PostgreSQL. **No** sale de `resenas_total` del documento de Mongo, que es
la copia del ETL y esta vieja hasta la proxima corrida.

### El grafo ya sabe que le falta: la cola del outbox

**Hecho el 2026-09-03, y es la mitad de abajo del pendiente 4.**

`migrations/015_outbox_grafo.sql` crea `evento_grafo` y un trigger sobre
`resena` que encola el id de cada resena que se toca **en la misma transaccion
que la resena**. Esa palabra es todo el diseno: la alternativa obvia -- que el
backend le escriba a Neo4j despues de commitear -- tiene un hueco que no se
puede cerrar, porque si el proceso se cae entre el `COMMIT` y esa escritura la
resena existe, no esta en el grafo, y no queda constancia de que falte.

`etl/cargar_grafo.sh` la vacia al terminar y estrena un modo `--cola` que
proyecta solo lo pendiente. Medido de punta a punta:

```
resena creada    -> 1 evento pendiente, el grafo sigue en 90
--cola           -> el nodo :Resena aparece con sus 3 relaciones
resena borrada   -> 1 evento pendiente, el grafo sigue en 91
--cola           -> el nodo desaparece, el grafo vuelve a 90
```

Y respeta la transaccion, que es el punto: dentro de un `BEGIN`, crear una
resena deja 1 pendiente y borrarla deja 2; tras el `ROLLBACK` quedan **0**.

**Lo que `--cola` NO hace es correr mas rapido**, y decir lo contrario seria
inventar. Baja el Cypher generado de 22 KB a 5 KB, pero el script entero tarda
lo mismo (21.8 s contra 22.6 s): esos segundos son casi todos arranques de la
JVM de `cypher-shell`. Hoy `--cola` vale porque es **el unico modo que sabe
aplicar las BAJAS** -- antes una resena borrada se quedaba en el grafo para
siempre y la unica salida era `--limpiar`, que borra el grafo entero.

**Y el 2026-09-04 se cerro el circulo entero.** Jose David escribio el worker
(`@Interval` cada 10 s) y la conciliacion (`GET /admin/grafo/conciliacion`), y
yo puse el aviso en el panel. Ahora **el grafo se mantiene al dia solo**:

```
resena creada  ->  ~10 s despues  ->  el nodo y sus 3 relaciones estan en Neo4j
resena borrada ->  ~10 s despues  ->  el nodo desaparece
```

Medido, con el log del backend diciendo "worker del grafo: 3 evento(s)
aplicados" sin que nadie corriera nada.

**Y el panel de fraude ya no calla.** Debajo de su introduccion sale una linea
que dice de cuando son los datos que se acaban de analizar: en gris "Grafo al
dia con PostgreSQL, sincronizado hace 9 minutos", y en rojo "Este analisis
puede estar incompleto" con la sugerencia del backend cuando no cuadra. Se
probo borrando un nodo `:Resena` a mano y viendo el aviso rojo aparecer.

Eso cierra el pendiente 4 entero, que llevaba dias escrito.

El plan completo, con las cinco trampas del worker, esta en
`backend/elementos Generales/plan pendiente/outbox-grafo.md`.

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

Medido el 2026-09-03 con el catalogo en **1105** productos: filtrando por nota
minima dentro de una categoria, **3 documentos examinados para 3 devueltos** con
el indice y **sin etapa SORT**, contra **1105 documentos y un SORT** sin ninguno.
Ese numero cambia con el catalogo que tenga quien lo corra; lo que no cambia es
que el indice sirve para el rango y para el orden a la vez.

**El filtro del catalogo todavia no existe**: el campo esta y el indice esta,
pero ninguna ruta del backend lo consume. El contrato de lo que falta esta en
`docs/BACKEND-PENDIENTE.md`.

### Y esa nota ya alcanza a los productos que el ETL no veia

**Hecho el 2026-09-04, y cierra el pendiente 6.**

El calculo de arriba vive dentro de `extraer.sql`, que recorre `FROM productos p`
en PostgreSQL. Todo lo que no tenga fila ahi le es invisible, y hay dos clases de
producto que caen justo en ese hueco:

```
el que solo vive en Mongo    nace en el panel del vendedor, no deja fila en
                             PostgreSQL, y su nota se quedaba en 0 para siempre
                             aunque lo resenaran. En la base viva son CUATRO,
                             los _id 103 a 106

al que le borran la ultima   la fila se va de `resena` y el documento conserva
resena                       la nota vieja, sin nada que la apague
```

El segundo se encontro midiendo, no leyendo: el producto 1 decia **1 resena con
nota 4** y PostgreSQL tenia **cero** filas suyas en `resena`. Mongo sostenia 52
productos con nota donde PostgreSQL solo respaldaba 51.

La etapa nueva son dos archivos y un enganche:

```
etl/extraer_notas.sql   agrupa `resena` por id_producto_mongo, SIN join contra
                        productos. Ese join es exactamente lo que dejaba fuera
                        a los de Mongo
etl/cargar_notas.js     escribe los dos campos y apaga los que dicen tener
                        resenas y ya no salen en la lista
etl/correr.sh           la corre como TERCERA etapa
```

**Va DESPUES de `cargar.js`, nunca antes.** `cargar.js` reemplaza el documento
entero con `replaceOne`, asi que al reves le pasaria por encima a todo lo que
esta etapa escribio. Esta dicho en la cabecera de los dos archivos para que a
nadie le tiente reordenarlas.

**Y estrena `--notas`**, que corre solo esa etapa, igual que `--cola` en el del
grafo. Tarda **4 segundos contra 13**, y sirve cuando lo unico que se movio son
resenas:

```
bash etl/correr.sh            las tres etapas
bash etl/correr.sh --notas    solo la nota
```

Se comprueba con `bash pruebas/notas.sh`, que da **10 OK** y **rompe el problema
antes de medirlo**: su primera parte corre `extraer.sql` de verdad y comprueba
que el producto elegido NO sale en su resultado. Sin ese paso, el arnes podria
estar aprobando algo que ya funcionaba antes del cambio.

Medido de punta a punta sobre el producto 103:

```
resena sembrada de 5 estrellas   ->  el documento sigue en 0|0
correr --notas                   ->  el documento dice 1|5
resena borrada, correr --notas   ->  vuelve a 0|0
```

Y al arnes se le rompio el codigo a proposito para ver si se daba cuenta: con el
`$gt: 0` del apagado cambiado por `$gt: 999999`, pasa de **10 OK** a **7 OK y 3
FALLA**, en tres sitios distintos.

**Lo que sigue sin hacer** es que la nota se refresque sola. Una resena nueva no
la mueve hasta que alguien corre el ETL. Es el pendiente 4 aplicado a otro dato:
el grafo tiene cola y worker, y la nota de Mongo no.

### Resenar desde el pedido, ya de punta a punta

**Hecho el 2026-09-04.** Jose David sumo `puede_resenar` y `ya_reseno` por linea
a `GET /comprador/pedidos/:id`, y esos dos campos estuvieron unas horas **sin
que nada los consumiera**: se buscaron en todo `frontend/src` y salian en CERO
archivos. Es la tercera vez en este proyecto que el backend arma bien una pieza
y la pantalla no se entera, asi que conviene buscarlo a proposito.

En `/pedidos`, cada linea de un pedido pagado tiene ahora "Resenar esta compra",
y las que ya se resenaron dicen "Ya la resenaste" en gris en vez de quedarse sin
nada, que se lee como que algo fallo.

**Es un ENLACE y no un formulario, y esa es la decision.** `POST /resenas` pide
el **correo** del vendedor, y la linea del pedido solo trae su nombre y su id.
Desde ahi no se puede publicar. La ficha del producto si tiene la lista de
calificables con sus correos, y ademas ya tiene el formulario entero escrito y
probado. El boton lleva alli:

```
/producto/1?resenar=1&vendedor=Carlos%20Ramirez
```

La ficha abre la pestana de resenas con el formulario desplegado y preselecciona
al vendedor.

**Por que viaja el nombre del vendedor, y no es un adorno.** Un producto se le
puede comprar a varios. En el pedido 17 de la semilla, el producto 1 tiene
**TRES** vendedores calificables (Andres Castillo, Carlos Ramirez y Lucia
Morales) y la compra fue a uno solo. Sin esa pista, la persona entra al
formulario y puede calificar sin querer a otro. Medido, la pista resuelve
`Carlos Ramirez` a `ventas.norte@mesh.com`.

Se compara por NOMBRE porque es lo unico que comparten la linea del pedido y la
lista de calificables. La linea guarda el nombre copiado del dia de la compra
(esta dicho en `LineaPedido`), asi que un vendedor que se haya cambiado el
nombre desde entonces no va a coincidir. Cuando no coincide **no se
preselecciona a nadie**, que es lo correcto: elegir al equivocado es peor que no
elegir, porque desde la pantalla no se deshace.

Dos cosas mas que no son obvias:

**`puede_resenar` y `ya_reseno` son opcionales en el tipo.** Un backend anterior
a hoy no los manda, y sin ellos el boton simplemente no sale. Falla hacia el
lado bueno: ofrecerlo y que el `POST` conteste 403 seria peor que no ofrecerlo.

**`ya_reseno` mira el trio completo** (comprador, vendedor, producto), el mismo
que protege el `UNIQUE` de `resena`. Mirando solo el producto, resenar a un
vendedor apagaria el boton del otro sobre el mismo producto comprado dos veces.

### El buscador de la Entrega 3, ya montado y cargado

**Hecho el 2026-09-04.** Elasticsearch 8.15.3 es la QUINTA base, contenedor
`mesh-elastic`, y sube sola con `.\arrancar.ps1`. El detalle largo esta en
`elastic/README.md`.

```
localhost:9200          la API, sin contrasena y solo en local
mesh_productos          el indice, 1104 documentos
elastic/001_indice.json el mapeo y el analizador
etl/extraer_busqueda.js + etl/cargar_busqueda.sh   el ETL
bash pruebas/busqueda.sh                           11 OK
```

**Por que Elasticsearch y no OpenSearch.** Cuando el equipo se atore en los
analizadores, lo que decide es cuanto hay escrito, y ahi Elasticsearch gana. La
objeción de la licencia ademas vencio: volvio a ofrecer AGPL 3.0 desde la 8.16,
en 2024. Y si algun dia se cambia, OpenSearch es un fork de la 7.10 y las
consultas se escriben casi igual, asi que la apuesta es barata.

**SE ALIMENTA DE MONGO Y NO DE POSTGRESQL, y es LA decision del ETL.** El
catalogo vive en MongoDB, y hay productos que existen solo ahi: los que publica
un vendedor desde el panel no dejan fila en PostgreSQL. Hoy son cuatro. Un
indice armado con `FROM productos` no los tendria, y el sintoma seria **un
producto que se vende y que el buscador jura que no existe**, sin ningun error.

Es el mismo agujero que tenia la nota del catalogo esa misma manana. Aparecio
dos veces en un dia, asi que conviene desconfiar de cualquier consulta nueva
que empiece por `FROM productos`.

Por eso la parte 3 de `pruebas/busqueda.sh` comprueba, uno por uno, que los
`_id` 103, 104 y 106 estan en el indice **y que no tienen fila en PostgreSQL**.
Es la unica prueba que se rompe si alguien reescribe el extractor contra el
relacional.

**Medido, con el catalogo real:**

```
buscando "labtop"    79 de 1104, y salen Laptops     (difusa)
buscando "ambár"     15 resultados sobre "Ambar"     (sin tildes)
escribiendo "lap"    79 resultados con la palabra a medias
el 105, rechazado    404, no se puede buscar
```

Se rompio a proposito para ver si el arnes se enteraba: borrando del indice los
tres que solo viven en Mongo y metiendo el rechazado a mano, pasa de **11 OK** a
**6 OK y 5 FALLA**, y el mensaje apunta al extractor.

**Dos cosas de las que hay que acordarse.**

El heap se fija a mano en 512 MB, con `Xms` y `Xmx` iguales. Sin eso la JVM se
queda con la mitad de la RAM que ve, y esta maquina se quedo sin memoria tres
veces ese mismo dia. Neo4j ya es otra JVM al lado. El dia que entre el millon de
productos, ese numero es el primero que hay que subir.

Y si Elasticsearch no sube, **el arranque no se corta**. Avisa y sigue. Cuando
se escribio esto era la unica base de la que no colgaba ninguna pantalla; hoy
cuelga el buscador (la caja de la cabecera, el autocompletado y `/buscar`),
pero el login y la portada no pasan por ella, y tumbar la maquina entera por
ella dejaria sin trabajar a quien venia a tocar el catalogo.

**Y las rutas ya existen desde esa misma noche.** Aqui decia "lo que falta es la
ruta" y llevaba dos dias sin ser cierto. Jose David publico
`GET /buscador/productos`, que filtra a `estado: activo` fijo en el codigo, y
`GET /buscador/productos/admin`, que es la misma consulta sin ese filtro y
protegida con `SesionGuard` mas `@Roles(ID_ROL_ADMIN)`. Ademas monto la cola:
la bandera `pendiente_busqueda` en Mongo y un `BuscadorSyncService` con
`@Interval` cada 10 s, o sea que **el indice se mantiene al dia solo**.

El frontend las consume desde el 2026-09-04: el buscador de la cabecera, la
pagina `/buscar` y el buscador del panel.

**Lo que SI falta del buscador son las facetas**, que es un requisito literal de
la Entrega 3 y hoy no tiene ni una linea escrita. Ver `docs/PENDIENTES.md`,
punto 10.

### El choque de los dos repartidores de id ya no es invisible

**Hecho el 2026-09-04.** No decide el pendiente 5 -- quien reparte el id de
producto sigue siendo cosa de Jose David -- pero borra la frase que decia que
**no habia nada que avisara**, que era lo peor de ese punto: el arranque quedaba
en verde, las cuentas cuadraban, y lo que se perdia era un producto entero.

`arrancar.ps1` corre ahora un paso mas despues del ETL:

```
>> Comprobando que los id de producto no se pisan
   sin cruce: PostgreSQL reparte el 1127 y el mayor de Mongo es 1105 (22 de margen)
```

**Pregunta por la SECUENCIA, no por `max(id_producto)`**, y ahi esta todo el
valor del aviso. No son el mismo numero: un `nextval` que se llevo una
transaccion con `ROLLBACK` no vuelve. Ese dia la secuencia iba en 1126 con un
maximo real de 1105, o sea que preguntar por el maximo habria prometido 21
numeros de margen que no existen.

Cuando hay cruce lo dice, y se probo bajando la secuencia a mano:

```
5 documento(s) de MongoDB ocupan un id que PostgreSQL va a repartir
  PostgreSQL entregara el 1101 en el proximo INSERT INTO productos
```

**No corta el arranque**, a proposito: un choque futuro no rompe nada de lo que
esta cargado hoy, y parar la maquina por algo que aun no ha pasado seria peor que
el problema.

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

**Los numeros son los de la base que tenga quien lo corra**, y por eso la pagina
no se versiona. Estos son los del 2026-09-03, con el catalogo en 1105 productos:

| Paso | Con indice | Sin ninguno |
|---|---|---|
| 2 -- categoria + orden | 79 | 1105 |
| 3 -- rango de precio | 96 | 1105 |
| 4 -- categoria + `$or` de caracteristicas | 79 | 1105 |

Con el catalogo curado a secas (102 productos) eran 7, 9 y 7 contra 102. La
proporcion es lo que hay que contar, no el numero.

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

### La base columnar, entera menos las rutas

**Hecho el 2026-09-06.** ClickHouse es la SEXTA base y es lo que el profesor
pidio para tendencias y para deteccion de fraude. El detalle largo esta en
`clickhouse/README.md`; aqui va lo que hay que saber para retomarlo.

```
docker-compose.yml            el contenedor mesh-clickhouse, sube con el resto
clickhouse/001_esquema.sql    cuatro tablas, idempotente, se aplica en cada arranque
clickhouse/lote/              el generador de eventos de prueba y su borrado
etl/extraer_eventos.sql       la copia de log_login y log_registro
etl/cargar_eventos.sh         incremental por marca de agua
pruebas/eventos.sh            el arnes
frontend PanelTendencias.svelte   la pantalla, en /panel?s=tendencias
```

**Por que ClickHouse y no Cassandra**, que es la opcion de referencia del
enunciado, en una linea: con Cassandra hay que saber la pregunta ANTES de
guardar el dato, y detectar fraude es por definicion encontrar lo que no sabias
que buscabas. El argumento entero, y por que esto NO contradice al ADR-3 sino
que cumple su condicion 6.2, esta en `docs/ARQUITECTURA.md`.

**Tres cosas medidas que no son obvias.**

**1. Los 317 logueos reales comparten UNA sola IP.** Es `127.0.0.1`, porque todo
el desarrollo es local, y `log_registro` tiene UNA fila. Contra eso el analisis
de fraude por IP no se puede calibrar: diria que las doce cuentas del sistema
son un anillo. Se ve en vivo, la consulta devuelve las dos filas juntas:

```
::ffff:10.66.221.180    8 cuentas    48 entradas   <- el anillo sembrado
::ffff:127.0.0.1        7 cuentas   323 entradas   <- el equipo, falso positivo
```

Por eso el generador siembra tambien logueos con IP variadas, y por eso las
cuatro tablas llevan la columna `lote`.

**2. La marca de agua se lee filtrando por `lote = 'real'`, y sin ese filtro el
ETL se apaga solo.** El generador siembra ids inventados del orden de los mil
millones en las mismas tablas. Sin filtrar, la marca se iria a **1887513295** y
la copia se saltaria los logueos reales para siempre diciendo "nada nuevo que
copiar" y dando las cuentas por cuadradas. Es el pendiente 5 con otro par de
numeros. Esta explicado en `etl/README.md`.

**3. El borrado de un lote son DOS mitades.** `vistas_por_producto_dia` se llena
por una vista materializada, y una vista materializada solo mira lo que ENTRA.
Borrar de `vista_producto` no quita nada del resumen. Medido: 3882 filas crudas
y 832 del resumen, y hay que borrar las dos.

**Lo medido, con el lote de la semilla 42 sembrado:**

```
tendencia       el producto 73 sube 7.87 veces contra su propio tramo anterior
inflado         el producto 100 va a 45 vistas por persona, con un fondo de 1.1
las dos consultas contestan en 17 ms
la copia de logueos no duplica: tres corridas seguidas, 325 filas y 325 ids
```

**(Escrito el 2026-09-06 y ya superado, ver "Lo de hoy": las rutas se publicaron el 2026-09-18, pero como rankings y no con estas firmas.)**
**Lo que falta son TRES rutas**, y la que de verdad urge es
`POST /eventos/vista`: sin ella `vista_producto` no se llena nunca y todo lo
demas queda de adorno. El contrato completo esta en `docs/BACKEND-PENDIENTE.md`
y la pantalla ya esta escrita contra el, asi que se enciende sola.

**Y la copia de logueos esta congelada desde el 2026-09-10.** Sigue leyendo
`log_login`, que ya no recibe filas. Esta en la seccion siguiente y en
`etl/README.md`.

---

### El fraude del inicio de sesion

**Hecho el 2026-09-10 y el 2026-09-11, y son dos mitades de dos personas.**

La de Jose David es el commit `e38e9a3`, todo en `backend/`:

```
LogService                       cada intento de entrar va a eventos_autenticacion
                                 de MongoDB; log_login y log_registro ya no se escriben
EventosAutenticacionSyncService  cada 5 s copia lo que tiene pendiente_elastic
                                 al indice mesh_eventos_autenticacion
FraudeLoginService               tres contadores en Redis en el camino del login;
                                 al cruzar un umbral hace un UPSERT en alerta_fraude
GET /admin/fraude/alertas-login  la lista, solo admin
```

```
fuerza_bruta_ip       8 fallos desde la misma IP en 60 s
fuerza_bruta_cuenta   5 fallos contra el mismo identificador en 60 s
multi_cuenta_ip       4 identificadores distintos desde la misma IP en 300 s
```

En el mismo commit van dos cosas que no son del fraude: las rutas
`GET /vendedor/ofertas/paginado` y `GET /vendedor/ofertas/pendientes/paginado`
(pendiente 13), y el timeout de MongoDB a 3 s, con el que comprar con Mongo
caido da 503 en unos 5 s en vez de 32 (fila 11 de `CONSISTENCIA-CHECKOUT.md`).

La mitad mia es lo que hacia falta para que eso funcione en cualquier maquina:

```
migrations/016_alerta_fraude.sql        alerta_fraude y sus dos catalogos
mongo/003_eventos_autenticacion.js      la coleccion y sus seis indices
elastic/002_eventos_autenticacion.json  la PLANTILLA del indice de eventos
arrancar.ps1                            el paso "Indice de eventos de autenticacion"
frontend PanelFraude.svelte             la tarjeta "Intentos de entrada sospechosos"
pruebas/alertas_login.sh                51 OK
pruebas/ofertas_paginadas.sh            29 OK
pruebas/eventos.sh                      un AVISO al empezar, ver abajo
```

**Tres decisiones que no son obvias.**

**1. La 016 copia el SQL del backend columna por columna, y lleva un candado.**
Las tablas salen de `backend/elementos Generales/plan pendiente/fraude-login-eventos.sql`.
Tienen que ser identicas porque ese SQL ya se corrio a mano en alguna base, y
ahi el `CREATE TABLE IF NOT EXISTS` se salta: una columna de mas aqui existiria
en unas bases y en otras no. Los catalogos se insertan por nombre, sin escribir
ningun id y sin quemar la secuencia. Pero el backend fija esos ids en su codigo
(1, 2 y 3), asi que el final del archivo **falla la migracion** si algun id no
es el que el backend espera, o si falta el indice unico que necesita su
`ON CONFLICT`. El detalle esta en `docs/base-de-datos.md`.

**2. Un indice parcial para el worker.** El worker pregunta cada 5 segundos por
`pendiente_elastic: true` ordenado por `fecha`. Sin indice era un COLLSCAN mas un
SORT en memoria, sobre una coleccion que solo crece. Con
`eventos_pendientes_elastic` (`{fecha: 1}`, parcial sobre `pendiente_elastic:
true`) sale IXSCAN y sin etapa SORT, y el indice tiene el tamano de la cola, que
casi siempre es cero. Los otros cinco los pide el plan del backend y hoy no los
usa ninguna ruta: sirven para investigar desde `mongosh`.

**3. Es una PLANTILLA y no un indice, por algo que paso de verdad.** El worker
escribe con `index()`, que autocrea el indice si no existe. El primer dia se
autocreo antes que la plantilla, con mapeo dinamico, y `ip` salio de tipo
`text`. Una plantilla actua sobre cualquier indice que nazca con ese nombre, lo
cree quien lo cree. Lleva `ip` de tipo `ip`, `identificador_intentado` con un
subcampo `.minusculas` (para que `Admin@Mesh.com` y `admin@mesh.com` no cuenten
como dos al agregar) y `dynamic: false`. Si el indice ya existe con `ip` de otro
tipo, el arranque lo tira, lo rehace y marca los eventos de Mongo para que el
worker los copie otra vez. Esta en `elastic/README.md`.

**La pestana del panel se llamaba "Resenas" y ahora se llama "Fraude".** Lleva
los anillos de calificaciones y los intentos de entrada sospechosos, y nadie
iria a buscar los segundos bajo el nombre viejo.

**Los dos arneses se rompieron a proposito, y los dos se dieron cuenta.** Por
ejemplo, sin la tabla `alerta_fraude` o sin la plantilla, `alertas_login.sh` da
FALLA en su parte 0 y se para, en vez de medir sobre otra cosa.

**En local todo el trafico sale de `127.0.0.1`.** El navegador, los arneses y
el servidor corren en la misma maquina. Por eso los contadores por IP son los
mismos para todo el equipo, y por eso `multi_cuenta_ip`, que cuenta los correos
o usuarios tecleados (tambien las entradas que salen bien), da una alerta con 4
cuentas distintas en 5 minutos desde el mismo equipo.

**Desde el 2026-09-15 el frontend no le habla directo al backend.**
`frontend/src/lib/api.ts` pide a `/api` del mismo sitio, y el proxy de
`frontend/vite.config.ts` se lo pasa al 3000 (o a `MESH_BACKEND`). En local da
igual; sirve para que por un tunel la pagina y la API sean el mismo origen, sin
CORS ni cambios en la cookie. Los arneses siguen yendo directo al 3000.

**Para entrar desde un celular** esta `.\tunel-celular.ps1`: compila el
frontend, lo sirve en el 5173 y abre un tunel rapido de Cloudflare hacia el.
Con `-ConCopia` usa una copia del backend con trustProxy y el login sale con la
IP del celular; sin eso sale `127.0.0.1` hasta que Jose David ponga
`trustProxy: 'loopback'` en `backend/src/main.ts`, que es lo unico que le toca
(arriba de todo en `BACKEND-PENDIENTE.md`). `-Cerrar` lo apaga. Ver
`docs/ENTRAR-DESDE-EL-CELULAR.md`.

**Para ensenarlo con una IP de otro pais** esta `.\demo-fraude-pais.ps1 -Pais sg`,
que va por Tor y un tunel contra la misma copia del backend, y
`.\demo-fraude-pais.ps1 -Limpiar` para borrar lo sembrado. Ver
`docs/DEMO-OTRO-PAIS.md`. Hasta el 2026-09-15 ese script decia que sembraba y
no sembraba nada; ahora comprueba la alerta en las bases antes de decir LISTO.
Los dos scripts arman la copia con `copia-backend.ps1`.

### La corrida completa del 2026-09-11

Los doce arneses en serie, de uno en uno, mas la compilacion del backend
(`tsc`) y `svelte-check` del frontend. **303 OK y 0 FALLA** en los doce, y los
dos compiladores sin un error (205 archivos en el frontend).

```
pruebas/resenas.sh              15     redis/prueba_carrito.sh         15
pruebas/carrito.sh              25     redis/prueba_concurrencia.sh    61
pruebas/notas.sh                10     neo4j/correr_fraude.sh          10
pruebas/busqueda.sh             13     mongo/demostracion_indices.ps1  12
pruebas/eventos.sh              31     pruebas/falla_checkout.sh       31
pruebas/alertas_login.sh        51
pruebas/ofertas_paginadas.sh    29
```

`falla_checkout.sh` sigue con su OJO, que es el hallazgo del 2026-09-06: con
Mongo parado no se compra. Esa corrida dejo los pedidos 119 y 120.

`eventos.sh` da verde y a la vez avisa que la copia a ClickHouse esta
congelada: ese dia habia **24 logins en Mongo que ClickHouse no ve**. El verde
dice que la copia funciona, no que este al dia.

### Lo que se toco DESPUES de esa corrida, medido el 2026-09-12

Una revision de lo nuevo encontro once cosas. Se arreglaron con Docker caido y
se midieron al dia siguiente, de una en una:

```
.\arrancar.ps1 sobre la base ya migrada   001 a 006 "ya estaba aplicada",
                                          007 a 016 en verde, como se predijo
candado de la 016 roto a mano             "016_alerta_fraude.sql FALLO" y el
  (el tipo 1 renombrado)                  arranque se corta, con los NOTICE
                                          "already exists" en la misma salida
indice de eventos vaciado a mano,         "Faltan al menos 30 evento(s)", marca
  con ip de tipo ip y 0 documentos        los 30, y el worker los copia al
                                          arrancar el backend (30 de 30)
bash pruebas/alertas_login.sh, dos veces  52 OK y 52 OK, 0 FALLA; la segunda
                                          espero al minuto siguiente y no
                                          encontro nada que borrar
bash pruebas/ofertas_paginadas.sh         26 OK, 0 FALLA, 3 SIN MEDIR (una
                                          sola oferta pendiente)
el panel de fraude, como admin            27 alertas en 2 paginas, los filtros,
                                          "(vacio)", el corte a 80 caracteres,
                                          la marca local y 400 px sin desborde;
                                          consola sin errores
```

El candado y el hueco del indice se restauraron despues de romperlos, y las
alertas, eventos y claves que sembro la prueba del panel se borraron.

Dos cosas que salieron midiendo, y que son del backend:

- **Un identificador vacio da 400 y aun asi cuenta como fallo.** Cinco
  `POST /usuario/login` con `"identificador": ""` dejan una alerta
  `fuerza_bruta_cuenta` cuya clave es la cadena vacia. El panel la pinta como
  "(vacio)".
- **Con Mongo caido el login se guarda a medias.** El 2026-09-11 Mongo dejo de
  contestar a mitad de una prueba. Los intentos fallidos de esa prueba **no
  estan en `eventos_autenticacion`**, pero sus alertas si llegaron a
  `alerta_fraude`: el log es best-effort y los contadores de Redis siguen. O
  sea que durante una caida de Mongo hay alertas sin su evidencia.

Lo que cambio, y que se miro en cada uno:

- **`arrancar.ps1`, el perdon de las migraciones.** `Correr-Migraciones` pinta
  en amarillo, como "ya estaba aplicada", una migracion que falla con
  `already exists`. Miraba la salida entera, y ahi estan siempre los
  `NOTICE ... already exists, skipping` de los `IF NOT EXISTS`. O sea que **en
  una base ya migrada los candados de la 015 y la 016 no paraban el arranque**,
  dijeran lo que dijeran. Ahora solo perdona si la linea del `ERROR` lo dice.
  Ademas `Out-String` lleva `-Width 4096`: sin eso PowerShell parte la linea del
  error al ancho de la consola y el perdon dejaria de reconocerla.
- **`arrancar.ps1`, el indice de eventos.** Solo marcaba eventos para recopiar
  si el indice faltaba o habia nacido malo. Si el worker lo recreaba solo, el
  hueco se quedaba para siempre y en verde. Ahora cuenta Mongo, pendientes e
  indice, y si indice mas pendientes no llega a Mongo, marca todo. Es una
  cuenta y no una comparacion por id: un sobrante en el indice puede tapar un
  hueco del mismo tamano.
- **`PanelFraude.svelte`.** Decia "cuentas probadas" y `multi_cuenta_ip` cuenta
  correos o usuarios tecleados, salgan bien o mal; los textos ahora lo dicen. La
  marca "este equipo (local)" ya no le echa la culpa a un proxy. Un identificador
  vacio sale como "(vacio)", y uno largo se corta a 80 caracteres con el texto
  en el `title`, hasta 1000.
- **`alertas_login.sh`.** La llave del UPSERT es el minuto, asi que la prueba
  podia engordar una alerta ajena del mismo minuto y despues borrarla. Ahora
  espera a un minuto sin alertas de ese tipo antes de cada deteccion, y no borra
  ninguna fila anterior a la corrida: la avisa. Y anota cada alerta que nace en
  `.mesh-alertas-nacidas.txt`, para que la corrida siguiente borre lo que dejo
  un proceso que murio sin correr su `trap`.
- **`ofertas_paginadas.sh`.** Con menos de 2 ofertas pendientes, la parte 2 ya
  no cuenta OK sin haber medido: dice SIN MEDIR, fuera de las dos cuentas. **El
  2026-09-11 habia una sola pendiente**, asi que el 29 OK no se repite tal cual
  si antes no se publica otra con un vendedor normal. Si la lista se mueve
  mientras la recorre, repite una vez y despues dice SIN MEDIR en vez de FALLA.
  Y la cabecera ya no dice que no escribe nada: sus dos logins suman al contador
  de `multi_cuenta_ip`, y al final avisa si nacio una alerta.

Lo que falta del fraude del login esta en `docs/PENDIENTES.md`, puntos 14 a 18,
y lo que le toca al backend en `docs/BACKEND-PENDIENTE.md`. Lo mas importante:
**Elasticsearch se llena y ninguna ruta lo consulta.**

---

## Las cinco cosas que hay que saber, y no son obvias

**1. La resena es de un VENDEDOR sobre un PRODUCTO.** No del producto solo.
`resena(id_usuario, id_usuario_vendedor, id_producto_mongo, ...)`. Colgaba de
`oferta` y se cambio: `oferta` es unica por (usuario, producto, **variante**), y
nadie resena una variante.

**2. No hay FK de `resena` a `pedido`, a proposito.** La resena sin compra es la
senal de fraude mas fuerte; exigir la compra la borra del modelo. Jose David SI
la exige **en la aplicacion** (compra verificada, y **al mismo vendedor**), y eso
es reversible. Desde el 2026-08-30 **la semilla cumple esa regla**: las **90**
resenas tienen su compra pagada detras, y las comprobaciones 10 y 11 de
`001_catalogo.sql` fallan la migracion si alguna deja de tenerla. Antes solo 2 la
tenian y el boton de escribir no aparecia casi nunca.

Eran 86 cuando se arreglo y son 90 desde que entro el anillo de fraude. Vuelto a
medir el 2026-09-03 con los mismos JOIN de la comprobacion 10: **0 resenas sin
compra pagada a ese vendedor y 0 fechadas antes de su compra**.

**3. El grafo tiene TRES nodos, no cuatro.** `:Usuario`, `:Resena`, `:Producto`
(mas `:Direccion`). **No hay `:Vendedor`**: en Mesh comprar no pide rol, asi que
partirlo dejaria la misma cuenta como dos nodos y **el anillo nunca cerraria**.
La resena es NODO porque conecta TRES cosas.

**4. El carrito de Redis guarda intencion, no precios.** Es
`id_oferta -> cantidad` y nada mas. El precio, el stock y el nombre se resuelven
al leerlo. **Consecuencia: el precio que se cobra es el de pagar.** Es el
pendiente #1.

**5. La semilla NO es idempotente.** **17 de sus 26** `INSERT` de primer nivel no
tienen guardia, asi que `001_catalogo.sql` solo carga contra una base vacia. Los
9 guardados son los tres del principio (cuentas, direcciones e historial de
direccion) y los seis del tramo del anillo de fraude del final. Se recuenta
mirando cada `INSERT` entero, no con un `grep` de `NOT EXISTS`, que cuenta de mas
porque los hay dentro de bloques `DO`.

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
nuevo metido antes de la **linea 1717** de `migrations/datos/generador.js` --
que es la ultima llamada a `azar()`, comprobada con
`grep -n "azar(" migrations/datos/generador.js | tail` -- reescribe las **556**
ofertas. La parte social tiene su propia semilla (`azarSocial`) justamente para
no arrastrarse con eso.

**"El servidor respondio algo inesperado" al entrar es casi siempre el backend reiniciandose.** El
backend corre con `nest start --watch` y el observador lo reinicia con cualquier toque a `backend/`,
incluidos los de OneDrive sin cambio de contenido. Durante esos segundos el proxy de Vite no tiene a
quien pasarle la peticion, contesta algo que no es JSON y `pedir()` lo traduce a ese texto. Medido el
2026-09-18: el backend se reinicio a las 22:23:10 (proceso nuevo colgando de `nest.js start --watch`,
`dist/` sin cambios desde las 21:03), y un login fallo justo ahi; 15 logins seguidos despues dieron
200 con JSON. Ya no se llega a ver: el proxy de Vite (`vite.config.ts`) contesta un 503 en JSON con la cabecera
`x-mesh-proxy-error` cuando no alcanza al backend, y `pedir()` (`api.ts`) reintenta esas peticiones
(8 veces, 1.5 s, unos 12 s en total) sin duplicar nada: la cabecera dice que la peticion nunca llego.
Si el backend sigue caido, la persona lee "El servidor se esta reiniciando" en vez del mensaje
inutil. Probado con `pedir()` compilado: backend caido, backend que vuelve a los 4 s (el POST entra UNA
vez) y un 503 propio del backend (no se reintenta). El reinicio en si sigue pasando: es de `backend/`.

**Tras varios recargados de HMR la pestana de Chrome se congela** y
`Runtime.evaluate` da timeout. Se cierra y se abre otra.

**Un `as` de TypeScript es una promesa de quien escribe, no una comprobacion.**
Un cast de las lineas del carrito a `LineaPedido` compilaba limpio y ensenaba
"Pagar QNaN": sumaba un campo que no existia.

**El fin de linea de Windows muerde por los DOS lados, no solo al leer.** Que
`psql` devuelva Unix y PowerShell lo parta con CRLF ya estaba sabido. Lo que
faltaba es que PowerShell 5.1 tambien lo mete AL ESCRIBIR a la entrada de un
programa externo, aunque el texto se una con `` `n `` a mano. ClickHouse contesta
`Code: 27 ... garbage after UInt64: "<CARRIAGE RETURN><LINE FEED>"`. Se arregla
con `--input_format_tsv_crlf_end_of_line 1`, que es el ajuste que el propio
mensaje de error nombra, y no peleando con PowerShell. El `.sh` no lo necesita
porque ahi la tuberia es directa entre dos procesos.

**Un verde sobre una linea que no se ejecuta no es un verde.** El 2026-09-06 se
probo ese camino de PowerShell suelto y dio verde, y dio verde porque en ese
momento no habia ni una fila pendiente que copiar: el `INSERT` no llego a correr.
El fallo salio despues, con el arranque entero. Para probar una copia
incremental hay que BORRAR algo del destino primero, para que tenga trabajo que
hacer. Es el mismo error que el arnes que aprobaba mirando otra cosa.

**A la base nueva hay que ponerle tope de memoria, y hay que comprobar que se
aplico.** Es la sexta base en una maquina que ya se quedaba corta, y ClickHouse
por defecto no tiene techo. Sin topes gastaba 800 MB y podia crecer; con ellos se
queda en 290 MB. Dos trampas al ponerlos, las dos escritas en
`clickhouse/README.md`: un `max_memory_usage` fuera de sitio deja el contenedor en
bucle de reinicio con codigo 137 y SIN ninguna linea de error, y un `<profiles>`
puesto en `config.d` en vez de `users.d` no da error y no se aplica. **Un
contenedor sano no quiere decir que el ajuste este puesto**: hay que preguntarle a
`system.settings` por el valor.

**Un `docker exec -i` deja la entrada estandar abierta, y eso cuelga a
`clickhouse-client`.** Con un `--query` que sea un `INSERT ... VALUES` se queda
esperando mas filas por ahi para siempre. A mano en una terminal no falla nunca,
porque la entrada da EOF enseguida; solo se cuelga cuando se corre en segundo
plano o desde otro guion, que es justo como lo va a correr una persona con prisa.
Medido: una corrida clavada con 459 segundos de `elapsed` en
`system.processes`, sin error y sin mensaje. Se cierra con `< /dev/null`.

**En PowerShell 5.1, `Out-String` sin `-Width` parte las lineas al ancho de la
consola.** Con 60 columnas, la linea de un `ERROR` de `psql` sale en tres
pedazos, y un `-match` que busque la frase entera en una sola linea deja de
encontrarla. Aparecio al arreglar el perdon de las migraciones: sin el
`-Width 4096` que ahora lleva, la regla nueva habria cortado el arranque en una
consola angosta. Medido con programas falsos que escriben como `psql`.

**Un `NOTICE` no es un error, pero un `-match` sobre la salida entera no lo
sabe.** Cada `CREATE ... IF NOT EXISTS` sobre una base ya migrada imprime
`already exists, skipping`, y eso bastaba para que el arranque perdonara
cualquier `RAISE EXCEPTION` de la misma migracion. Un candado que se perdona
solo es un candado pintado.

---

### El precio del carrito ya avisa antes de cobrar

`POST /carrito/comprar` acepta `lineas_precio_visto`: el frontend manda el
precio que ENSENO y el backend lo compara contra el de hoy **dentro de la misma
peticion que cobra**. Si no cuadra, no cobra nada y contesta `comprado: false`
con los avisos; reenviar con `confirmar_cambios: true` acepta el nuevo.

Que la comparacion viaje en la misma peticion es lo que la hace valer: entre
mirar y cobrar no queda ninguna ventana. Comprobarlo desde el frontend antes de
llamar dejaba milisegundos abiertos, y se probo asi antes de cambiarlo.

El precio todavia NO se congela -- si se confirma, se cobra el de hoy -- pero ya
no se cobra en silencio, que era el dano. Ver el pendiente 1.

**Medido el 2026-09-03 contra el backend vivo:** con el precio real en Q6,263 se
manda `precio_visto: "1.00"` y contesta `comprado: false` con el aviso que trae
los dos precios; los pedidos siguen en 32 antes y despues, y el carrito queda
entero.

Y una condicion que conviene saber, porque la proteccion **es opcional del lado
del cliente**: `detectarAvisosPrecio` devuelve una lista vacia si
`lineas_precio_visto` no viene o viene vacia, o sea que quien no mande el campo
cobra el de hoy en silencio igual que antes. `Checkout.svelte` si lo manda, asi
que la aplicacion esta cubierta; cualquier otro cliente, y cualquier linea que se
quede fuera de ese array, no lo esta.

## Que falta

En `docs/PENDIENTES.md`, con su urgencia.

**Al 2026-09-06 la lista quedo revisada contra el codigo**, y de paso se cerraron
dos puntos que llevaban dos dias hechos sin que nadie los tachara: el 409 del
`PATCH` (punto 8) y el apagado de la venta relampago vencida (punto 7). El 409 lo
decia este mismo documento como "lo mas urgente" cuando ya estaba resuelto.

Lo que queda vivo, en orden de lo que mas duele (al 2026-09-11):

| # | Que | De quien |
|---|---|---|
| 17 | Medir en vivo lo que se toco despues de la corrida del 2026-09-11 | mia |
| 14 | Las rutas de agregacion sobre `mesh_eventos_autenticacion`: lo que pidio el profesor | Jose David |
| ~~9~~ | ~~Las tres rutas de la base columnar~~ **HECHAS el 2026-09-18** (seis rankings, `POST /eventos/*` y mas vendidos). Queda pedir el filtro `lote` | Jose David |
| 10 | Los filtros facetados del buscador, con agregaciones. Requisito de la Entrega 3 | los dos |
| 16 | La copia de logueos a ClickHouse, congelada desde el 2026-09-10 | decidir con el profesor |
| 15 | Los detectores que faltan y los detalles del servicio de fraude del login | Jose David |
| 12 | El checkout no compra con MongoDB caido: las tres salidas, por decidir | con el profesor |
| 13 | La lista del vendedor sigue entera: a la ruta paginada le faltan filtros | Jose David |
| 18 | Las tres tablas de la 016 en el diagrama ER | mia |
| 5 | Decidir quien reparte el id de producto | Jose David |
| 1 | El precio se congela al pagar y no al agregar | cubierto a medias |

La 11, la prueba de falla simulada del checkout, se cerro el 2026-09-06 y esta
tabla la seguia dando por abierta.

Del 9, lo urgente es `POST /eventos/vista`: **sin esa ruta la tabla que sostiene
el panel de tendencias no se llena nunca**, y todo lo demas de la base columnar
queda de adorno.

Y lo mas grave de fondo sigue siendo el punto 1: ya no se cobra en silencio, pero
tampoco se respeta el precio que se enseno.

Lo unico que queda sin comprobar es la revision a ojo en el navegador, que pide
entrar con una cuenta.

**Los 2.5 puntos de la Entrega 2 que no dependian de nadie ya estan escritos**
(2026-09-03):

| Que | Donde |
|---|---|
| Comparativa grafos vs columnar, con las condiciones bajo las cuales SI habria que incorporar la columnar | `docs/DECISION-GRAFOS-VS-COLUMNAR.md` |
| Diagrama de arquitectura, que no es el ER | `docs/ARQUITECTURA.md` y `docs/diagrama-arquitectura.drawio` |

La comparativa **no descarta Cassandra, la aplaza**, y con cinco condiciones
medibles contra este mismo sistema. Y dice de frente lo que hay que decir antes
que nada: a 32 pedidos y 14 aristas de calificacion **ninguna de las dos familias
hace falta por rendimiento**. Se midio el analisis de fraude escrito entero en
SQL con `WITH RECURSIVE` y encuentra exactamente los mismos anillos que Neo4j, en
28.7 ms. Lo que decide no es la velocidad, es que la version en SQL **sin la
guardia de nodos repetidos convierte 2 anillos reales en 7**, y eso tambien esta
medido.

---

## Donde esta cada cosa

```
El informe de la Entrega 2 se genera, no se escribe a mano:

```
contenido-entrega2.json        el TEXTO, separado del formato a proposito
generar-reporte-entrega2.py    lo maqueta clonando la caratula de la Entrega 1
medir-paginas-entrega2.ps1     abre el .docx con Word y apunta las paginas
```

**Son DOS pasadas y el orden importa.** `python-docx` no sabe paginar, asi que la
primera pasada deja el indice con guiones, el `.ps1` mide con Word de verdad y la
segunda pasada escribe los numeros. Medido el 2026-09-19: 68 paginas, 8 secciones, 38
subsecciones, 7 figuras (cuatro son capturas de pantalla) y 16 tablas, y las dos mediciones dieron la misma paginacion,
asi que el indice no se corre al rellenarse. El contenido ahora es una lista de bloques
(parrafo, tabla, figura, codigo, registro de decision, ver la cabecera del generador) y
el generador se NIEGA a escribir el Word si el texto lleva dos puntos, punto y coma,
comillas angulares, rayas largas, puntos suspensivos o menciones de como se escribio.
Ojo, el medidor solo cuenta como titulo de seccion una linea EN MAYUSCULAS: las
alternativas numeradas de los registros de decision lo confundian.

Es lo que le falta al informe de la Entrega 1, cuyo indice tiene los numeros casi
todos vacios y los tres que hay no corresponden.

```
migrations/          el esquema (la 016 es la ultima, 017 sera la siguiente)
                     y el generador de datos
etl/                 las cuatro copias hacia las bases derivadas
mongo/               los indices (catalogo, resenas y eventos_autenticacion),
                     la demostracion de indices y el generador de lotes
neo4j/               el modelo del grafo y las 5 consultas de fraude
redis/               el carrito, el Lua del inventario limitado y sus arneses
elastic/             el mapeo del buscador y la plantilla del indice de eventos
clickhouse/          el esquema de eventos y el generador de lotes.
                     La puerta es clickhouse/README.md
pruebas/             los ocho arneses de rutas y de bases
docs/                base-de-datos.md manda sobre el modelo;
                     ARQUITECTURA.md es el diagrama de arquitectura (no el ER);
                     DECISION-GRAFOS-VS-COLUMNAR.md es el ADR-3 de la Entrega 2;
                     GUIA-PRESENTACION.txt es el guion para defenderlo
backend/             de Jose David. NO SE TOCA. Su doc buena esta en
                     "elementos Generales/endpoints-*.md"
```

---

## El carrito y la ficha ya no dejan pasar del stock (2026-09-18)

El carrito de Redis es SOLO INTENCION, y asi lo dejo documentado Jose David
(`backend/elementos Generales/endpoints/endpoints-carrito.md`): "el stock no se comprueba al agregar
-- nunca fue una reserva --", el PUT es "Redis puro" y acepta cualquier cantidad de 1 a 1000, y "el limite
real es el stock, que no se comprueba aca para una oferta normal (se ve en GET /carrito y bloquea al
pagar)". Redis no piensa: **quien debe frenar es el frontend**, y el backend es la red de abajo, que
rechaza con 409 al pagar. Por eso no se puede vender de mas, pero sin el limite del frontend una persona
llegaba a tener la olla arrocera en **6 con 4 en stock**, una linea que no se puede comprar, con el `+`
siempre activo. **Esto NO es un hueco del backend y no se le pide nada a David** (una nota mia decia lo
contrario y estaba equivocada). El limite se pone en los dos sitios donde se agrega:

```
CarritoRedis.svelte   el "+" se apaga al llegar a stock_disponible y dice "No hay mas unidades". Solo se
                      frena SUBIR: bajar siempre se puede. Una linea que ya se paso ensena "Ajustar a N", que
                      la deja en lo que si hay
producto/[id]         el input tiene max, y lo escrito por encima se recorta al tope (escribir 50 con 9 libres
                      deja 9). Lee el carrito al entrar para restar lo que YA tienes, y avisa "Ya tienes 3 en
                      el carrito. Puedes agregar 9 mas". Si pediste mas de lo que cabe, agrega lo que cabe y
                      te dice cuanto
```

**Una venta relampago tiene otro tope.** El PUT reserva contra el contador de Redis, y lo que ya tenias
apartado ya no esta en ese contador; restarlo otra vez le quitaria unidades que si hay. Ahi el tope es lo
que queda. En el carrito, `stock_disponible` de una linea relampago es el de PostgreSQL congelado y solo es
una cota superior: la exactitud la sigue decidiendo el backend.

Medido en el navegador con el carrito real de `admin@mesh.com`: la laptop (3 de 12) deja el `+` activo y
la ficha da `max=9`; la olla (6 con stock 4) salia con el `+` deshabilitado y "Ajustar a 4", que la dejo en
4 y comprable; en la ficha de la olla, con las 4 ya en el carrito, el input y el boton quedan deshabilitados.
