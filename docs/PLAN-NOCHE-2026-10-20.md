# Plan de la noche del 20-10 (Meme se fue, trabajo solo, sin agentes, sin parar)

Si se compacta la conversacion: LEER ESTO PRIMERO y seguir por el primer paso sin [x].
Orden de Meme: hacer TODO lo hablado, probado en backend, frontend, base, pruebas, demos y migraciones,
con sumo cuidado, soluciones de fondo, sin parches. Permiso total sobre las dos PC (backend incluido,
lo dijo Meme). No hay SSH a la PC de David: las caidas se simulan con interruptores locales.

## Lo que pidio el profesor (audios del amigo, 19-10)

1. Consistencia simulada: se apaga una base y la tienda sigue respondiendo con las que quedan.
   Ejemplo del profesor: apagan Redis y la app consulta otra base. Y que pasa si se apaga PostgreSQL.
2. Elasticsearch: los filtros (categoria, etc.) van en la consulta, no despues en los agregados
   (hoy usamos post_filter en facetado.service.ts).
3. Buscar "asdffff" tiene que traer al menos un producto relacionado, nunca vacio.

## Decisiones ya tomadas con Meme (no volver a discutir)

- Redis caido: mas vendidos, combos, mas vistos y tambien vieron salen de ClickHouse en vivo (misma
  consulta del worker). Ofertas destacadas desde PostgreSQL. Los contadores de fraude de login se pierden.
- PostgreSQL caido: el SesionGuard confia en el token firmado SOLO si PostgreSQL no contesta (si contesta
  "suspendida", corta). Login nuevo sin PostgreSQL: no se copia la cuenta a otra base; aviso claro.
  El carrito ya aguanta con la copia de Redis; pagar da 503 sin dejar nada a medias.
- Busqueda sin resultados: `total` = lo que coincidio de verdad (va a ClickHouse igual, el reporte
  de busquedas sin resultados no cambia); `sugeridos` aparte: vectores sin umbral, luego mas vendidos,
  luego la copia del catalogo en PostgreSQL.
- La pagina nunca nombra una base.

## Pasos (marcar [x] al terminar, con el commit)

- [x] 0. Leer todo el proyecto (backend, frontend, pruebas, demos, migraciones, docs) antes de tocar.
        Hallazgos que guian lo demas:
        - database/*.ts: pg Pool SIN connectionTimeoutMillis (con PostgreSQL colgado espera ~21 s);
          Redis 10 s, Neo4j 8 s, ClickHouse 8 s, Elastic 8 s x2 intentos (22 s). Solo Mongo tiene
          cortacircuitos (catalogo-respaldo.ts, PAUSA_MS 15 s). esRedisInalcanzable() ya existe.
        - Rankings: los 4 workers (mas-vendidos, mas-vistos, combos, tambien-vieron) ya consultan
          ClickHouse; el respaldo es reusar su consulta. Ofertas destacadas salen de oferta (PG).
        - Para ti y tambien compraron: Cypher sobre :Compra, que es copia de pedido (PG, 041).
        - Buscador: facetado (pagina /buscar) + hibrida en paralelo; registra en ClickHouse desde
          facetado y productos con resultado.total. Vectores en PG (vector_producto) y Ollama local.
          pg_trgm y unaccent DISPONIBLES en la PG de David (no instaladas).
        - Sesion: SesionGuard -> estaActivo (PG) en cada peticion. /usuario/yo -> obtenerPorId (PG).
          La Cabecera ya trata un 503 de /usuario/yo como "servidor caido, la sesion sigue".
        - Carrito: ver sale de Redis (calentar() da vacio si PG no responde); agregar necesita PG
          (consultarOfertas). Checkout PG.
        - Frontend: api.ts cambia cualquier mensaje con nombre de base por uno comun (f25b608).
        - Migraciones: se reejecutan en cada arranque, tienen que ser idempotentes. 047 es el molde.
        - notas.sh necesita un producto solo en Mongo sin resenas (o lo crea el panel del vendedor).
        - Panel de comandos: catalogo en panel-comandos/servidor.mjs; servicios.ps1 reinicia backend.
- [x] 1. Interruptores: remoto/interruptor.cjs (arriba / apagada / congelada, control en 127.0.0.1:5198,
        puertos de siempre + 10000, Mongo 37018) y remoto/caidas.ps1 (levantar, apagar, congelar,
        prender, estado, quitar). OJO: el backend tarda ~3 min en arrancar.
- [x] 2. helpers/cortacircuitos.ts en las 6 bases (pausa 15 s, log "[Cortacircuitos] X no responde" /
        "X volvio", GET /db/cortacircuitos). pg: connectionTimeoutMillis 5 s, query_timeout 30 s;
        Redis commandTimeout 3 s y reconexion forzada si se congela; Neo4j limite 20 s; Mongo
        socketTimeoutMS 20 s; Elastic maxRetries 0.
- [x] 3. Redis caido: los 4 rankings con la misma consulta del worker en vivo (calcular()), Memoria de
        60 s, orden de empates como ZREVRANGE; tarjetas comunes (helpers/tarjetas-producto.ts, con
        respaldo de Mongo); ofertas destacadas desde PG (registro.desdePostgres). Comparado: 8/8 iguales.
        Hallazgo arreglado: la copia de ofertas en Redis no se refrescaba con compras (stock viejo);
        ahora la refresca el worker de evento_oferta y la reconciliacion de 10 min.
- [x] 4. PostgreSQL caido: SesionGuard se cree al token si PG no contesta; perfil en Redis
        (helpers/perfil-sesion.ts) para /usuario/yo; consultaCorta 3 s para guard y perfil; ficha con
        ofertas_no_disponibles; frontend: entrar 503, checkout 503, aviso de la ficha, api.ts
        distingue cargar/completar. Medido apagada y congelada: todo 200 salvo pagar/agregar/entrar 503.
- [ ] 5. Elasticsearch caido: buscador desde la copia del catalogo en PostgreSQL.
- [ ] 6. Neo4j caido: tambien compraron desde PostgreSQL (pedidos), para ti con plan B.
- [ ] 7. Facetas sin post_filter (punto 2) + facetas.py + docs.
- [ ] 8. Busqueda nunca vacia (punto 3) + frontend + reporte intacto.
- [ ] 9. Frontend: avisos sin nombrar bases, sugeridos, carrito y login sin PostgreSQL.
- [ ] 10. Las 2 pruebas que fallaban: neo4j/correr_patrones.sh B.1 y pruebas/notas.sh (producto solo en Mongo).
- [ ] 11. Prueba nueva de caidas con los interruptores + correr_todas en remoto en verde.
- [ ] 12. Edge 1536x730 de cada caida, abrir cada captura.
- [ ] 13. Docs: QUE-PASA-SI-SE-CAE-UNA-BASE.md, cambio_propuestas, TRASPASO, memoria. Commit y push.

## Notas para mi mismo (trampas de esta noche)

- Herramientas: scratchpad de esta sesion
  C:\Users\memit\AppData\Local\Temp\claude\C--WINDOWS-system32\540f8a10-3ab0-4dcc-b55a-505462817dba\scratchpad
  (puertos.cjs, vigilar_log.cjs, medir.mjs, colas.sh). Las de anoche en ...\3b53695c-87d3-4994-9bcd-0473fe38cf81\scratchpad.
- Lanzar procesos con Win32_Process + cmd /c (Start-Process muere). Logs en %TEMP%\mesh-logs.
- Barras invertidas en heredoc de Git Bash se pierden: escribir con Write o con .py.
- psql: variables DB_USER, DB_PASSWORD, DB_NAME del .env de la raiz, con -w.
- No editar el producto 21 por la API (etl_mongo.sh).

## Bitacora

- 00:50 pasos 1 a 4 hechos y medidos con el interruptor; commit.

- 00:05 plan escrito. Todo arriba (backend, frontend 5173, panel, ollama), 6 bases de David arriba.
