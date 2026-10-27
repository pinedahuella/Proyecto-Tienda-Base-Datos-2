-- extraer_grafo.sql
-- Saca de PostgreSQL, ya escrito en Cypher, todo lo que va al grafo de Neo4j.
--
-- Es el mismo patron que extraer.sql: PostgreSQL arma el texto y el cliente
-- que vive DENTRO del contenedor lo carga. Alla el texto es JSON y lo carga
-- mongosh; aqui el texto es Cypher y lo carga cypher-shell. En los dos casos
-- no hay ni un paquete que instalar, que es la regla de etl/README.md:
-- "No hay nada que instalar".
--
-- Se corre con "psql -qtAX", que no imprime encabezado, ni relleno de
-- columnas, ni conteo de filas, y que ignora el .psqlrc de quien lo corra. Lo
-- que sale por pantalla es un script de Cypher y nada mas.
--
--
-- Por que Cypher y no JSON
-- ============================================================
-- Con Mongo el ETL es cargar.js, un programa que corre dentro de mongosh y que
-- tiene trabajo de verdad: reconstruye el historial de fotos a eventos. Aqui no
-- hay nada que reconstruir -- las tres columnas de `resena` YA son las tres
-- relaciones del grafo -- asi que un programa intermedio solo agregaria un
-- archivo mas donde equivocarse.
--
-- La alternativa era emitir JSON y cargarlo con apoc.load.json. Se descarto:
-- obliga a dejar el archivo dentro del contenedor y a habilitar
-- apoc.import.file.enabled en neo4j.conf, o sea a tocar docker-compose.yml por
-- una comodidad. Cypher por la entrada estandar no necesita permiso de nada.
--
--
-- Como se escriben los literales sin equivocarse
-- ============================================================
-- Todos los textos salen por to_json(x)::text, NUNCA concatenados a mano entre
-- comillas. El motivo es concreto: el escape de una cadena JSON es un
-- subconjunto del de Cypher (comilla doble, barra invertida, saltos de linea y
-- \uXXXX significan lo mismo en los dos), asi que lo que to_json devuelve ya es
-- un literal de Cypher valido, comillas incluidas.
--
-- Concatenar a mano se rompe con la primera resena que lleve una comilla, y en
-- este proyecto los textos los escribe el usuario. Peor: no se rompe con un
-- error de sintaxis claro sino con un script partido a la mitad.
--
-- Las claves de los mapas van SIN comillas ({id: 1} y no {"id": 1}) porque
-- Cypher exige identificador en la clave; ahi si es concatenacion, pero las
-- claves las escribo yo en este archivo y no vienen de la base.
--
--
-- Idempotencia: todo es MERGE
-- ============================================================
-- Ni un CREATE en todo el archivo. Correr el ETL dos veces tiene que dejar los
-- mismos conteos, y eso se mide en la entrega. MERGE encuentra el nodo por su
-- id -- el mismo de PostgreSQL -- y solo lo crea si no estaba; el SET que va
-- despues lo pone al dia igual la primera vez que la decima.
--
-- El MERGE se apoya en las restricciones de unicidad de neo4j/001_esquema.cypher.
-- Sin ellas dos corridas simultaneas pueden duplicar; el por que esta explicado
-- alla y no se repite aqui.
--
-- Lo que la idempotencia NO cubre: si una resena se BORRA en PostgreSQL, el
-- nodo se queda en el grafo. El ETL solo agrega y actualiza, nunca resta. Para
-- eso esta "cargar_grafo.sh --limpiar", que borra el grafo entero y lo vuelve a
-- construir. El grafo es una proyeccion: se puede tirar sin perder nada.


-- Las fechas salen con la zona del cliente. Fijandola aqui, el grafo cargado
-- desde dos maquinas distintas tiene las mismas fechas, y una consulta de
-- "resenas dentro de la misma hora" no depende de quien corrio el ETL.
SET TIME ZONE 'UTC';


-- ============================================================
-- La direccion normalizada: la unica transformacion de este archivo
-- ============================================================
-- Dos cuentas que viven en la misma casa escriben la direccion distinto:
-- "Sacatepequez" con tilde en la e y "Sacatepequez" sin ella, con dos espacios
-- o con uno, en mayusculas o no. Comparadas tal cual son direcciones distintas
-- y la senal se pierde. En los datos de hoy pasa de verdad: la misma casa de
-- Antigua esta cargada tres veces, escrita distinto cada vez.
--
-- La normalizacion es minusculas, sin tildes y con los espacios colapsados. Y
-- el resultado es la IDENTIDAD del nodo :Direccion, no una propiedad suya: por
-- eso se calcula aqui, en el ETL, y no en la consulta -- una consulta que
-- normalizara al vuelo tendria que leer todas las direcciones para comparar
-- dos, que es justo lo que el grafo evita.
--
-- Las tildes se quitan con translate() y no con unaccent(), que es una
-- extension: instalarla seria tocar la base por una comodidad, y la regla del
-- proyecto es no agregar dependencias. Como se escriben las letras acentuadas
-- sin escribirlas, esta explicado dentro de la funcion.
CREATE OR REPLACE FUNCTION pg_temp.clave_direccion(
    p_pais text, p_departamento text, p_ciudad text, p_exacta text
) RETURNS text AS $$
    SELECT lower(regexp_replace(
        trim(translate(
            coalesce(p_pais, '') || '|' || coalesce(p_departamento, '') || '|' ||
            coalesce(p_ciudad, '') || '|' || coalesce(p_exacta, ''),
            -- Las 14 letras acentuadas del espanol, en el mismo orden que sus
            -- reemplazos de la linea siguiente: a e i o u u n A E I O U U N.
            --
            -- Van por chr() y no escritas a la vista para que este archivo
            -- quede en ASCII PURO, que es la regla de la casa para todo el SQL.
            -- No es capricho: un .sql con acentos abierto o redirigido desde la
            -- consola de Windows se guarda en otra codificacion y el translate
            -- deja de coincidir en silencio -- no da error, solo deja de
            -- normalizar, y la senal de "misma direccion" desaparece sin que
            -- nadie se entere.
            --
            -- Tampoco se usan escapes E'\uXXXX', que tambien serian ASCII:
            -- chr() dice el numero a la vista y no depende de que la cadena se
            -- haya escrito con el prefijo E.
            chr(225) || chr(233) || chr(237) || chr(243) || chr(250) ||
            chr(252) || chr(241) || chr(193) || chr(201) || chr(205) ||
            chr(211) || chr(218) || chr(220) || chr(209),
            'aeiouunAEIOUUN')),
        '\s+', ' ', 'g'));
$$ LANGUAGE sql IMMUTABLE;
-- pg_temp: la funcion vive lo que dura la sesion de psql y se va sola. Este
-- archivo NO debe dejar nada escrito en la base -- es un extractor, no una
-- migracion -- y una funcion permanente aqui seria un objeto que ninguna
-- migracion declara y que nadie sabria de donde salio.


-- ============================================================
-- El alcance: todo, o solo lo que la cola tiene pendiente
-- ============================================================
-- Desde la migracion 015 existe `evento_grafo`, la cola de outbox: un trigger
-- sobre `resena` encola el id de cada resena que se toca, en la misma
-- transaccion. Este archivo puede proyectar TODO (lo de siempre) o solo lo que
-- esa cola tiene pendiente, y lo decide la variable `solo_cola`:
--
--   psql -f extraer_grafo.sql                    todo, como siempre
--   psql -v solo_cola=1 -f extraer_grafo.sql     solo lo pendiente
--
-- Lo que se recorta NO son las cinco secciones, son DOS. Las cuentas, las
-- direcciones y el "quien vive donde" se proyectan enteras en los dos modos, y
-- eso es a proposito por dos razones:
--
--   Son baratas. Estan acotadas por el numero de cuentas (12 hoy), no por el
--   de resenas, asi que recortarlas no ahorra nada medible.
--
--   Y sobre todo: el trigger NO las vigila. Solo encola resenas. Si alguien se
--   cambia el nombre o corrige su direccion, eso no genera ningun evento y en
--   un modo incremental "puro" no llegaria al grafo NUNCA. Dejandolas enteras,
--   cada corrida las pone al dia gratis. El modo incremental ahorra donde
--   crece el trabajo y no donde no crece.
--
-- La cola se lee UNA vez, aqui, a una tabla temporal. Asi el resto del archivo
-- no vuelve a nombrar `evento_grafo`, y de paso esto sigue corriendo contra una
-- base que todavia no aplico la 015: si la tabla no existe, la temporal se crea
-- vacia y `solo_cola` se fuerza a 0.

-- ¿Existe la cola? Sin esto, un ETL contra una base sin la 015 falla con
-- "relation evento_grafo does not exist", que no dice nada de lo que pasa.
SELECT (to_regclass('public.evento_grafo') IS NOT NULL) AS hay_cola \gset

-- El valor por defecto va DESPUES de mirar si la variable ya vino, porque un
-- `\set solo_cola 0` a secas pisaria el `-v solo_cola=1` de quien llama: psql
-- lee el archivo de arriba abajo y la ultima asignacion gana.
\if :{?solo_cola}
\else
    \set solo_cola 0
\endif

\if :hay_cola
CREATE TEMP TABLE cola_pendiente AS
    SELECT DISTINCT id_resena FROM evento_grafo WHERE procesado_en IS NULL;
\else
CREATE TEMP TABLE cola_pendiente (id_resena bigint);
\set solo_cola 0
\endif


-- ============================================================
-- La salida: cinco sentencias de Cypher, en este orden
-- ============================================================
-- El orden NO es decorativo. Las relaciones se crean con MATCH sobre los dos
-- extremos, asi que los nodos tienen que existir antes. Si la sentencia de
-- resenas corriera primero, sus MATCH no encontrarian nada, no fallaria, y el
-- grafo quedaria con nodos y sin una sola relacion: el peor resultado posible,
-- porque parece que cargo.
--
-- Van como cinco filas de una sola columna. psql las imprime una tras otra y
-- cypher-shell las separa por el punto y coma final de cada una.
SELECT sentencia FROM (


-- ------------------------------------------------------------
-- 1. Las cuentas
-- ------------------------------------------------------------
-- TODAS, no solo las que aparecen en alguna resena. Una cuenta recien creada
-- que todavia no califico a nadie es parte del universo que se investiga, y
-- ademas es la forma que tiene el grafo de contestar "cuantas cuentas hay" sin
-- volver a PostgreSQL.
--
-- fecha_alta viaja porque es senal: un anillo de cuentas creadas el mismo dia
-- y que se califican entre si dice mucho mas que el anillo solo. Se usa en la
-- consulta compuesta del 002.
--
-- La contrasena NO viaja, ni su hash. El grafo se abre en un navegador en el
-- 7474 sin la proteccion que tiene el backend; lo que no hace falta para una
-- consulta no se copia.
SELECT 1 AS orden,
       'UNWIND [' || coalesce(string_agg(
           format('{id:%s,correo:%s,usuario:%s,nombre:%s,apellido:%s,fecha_alta:datetime(%s)}',
                  u.id_usuario,
                  to_json(u.correo_electronico)::text,
                  to_json(u.usuario)::text,
                  to_json(u.nombre)::text,
                  coalesce(to_json(u.apellido)::text, 'null'),
                  to_json(u.fecha_creacion)::text),
           ',' ORDER BY u.id_usuario), '') || '] AS f
MERGE (u:Usuario {id: f.id})
SET u.correo = f.correo, u.usuario = f.usuario, u.nombre = f.nombre,
    u.apellido = f.apellido, u.fecha_alta = f.fecha_alta;' AS sentencia
FROM usuarios u

UNION ALL

-- ------------------------------------------------------------
-- 2. Los productos que tienen al menos una resena
-- ------------------------------------------------------------
-- Aqui SI se filtra, al reves que con las cuentas, y por una razon que se
-- puede defender: un producto sin resenas no puede aparecer en ningun camino
-- del grafo -- las tres relaciones del modelo lo alcanzan solo desde una
-- :Resena. Cargar los 102 meteria decenas de nodos sueltos que ninguna
-- consulta puede tocar.
--
-- El catalogo completo ya vive en MongoDB y en PostgreSQL. Copiarlo entero
-- aqui seria una tercera copia del mismo dato, y este grafo existe para las
-- relaciones, no para el catalogo.
--
--
-- LA LISTA SALE DE `resena`, NO DE `productos`, Y ESO NO ES UN DETALLE
-- ============================================================
-- Antes decia "FROM productos p WHERE EXISTS (... resena ...)", que suena a lo
-- mismo y no lo es: `resena.id_producto_mongo` NO TIENE LLAVE FORANEA, porque
-- el catalogo vive en MongoDB. Un producto que publica un vendedor existe en
-- Mongo y NO tiene fila en `productos` -- hoy hay tres asi con ofertas vivas
-- (105, 108 y 109).
--
-- Con la version vieja, una resena sobre uno de esos productos se perdia EN
-- SILENCIO: el nodo :Producto no se emitia, el MATCH de la sentencia 5 no lo
-- encontraba y la fila entera se descartaba sin error. Medido dentro de un
-- BEGIN/ROLLBACK: al insertar una resena sobre el producto 108, el Cypher salia
-- con 87 resenas y 54 productos, y el grafo quedaba con 86 :Resena. cypher-shell
-- termino con exito y sin una sola advertencia.
--
-- Y el sitio donde eso duele es justo donde se busca fraude: un anillo que
-- publica su propio producto y se resena encima quedaba invisible para las
-- cinco consultas.
--
-- Partiendo de `resena` no se pierde ninguna. El LEFT JOIN es para el nombre, y
-- cuando el producto solo vive en Mongo se pone uno de relleno que dice de
-- donde salio -- mejor un nodo con nombre feo que una resena desaparecida.
--
-- De paso, esto hace que la cuenta esperada por arrancar.ps1
-- (count(DISTINCT id_producto_mongo) FROM resena) sea la correcta: antes el
-- codigo cargaba una cosa y la comprobacion esperaba otra, y el dia que
-- apareciera una resena sobre un producto de vendedor el arranque quedaba en
-- rojo para siempre haciendo el ETL exactamente lo que debia.
--
-- La categoria (id y nombre) sale de la copia del catalogo, igual que en los
-- workers del backend (GrafoSyncService, GrafoComprasSyncService y
-- GrafoCategoriasSyncService). La usa "quienes lo compraron tambien llevaron"
-- para poner primero los productos de la misma categoria. Sin fila en la copia
-- va null, y el SET deja el nodo sin categoria.
SELECT 2 AS orden,
       'UNWIND [' || coalesce(string_agg(
           format('{id:%s,nombre:%s,id_categoria:%s,categoria:%s}',
                  p.id, to_json(p.nombre)::text,
                  coalesce(p.id_categoria::text, 'null'),
                  coalesce(to_json(p.categoria)::text, 'null')),
           ',' ORDER BY p.id), '') || '] AS f
MERGE (p:Producto {id: f.id})
SET p.nombre = f.nombre, p.id_categoria = f.id_categoria, p.categoria = f.categoria;' AS sentencia
FROM (
    SELECT DISTINCT r.id_producto_mongo AS id,
           coalesce(pr.nombre,
                    'Producto ' || r.id_producto_mongo || ' (solo en MongoDB)') AS nombre,
           pc.id_categoria,
           cat.nombre AS categoria
    FROM resena r
    LEFT JOIN productos pr ON pr.id_producto = r.id_producto_mongo
    LEFT JOIN producto_catalogo pc ON pc.id_producto_mongo = r.id_producto_mongo
    LEFT JOIN categorias cat ON cat.id_categoria = pc.id_categoria
    -- El recorte del modo incremental. Con solo_cola=0 esto es siempre cierto y
    -- la consulta queda exactamente como estaba.
    WHERE :solo_cola = 0
       OR r.id_resena IN (SELECT id_resena FROM cola_pendiente)
) p

UNION ALL

-- ------------------------------------------------------------
-- 3. Las direcciones, deduplicadas por su texto normalizado
-- ------------------------------------------------------------
-- Un nodo por direccion DISTINTA, no por fila de `direcciones`. Ese GROUP BY
-- es la pieza entera: es lo que hace que las dos filas de dos cuentas que
-- viven en la misma casa caigan en un solo nodo y que exista el camino
-- (a)-[:VIVE_EN]->(d)<-[:VIVE_EN]-(b).
--
-- Los campos sueltos (pais, departamento, ciudad) viajan SIN normalizar, con
-- el min() de las filas que cayeron en el mismo nodo, y son solo para leer el
-- resultado. Lo que identifica es `clave`; lo demas es para que un humano vea
-- "Antigua Guatemala" y no "guatemala|sacatepequez|antigua guatemala|".
--
-- Se cargan TODAS las direcciones, incluso las de una sola cuenta. Filtrar
-- aqui a las compartidas seria meter la conclusion en el ETL: el grafo debe
-- poder contestar tambien "esta cuenta vive sola", y sobre todo la respuesta
-- cambia cuando entra una cuenta nueva. Lo que decide es la consulta.
--
-- Lo que esto NO significa: compartir direccion no es fraude. Una familia
-- comparte casa. Es una senal que solo pesa junto con otra, y por eso en las
-- consultas nunca aparece sola.
--
--
-- `tiene_calle`: LA PROPIEDAD QUE EVITA QUE "MISMA CASA" SIGNIFIQUE "MISMA CIUDAD"
-- ============================================================
-- La clave incluye `direccion_exacta`, y cuando esa columna es NULL la clave
-- termina en barra con nada detras: "guatemala|sacatepequez|antigua guatemala|".
-- O sea que TODAS las cuentas que solo declararon su ciudad caen en el MISMO
-- nodo :Direccion. No es un caso raro: 13 de las 16 filas de `direcciones` no
-- tienen calle.
--
-- Asi, la consulta A.4 decia "cuentas que comparten direccion" y en realidad
-- listaba cuentas que comparten CIUDAD, y el puntaje compuesto les regalaba un
-- punto de senal por eso. Los dos unicos pares que devolvia -- comprador.sur +
-- compradora.norte en Antigua Guatemala y tienda + Meme#gordo en San Jose
-- Pinula -- imprimian direccion_exacta NULL en su propia salida.
--
-- Los nodos se siguen emitiendo TODOS (el grafo tiene que poder contestar donde
-- vive una cuenta, y filtrar aqui seria meter la conclusion en el ETL), pero
-- ahora cada uno dice si identifica una casa o solo una ciudad, y las consultas
-- exigen la bandera. Una direccion sin calle no identifica una casa.
--
-- bool_or y no un min(): dentro de un mismo nodo todas las filas normalizan a
-- la misma calle, asi que el valor es uniforme; bool_or lo deja igual de
-- correcto si algun dia la normalizacion junta dos escrituras distintas.
SELECT 3 AS orden,
       'UNWIND [' || coalesce(string_agg(
           format('{clave:%s,pais:%s,departamento:%s,ciudad:%s,exacta:%s,tiene_calle:%s}',
                  to_json(d.clave)::text,
                  to_json(d.pais)::text,
                  to_json(d.departamento)::text,
                  to_json(d.ciudad)::text,
                  coalesce(to_json(d.exacta)::text, 'null'),
                  CASE WHEN d.tiene_calle THEN 'true' ELSE 'false' END),
           ',' ORDER BY d.clave), '') || '] AS f
MERGE (d:Direccion {clave: f.clave})
SET d.pais = f.pais, d.departamento = f.departamento,
    d.ciudad = f.ciudad, d.exacta = f.exacta, d.tiene_calle = f.tiene_calle;' AS sentencia
FROM (
    SELECT pg_temp.clave_direccion(pais, departamento, ciudad, direccion_exacta) AS clave,
           min(pais) AS pais, min(departamento) AS departamento,
           min(ciudad) AS ciudad, min(direccion_exacta) AS exacta,
           bool_or(direccion_exacta IS NOT NULL AND btrim(direccion_exacta) <> '') AS tiene_calle
    FROM direcciones
    GROUP BY 1
) d

UNION ALL

-- ------------------------------------------------------------
-- 4. Quien vive donde
-- ------------------------------------------------------------
-- DISTINCT sobre el par (cuenta, clave) porque una misma cuenta puede tener
-- dos filas en `direcciones` que normalizan igual -- y las tiene: en los datos
-- de hoy hay una cuenta con la misma direccion de Antigua cargada tres veces,
-- escrita distinto cada vez. Sin el DISTINCT saldrian tres filas que el MERGE
-- resolveria a una sola relacion igual, pero el script pesaria de mas y la
-- cuenta de filas no cuadraria con las relaciones creadas al revisarlo.
--
-- La relacion tambien es MERGE. MERGE sobre una relacion entre dos nodos ya
-- fijados por MATCH no puede duplicar: si ya existe la encuentra.
SELECT 4 AS orden,
       'UNWIND [' || coalesce(string_agg(
           format('{usuario:%s,clave:%s}', v.id_usuario, to_json(v.clave)::text),
           ',' ORDER BY v.id_usuario, v.clave), '') || '] AS f
MATCH (u:Usuario {id: f.usuario})
MATCH (d:Direccion {clave: f.clave})
MERGE (u)-[:VIVE_EN]->(d);' AS sentencia
FROM (
    SELECT DISTINCT id_usuario,
           pg_temp.clave_direccion(pais, departamento, ciudad, direccion_exacta) AS clave
    FROM direcciones
) v

UNION ALL

-- ------------------------------------------------------------
-- 5. Las resenas y sus tres relaciones
-- ------------------------------------------------------------
-- Una sola sentencia crea el nodo y sus tres aristas, y tiene que ser asi: una
-- :Resena sin su ESCRIBIO o sin su CALIFICA_A no es media resena, es un nodo
-- que rompe todos los caminos que pasen por ahi. Partirlo en cuatro sentencias
-- dejaria el grafo a medias si la tercera falla.
--
-- Los tres MATCH van ANTES del MERGE del nodo, y el orden importa: si el autor
-- o el producto no estan cargados, la fila entera no produce resultado y no se
-- crea la :Resena. Es lo que se quiere -- mejor una resena de menos que un
-- nodo colgando. Con MERGE primero quedaria el nodo huerfano.
--
-- LA FECHA NO ESTA EN `resena`. Sale de `comentario.fecha_publicacion` por el
-- id_comentario de la raiz, que es UNIQUE en resena. Es la trampa de esta
-- consulta: la tabla `resena` guarda quien, a quien, sobre que y cuanto, pero
-- el CUANDO vive en el comentario que la resena obliga a tener. Sin ese JOIN
-- no hay consulta de rafagas, que es media senal de fraude.
--
-- El texto viaja porque es senal por si mismo: cinco cuentas distintas que
-- escriben palabra por palabra lo mismo no son cinco personas. Se guarda
-- entero y sin cortar; el comentario mas largo del conjunto no llega a 90
-- caracteres.
--
-- Lo que NO viaja: las RESPUESTAS a la resena (comentario con padre) y los
-- votos de `likes`. Las respuestas las escribe el vendedor en su propia
-- resena, asi que no agregan ningun camino entre cuentas que ESCRIBIO no de ya;
-- los votos si agregarian uno (quien apoya a quien), y son la primera cosa que
-- este grafo deberia crecer si hiciera falta mas senal. Hoy son 62 votos de
-- dos cuentas: no alcanza para un patron y meterlos seria ruido con nombre.
SELECT 5 AS orden,
       'UNWIND [' || coalesce(string_agg(
           format('{id:%s,autor:%s,vendedor:%s,producto:%s,calificacion:%s,fecha:datetime(%s),texto:%s}',
                  r.id_resena,
                  r.id_usuario,
                  r.id_usuario_vendedor,
                  r.id_producto_mongo,
                  r.calificacion,
                  to_json(c.fecha_publicacion)::text,
                  to_json(c.comentario)::text),
           ',' ORDER BY r.id_resena), '') || '] AS f
MATCH (a:Usuario {id: f.autor})
MATCH (v:Usuario {id: f.vendedor})
MATCH (p:Producto {id: f.producto})
MERGE (r:Resena {id: f.id})
SET r.calificacion = f.calificacion, r.fecha = f.fecha, r.texto = f.texto
MERGE (a)-[:ESCRIBIO]->(r)
MERGE (r)-[:CALIFICA_A]->(v)
MERGE (r)-[:SOBRE]->(p);' AS sentencia
FROM resena r
JOIN comentario c ON c.id_comentario = r.id_comentario
WHERE :solo_cola = 0
   OR r.id_resena IN (SELECT id_resena FROM cola_pendiente)

UNION ALL

-- ------------------------------------------------------------
-- 6. Las resenas BORRADAS, que hay que quitar del grafo
-- ------------------------------------------------------------
-- Esta seccion no tiene gemela en las otras cinco: las otras cinco AGREGAN, y
-- esta resta. Existe porque el trigger encola igual un alta que una baja -- las
-- dos escriben el mismo id_resena -- y quien vacia la cola distingue una de la
-- otra mirando si la fila todavia existe. Si ya no existe, es una baja.
--
-- Va SIEMPRE, en los dos modos, y no detras de solo_cola. Es una mejora sobre
-- lo que habia: hasta ahora el ETL solo sumaba, asi que una resena borrada en
-- PostgreSQL se quedaba para siempre en Neo4j y la unica salida era --limpiar,
-- que borra el grafo entero. Ahora las bajas que pasaron por la cola se
-- deshacen solas.
--
-- Lo que NO arregla, y hay que saberlo: una resena borrada ANTES de que
-- existiera la 015 no dejo evento, asi que sigue en el grafo. Para esas sigue
-- haciendo falta --limpiar.
--
-- Los nodos de usuario, producto y direccion se dejan en pie: pueden estar en
-- otros caminos, y un nodo suelto no ensucia ninguna de las cinco consultas de
-- fraude. DETACH DELETE porque la resena tiene tres relaciones y un DELETE a
-- secas sobre un nodo con relaciones falla.
--
-- El HAVING no es adorno. Un agregado sin GROUP BY devuelve UNA fila aunque no
-- haya nada que agregar, asi que sin el, cada corrida sin bajas pendientes
-- emitia una linea vacia de mas. cypher-shell se la salta sin quejarse, pero
-- entonces la salida de este archivo dejaba de ser byte a byte la de antes y
-- comparar dos corridas para ver si algo cambio pasaba a dar siempre una
-- diferencia. Con el HAVING, sin bajas no sale ninguna fila.
SELECT 6 AS orden,
       string_agg(
           format('MATCH (r:Resena {id: %s}) DETACH DELETE r;', e.id_resena),
           E'\n' ORDER BY e.id_resena) AS sentencia
FROM cola_pendiente e
WHERE NOT EXISTS (SELECT 1 FROM resena r WHERE r.id_resena = e.id_resena)
HAVING count(*) > 0


) salida
ORDER BY orden;
