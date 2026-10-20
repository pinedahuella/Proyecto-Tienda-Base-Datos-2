# TRASPASO -- Mesh (Bases de Datos 2)

**Para quien retome el proyecto: leete esto entero antes de tocar nada.**
Son cinco minutos y te ahorra el dia.

Ultima actualizacion: **2026-10-20, 17:00**.

**EMPIEZA AQUI (20-10, tarde). Revision entera antes de la presentacion, datos de prueba limpiados e informes al dia.**
Commiteado (e366d91, 00c376a y el de los informes) y pusheado, Meme lo pidio.

Medido contra las bases de 100.64.42.11: bateria 39 de 41 (etl_compras fallaba por datos, ya arreglado;
correr_patrones es la carrera de Neo4j de siempre), caidas.mjs 51 OK apagadas y 51 congeladas, demo_concurrencia
con Elasticsearch, MongoDB y Redis caidas juntas (2 de 4 ganan, pagan en 0.7 s), las 9 partes de
demo-entrega-final.ps1 en verde, tsc y svelte-check en 0.

Datos arreglados por la API o con la misma limpieza que hace la demo:
- ClickHouse sin las 10 ventas de demo_concurrencia de las 07:46 (pedidos 1350 a 1359, oferta 6159). etl_compras
  cuadra otra vez, 934 y 934.
- Retiradas las 59 ofertas a Q15 de las cuentas famb*/anit* que dejan anillos.sh y anillos_familia_b.sh. Lo mas
  vendido decia "desde Q15.00". Si se corren otra vez, vuelven.
- Producto 1105 "ayuda" inactivo y su oferta 6179 retirada. Ofertas 4 y 7 (laptops) sin la venta relampago al 80 %,
  y 331 y 333 sin el 50 % que les quedo de las pruebas de las 11:34. La 11 (laptop al 10 %) se queda, es la venta
  relampago que sale en el inicio.
- Tendencias sin 27 busquedas basura (asdf*, asisifsfasaa, gggg..., un texto pegado del panel).

Arreglado en el repo: Fraude en telefono ya no se sale (botones de Casos envuelven, el select Tipo se encoge);
el comentario suelto de catalogo-respaldo.ts; diagrama de arquitectura al 20-10 (vectores en PostgreSQL, compras en
Neo4j, ofertas y avisame en Elasticsearch, combos, 86 tablas y 107 llaves); Reporte Entrega Final al 20-10, 20
paginas, con la vuelta a pgvector (ADR-10 y sus dos revisiones en 2.2); Entrega 3 con 346 commits, 86 tablas y
caidas 51; los generadores ya no dejan una hoja en blanco antes de una seccion ni separan un codigo de su leyenda.
PREGUNTAS-SUSTENTACION.md 108 y 118 al dia. Fuera del repo: ENTREGAS-3-Y-4.txt al dia y la fecha de la guia.

Lo que queda: la red con la PC de Jose David se corto un minuto a las 13:14 (las seis bases a la vez), revisarla
antes de presentar. No correr la bateria justo antes de presentar, mete casos y anillos de fraude nuevos.
docs/ARQUITECTURA.md tambien al 20-10 (el Mermaid con las mismas flechas que el diagrama).

**EMPIEZA AQUI (20-10, de 09:45 a 11:00). El Word de la Entrega 3 con lo nuevo, y /buscar sin resultados a lo ancho.**
SIN commitear (Meme no lo pidio).

Al empezar, las seis bases de 100.64.42.11 arriba (MongoDB en el 27018, el 27017 alla no se publica) y el
cortacircuitos sin ninguna caida. Jose David no subio nada despues de 3d3459f.

El Word de la Entrega 3 (Meme lo pidio): 26 paginas, dos pasadas, el validador pasa.
- 1.1 con 343 commits (contando el de hoy) y un parrafo que apunta a lo nuevo; 1.2 y 1.3 con la demo y el dashboard (220, 118, 5).
- 4.4 nueva, Muchos compradores a la vez, con la tabla de demo_concurrencia.mjs MEDIDA hoy: todo arriba navegar
  mediana 2.1 s, 10 de 40 ganan (4.2 s), 10 pagan con 201 (4.3 s), stock 10 a 0; con -Caida redis 1.8, 3.6 y 1.8 s,
  lo mismo de stock. Las dos corridas limpiaron solas (pedidos cancelados, ClickHouse sin la demo).
- 7.3 con arrancar.ps1 en remoto (no se volvio a sembrar hoy, es lo probado esta manana en remoto/README.md).
- 7.4 nueva, el dashboard, con docs/captura-dashboard.png (Ventas, Este anio) y dashboard.mjs 35 OK de hoy.
- 8.1 con una frase de la concurrencia.

/buscar sin resultados (Meme: horizontal, responsive, aprovechar el espacio): la caja va a todo el ancho con el
texto a la izquierda y Hasta Q, Avisame y Ver todo el catalogo a la derecha (este ultimo con borde, sin relleno).
Los sugeridos en tarjetas, 3 por fila, 2 por debajo de 900 px y en telefono se deslizan de lado. Solo
routes/buscar/+page.svelte (clases sin-nada y .sugeridos), svelte-check 0. Visto en Edge a 1536x730 (todo entra
sin bajar), 800 y 390 (la pagina no se mueve de lado), y con el aviso de iniciar sesion.

El buscador de la cabecera (Meme mando captura: "lap" daba ocho veces El camino de las nubes). Medido: la
cabecera usaba solo la difusa, que toma "lap" por "las" y con "lapt" da 0, y las copias de lote llenaban la lista.
- GET /buscador/productos?escribiendo=1 (solo la cabecera): bool_prefix sobre nombre.escribiendo con peso 20 (el
  prefijo puntua fijo; con 3 la difusa de "las", 8.2, le ganaba) mas la difusa, empate por resenas_total, pide
  hasta 15 veces el tope y deja uno por producto (helpers/copias-de-lote.ts, MARCA_DE_LOTE sale de ahi tambien
  para sugeridos.service.ts). Sin Elasticsearch, buscarEnCopia con prefijo (la ultima palabra vale como principio,
  1.2 contra 0.8 de una letra distinta). Sin el parametro, todo igual que antes (/buscar no cambia).
- La fila marcada ya no lleva barra en el canto: fondo y borde fino alrededor.
- pruebas/buscador_escribiendo.mjs (en correr_todas): 20 OK. busqueda.sh 14 OK en remoto. tsc, eslint y
  svelte-check limpios, dist compilado y backend reiniciado. Visto en Edge claro y oscuro.
- elastic/README.md y el Word (2.3) lo cuentan; el Word sigue en 26 paginas.
- Visto de paso: las ofertas 4 y 7 de Laptop Ambar Campus 14 con 80 % y venta relampago desde las 10:21, y los
  pedidos 1412 y 1413 del admin. Los hizo Meme probando, no es un error.

Mis pedidos sin "Ver el detalle de ese dia" (Meme lo pidio): fuera el boton, su ventana, su estado, sus estilos y
traerProductoEnFecha / traerOfertaEnFecha con sus tipos de lib/pedido.ts. El backend no se toco: la ruta
/productos/:id/historial queda sin pantalla, y el vendedor sigue viendo el historial por la suya. docs/frontend.md
al dia. svelte-check 0 y 0, visto en Edge a 1536 y 390.

Reglas por fecha del vendedor (Meme: si hay un mes el otro no puede ser cada mes, el anio en lista, fechas
correctas):
- Backend validarFechasPosibles (helpers/validaciones-regla-descuento-periodo.ts), en crear y en editar si cambia
  una fecha: el dia existe en su mes (febrero 29 sin anio), con anio no pasa al anio siguiente ni termino antes de
  hoy en Guatemala. reglas_periodo.sh 68 OK (7 nuevos).
- ReglasPeriodo.svelte: elegir un mes con el otro en cada mes le pone el mismo, volver uno a cada mes vuelve los dos
  y quita el anio; el anio es un select (este y los cuatro siguientes, mas el de la regla si es viejo); el maximo
  del dia sigue al mes. Las mismas reglas antes de mandar. Visto en Edge a 1536 y 390.
- En la base habia una sola regla, la 39 (oferta 396 de tienda@mesh.com), del 1 al 10 de enero de 2026, que Meme
  creo antes del arreglo. Nunca se aplico (la oferta sin descuento). Meme pidio borrarla: pausada y borrada por la
  API como tienda@mesh.com. Quedan 0 reglas por fecha.
- Nota para David: backend/cambio_propuestas/2026-10-20_1100-buscador-escribiendo-y-fechas-de-reglas.md.

Panel del admin sin MongoDB (Meme lo vio a las 11:50 con Mongo, Neo4j, ClickHouse y Elasticsearch apagados en la
PC de David, de verdad, no con el interruptor):
- Ofertas daba "No pudimos cargar" al abrir un producto, y EDITAR una oferta guardaba en PostgreSQL y contestaba
  503 al armar la respuesta. ofertas.service.ts: consultarProductosLigeros, obtenerConMisOfertas y crear pasan por
  conRespaldoDeMongo con la copia (productosDesdePostgres). Medido sin Mongo: abrir 0.1 s, lista 0.5 s, editar 200.
- Catalogo daba "No pudimos cargar": listarPropios, listarPropiosPaginado y obtenerPropio con la copia
  (catalogoPanelDesdePostgres en helpers/catalogo-respaldo.ts, mismo orden y filtro por nombre). 1003 productos.
- Crear o editar un producto y su historial siguen necesitando Mongo (a proposito, QUE-PASA lo dice).
- pruebas/caidas.mjs suma 4 comprobaciones en MongoDB (lista de ofertas, abrir, editar con el mismo precio,
  catalogo del panel). SIN CORRER entera: cuando la corri estaban cuatro bases apagadas alla. Comprobadas a mano
  contra el backend con Mongo caido de verdad.
- Sin commitear todavia.
- Medido despues con Mongo caido de verdad: demo_concurrencia --usuarios 4 --stock 2 publico la oferta (crear con la
  copia), vendio exactamente 2 y pago en 1.7 s, y limpio. Mongo, Elastic y Redis caidas juntas NO se han medido.

Guia de estudio de Meme para el 21-10 (fraudes de devolucion y de ClickHouse, casos, las cuatro reglas R-CASI,
tendencias, regla por ventas rapidas y el guion de la demo de caidas): docs/GUIA-ESTUDIO-2026-10-21.txt. Revisada
contra el codigo; corrige tres cosas de sus notas (el bono de ida y vuelta sube cuanto mas rapido, la regla 2 es de
cuentas de menos de 60 minutos, no hay deteccion por dispositivo).

Como quedo la maquina: backend directo (interruptor quitado despues de la demo con Redis), frontend, panel y
Ollama arriba.

**ANTES (20-10, de 08:30 a 09:45). Dashboard general del admin, demos de pais en remoto, Revisar va al caso.**

Dashboard general (pestana Dashboard del admin, la primera; el enlace Admin de la cabecera abre ahi):
- Backend en carpetas dashboards: controllers/dashboards/dashboard-general.controller.ts, services/dashboards/
  (dashboard-general.service.ts las consultas, dashboard-periodo.ts el periodo, dashboard-exportar.service.ts
  Excel con ExcelJS y PDF con PDFKit, dashboard-correo.service.ts Nodemailer), dto/dashboards/dashboard-general.ts.
- Rutas GET /admin/dashboard/{resumen,ventas,embudo,categorias,pagos,mapa,vendedores,productos,departamentos,
  busquedas,cancelaciones,pedidos}?desde=AAAA-MM-DD&hasta=AAAA-MM-DD, solo admin. Exportar: GET exportar/excel,
  GET exportar/pdf (?secciones=a,b), POST exportar/correo {correos, formato pdf|excel, desde, hasta, secciones}.
- Cifras contra el periodo anterior del mismo largo. Una venta es comprado, enviado o entregado; lo cobrado sale de
  pago pagado, igual que Reportes. Embudo y busquedas salen de ClickHouse (lote real), lo demas de PostgreSQL. Dias y
  horas en hora de Guatemala.
- Frontend: lib/PanelDashboard.svelte, un dashboard a la vez (Ventas, Clientes, Vendedores y productos, Busquedas,
  Cancelaciones, Pedidos), periodo en un solo boton, exportar en un dialogo. Graficas nuevas en lib/graficas:
  Linea, MapaCalor (5 escalones como la aerolinea), Apiladas, Embudo (barra con borde, Meme lo pidio).
- pruebas/dashboard.mjs (en correr_todas): 35 OK, todas las secciones suman lo mismo, igual que Reportes y que
  PostgreSQL contado aparte, el Excel y el PDF traen esos numeros, el correo rechaza lo invalido sin mandar nada.
- Correo: SMTP_* en backend/.env (no se sube), con la cuenta de LEDKID (LEDKID-SIMULADOR/backend/.env), Meme lo
  autorizo. Probado con un sumidero local y con un correo real a Meme (PDF de octubre, 3.4 s).

Demos de otro pais en remoto: el docker falso le pasa al Docker de esta PC todo lo que no es una de las seis bases
(los mesh-tor-*), y abre Docker Desktop si hace falta. docker.ps1 manda los argumentos en base64 por el ambiente:
Git Bash se comia las comillas simples ('ip') y las llaves ({sg} llegaba a Tor como sg y Tor no salia por el pais).
Probado desde el panel: Singapur, Alemania y Japon, estado, cerrar y limpiar. arrancar.ps1 entero otra vez bien.

Arreglos de pantalla: el carrito de la cabecera es un icono; sin barras de color a la izquierda ni arriba en las
tarjetas (Checkout, Mis pedidos, Reportes, Tendencias, Ofertas, Cifra); Revisar en los avisos del admin abre la
pagina del caso, baja hasta el y lo marca (?anillo=id); en el telefono las pestanas del panel se deslizan.

**ANTES (20-10, de 06:00 a 08:30). Los 6 hallazgos arreglados, sugeridos desde Elasticsearch, demo de concurrencia y semilla remota.**
Meme dio el visto bueno a los arreglos de la seccion de abajo y pidio ademas tres cosas. Todo probado contra
la PC de Jose David (100.64.42.11) y commiteado.

Arreglado (lo que estaba en "Encontrado y SIN arreglar" de abajo):
- MongoDB congelada: conRespaldoDeMongo (helpers/catalogo-respaldo.ts) corre deMongo con conLimite de 3 s. Medido
  3.2 a 3.7 s la primera ficha (antes 9.4 a 15.1).
- ClickHouse congelada: viste hace poco lleva abort_signal limiteDeTienda() de 3 s (database/clickhouse.ts). Medido
  3.0 a 3.5 s (antes 8.0). Los paneles y los workers siguen con 8 s.
- asdffff: sugeridos.service.ts pide 240 vecinos (CUANTOS * 40) en la fuente por significado.
- facetas.py: dos comprobaciones nuevas, los tramos se tocan y son los de backend/src/helpers/facetas-buscador.ts.
  26 OK. Con el 500-1000 movido a 600-1000 fallan las dos.
- notas.sh: espera a que el worker de evento_producto vacie su fila y devuelve el documento a 0 a mano.
- Calificacion: facetado.service.ts devuelve los tramos en el orden de RANGOS_PRECIO y RANGOS_NOTA (4 o mas primero).
- /buscar: el encabezado cuenta lo mismo que el panel, "109 productos encontrados, se ven los 50 mas parecidos".
- Tendencias y Mas vendidos: las compras de un pedido cancelado no cuentan (admin-tendencias.service.ts y
  mas-vendidos-sync.service.ts, id_pedido NOT IN devolucion_producto, como combos-sync). tendencias.sh siembra un
  pedido cancelado y espera 8 en compra y 7 en devolucion.

Nuevo:
- Los sugeridos los elige Elasticsearch (consultaSugeridos en sugeridos.service.ts): fuzziness 2 contra nombre,
  descripcion, variantes y categoria, peso 10, y si nada se parece, ordena por resenas, nota y existencias. Sin
  Elasticsearch, lo de antes (vectores, mas vendido, mas resenados). La respuesta trae sugeridos_desde.
  busqueda.sh parte 6 lo comprueba, caidas.mjs mira que sin Elasticsearch salgan de otra fuente (47 OK en las dos).
- demo-concurrencia.ps1 (pruebas/demo_concurrencia.mjs): N compradores navegan a la vez, la venta relampago con
  mas gente que unidades gana exactamente STOCK, pagan todos a la vez y el stock queda en 0. -Caida redis la hace
  con Redis apagado (decide PostgreSQL con FOR UPDATE). Medido 40 compradores y 10 unidades, con y sin Redis.
  Usa su propio vendedor, vendconcurrencia@mesh.com, y etl/extraer_compras.sql no copia sus ventas, asi la
  limpieza (cancela y borra de ClickHouse) no la deshace el siguiente arranque.
- arrancar.ps1 corre en modo remoto, y el panel de comandos deja generar y borrar productos, volver a migrar,
  rehacer el grafo y levantar todo con las bases en la otra PC (remoto/README.md). Se niegan rehacer MongoDB y
  borrar todo, que borran volumenes alla. Probado desde el panel, 3 productos generados y borrados en las tres bases.
- Las contrasenas de la PC de David estan en remoto/.env.remoto (no se sube). activar.sh las carga.
  redis/prueba_acceso.sh da 31 OK en remoto.

Encontrado y arreglado de paso (ya existia):
- Borrar un lote con -Semilla no arrancaba (la guardia de -Semilla no contaba -Borrar), y sin -Semilla mandaba
  semilla 0 y no borraba nada. Ahora -1 si no se paso.
- Despues de borrar un lote, la lista de productos vivos se escribia con ">" (UTF-16 en PowerShell 5.1), Mongo la
  leia como basura y quitaba TODOS los productos de lote (903 el 20-10); el catalogo los volvia a cargar desde
  PostgreSQL y no se notaba. Ahora WriteAllText en UTF-8 y el script se para si la lista no se lee.

Bateria entera del 20-10 a las 07:00 en remoto: todo en verde salvo correr_patrones (1 FALLA por Neo4j poniendose
al dia con 6 usuarios durante la prueba, repetida sola Todo bien) y caidas.mjs (corrio contra el backend sin
sugeridos_desde; con el backend nuevo 47 y 47). falla_checkout SIN MEDIR en remoto como siempre.
El Word de la Entrega 3 regenerado: 2.6 con los sugeridos de Elasticsearch, tabla 12 y 5.3 con los tiempos
nuevos, facetas 26, caidas 47. 24 paginas.

Estado al cerrar: backend en el 3000 directo a 100.64.42.11 (interruptor quitado), frontend 5173, panel 5199
reiniciado, Ollama arriba. Los 20 pedidos de las dos primeras corridas de la demo (oferta 6059 de vendcarga)
quedaron cancelados y en ClickHouse, como cualquier prueba de vendcarga.

**ANTES (20-10, de 03:30 a 06:00). La bateria entera en remoto, caidas medidas y el Word de la Entrega 3.**
Meme pidio correr la bateria que se corto, hacer el Word de la Entrega 3 y probar todo, y avisar ANTES de arreglar
cualquier cosa que falle. No se toco backend/ ni frontend/. SIN commitear (no lo pidio).

La bateria, de eventos.sh a falla_checkout.sh, corrida en remoto contra 100.64.42.11 (OneDrive cerrado para
hacer sitio, 6 GB libres):

```
en verde        tendencias 53, tendencias_avanzadas 28, etl_mongo 21, resenas 15, casos_fraude_fusion 0 FALLA,
                casos_fraude_granja 6, correr_detectores_resenas, correr_detectores_fraude, vectores_worker 5,
                clasificador_en_postgres 5, recomendacion_semantica 15, facetas.py 24, prueba_carrito,
                prueba_restaurar 20, prueba_concurrencia, mas_vendidos, clickhouse/correr_consultas
repetidas solas eventos 31 (la primera vez fallo por la marca 203.0.113.77 que dejo la corrida que se corto por
                memoria, su trap la limpio al salir), notas 10 (la primera dio 9 y 1: carrera, el worker de
                evento_producto actualizo la nota antes de que el mongosh remoto mirara), correr_patrones Todo
                bien (la primera vio 206 y despues 209 usuarios: Neo4j se puso al dia con PG durante la prueba,
                quedo 209 = 209)
las 16 primeras tambien, repetidas a las 05:15 con el backend directo: etl_compras 30, grafo_compras 25,
                recomendaciones 29, carrito 42, carrito_vencimiento 25, oferta_limitada 33, descuentos 98,
                reglas_descuento 44, reglas_periodo 61, ofertas_paginadas 40 (3 SIN MEDIR de siempre),
                ofertas_y_seguimientos 50, busquedas_sin_resultados 13, busqueda 10 (1 SIN MEDIR), alertas_login 52,
                anillos 27, anillos_familia_b 40, todas 0 FALLA
herramienta     redis/prueba_acceso 12 OK y 19 FALLA, todas de inspeccion y operador: sus contrasenas de la PC
                de David no estan aqui (remoto/README.md)
caidas.mjs      con el interruptor: 46 OK apagadas y 46 OK congeladas
falla_checkout  SIN MEDIR en remoto (SIN_CAIDA=1); la ultima es la del 18-10, 32 OK, sin Redis compra
```

Tiempos medidos con el interruptor (scratchpad tiempos.mjs, mismo dato en la tabla 12 del Word):

```
                apagada                        congelada, primera     vuelve sola
PostgreSQL      < 0.1 s, pagar 503 en 0.2 s    3.0 s                  15.5 s
MongoDB         la primera 3.2 s, luego < 0.4  9.4, 13.8 y 15.1 s     14 s
Redis           < 0.11 s                       3.2 s                  14 s
Elasticsearch   0.2 a 0.3 s                    3.3 s                  15 s
Neo4j           < 0.4 s                        3.2 s                  15 s
ClickHouse      viste hace poco 503 en 0.03 s  8.0 s (las tres veces) 15 s
```

Encontrado y SIN arreglar a esa hora (ARREGLADO despues, ver arriba), con el arreglo propuesto:
- MongoDB congelada: la primera ficha tarda 9 a 15 s, no 3. La conexion abierta no tiene limite por consulta
  (socketTimeoutMS 20 s) y espera a que el latido del driver note la caida. Propuesto: limite de 3 s a deMongo()
  en conRespaldoDeMongo (helpers/catalogo-respaldo.ts), con un Promise.race o el timeoutMS del driver 7.
- ClickHouse congelada: viste hace poco tarda 8 s en avisar (request_timeout 8000 de database/clickhouse.ts).
  Propuesto: 3 s solo en esa consulta, como OPCIONES_BUSQUEDA de Elasticsearch.
- Los sugeridos de asdffff son 4 y no 6. sugeridos.service.ts pide los 36 vectores mas cercanos, y con 1000
  productos de 102 originales (unas 10 copias de lote por original, mismo vector) quedan 4 grupos. Con 200
  vecinos salen 6 distintos (medido con la consulta aparte). Propuesto: CUANTOS * 6 a CUANTOS * 40.
- facetas.py no ve un hueco en un tramo de precio si ningun resultado cae en el (500-1000 movido a 600-1000 dio
  24 OK). Con los filtros devueltos a post_filter si falla, 7 de 24. Propuesto: comprobar que los tramos se tocan.
- notas.sh tiene una carrera con el worker de evento_producto desde la 030 (en remoto a veces da 9 y 1).
- Detalles de pantalla: sin Elasticsearch la faceta de calificacion sale en orden inverso (4 antes que 3); sin
  filtros el encabezado de /buscar cuenta la lista hibrida (50) y el panel la facetada (109); en Tendencias el
  mas vendido y el mas devuelto son el mismo libro (107 y 107) porque cuenta en bruto 50 pedidos del 17-10 que
  estan todos cancelados (Reportes si descuenta lo cancelado).
- La Entrega 2 y la final tienen "python-docx" en el campo modificado por (la 3 ya no).

Revisado aparte: tsc, eslint y svelte-check limpios; dist compilado despues del ultimo cambio de src; la ruta
GET /buscador/productos/facetado da lo mismo que la consulta de referencia de facetas.py (109, 71, 86, 68, 108).
Edge 1536x730, 37 capturas abiertas, 0 errores de JavaScript: portada, buscar (laptop, con categoria, labtop,
asdffff), ficha, pedidos, perfil, las 8 pestanas del admin y las 4 del vendedor; con Mongo congelada la ficha con
su aviso, sin Elasticsearch labtop con categoria y asdffff con sugeridos, sin PostgreSQL portada (las fotos
cargan, la primera captura salio antes de bajarlas), ficha sin vendedores y el aviso al entrar.

El Word: `Reporte Tercera Entrega - DABD2 - Mesh.docx`, 24 paginas, fecha martes 20 de octubre, indice medido
con Word (dos pasadas). Contenido en contenido-entrega3.json: 1.1 a 1.3 al dia (340 commits), 2.4 facetas en la
consulta con la tabla de hoy, 2.6 asdffff, 2.7 buscador sin Elasticsearch, 3 y 4 con el carrito en PostgreSQL
(045, catorce puntos de falla, falla_checkout del 18-10), 5 nueva (la tienda con una base caida, con los tiempos
de arriba), NewSQL pasa a 6, arquitectura a 7 (78 tablas y 94 llaves, migraciones hasta 048), conclusiones a 8.
El generador ahora pone last_modified_by. Para rehacerlo: python generar-reporte-entrega3.py,
.\medir-paginas-entrega3.ps1, python generar-reporte-entrega3.py.

Como quedo la maquina: backend directo a 100.64.42.11 (el interruptor quitado), frontend 5173, Ollama y panel
arriba. backend/.env sin tocar.

**EMPIEZA AQUI (20-10, madrugada). Lo que pidio el profesor, los tres puntos: la tienda sigue con una base caida, las facetas filtran en la consulta y una busqueda sin sentido trae sugeridos.**
Meme dio permiso para tocar `backend/` y las bases de la PC de Jose David. Para David, el detalle de lo
que cambio en su backend: `backend/cambio_propuestas/2026-10-20_0200-caidas-con-respaldo-y-buscador.md`.
Lo que pasa con cada base, para el profesor: `docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md` (reescrito). El plan
de la noche, paso por paso: `docs/PLAN-NOCHE-2026-10-20.md`.

```
cortacircuitos  helpers/cortacircuitos.ts en las seis bases: tras una caida, 15 s sin preguntarle, linea
                "[Cortacircuitos] X no responde / X volvio", GET /db/cortacircuitos. Limites nuevos: pg
                20 conexiones, 10 s para conectar y 120 s por consulta (red), Redis 3 s por comando, Neo4j 20 s (3 s la pagina), Mongo
                socket 20 s, Elastic sin reintento (3 s la pagina)
Redis           los 4 rankings con la consulta del worker en vivo (ClickHouse), ofertas destacadas desde
                PostgreSQL. Arreglado: la copia de ofertas en Redis no se refrescaba con las compras
PostgreSQL      la sesion abierta sigue por su token (SesionGuard), perfil copiado en Redis, carrito desde
                Redis, ficha sin vendedores con ofertas_no_disponibles. No se paga ni se entra de nuevo
Elasticsearch   el buscador (facetado, simple, admin, hibrida, intencion, sugerencias) sale de la copia del
                catalogo en PostgreSQL con la regla de texto del indice (048 APLICADA en la base de David)
Neo4j           para ti y tambien compraron en SQL sobre los pedidos, identicos al grafo
facetas         filtros en el filter de la consulta, agregaciones sueltas (facetado.service.ts, facetas.py)
sugeridos       con 0 resultados y sin filtros: vectores, mas vendidos o mas resenados, aparte; total 0
demo en vivo    remoto/interruptor.cjs + remoto/caidas.ps1, y en el panel el grupo Caida de una base
pruebas         pruebas/caidas.mjs (en correr_todas): 46 OK apagadas y 46 OK congeladas
arreglos        notas.sh 10 OK (el mongosh falso no traducia el /tmp de un guion suelto; si habia
                productos solo en Mongo) y neo4j/correr_patrones.sh Todo bien (el control -206 coincidia
                con la cadena real 203-204-205-206)
```

Medido contra la PC de Jose David, con el interruptor (apagada y congelada):

- Redis: las 8 vitrinas iguales con y sin Redis; 60-115 ms apagada, la primera 3.2 s congelada (antes 503 a
  los 10 s).
- PostgreSQL: con sesion abierta todo 200 en menos de 1.5 s, pagar/agregar/entrar 503 en 0.2 s; congelada
  la primera 3.4 s (consultaCorta de la sesion).
- Elasticsearch: totales y facetas identicos a los del indice, 50-760 ms; congelada la primera 3.5 s
  (antes 22 s).
- Neo4j: 8 de 8 recomendaciones iguales, con el mismo porque; congelada la primera 3 s.
- `elastic/pruebas/facetas.py` 24 OK, `pruebas/caidas.mjs` 46 OK en las dos formas.
- Falso positivo encontrado en la bateria y arreglado: el cortacircuitos de PostgreSQL se abria con la base
  sana cuando 60 logins a la vez se esperaban en la misma fila (pool lleno / consulta larga). Ahora solo lo
  abren fallos de conexion (esCaidaDePostgres).
- `tsc`, eslint de todo el backend (se arreglo un formato de `pedidos.service.ts` de 25f0fe0) y
  `svelte-check` limpios.

`pruebas/correr_todas.sh` en modo remoto: Claude Code la DETUVO por memoria baja en la prueba 17 de 39.
Las 16 que alcanzaron: etl_compras 30, grafo_compras 25, recomendaciones 29, carrito 42, carrito_vencimiento
25, oferta_limitada 33, descuentos 98, reglas_descuento 44, reglas_periodo 61, ofertas_y_seguimientos 50,
busquedas_sin_resultados 13, alertas_login 52, anillos_familia_b 40 (todas 0 FALLA), ofertas_paginadas y
busqueda con sus SIN MEDIR de siempre, y anillos.sh 3 FALLA por el falso positivo de PostgreSQL de arriba.
Arreglado y repetido: anillos.sh 27 OK, caidas.mjs 46 OK apagadas y 46 congeladas. **No se relanzo la
bateria entera** (pidio no hacerlo solo por la memoria): faltan de eventos.sh a falla_checkout.sh. Para
correrla: `source remoto/activar.sh` y `bash pruebas/correr_todas.sh` (unos 40 min), mejor con poco abierto.

Visto en Edge a 1536x730 con cada base caida (12 capturas, todas abiertas): portada sin Redis con sus
vitrinas, ficha sin Mongo con el aviso, labtop sin Elasticsearch con el panel de filtros y la categoria
recortando las facetas, asdffff con Te pueden interesar, para ti y tambien compraron sin Neo4j, sin viste
hace poco con ClickHouse caido, y con PostgreSQL caido la sesion abierta, la ficha sin vendedores y el aviso
al entrar. Ninguna pantalla nombra una base. Los sugeridos juntan las copias de un lote (L1-0880) en una.

Cosas para saber:

- `frontend/src/routes/buscar/+page.svelte` quedo en LF, como los otros 853 archivos del indice (era el
  unico con CRLF). Por eso su diff de 099857c es enorme; lo que cambio de verdad son los sugeridos.
- El backend tarda unos 3 minutos en arrancar contra la PC de David (los workers de arranque).
- La primera busqueda por vector con Ollama frio tarda ~8 s; los sugeridos le dan 3 s y pasan a lo mas
  vendido.
- Sin respaldo, a proposito: crear un avisame (el percolator es de Elasticsearch), el buscador de ofertas
  del vendedor (la lista normal sigue), viste hace poco y las tendencias (las vistas solo viven en
  ClickHouse), iniciar sesion sin PostgreSQL.
- Pendientes del frontend que NO se tocaron (no los pidio Meme): pasar un pedido a enviado y entregado, y
  la serie por dia para las graficas (`docs/BACKEND-PENDIENTE.md`).

Como quedo la maquina: backend (directo a 100.64.42.11, sin interruptor), frontend en 5173, Ollama y panel de
comandos ARRIBA, para que Meme pruebe. Docker local y WSL apagados. `backend/.env` en 100.64.42.11 sin tocar.
Para apagar: los node de backend, frontend y panel, y ollama serve.

**EMPIEZA AQUI (19-10, noche 3). Respaldo del catalogo: la tienda se ve sin MongoDB (4d63929).**
El punto 1 del profesor ("apagan una base y la aplicacion sigue, con las que quedan"). Jose David dio permiso
para tocar `backend/` esta vez. Detalle completo en `backend/cambio_propuestas/2026-10-19_2230-respaldo-catalogo-sin-mongo.md`
y lo que pasa con cada base en `docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md`.

```
047             producto_catalogo suma estado, id_categoria, descripcion y fecha_creacion. APLICADA y llenada en la
                base de Jose David (1000 activos y 1 rechazado; el paso 7e lo hace solo en un arranque)
escrituras      sincronizarCatalogo copia los campos nuevos; editar() sincroniza tambien con solo estado, descripcion
                o categoria; revisar y reenviar una propuesta actualizan el estado en su transaccion
respaldo        backend/src/helpers/catalogo-respaldo.ts: catalogo con todos los filtros fijos, ficha, categorias,
                para ti, tambien compraron, parecidos, vistos recientemente y las dos tendencias salen de PostgreSQL
                si Mongo no responde. Cortacircuitos de 15 s. Filtrar por caracteristica da 503 a proposito
Topology closed si el backend arrancaba con Mongo caido, el driver 7 cerraba el cliente para siempre (500).
                esCaidaDeMongo lo reconoce y el respaldo llama a mongoClient.connect() al volver a probar Mongo
frontend        la ficha con desde_respaldo dice que algunos detalles no se pueden mostrar
```

Medido contra la PC de Jose David, sin tocar su Mongo (el backend apuntado a un puerto cerrado, y un reenviador en
27999 para prender y apagar Mongo en vivo):

- 71 llamadas con y sin Mongo comparadas campo por campo: 362 iguales y 1 distinta (la del filtro por caracteristica).
- Mongo se cae con el backend corriendo: la primera ficha 3.2 s, las siguientes 70 ms; vuelve y a los 15 s sale de
  Mongo sin reiniciar. Arrancar con Mongo caido y que vuelva: se reconecta solo, workers incluidos.
- Las 9 escrituras dejan la copia igual a Mongo. Queda el producto 1104 de la prueba, inactivo (no se ve).
- Edge 1536x730 sin Mongo: catalogo y ficha completos, 0 errores de JavaScript.
- Las 38 pruebas del repo con el backend nuevo: todas bien salvo notas.sh (sin producto solo en Mongo alla, de
  siempre) y neo4j/correr_patrones.sh. etl_mongo.sh dio 1 FALLA porque la prueba de escrituras habia editado su
  producto 21; se borraron esos 4 eventos y volvio a 21 OK. redis/prueba_acceso.sh 31 OK con las contrasenas de
  inspeccion y operador de Jose David pasadas por el ambiente (no estan en el repo).
- **Sin resolver:** neo4j/correr_patrones.sh da 2 FALLA en B.1 (cadenas de los usuarios 203 a 209, que crearon hoy
  pruebas/anillos.sh y anillos_familia_b.sh en la base de Jose David y se quedan). No toca el catalogo. Revisar si la
  prueba debe ignorar cuentas de otras pruebas o si esas pruebas deben limpiar.

Como quedo la maquina: todo apagado (backend, frontend, Ollama, panel de comandos), Docker y WSL apagados,
`backend/.env` en 100.64.42.11. La cuenta desarrollador1@mesh.com existe en la base de Jose David.

**EMPIEZA AQUI (19-10, noche 2). El modo remoto medido contra la PC de Jose David, y el documento de fraude.**
No se toco `backend/`. Pusheado en main: 94335e0 (modo remoto) y becbbba (documento).

```
remoto/          commiteado (antes estaba sin subir). Medido entero contra 100.64.42.11 con el Docker local
                 apagado: lo que salio y lo que se arreglo esta en remoto/README.md, seccion Medido.
                 Nuevo: redis-benchmark y pg_isready, docker exec de comandos comunes (true, cat, rm),
                 docker ps con ^nombre$, el \o de psql y el '/tmp/ de los guiones de mongosh, la ruta
                 de los clientes de Node (no arrancaban), y activar pone SIN_CAIDA=1
pruebas          carrito.sh (elegia dos veces la misma oferta), etl_compras.sh (mide las compras aunque
                 no haya devoluciones copiadas por el ETL), falla_checkout.sh (SIN MEDIR con SIN_CAIDA),
                 recomendacion_semantica.py (docker falso por el bash de Git), correr_todas.sh (no le
                 pasa SALIDA a las pruebas: eventos.sh se caia entera)
demo             demo-evento-fraude.ps1 -Tipo multi_cuenta_ip_lenta en modo remoto, de punta a punta
docs             FRAUDE-DETECCION-Y-CASOS.md (lo pidio el amigo de Meme): los 31 tipos con su detector,
                 umbral y puntos, que entra a un caso y que no, la union por cuentas, nucleo y periferia,
                 el puntaje, los niveles, las reglas R-CASI tal como las revisa el codigo y la vida de un
                 caso. FRAUDE-CATALOGO.md corregido: el texto se valora desde 100 caracteres, no 40
```

Contra la PC de Jose David, en verde todo menos:

- **prueba_acceso 19 FALLA**: sus contrasenas de `inspeccion` y `operador` de Redis son otras. Hay que
  pedirselas y pasarlas por el ambiente (remoto/README.md).
- **recomendacion_semantica 1 FALLA, fallo real nuestro, ARREGLADO**: `producto_catalogo` tenia 102 productos
  (1001 a 1102) que ya no estaban en Mongo ni tenian vector, de un `-Borrar 102` en esa PC.
  `migrations/lote/borrar_lote.sql` era del 03-09 y no borraba de `producto_catalogo` (029 y 040 son
  posteriores). Ahora lo borra (sus variantes y su vector se van por la cascada) y se comprueba en el bloque
  de verificacion; validado con EXPLAIN, el -Borrar entero no se volvio a correr (pide un lote generado en una
  base local). Con permiso de Meme se borraron los 102 en la base del amigo, en una transaccion que exigia
  que fueran exactamente 102 sin oferta, pedido ni resena y que no estuvieran en Mongo: producto_catalogo
  quedo en 1001, igual que Mongo y vector_producto (202 variantes se fueron con ellos). La prueba otra vez:
  15 OK, 0 FALLA.
- **SIN MEDIR por sus datos**: busqueda parte 4 y notas.sh (no hay producto que viva solo en Mongo; se crea uno
  desde el panel del vendedor), las devoluciones de etl_compras, falla_checkout (en remoto no se tumban bases).

**La semilla de fraude, sembrada en la base del amigo** (con permiso de Meme), como el paso 5e de arrancar
pero por el psql falso: 3 vendedores y 21 compradores `fraude.*@mesh.com`, 26 resenas, 35 pedidos (3
cancelados). El backend de aqui calculo y valoro los 26 vectores y paso todo al grafo por sus colas, despues
`bash etl/cargar_compras.sh` (35 ventas y 3 devoluciones nuevas, cuadra) y `node pruebas/correr_detectores_fraude.cjs`.
Salieron las 8 senales y ninguna de mas con esas cuentas: satelites, persistente, reputacion_expres,
resenas_repetidas, compras_en_rafaga, devoluciones_seriales (por cuenta), notas_incoherentes_producto en el
Sillin Vertebra SR-2 (p71) y resenas_parecidas_producto en los Guantes Zarpa 300 (p66). Su proximo
`.\arrancar.ps1` dira que ya estaban y no tocara nada.

**Las bases apagadas en vivo, la misma noche.** La PC de Jose David apago por rondas Neo4j y ClickHouse, Redis y
Elasticsearch, y MongoDB, y se midio cada funcion de la tienda, una compra por ronda (1063, 1064 y 1065,
canceladas) y la vuelta. Todo en `docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md` (77e9a31, 3d02c35), con lo que se ve en
cada pantalla y como mirarlo en el registro del backend y en las colas. De ahi salieron dos arreglos:
- f25b608: ningun error nombra una base en la pagina (`pedir()` de `frontend/src/lib/api.ts` cambia el mensaje
  si trae el nombre de una pieza interna y lo deja en la consola). Pedido de Meme.
- 341d985: el panel de comandos corre las demos en modo remoto, mira el estado de las bases en la otra PC y niega
  lo que arranca o rehace bases; redis-cli de remoto/ lee REDISCLI_AUTH. Se creo `desarrollador1@mesh.com`
  (Desarrollo123!, vendedor) en la base de Jose David por la API: no existia alla y Meme no podia entrar.

Sin hacer, a proposito:

- Lo de "luego" de Meme: los 3 puntos del profesor (backend) y las resenas del clasificador que no hablan de su
  producto.

Como quedo la maquina: todo apagado (backend, frontend, Docker, WSL, Ollama), Tailscale conectado y
`backend/.env` apuntando a 100.64.42.11.

**EMPIEZA AQUI (18-10, noche). Semilla de combos y pedidos quitados que tambien se borran de ClickHouse.**
Lo que David dejo en `backend/cambio_propuestas/2026-10-17_0015-combos.md`: la portada "Se compran juntos" y la
ficha "Quienes lo compraron tambien llevaron" necesitaban pedidos de varios productos que tengan sentido juntos.
No se toco `backend/`.

```
semilla-combos/  combos.sql (idempotente: si ya existe cualquiera de las 8 cuentas no toca nada), quitar.sql y
                 README. 8 cuentas combo1..combo8@mesh.com (clave Comprador123) con direccion, 18 pedidos y 45
                 lineas de 8 combos (3 trios y 5 pares), cada combo en 2 o 3 pedidos, comprados con
                 crear_pedido, agregar_linea y comprar_pedido, fechas relativas en los ultimos 180 dias
arrancar.ps1     paso 5d "Pedidos de los combos" (dice si sembro o si ya estaban y lista los combos) y, en el
                 ETL de ClickHouse, Quitar-Compras antes de copiar
migracion 046    pedido_quitado: desde psql no se llega a ClickHouse, asi que cada quitar.sql anota los pedidos
                 que borra y el ETL de compras (arrancar.ps1 y etl/cargar_compras.sh) los borra de
                 compra_producto y devolucion_producto y marca aplicado_en
clasificador     su quitar.sql tambien anota (motivo semilla-clasificador). generar.js lee desde el 19-10 los
                 vectores de vector_producto de PostgreSQL y corre de nuevo; resenas.sql regenerado (20 resenas
                 que caian en productos de prueba del panel ahora caen en productos de verdad)
huerfanas        las 480 lineas de los pedidos 771 a 1250 ya se borraron de ClickHouse; etl_compras.sh en verde
```

Probado con la base LOCAL:

```
arrancar.ps1    tres veces: la segunda no duplica; quitar.sql y arrancar otra vez deja la misma foto (cuentas,
                pedidos, lineas, stock de cada oferta, ClickHouse y grafo)
desde cero      mesh_limpia: entra sin error, segunda pasada sin duplicar, borrada al terminar
backend         /productos/combos trae los combos sembrados, tambien-compraron y para-ti coherentes, conciliacion
                del grafo cuadrada (832 y 832), ninguna senal, hallazgo ni caso de fraude con las cuentas combo
pruebas         las 35 con exit 0: etl_compras 30 (antes 5 FALLA, con parte 7 nueva del borrado), grafo_compras
                30, recomendaciones 29, carrito 42, carrito_vencimiento 25, oferta_limitada 33, descuentos 98,
                reglas 44 y 61, ofertas_paginadas 40 (3 SIN MEDIR de siempre), ofertas_y_seguimientos 56,
                busquedas_sin_resultados 13, busqueda 13, alertas_login 52, anillos 27 y 40, eventos 31,
                tendencias 53 y 28, etl_mongo 21, resenas 15, notas 10, fusion 0 FALLA, granja 6, vectores 5,
                clasificador 5, recomendacion_semantica 15, facetas.py 19, prueba_acceso 31, prueba_carrito,
                prueba_restaurar 20, prueba_concurrencia sin sobreventa, mas_vendidos, falla_checkout 32
Edge            1536x730 sin ventana: portada con "Se compran juntos" y ficha de la Laptop Aurora 14 con sus
                audifonos y su monitor primero en "Quienes lo compraron tambien llevaron"
```

- **Hasta el 26-10 la portada muestra 5 de los 8 combos**: los pedidos 6 y 10 de la semilla original (muchos
  productos sueltos) llenan los demas lugares con trios sin sentido y salen solos de la ventana de 180 dias ese
  dia. Sugerencia para David en `docs/BACKEND-PENDIENTE.md` (MAX_PRODUCTOS_POR_PEDIDO mas bajo).
- backend/.env vuelto a 100.64.42.11 al terminar.
- Para estudiar todo lo del backend del 1 al 18-10 (carrito con verdad en PostgreSQL, pgvector, percolator,
  compras en el grafo, combos, fraude por texto y la limpieza del 17-10): `docs/guia-estudio-cambios-backend-octubre.md`,
  con el mismo formato que las guias de David en `backend/elementos Generales/guias-estudio/`.

**EMPIEZA AQUI (18-10). Lo de David del 16 y 17 (25f0fe0) llevado a todas las capas y probado en la base local.**
Meme pidio revisar lo nuevo de GitHub, aplicarlo en todos lados y probarlo a fondo. David subio 126 archivos de
`backend/` (carrito con la verdad en PostgreSQL, vectores de vuelta a pgvector, compras en el grafo, buscador de
ofertas, avisame con percolator, limpieza de fraude, combos y busquedas sin resultados) y dejo marcadores de conflicto
en `docs/BACKEND-PENDIENTE.md` (arreglado). Lo que le toca a el esta al principio de ese archivo. No se toco `backend/`.

```
migraciones     040 vectores en PostgreSQL, 041 compras al grafo, 042 limpieza de fraude, 043 cola de ofertas,
                044 avisame, 045 carrito en PostgreSQL. Las siembras corren una sola vez (no en cada arranque)
arrancar.ps1    vectores ANTES del indice del buscador (copia los de Elasticsearch sin Ollama la primera vez),
                indice sin vector, encola los comentarios y borra mesh_comentarios, crea mesh_ofertas y
                mesh_seguimientos (paso 9e; recarga el percolator desde PostgreSQL si no cuadra), y el ETL del
                grafo vuelve a encolar las compras tras --limpiar
otras capas     elastic 004 y 005, clickhouse termino_normalizado, neo4j compra_id, redis rama restaurar,
                etl/cargar_vectores.ps1 a vector_producto
frontend        carrito desincronizado y su boton, 409 del checkout, sin el modo pedido, avisame (ficha, /buscar,
                pestana Avisos y numero en la cabecera), tambien compraron, combos, buscar ofertas, lo que no
                tenemos, fuera los tipos de fraude quitados. svelte-check 0 en 222 archivos. Visto en Edge
```

Probado el 18-10 con la base LOCAL (backend/.env apuntado a localhost con `usar-bases-remotas.ps1 -Local`):

```
arrancar.ps1    sobre la base vieja (039): exit 0 en 307 s, migraciones sin error, 3105 vectores copiados de
                Elasticsearch, 16936 ofertas encoladas e indexadas por el worker en ~2 min, 700 comentarios
                recalculados. Segunda vez, borrando mesh_ofertas y mesh_seguimientos con 3 avisos vivos: exit 0
                en 181 s, los dos se rehicieron y las 3 consultas volvieron identicas
desde cero      base aparte mesh_limpia en el mismo contenedor: migraciones y semilla sin un error, las colas
                se llenan solas por los triggers; segunda pasada solo con los already exists de 001-006 y sin
                duplicar nada. Borrada al terminar
pruebas nuevas  ofertas_y_seguimientos 56 (con Elasticsearch caido), grafo_compras 30 (con Neo4j caido),
                busquedas_sin_resultados 13, redis/prueba_restaurar 20
actualizadas    carrito 42, carrito_vencimiento 25, falla_checkout 32 (con Redis parado AHORA COMPRA),
                anillos_familia_b 40, recomendaciones 29, vectores_worker 5, clasificador_en_postgres 5,
                recomendacion_semantica 15
sin cambios     oferta_limitada 33 (y PostgreSQL registro las 40 reservas y las devolvio), descuentos 98,
                reglas_descuento 44, reglas_periodo 61, ofertas_paginadas 40 (3 SIN MEDIR de siempre),
                alertas_login 52, anillos 27, eventos 31, tendencias 53 y 28, etl_mongo 21, resenas 15,
                busqueda 13, notas 10, facetas.py 19, casos_fraude_fusion 0 FALLA, granja 6, prueba_acceso 31,
                prueba_concurrencia sin sobreventa, detectores de resenas corren
demos           demo-entrega-final (las 9 partes), demo-patrones-resenas 2 de 2, demo-resenas-texto 6 de 6
```

Lo que salio en el camino:

- **etl_compras.sh 5 FALLA, de antes.** ClickHouse tiene 480 lineas de compra de pedidos (771 a 1250) que ya no
  estan en PostgreSQL: son los de la semilla del clasificador que `clasificador-resenas/semilla/quitar.sql` borro el
  04-10 y que ClickHouse conservo (fechas de enero a septiembre). arrancar tambien lo avisa ("las ventas no
  cuadran"). No es de lo de hoy; para limpiarlo, `quitar.sql` tendria que borrar tambien en ClickHouse.
- **Un fallo mio, arreglado:** `cargar_vectores.ps1` leia `activo` como 't' y PostgreSQL lo da como 'true' al
  concatenarlo; cada arranque reescribia 3103 filas. Medido en el segundo arranque, corregido y vuelto a correr: 0.
- **Notas incoherentes ya detecta** (3 por cuenta, 3 por vendedor) con la version en SQL de David; el 08-10 daba 0.
- **POST /comprador/seguimientos da 201**, no 200 como dice su doc (anotado para David).
- **Sin hacer, a proposito:** las semillas con pedidos de varios productos para los combos (David las pidio). Cambian
  conteos que esperan varias pruebas; queda para decidirlo con Meme.

Como quedo la maquina: ver el final de esta entrada en el resumen del 18-10 (se apago todo y `backend/.env` volvio a
apuntar a la PC de David, 100.64.42.11). En la PC de David hay que hacer `git pull` y `.\arrancar.ps1`.

**EMPIEZA AQUI (08-10, 16:00). Con el arreglo de Postgres de David (f03636b), todo el repo en verde contra su PC.**
Backend, frontend y Ollama en la PC de Meme; las seis bases en la de David por Tailscale. Su base ya tiene 1000
productos exactos (102 curados + 898). En Mongo esta ademas el 1103, una propuesta rechazada que se deja A PROPOSITO
para la parte 4 de `busqueda.sh` (sin ella queda SIN MEDIR); a las 16:20 se renombro a "Laptop Quetzal 13" para que
no diga "prueba" en el panel, y la parte 4 sigue en verde.

```
corte real      a las 15:37 hubo un microcorte de Tailscale (timeouts de Postgres y Mongo) y el backend NO se
                cayo: dejo "Se perdio una conexion en uso" y siguio con el mismo proceso. Antes moria. Tambien
                probado a mano con pg_terminate_backend sobre una conexion sacada del pool
en verde        carrito 25, resenas 15, recomendaciones 23, tendencias 53, tendencias_avanzadas 28,
                reglas_descuento 44, reglas_periodo 61, ofertas_paginadas 40, descuentos 98,
                carrito_vencimiento 20, oferta_limitada 33, eventos 31, alertas_login 52, anillos 27,
                anillos_familia_b 37, etl_mongo 21, busqueda 10 (1 SIN MEDIR), casos_fraude_fusion 0 FALLA
                (con las senales que sembro David), casos_fraude_granja 6, vectores_worker 5,
                clasificador_en_elastic 3, facetas.py 19, recomendacion_semantica.py 15
por los datos   notas.sh 9 y 1 (un worker actualiza la nota antes del ETL) y etl_compras.sh 18 y 1 (no hay
                devolucion copiada por el ETL), los dos igual que en la manana
falla_checkout  corrida por David en su PC a las 16:40, 32 OK, 0 FALLA (3 pedidos nuevos y Postgres reiniciado
                a las 16:39 en su base). Con eso la Entrega 3 y la final quedan completas
de David        solo NotasIncoherentesDetectorService, en 0 contra 8 del clasificador, que no lo pide ninguna entrega
informes        los dos regenerados el 08-10 con 1000 productos, 304 commits y portada del 8 de octubre
```

El `docker` falso de la manana se rehizo en la carpeta temporal de la sesion: `psql` (con `-v`, `:{?var}`, `\set`
y `\if`, que usa extraer_eventos.sql) y `redis-cli` (con `-x` y `--scan`) en Node, mongosh 2.3.8 de npm,
mongodump/mongorestore 100.10.0, y `clickhouse-client` por HTTP (con `INSERT ... FORMAT` por stdin). Trampas que
costaron una vuelta: las pruebas exportan `MSYS_NO_PATHCONV=1`, asi que los clientes necesitan rutas `C:/...`;
los .js de Mongo leen `/tmp/...` fijo, que para Node en Windows es `C:\tmp` (se resolvio con un junction temporal,
ya borrado); `alertas_login.sh` y `busqueda.sh` piden `ES=http://100.64.42.11:9200`; y
`recomendacion_semantica.py` llama a `docker` desde Python, que no ve un script de bash.

**EMPIEZA AQUI (08-10, tarde). Las pruebas del repo corridas contra las bases de David.** Todo en verde menos lo
que depende de sus datos o de su PC. Sin correr: falla_checkout.sh (apaga contenedores, va en la PC de las bases) y
redis/prueba_concurrencia.sh (usa redis-benchmark dentro del contenedor). No se toco `backend/`:

```
en verde        carrito 25, resenas 15, recomendaciones 23, tendencias 53, tendencias_avanzadas 28,
                reglas_descuento 44, reglas_periodo 61, ofertas_paginadas 40 (3 SIN MEDIR, sin pendientes),
                descuentos 98, carrito_vencimiento 20, oferta_limitada 33 (60 compradores sobre 20 unidades),
                eventos 31, alertas_login 52, anillos 27, anillos_familia_b 37, etl_mongo 21,
                casos_fraude_granja 6, los 5 detectores de resenas corren (0 senales), mas_vendidos bien
por los datos   notas.sh 9 OK y 1 FALLA: un worker del backend ya actualizo la nota antes de correr el ETL
                (la prueba supone que nadie mas la toca). etl_compras.sh 18 OK y 1 FALLA: la parte 5 pide
                una devolucion copiada por el ETL y en la base de David la unica la escribio el backend.
                casos_fraude_fusion.cjs no corre: faltan dos senales de anillo y una multi_cuenta_ip, que
                en la base de Meme dejaron las demos de fraude
redis           prueba_carrito.sh: un TTL leido en 12 y no entre 13 y 15, por la latencia de llamar por la
                red; la renovacion si se ve (de 5 a 12)
pruebas viejas  resenas.sh mandaba un comentario de menos de 40 letras (la regla es del 04-10);
                anillos_familia_b.sh contaba 7 tipos en patron_resenas y desde la 035 son 16, ahora busca los
                7 de la familia B por nombre; etl_compras.sh tenia los pedidos 10, 11 y 18 fijos, ahora si no
                estan elige otros de lo que copio el ETL
backend         se cayo tres veces hoy con el mismo error de Postgres (abajo y en BACKEND-PENDIENTE.md)
```

Como se corrieron desde la PC de Meme: un `docker` falso que corre el comando de cada `docker exec` en esta PC, con
el ambiente del contenedor y clientes que apuntan a 100.64.42.11 (psql y redis-cli en Node, mongosh 2.3.8 de npm,
mongodump 100.10.0 y ClickHouse por HTTP). Vivio en la carpeta temporal de la sesion, no en el repo.

**EMPIEZA AQUI (08-10). Todo lo de la Entrega 3 y la final probado con las bases en la PC de David.** Backend,
frontend y Ollama en la PC de Meme. No se toco `backend/`:

```
pruebas         facetas.py 19 OK, recomendacion_semantica.py 15 OK, vectores_worker.cjs 5 OK,
                clasificador_en_elastic.mjs 3 OK, busqueda.sh 10 OK y 1 SIN MEDIR. De punta a punta por el
                backend: buscar, filtros, autocompletado, quisiste decir, hibrida, intencion, parecidos,
                login, carrito, comprar, historial y cancelar (el stock baja y vuelve)
redis           prueba_acceso.sh 31 OK contra el Redis de David. Sus contrasenas de inspeccion y operador
                NO son las del .env de Meme (su arrancar las genero): se pasan como variables de entorno
sin correr      falla_checkout.sh, porque apaga contenedores y solo corre en la PC de las bases
frontend        /buscar ya no ensena lo que la hibrida trae por significado con poca similitud: "labtop"
                ponia una lampara despues de cada laptop. filtrarHibrida() en lib/buscador.ts, con los
                numeros medidos; pedido a David en BACKEND-PENDIENTE.md
busqueda.sh     las partes 3 y 4 buscan el producto en la base que haya en vez de los ids fijos 103 a 106
                de la base de Meme (en la de David son del lote y daban 3 FALLA falsos); sin datos dicen
                SIN MEDIR. En la base de David quedo el 1103, una propuesta rechazada para la parte 4
backend         se cayo a las 10:25 por el corte de Postgres de abajo, ahora sin que David apagara nada. Lo
                primero que tiene que arreglar antes de presentar
Ollama          la busqueda por intencion, la hibrida y el worker de vectores lo piden en localhost:11434;
                con las bases en otra PC hay que levantar el Ollama de Meme ("ollama serve")
WARP            NO apagarlo: ya excluye 100.64.0.0/10 y es lo que deja salir el tunel de LEDKID en la U
```

**EMPIEZA AQUI (07-10). Las bases pueden vivir en otra PC.** La laptop de Meme llegaba al 95 % de RAM con todo
arriba. Ahora David corre las seis bases en su PC y Meme solo el backend y el frontend, por Tailscale. Probado en vivo
en la red de la UNIS:

```
scripts         preparar-pc-bases.ps1 (la PC de las bases) y usar-bases-remotas.ps1 -Ip / -Local (la del
                backend), commit 73dbb16. Como se usan, en instalacion.md, "Bases en otra PC"
arrancar        -Reiniciar -Productos N ya no rechaza el lote con Mongo vacio (c52d22c)
PC de David     desktop-kmf1be7, 100.64.42.11, compartida a la cuenta de Tailscale de Meme. 1102 productos
                (102 curados + lote L1 de 1000), todos con vector; 570 resenas
medido          las seis bases a ~10 ms, login 0,6 s, busqueda con quisiste decir 0,4 s; el worker de
                comentarios lleno mesh_comentarios (598) en 30 s con el Ollama de Meme
pendiente       de David: un corte de red con una conexion de Postgres en uso tumba el backend (paso cuando
                apago su PC). Arreglo propuesto al principio de BACKEND-PENDIENTE.md, no se toco backend/
```

En la PC de Meme: el `backend/.env` quedo apuntando a 100.64.42.11 (copia en `.env.antes-remotas`). Para volver a lo
local, `.\usar-bases-remotas.ps1 -Local`. Se quitaron de WARP cinco exclusiones de `*.tailscale.com` que hacian que la
UNIS cortara Tailscale. Meme quiere 1000 productos exactos: no se borran los 102 curados (ventas, resenas, son las
plantillas del generador); David corre `.\arrancar.ps1 -Borrar 102` y quedan 102 + 898.

**EMPIEZA AQUI (06-10). Los dos informes, al dia. SIN commitear, sin levantar nada.** Solo se toco el contenido y
la fecha de los informes, nada de codigo:

```
Entrega 3       16 paginas. Comprar con MongoDB caido (4.3 reescrita, falla_checkout 32 OK del 01-10), copia
                del catalogo y cola evento_producto en 3.1 y 3.2, quisiste decir en 2.3, vector en el mapeo,
                291 commits, 76 tablas y 97 llaves, diagrama al 04-10
Entrega final   20 paginas. ADR-10 revisado (2.2, el vector pasa a Elasticsearch), consulta kNN de
                SimilaresService (2.4), busqueda hibrida y por intencion (2.6), seccion 5 nueva con el modelo
                unico de senales, las senales de resenas (035, 037 a 039) y el clasificador. Retrospectiva con
                siete y siete; ya no dice pgvector como si siguiera
Fecha           martes 6 de octubre en las dos portadas (FECHA de los dos generadores). Cambiarla el dia
                que se entregue
```

Sin correr tras el 04-10, y lo que el informe da por bueno con la ultima medicion: `busqueda.sh`, `facetas.py`
(19 OK del 28-09) y los arneses en serie. Correrlos antes de presentar.

**EMPIEZA AQUI (04-10). Los vectores y las resenas viven en Elasticsearch, y las senales de David estan conectadas.
TODO commiteado y pusheado, todo apagado.** Se jalaron y conectaron tres commits de David, fa3281c, 3305cf3 y
1f1f480; todo lo que dejo como "Pendiente de otros" esta hecho. El detalle, con lo medido y lo que le toca a el, esta
al principio de `docs/BACKEND-PENDIENTE.md`.

```
migraciones     034 cola evento_comentario, 035 senales de texto, 036 quita producto_vector, 037 notas
                incoherentes, 038 resenas parecidas, 039 resenas canceladas (fuente postgres)
elastic         001 con el vector de cada producto; 003_comentarios.json, el indice mesh_comentarios con el
                vector en flat (HNSW no encontraba las mejores con textos repetidos)
arrancar        el indice de productos compara contra TODOS los de Mongo (se rehacia en cada arranque); antes de
                rehacerlo guarda los vectores en mesh_productos_vectores_previos; el paso 7d va despues del
                buscador; paso Indice de comentarios; paso Resenas del clasificador (480 resenas de 40 cuentas)
etl             cargar_vectores.ps1 escribe en Elasticsearch y devuelve los guardados sin Ollama (48 s y no 7 min)
frontend        /buscar con la hibrida, el quisiste decir y Lo que cuentan otros compradores; formulario de
                resena de 40 a 350; sugerencias al proponer; los tipos nuevos en Fraude
demos           demo-resenas-texto.ps1 y cuatro partes nuevas de demo-entrega-final.ps1, todas en el panel
pruebas         recomendacion_semantica.py 15 OK, vectores_worker.cjs 5 OK, clasificador_en_elastic.mjs 3 OK,
                correr_detectores_resenas.cjs para no esperar los 15 minutos
```

Medido: arrancar entero exit 0 tres veces seguidas, svelte-check 0, la demo de resenas da cada senal sola a los 3 o
4 segundos. Respaldo de antes de la 034 en `respaldos/antes_034_20261004.dump`. Lo que queda abierto es de David:
el quisiste decir con frases, las copias del generador en la hibrida y la intencion, el umbral de 0,40 y los nodos
de producto huerfanos del grafo. El informe de la Entrega final (`contenido-entrega-final.json`) sigue diciendo
pgvector en la seccion 2.1: no se toco porque es un entregable.

**Trampa nueva:** los procesos que se lanzan con Start-Process desde una sesion de Claude se mueren al cerrarse la
llamada. Backend, frontend y panel se levantaron con Invoke-CimMethod Win32_Process Create.

**EMPIEZA AQUI (02-10). El frontend ya no tiene el flujo viejo del pedido abierto. SIN commitear.** GitHub no
traia nada nuevo (main = origin en 66ea178). Se borro lo que quedaba de abrir un pedido vacio y llenarlo linea por
linea, que ya nadie usaba porque el boton Agregar va al carrito de Redis:

```
frontend        lib/Pedido.svelte borrado (la caja "Tu pedido / Abrir pedido" que salia en /pedidos);
                producto/[id] sin pedidoAbierto() ni el aviso "Se entrega en"; pedido.ts sin leerPedidoAbierto,
                guardarPedidoAbierto, crearPedido, agregarLinea, quitarLinea, pedidoCaduco ni LineaAgregada.
                olvidarPedidoAbierto se queda (borra la llave vieja del localStorage)
docs            frontend.md, PENDIENTES 3, BACKEND-PENDIENTE (agregarLinea ya no le toca a David; las rutas
                POST /comprador/pedidos y /detalles quedan sin uso, el decide si las borra)
```

Medido: svelte-check 0 en 218 archivos, `npm run build` bien, `arrancar.ps1` entero exit 0 (033 migraciones, 3105
de 3105 con vector, todas las ofertas con su variante en variante_catalogo, grafo cuadrado). Backend y frontend
con `panel-comandos\servicios.ps1`. En Edge sin ventana como admin: Agregar en la ficha deja la linea en el carrito
de Redis, `/pedidos` muestra solo "Pedidos anteriores" y 0 errores en consola. Se borro despues la linea del carrito
y los 2 eventos de la prueba en ClickHouse (vista_producto, carrito_producto y vistas_por_producto_dia del dia).
Quedo TODO LEVANTADO. De David solo queda la llave foranea de `oferta` a `variante_catalogo`.

Ideas del equipo sin decidir (02-10): tendencias con las palabras de las resenas (significant_text de
Elasticsearch, con la calificacion como peso y sin cuentas con senal_fraude); detectar cuentas con muchas resenas
de 5 estrellas casi iguales por vector (senal nueva de fraude, con largo minimo); buscar por intencion sobre el
texto de las resenas. Opinion dada: mantener pgvector y copiar el vector a Elasticsearch (ADR-17), no mudarlo.

**EMPIEZA AQUI (01-10, madrugada). Comprar sin MongoDB queda con el diseno de David, probado y pusheado.** David subio
6f89237 sin conocer nuestra 029 y 030, que nunca se habian subido, con otro diseno. Por decision de Meme se quedo el suyo:

```
migraciones     029_catalogo_en_postgres (producto_catalogo y variante_catalogo) y 030_evento_producto (outbox, una
                fila pendiente por producto, triggers en oferta y resena). Las nuestras (columnas en oferta y
                evento_catalogo) se borraron del repo, junto con pruebas/evento_catalogo.sql y docs/PLAN-COMPRAR-SIN-MONGO.md
arrancar 7e     etl/extraer_catalogo_postgres.js, dentro de los contenedores, solo escribe lo que cambio
base local      limpieza UNA vez de lo viejo (columnas de oferta, evento_catalogo, sus triggers y funciones) y
                oferta_tocar_fecha() devuelta a la de la 005, que la 029 vieja habia reescrito y nada restauraba.
                Respaldo previo en respaldos/antes_029david_20261001_0543.dump
pruebas         falla_checkout.sh escenario B ahora EXIGE comprar con Mongo parado (regla debe-comprar).
                descuentos.sh espera a que evento_producto procese el producto antes de mirar Mongo
docs            CONSISTENCIA-CHECKOUT filas 8 y 11 (resuelta), base-de-datos, ARQUITECTURA (Mermaid, linea de tiempo,
                diagrama), ER, migrations/README, BACKEND-PENDIENTE, PENDIENTES 12
```

Medido, prendiendo solo lo necesario: dos pasadas del esquema limpias; paso 7e con 3105 productos y 6232 variantes en
3 s, la segunda vuelta escribe 0 y 0, 0 ofertas sin su variante de 16915. `falla_checkout.sh` 32 OK, 0 FALLA: con
Mongo parado COMPRA y las cuatro tablas se mueven juntas; el worker vacio evento_producto (3 recalculados, 0 errores).
`descuentos.sh` 98 OK. ER 76 tablas y 97 llaves. Todo apagado al final. Lo que queda de David: la llave foranea de
oferta a variante_catalogo (su etapa 2) y `PedidosCompradorService.agregarLinea`.

**EMPIEZA AQUI (30-09, noche). Escrito, PROBADO en vivo y commiteado.** Se jalo 7453ffe de David, el refactor de
fraude a un solo modelo de senales (`senal_fraude`), con merge 880073f junto a la 029 y la 030, que siguen sin push.
Su backend ya solo lee y escribe las tablas nuevas y no traia migracion. De este lado:

```
migraciones     031_senales_fraude, 032_evidencia_y_aviso_por_senal, 033_sin_llaves_viejas_de_fraude, de sus .sql de
                referencia. La copia de las tablas viejas y la 032 corren UNA vez, mientras exista
                evidencia_caso_fraude.id_anillo_fraude, que la 033 quita. La 018 y la 026 llevan un \if de psql para
                no cortar el arranque siguiente (la unica edicion de migraciones corridas, en migrations/README.md)
pruebas         casos_fraude_fusion y _granja siembran senales; anillos, anillos_familia_b, alertas_login y
                ofertas_paginadas leen senal_fraude. alertas_login mide cuanto SUBE total_detecciones
demos           demo-evento-fraude y demo-fraude-pais leen y limpian senales
clickhouse      F2, F3 y F5 con ids_pedidos, max_pedidos=50 en parametros.txt
panel           login dice "N veces" y "Ultima vez"
docs            ER (generar-er.py, con evento_catalogo que faltaba), base-de-datos, ARQUITECTURA, preguntas 57, 92,
                93, 120 y la 122, BACKEND-PENDIENTE, PENDIENTES 31 y 32
```

Sin levantar nada tambien dio 0 el parser de PowerShell, svelte-check (219 archivos) y el tsc del backend.
`arrancar.ps1` entero el 01-10 de madrugada: exit 0, sin fallos, con la 031 a la 033 dentro. Todo apagado al final.
**Probado en vivo el 30 a las 22 h**, prendiendo solo lo que cada paso pedia. Respaldo previo en
`respaldos/antes_031_20260930_2208.dump` (git lo ignora). Medido:

```
esquema          dos pasadas enteras de 001 a 033, las dos limpias; la segunda pasa la 018 y la 026. Re-correr la
                 031 no pisa una senal revisada (probado y devuelto)
copia            67 anillos a 67 senales, 190 alertas de login a 28 senales con 1622 detecciones, evidencia 163 a 71
                 (el mismo hecho contado varias veces en un caso), notificaciones 925 a 125. Ninguna evidencia sin senal
ER               74 tablas y 96 llaves foraneas, sin cajas pisadas
backend          compila y arranca; el agrupador lee las senales (13 casos de 71 hallazgos)
pruebas          alertas_login 52 OK, ofertas_paginadas 40 OK, anillos 27 OK, anillos_familia_b 37 OK,
                 casos_fraude_fusion 0 FALLA (C1 sigue como DECISION), casos_fraude_granja 6 OK,
                 clickhouse/correr_consultas.sh bien con ids_pedidos. 0 FALLA en todas
demos            demo-evento-fraude con fuerza_bruta_cuenta y multi_cuenta_ip; el -Limpiar de demo-fraude-pais borro
                 tambien 7 senales de IPs de Tor de demos viejas (es lo que hace -Limpiar)
```

El borrado de las tablas viejas (`refactor-fraude-senales-etapa8-borrado.sql`) no se hizo: la 016, la 019, la 023 y
la 025 las vuelven a crear en cada arranque.

**EMPIEZA AQUI (29-09).** De las propuestas del profesor se empezo por la decision 5, comprar sin MongoDB. La
base quedo hecha y probada en vivo: `migrations/029_catalogo_en_oferta.sql` (seis columnas en `oferta`, la funcion
`copiar_catalogo_a_oferta` y el trigger de la fecha que ya no se mueve por la copia) y el paso 7e de `arrancar.ps1`
con `etl/extraer_catalogo_oferta.js`. Medido: 16908 ofertas copiadas, la segunda vuelta cambia 0, las fechas de las
ofertas iguales antes y despues, 0 sin copia. Despues, por decision del equipo, la migracion 030 con el outbox
`evento_catalogo` (precio, descuento, stock y estado de una oferta van a MongoDB por un worker) y editar un producto
pasa a ser sincrono en las dos bases. `pruebas/evento_catalogo.sql` da 14 OK. **El backend es de David y no se toco.** Sus pasos, con archivo y linea,
estan en `docs/PLAN-COMPRAR-SIN-MONGO.md`. Cuando los suba, falta ajustar el escenario B de `pruebas/falla_checkout.sh`
(con MongoDB parado la compra tiene que salir) y cerrar la fila 12 de PENDIENTES y la 11 de CONSISTENCIA-CHECKOUT.

**EMPIEZA AQUI (28-09, noche).** Lo del 26 quedo probado todo junto y la revision del profesor dejo trabajo nuevo.

**Lo siguiente es decidir las propuestas de `docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md`** (fila 32 de PENDIENTES). El
profesor dijo que las decisiones del informe son genericas y no contestan ni las dependencias entre bases ni el fraude.
El documento propone un modelo unico de senales con su historia de detecciones en ClickHouse (su ejemplo del par mutuo
que se vuelve a detectar), doce consultas nuevas en las cinco bases, copiar el nombre en `oferta` para comprar solo con
PostgreSQL y Redis, el carrito que guarda la foto que manda el frontend, Elasticsearch mas alla de las facetas y la
busqueda hibrida con el vector. Nada esta implementado, se espera la decision del equipo.

**de5de2a de David, revisado y probado en vivo el 28.** Arreglo C6, C7, los pendientes 8 y 9 y el NaN de la regularidad.

```
arrancar.ps1            corrio entero con 026, 027 y 028 (279 s, exit 0). Se salto los vectores porque Ollama de la
                        PC tardo mas de 30 s en despertar con todo lo demas subiendo. Ahora espera 120 s, y probado
                        con Ollama apagado, lo enciende y sigue (25 s)
C7                      el agrupador corre al arrancar, 10 casos de 126 hallazgos, el backend escucha unos 2 s despues
C6 y regularidad        pruebas/casos_fraude_granja.cjs, 6 OK, saboteada (sin el filtro) da 2 FALLA
casos_fraude_fusion     0 FALLA, C1 sigue como DECISION
9, fechas de vencimiento  el panel del vendedor dice "-10% hasta las 22:40" y "Venta relampago abierta hasta las 22:40",
                        y si la venta vence sola se lleva el descuento, asi que manda la fecha mas temprana. Visto en
                        Edge como desarrollador1, 0 errores de JavaScript
Pruebas sueltas         descuentos 98, vectores_worker 5, recomendacion_semantica 15, facetas 19
Demos                   las 5 de la Entrega final y la de descuentos, corridas desde la pestana Comandos del frontend
                        como desarrollador1, todas "Termino bien". La de descuentos ahora muestra la fecha por la ruta
Arneses en serie        23 de 23 en verde, incluido falla_checkout 31. Dos estaban viejos y se ajustaron,
                        alertas_login (la 026 agrego el estado confirmada, 52 OK) y anillos (la cuenta de control sale
                        en una cadena abierta de la familia B, que es periferia por diseno, 27 OK)
```

**El 26 a las 22:15: 14e5084 de David, los arreglos de los casos de fraude.** Arreglo C2, C3, C5 y C8. Comprobado de este
lado con `node pruebas/casos_fraude_fusion.cjs` contra su backend compilado: el caso fusionado queda confirmado y con sus
5 cuentas, 0 FALLA. C1 sigue como decision (la prueba lo marca asi), y mientras se una, el puntaje sale del ultimo grupo
(32,5 contra 36,4). Quedan C4, C6, C7 y C9 en BACKEND-PENDIENTE. Nada de lo nuestro necesito cambio para su arreglo.

**El 26 a las 22:00: 37ad2e6 de David ("detalles varios"), conectado y probado en vivo.** Trae el vencimiento de los
descuentos y de la venta relampago en PostgreSQL (migracion 028, dos columnas, NULL es permanente), asi que la clave de
Redis `mesh:oferta:<id>:descuento` desaparecio y un Redis vaciado ya no se lleva descuentos. Tambien `hay_descuento` en
el indice, el total en `resultados` de ClickHouse, el % en el historial de precio y mas vendidos al arrancar. De este
lado: la 028 (aplicada dos veces sin error), el paso 5b-2 de arrancar ya no siembra claves y solo comprueba que la
semilla nace permanente, `hay_descuento` en `etl/extraer_busqueda.js` y en `elastic/001_indice.json` (el indice
reconstruido lo trae, coincide con Mongo), la etiqueta "Con descuento" en la cabecera y en /buscar (vista en Edge), el %
del dia en Mis pedidos y en el historial del vendedor, y la demo y la prueba de descuentos sin la clave de Redis.
`pruebas/descuentos.sh` 98 OK y `demo-descuentos-solos.ps1 -Parte manual` en verde, contra su backend. Pedido nuevo para
el: que `GET /vendedor/ofertas` devuelva las dos fechas de vencimiento.

**El 26 en la noche: los casos de fraude de David (a9e3d95).** Jalado y conectado. De este lado, la migracion
026_casos_fraude.sql (su SQL con las llaves en cascada y R-CASI-1 sin A.4, aplicada dos veces sin error y con el
candado de la 016 intacto) y la pestana Casos en Fraude (filtros por estado y nivel, detalle con nucleo, periferia
y evidencia, revisar, confirmar y descartar con motivo), vista en Edge con 0 errores de JavaScript. Su logica tiene
fallos medidos, anotados como C1 a C8 en BACKEND-PENDIENTE: una fusion borra el caso que el admin confirmo (C2) y
105 evidencias quedaron sin cuentas (C3). El worker dijo 10 casos y guardo 2, y el caso grande tenia a admin_mesh y
la tienda como nucleo, pero eso es de probar en local: sus 67 alertas de login salieron de 127.0.0.1, y las 13 con
IP real de las demos con Tor no entraron en ningun caso. Lo que queda de C1 es una decision: si una IP compartida
debe unir casos o no, porque el agrupador dice que no y el guardado lo hace. Probado con sus
clases compiladas dentro de una transaccion deshecha, en pruebas/casos_fraude_fusion.cjs, que hoy da 3 FALLA (C1, C2 y C3) y
tiene que dar 0 cuando David lo arregle. Nada de backend/ se toco.

**Ollama y el backend, probado en vivo el 26 a las 21:25.** cargar_vectores.ps1 corrio entero (3105 de 3105, 0 por
calcular, 26 s; no toco backend/.env porque ya coincidia). El worker de vectores de David (VectoresSyncService) se
corrio a mano con su codigo compilado sobre un producto marcado como editado: llego a Ollama, recalculo, dejo el mismo
hash y el MISMO vector que el ETL (distancia 0) y bajo la bandera en Mongo. pruebas/vectores_worker.cjs, 5 OK. Sin
probar queda solo el contenedor mesh-ollama, que se usa unicamente en una PC sin Ollama.

**El 2026-09-26: ced29f5 de David jalado y conectado, sin levantar nada.** David hizo las tres rutas que faltaban:
`GET /productos/:id/similares`, `GET /buscador/productos/facetado` y `GET /buscador/productos/sugerencias`. Tambien
agrego `VectoresSyncService`, que cada 3 horas recalcula los vectores de los productos editados, `GET /vectores`,
tres rankings de facetas y la reconciliacion de ofertas al arrancar. Las rutas encajan con las pantallas que ya
estaban, asi que "Parecidos a este" y el panel de /buscar deberian salir solos. De este lado:

```
ClickHouse           Columnas de facetas (facetada, categorias, precios, calificaciones, disponible) en
                     busqueda_realizada y busqueda_clic, como ALTER ... ADD COLUMN IF NOT EXISTS en 001_esquema.sql.
                     David las tenia solo en su base local. Sin ellas, en una base nueva fallaban en silencio los
                     eventos de busqueda y clic
Ollama y backend     cargar_vectores.ps1 escribe OLLAMA_URL y OLLAMA_MODELO_VECTORES en backend/.env con el Ollama
                     que eligio. Si es mesh-ollama en el 11435, el backend ya no se queda en el 11434
/buscar              El clic manda las facetas activas, solo si los resultados salieron de la ruta facetada
Tendencias           Rankings "Categorias filtradas", "Precios filtrados" y "Estrellas filtradas"
Demos                demo-entrega-final.ps1 -Parte semantica compara la base con /similares; -Parte facetas
                     ensena el facetado y las sugerencias por el backend
Comprobado           tsc del backend 0 errores, svelte-check 0 en 219 archivos, parser de PowerShell 0. Probado
                     sobre una copia el bloque que escribe backend/.env, que no reescribe si ya coincide
```

**Segunda vuelta del 26, ya en vivo y levantando solo lo necesario** (Postgres, Mongo y Redis primero, Elastic y
ClickHouse despues, sin Neo4j, sin consolas web y sin arrancar.ps1, porque la RAM no daba para todo).

```
Similares y HNSW     productos_similares() de la 024 NUNCA usaba el indice: comparaba con un JOIN y el HNSW solo
                     ordena por distancia a un vector fijo. La 027 la reescribe. Medido sobre los 3103 activos,
                     3,8 ms por producto con indice y 32 ms recorriendo todo, los mismos seis en 3099 de 3103.
                     Lleva enable_seqscan = off solo mientras corre porque el planificador estimaba mal. Antes de
                     aplicarla se comparo la salida de 20 productos con la vieja, igual. recomendacion_semantica.py
                     sigue en 15 OK. El informe final y la demo ya lo cuentan con estos numeros
Demos                demo-entrega-final.ps1 suma -Parte vectores y -Parte rastro, y las dos estan en el panel.
                     Arreglado un fallo que ya estaba: con una sola fila, (Psql ...)[0] tomaba la primera LETRA
                     y el conteo de vectores decia 3 en vez de 3105. Todas las demos corridas en verde, tambien
                     vectores y rastro desde el panel
ClickHouse           001_esquema.sql aplicado, las 10 columnas de facetas estan. Probado el clic con y sin facetas
                     por POST /eventos/busqueda-clic, y los tres rankings de facetas como admin
Pantallas            Vistas en Edge sin ventana: la ficha con Parecidos a este, /buscar con el panel de facetas
                     (Laptops y mas de Q3,000 dan 205, igual que facetas.py) y Tendencias con Categorias filtradas
                     mostrando el nombre. 0 errores de JavaScript. Lo que el navegador de prueba dejo en ClickHouse
                     se borro
Sustentacion         PREGUNTAS-SUSTENTACION.md 108, 109, 116, 117 y 118 decian que no habia vectores, ni control
                     de acceso, ni retrospectiva. Reescritas con lo que hay y donde se ve
facetas.py           19 OK
servicios.ps1        Lanzaba el backend como dist/main, relativo, y Procesos-De busca la carpeta del repo en la
                     linea de comando. parar-backend decia "no estaba corriendo" con el backend vivo y reiniciar
                     desde el panel lo dejaba duplicado. Ahora va con la ruta entera, probado que lo encuentra
```

**El 2026-09-24 y 25: lo de David del 24 y 25 conectado, y lo de la Entrega 3 que es de este lado.** Commits nuestros
b2d3292, 72eea96 y f8f537f, todos pusheados. De David se jalaron ad20dcd, 4e93bba, 99891a8, d1b670b, 6ecd31b y
31322cb (solo `backend/`). El repo vive desde el 25 en `C:\Proyectos\Proyecto-Tienda-Base-Datos-2`, ya no en
OneDrive, asi que los avisos de recargas de vite por OneDrive ya no aplican.

```
Migraciones          022 reglas de descuento por periodo, 023 anillos de fraude familia B, 024 producto_vector
                     (pgvector, HNSW) y productos_similares(), 025 hallazgos F1 a F6 de ClickHouse. La de casos de
                     fraude quedo como 026 y sigue en el plan de David
Descuentos           Pantalla de reglas por periodo, duracion del descuento y avisos de los 409 de exclusion entre
                     mecanismos. arrancar.ps1 paso 5b-2 crea con NX las claves mesh:oferta:<id>:descuento de la
                     semilla, porque el worker de David borra cada minuto los descuentos sin clave. Boton Borrar en
                     las reglas pausadas (DELETE de 31322cb)
Fraude               Tipos B en el panel y en la campana, pestana "Compras y navegacion" con F1 a F6
Tendencias           T1 a T3 en Tendencias, R1 y R3 en la portada, R2 en la ficha. "Para ti" vacio cae a
                     /productos/mas-vistos con el titulo "Lo mas visto"
Buscador             Facetas en elastic/pruebas/facetas.py (19 OK) y el panel de /buscar, que cae a la busqueda de
                     siempre con 404. autocompletar() con bool_prefix sobre nombre.escribiendo. Falta la ruta
Semantica            etl/cargar_vectores.ps1 (paso 7d de arrancar) llena los vectores con Ollama y
                     paraphrase-multilingual, 3105 en unos 7 minutos. La columna grupo evita recomendar copias del
                     generador. pruebas/recomendacion_semantica.py 15 OK. La ficha tiene "Parecidos a este", que no
                     pinta nada hasta que exista la ruta
Ollama               Nadie lo instala a mano. cargar_vectores usa el de la PC (localhost:11434, y lo enciende si esta
                     apagado), y si no hay levanta mesh-ollama, perfil ollama del compose, en el 11435. El modelo se
                     baja solo. Su volumen mesh-ollama-modelos es externo y -Reiniciar no lo borra. Apagar todo es
                     docker compose --profile ollama down
Redis                Tres usuarios ACL (default, inspeccion, operador) en docker-compose. El comando va como LISTA,
                     escrito en linea compose corta en el > de la contrasena. arrancar agrega al .env
                     REDIS_INSPECCION_PASSWORD y REDIS_OPERADOR_PASSWORD. redis/prueba_acceso.sh 31 OK
Docs                 DECISION-NEWSQL-PAGOS.md (ADR-8, no migrar, y si hiciera falta YugabyteDB). Diagrama de
                     arquitectura con los flujos 9 y 10. ER regenerado con las tablas nuevas
Informe              contenido-entrega3.json, generar-reporte-entrega3.py y medir-paginas-entrega3.ps1 generan
                     "Reporte Tercera Entrega - DABD2 - Mesh.docx" (15 paginas)
Demos                demo-patrones-resenas.ps1 (B.1, B.5, B.6) y demo-descuentos-solos.ps1, en el panel de comandos
Arneses              descuentos, reglas y los seis de las rutas del 24 y 25 en verde. reglas_periodo.sh 61 OK
Entrega final        "Reporte Entrega Final - DABD2 - Mesh.docx" (16 paginas) con la retrospectiva en el capitulo 5,
                     ADR-10 (pgvector) y ADR-11 (ACL de Redis). Se genera con contenido-entrega-final.json,
                     generar-reporte-entrega-final.py y medir-paginas-entrega-final.ps1, igual que el de la Entrega 3.
                     La fecha de la portada es FECHA en el generador
Demos finales        demo-entrega-final.ps1 -Parte acceso|semantica|facetas, en el panel de comandos como "Demos de la
                     Entrega final". Hablan directo con Redis, PostgreSQL, Mongo y Elasticsearch, sin backend
Pendiente de David   /productos/:id/similares, /buscador/productos/facetado, /buscador/productos/sugerencias, el
                     worker que borra descuentos sin clave, la cadena_abierta que sobra en un anillo de 3, R4, B.4,
                     casos de fraude (026) y reconciliar al arrancar. Todo en BACKEND-PENDIENTE.md
```

**El 2026-09-23 en la noche: propuesta de patrones de fraude, reglas de alertas y consultas de ClickHouse.** Todo en
`docs/fraude-entrega3/`, para aprobar. Nada toca `backend/` ni `migrations/`.

```
Neo4j                neo4j/consultas/B0..B7 (cadena abierta, satelites, persistente, anillo en el tiempo, favor
                     devuelto, coordinados, reputacion expres). Arnes bash neo4j/correr_patrones.sh, que compara cada
                     consulta contra su version SQL (neo4j/pruebas/equivalentes.sql) con datos reales y con una
                     siembra que se deshace con ROLLBACK. Verde el 2026-09-23
ClickHouse           clickhouse/consultas/R1..R4, T1..T3, F1..F6. Arnes bash clickhouse/correr_consultas.sh, siembra
                     en una base aparte que se borra. Verde el 2026-09-23
Hallazgo             el detector del backend (ventana de 60 dias) ya no ve el anillo anillo.uno/dos/tres de marzo
```

**El 2026-09-23 en la tarde: vitrinas de ofertas y reglas de descuento automatico.** Llegan con 565aca1 y 56ce5f8
de David (solo `backend/`).

```
Vitrinas             GET /productos/ofertas/descuento y /productos/ofertas/venta-relampago, publicas, leen dos HASH
                     de Redis (mesh:ofertas:descuento y mesh:ofertas:venta_relampago). Cada fila es una OFERTA, no un
                     producto. La portada las pinta como "Ventas relampago" y "Ofertas con descuento" encima de los
                     filtros, ordenadas por % y sin las agotadas. Solo salen sin filtros y si hay algo
Mas vendidos         Desde 565aca1 devuelve una tarjeta corta (sin variantes, categoria ni total_ofertas, con
                     imagen suelta). La portada tiene su propio snippet, tarjetaVendido. Los primeros 10 min tras
                     arrancar el HASH puede traer todavia la forma vieja y la portada la acepta
Reglas               Tabla regla_descuento_automatico, migrations/021 (David no dejo SQL, se escribio desde su
                     modelo). Una por oferta. Rutas POST, GET, GET paginado y PATCH /vendedor/reglas-descuento.
                     Pestana "Reglas" del panel, lib/ReglasDescuento.svelte, para vendedor y admin. El DISPARO por
                     ClickHouse no existe todavia, la pantalla lo avisa. No hay ruta para borrar una regla
Arneses              pruebas/reglas_descuento.sh, 34 OK. Borra su regla con un DELETE directo, no hay ruta
Pendiente de David   reconciliar() al arrancar y la ruta de borrar, en BACKEND-PENDIENTE.md
```

**El 2026-09-23: descuentos en las ofertas, carrito solo en Redis y venta relampago con descuento.** Llegan con los
commits e7f1e02 y c317197 de David (solo `backend/`); lo de fuera de `backend/` es nuestro.

```
Descuento            oferta.porcentaje_descuento y precio_historial.porcentaje_descuento, numeric(5,2), nullable, de 0
                     a 100 sin incluirlos. oferta.precio sigue siendo el de LISTA. El precio final es
                     ROUND(precio * (1 - COALESCE(pct,0)/100), 2), se calcula en cada consulta y nunca se guarda.
                     Lo aplica migrations/020_descuentos_oferta.sql (tambien reemplaza el trigger del historial y
                     comprar_pedido, que cobra el final). El vendedor lo pone y lo quita con
                     POST/DELETE /vendedor/ofertas/:id/descuento (1 a 90, dos decimales, 409 si ya hay uno o si no hay)
Semilla              13 ofertas de la tienda nacen con descuento (10 a 30 %), al final de 001_catalogo.sql. Solo se
                     ven en una base nueva (.\arrancar.ps1 -Reiniciar) o poniendo uno desde el panel
Mongo y ETL          hay_descuento en la raiz y en cada variante; precio_tienda y precio_desde ya van con descuento.
                     etl/extraer.sql usa la misma formula que el backend. No va al indice de Elasticsearch
Carrito              El HASH mesh:carrito:<id> guarda id_oferta -> JSON (foto con cantidad, precio final, % y nombre).
                     GET /carrito solo lee Redis. POST /carrito/comprar ya no recibe lineas_precio_visto: el backend
                     compara la foto con el precio de hoy y contesta comprado:false con avisos si cambio
Mas vendidos         El worker cachea el detalle en mesh:productos:mas_vendidos:detalle (cada 10 min). La respuesta
                     de GET /productos/mas-vendidos no cambio de forma, pero un descuento tarda hasta 10 min en verse
                     en el estante (anotado en BACKEND-PENDIENTE)
Venta relampago      POST .../venta-limitada da 409 si la oferta no tiene descuento, y DELETE .../descuento da 409 si
                     la venta relampago esta abierta. El panel del vendedor lo explica antes de dejar intentarlo
Arneses              pruebas/descuentos.sh (nuevo) cubre rutas, 400, los dos 409, historial, Mongo, carrito y compra.
                     oferta_limitada.sh pone un descuento antes de abrir la venta y lo quita despues de cerrarla
```


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
                     arrancar.ps1 tiene el paso 9d "Vistas de Kibana" (espera hasta 3 min y muestra su log) y el
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
PREGUNTAS-SUSTENTACION.md  En la raiz. 121 preguntas y respuestas para la sustentacion, con el archivo y las
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
> **Antes de decir que algo funciona, MIDELO.** Este proyecto tiene DIECINUEVE arneses:
> `bash pruebas/resenas.sh`, `bash pruebas/carrito.sh`, `bash pruebas/notas.sh`,
> `bash pruebas/busqueda.sh`, `bash pruebas/eventos.sh`,
> `bash pruebas/alertas_login.sh`, `bash pruebas/ofertas_paginadas.sh`,
> `bash pruebas/tendencias.sh`, `bash pruebas/etl_mongo.sh`, `bash pruebas/etl_compras.sh`,
> `bash pruebas/falla_checkout.sh`, `bash redis/prueba_carrito.sh`,
> `bash redis/prueba_concurrencia.sh`, `bash neo4j/correr_fraude.sh`,
> `.\mongo\demostracion_indices.ps1`, y los tres que PASAN POR EL BACKEND (20 de
> septiembre), `bash pruebas/carrito_vencimiento.sh`, `bash pruebas/oferta_limitada.sh`
> y `bash pruebas/anillos.sh`, y `bash pruebas/descuentos.sh` (23 de septiembre, tambien
> por el backend, y deja un pedido real). `oferta_limitada.sh` ahora pone un descuento
> antes de abrir la venta y lo quita despues de cerrarla.
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

**4. El carrito de Redis guarda una foto de cada linea.** Desde el 2026-09-23
es `id_oferta -> JSON` (cantidad, precio final con descuento, %, nombre, imagen,
vendedor), mas `t:<id_oferta>` para los tickets de venta relampago. `GET /carrito`
solo lee Redis. **Se cobra el precio de pagar**, pero si no coincide con la foto
el backend avisa y no cobra hasta que se confirme.

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

**Actualizado el 2026-09-23:** `lineas_precio_visto` se quito. El carrito de
Redis guarda por linea una foto con el precio que se enseno (ya con descuento), y
el backend compara esa foto contra el de hoy **dentro de la misma peticion que
cobra**. Si no cuadra, no cobra nada y contesta `comprado: false` con los
avisos; reenviar con `confirmar_cambios: true` acepta el nuevo. Lo de abajo
cuenta como era antes, con el campo que mandaba el frontend.

Que la comparacion viaje en la misma peticion es lo que la hace valer: entre
mirar y cobrar no queda ninguna ventana. Comprobarlo desde el frontend antes de
llamar dejaba milisegundos abiertos, y se probo asi antes de cambiarlo.

El precio todavia NO se congela -- si se confirma, se cobra el de hoy -- pero ya
no se cobra en silencio, que era el dano. Ver el pendiente 1.

**Medido el 2026-09-03 contra el backend vivo:** con el precio real en Q6,263 se
manda `precio_visto: "1.00"` y contesta `comprado: false` con el aviso que trae
los dos precios; los pedidos siguen en 32 antes y despues, y el carrito queda
entero.

Antes la proteccion **era opcional del lado del cliente**: quien no mandara
`lineas_precio_visto` cobraba el de hoy en silencio. Con la foto en Redis eso ya
no pasa: la comparacion la hace el backend para cualquier cliente y cualquier
linea.

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
