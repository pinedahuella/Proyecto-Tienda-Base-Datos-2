-- extraer_eventos.sql
-- Saca de PostgreSQL las filas de `log_login` o las de `log_registro` que
-- todavia no estan en ClickHouse, ya en TabSeparated, listas para entrar por
-- una tuberia a `clickhouse-client ... FORMAT TabSeparated`.
--
-- No se corre a mano. Lo corre etl/cargar_eventos.sh, que es quien sabe hasta
-- donde se copio la vez pasada. Aqui solo se traduce.
--
--
-- ES UNA COPIA, NO UNA MUDANZA
-- ============================================================
-- Las dos tablas se quedan enteras en PostgreSQL y este archivo no borra ni
-- actualiza nada -- son dos SELECT y nada mas. La verdad sigue viviendo alla,
-- donde `log_login.id_usuario` tiene una llave foranea contra `usuarios` con
-- ON DELETE RESTRICT que impide que quede un evento apuntando a una cuenta que
-- ya no existe. ClickHouse no tiene llaves foraneas y no puede sostener eso.
-- Lo que gana a cambio es la pregunta por IP, que es la que el indice de
-- PostgreSQL no contesta barato.
--
--
-- LAS DOS CONSULTAS VIVEN EN EL MISMO ARCHIVO A PROPOSITO
-- ============================================================
-- Son la misma traduccion contra dos tablas casi gemelas, y partirlas en dos
-- archivos garantiza que un dia alguien arregle el formato de la fecha en uno
-- y se olvide del otro. Lo elige `:es_login`, que pone el script.
--
-- El precio de tenerlas juntas es que el ORDEN DE LAS COLUMNAS de cada rama es
-- un contrato con la lista del INSERT que arma cargar_eventos.sh. TabSeparated
-- no lleva nombres: es posicional, y ClickHouse mete alegremente el id en la
-- fecha si el orden se cae. Si se toca una lista de aqui hay que tocar la de
-- alla, y estan escritas en el mismo orden para que se puedan comparar de un
-- vistazo:
--
--   login     fecha  id_usuario  ip  tipo  lote  id_log_login
--   registro  fecha  id_usuario  ip  lote  id_log_registro
--
--
-- LA MARCA DE AGUA LLEGA DE FUERA, Y VIENE DEL DESTINO
-- ============================================================
-- `:desde` es el mayor id que ClickHouse ya tiene copiado, y el WHERE trae
-- solo lo que esta por encima. El porque de que la marca pueda vivir en el
-- destino, en vez de en una tabla de cola de PostgreSQL como hace el ETL del
-- grafo, esta explicado largo en cargar_eventos.sh. En corto: estos eventos
-- son inmutables y solo crecen.
--
-- Si el script se olvida de pasarla, se asume 0 y se copia todo. Es el unico
-- valor seguro: quedarse corto reenvia filas que ReplacingMergeTree colapsa,
-- mientras que pasarse de largo deja huecos que nadie vuelve a mirar.

\if :{?desde}
\else
    \set desde 0
\endif

-- `:hasta` ES EL TOPE, Y CIERRA UNA CARRERA QUE YA ESTABA PASANDO
-- ============================================================
-- Sin el, el tramo era abierto por arriba: todo lo que hubiera por encima de
-- `:desde` EN EL MOMENTO DE LEER. Y entre el instante en que el script cuenta
-- cuantas filas hay pendientes y el instante en que esta consulta las lee pasa
-- casi un segundo, con el portal vivo escribiendo logueos.
--
-- Lo que salia de ahi era el peor final posible: la copia entraba PERFECTA, con
-- una fila mas de las contadas, y la guarda del script lo leia como datos rotos
-- y mataba la corrida con MORTAL. Un ETL que se suicida cuando todo fue bien.
--
-- Medido el 2026-09-06 durante la revision: los id de `log_login` subieron de
-- 323 a 332 solos, sin que nadie tocara nada, con el backend corriendo.
--
-- El tope se toma del MISMO vistazo que la cuenta, en una sola consulta, y por
-- eso los dos numeros son coherentes aunque la tabla siga creciendo detras.
--
-- Y lo que queda por encima del tope no se pierde: la siguiente corrida lo ve,
-- porque la marca de agua queda justo en `:hasta`.
\if :{?hasta}
\else
    -- Sin tope se copia todo lo de arriba, que es como se comportaba antes.
    -- Se deja asi para que la consulta siga sirviendo suelta, a mano, sin que
    -- quien la pegue en psql tenga que saberse los dos parametros.
    \set hasta 9223372036854775807
\endif

-- Los `timestamptz` de PostgreSQL se imprimen en la zona de la sesion, y la
-- sesion hereda la del contenedor. Sin esto, la misma fila copiada desde dos
-- maquinas distintas entraria en ClickHouse con horas distintas, y la pregunta
-- que justifica toda esta tabla ("cuantas cuentas entraron desde esta IP EN LA
-- MISMA TARDE") se contestaria sola que no. UTC y se acabo, igual que en
-- extraer_notas.sql.
SET TIME ZONE 'UTC';

-- ESTA LINEA PARECE UN ADORNO Y ES LA GUARDA MAS IMPORTANTE DEL ARCHIVO.
--
-- Medido el 2026-09-06: cuando `\if` recibe algo que no es un booleano, psql
-- SE QUEJA Y SIGUE. Escribe "unrecognized value for \if expression" por la
-- salida de errores, trata la condicion como falsa y se mete en el `\else`.
-- Con ON_ERROR_STOP=1 puesto y todo: eso solo frena los errores de SQL, no los
-- de las meta-ordenes. Asi que una variable mal pasada no para la copia, hace
-- que salgan por la tuberia las filas de la OTRA tabla, con otro numero de
-- columnas y en otro orden.
--
-- Aqui se convierte ese descuido en un error de SQL, que es lo unico que
-- ON_ERROR_STOP si mata. Un valor que no sea 0 ni 1 divide entre cero; un
-- valor que ni siquiera sea un numero (o la variable sin pasar) ni llega a
-- compilar. El `WHERE false` es para que en el camino bueno no salga ni una
-- fila y no se ensucie la tuberia.
--
-- Y TIENE QUE SER UN CASE, no un `SELECT 1/0 WHERE :es_login NOT IN (0,1)`,
-- que fue el primer intento y reventaba SIEMPRE, tambien con el valor bueno.
-- PostgreSQL pliega las expresiones constantes al PLANIFICAR, antes de mirar
-- el WHERE, asi que el 1/0 se evaluaba aunque la condicion fuera falsa. Con el
-- CASE el plegado tambien ocurre, pero solo entra en la rama que toca, y la
-- division ni se mira cuando el valor es 0 o 1. Comprobado con los cuatro
-- valores el 2026-09-06.
SELECT CASE WHEN :es_login IN (0, 1) THEN 0 ELSE 1 / 0 END WHERE false;

\if :es_login

-- ============================================================
-- log_login  ->  evento_login
-- ============================================================
SELECT

    -- CORREGIDO EL 2026-09-18: la fecha viaja como EPOCA y no como texto. Lo de
    -- abajo, sobre el formato del texto y el AT TIME ZONE 'UTC', describe la
    -- version anterior y se deja como historia de por que era asi. Ese texto se
    -- escribia en UTC y ClickHouse lo lee sin zona en la de SU servidor, que aqui
    -- es America/Guatemala (TZ del docker-compose): todo quedaba 6 horas corrido
    -- hacia adelante. Medido: el login 359 es de las 16:53 en PostgreSQL y salia a
    -- las 22:53 en ClickHouse. Una epoca es el mismo instante en cualquier zona.
    -- Ver etl/extraer_compras.sql, que ya lo hacia asi.
    --
    -- ClickHouse lee DateTime64(3) desde texto, pero solo con este formato
    -- exacto. El de PostgreSQL por defecto trae el desplazamiento pegado
    -- ("2026-09-06 20:31:00.123+00") y ClickHouse lo rechaza entero, no lo
    -- recorta. El AT TIME ZONE 'UTC' de aqui no es redundante con el SET de
    -- arriba: convierte a `timestamp` sin zona, que es lo que to_char espera
    -- para no volver a colgar el desplazamiento.
    --
    -- MS y no US: la columna de ClickHouse guarda milisegundos. Mandar
    -- microsegundos no da error, se truncan en silencio, y entonces el texto
    -- que se manda deja de ser el texto que se guarda.
    round(extract(epoch FROM l.fecha_login)::numeric, 3),

    l.id_usuario,

    -- host() y no el `inet` pelado. El tipo `inet` se imprime con la mascara
    -- cuando la lleva ("127.0.0.1/32"), y esa barra hace que ClickHouse
    -- rechace la fila entera. host() devuelve solo la direccion.
    --
    -- El coalesce tapa un hueco que hoy no existe pero que la tabla permite:
    -- `ip_origen` es NULL-able en PostgreSQL y la columna `ip` de ClickHouse
    -- no lo es. Medido el 2026-09-06 sobre la base viva, las 317 filas tienen
    -- IP; el dia que entre una sin ella, sin este coalesce se caeria la copia
    -- ENTERA por una sola fila. '::' es la direccion sin especificar de IPv6,
    -- y se distingue a simple vista de cualquier IP de verdad.
    coalesce(host(l.ip_origen), '::'),

    -- El nombre y no el numero. La columna de ClickHouse es LowCardinality
    -- (String) y guardar ahi un 1 obligaria a quien consulte a recordar que 1
    -- es login. El diccionario de LowCardinality hace que el texto no cueste
    -- mas espacio que el numero, asi que no se gana nada guardando el codigo.
    --
    -- LEFT JOIN y no INNER, aunque haya llave foranea. Un INNER JOIN que no
    -- encuentra pareja no da error: se come la fila. Y una fila comida aqui es
    -- justo un logueo que desaparece del analisis de fraude sin dejar rastro.
    -- Con el LEFT sale como 'desconocido', que se ve y se puede preguntar.
    coalesce(t.tipo_login_nombre, 'desconocido'),

    -- El lote se escribe explicito y no se deja al DEFAULT de la tabla. La
    -- columna existe para separar lo medido de lo inventado, y dejarla al
    -- valor por omision seria confiar en que nadie cambie ese DEFAULT nunca.
    -- Esto SALE de log_login, asi que es 'real', y se dice aqui.
    'real',

    -- El id de origen viaja con la fila. Es lo que permite reanudar la copia
    -- sin repetir y lo que permite ir a mirar la fila original en PostgreSQL
    -- cuando un numero no cuadre.
    l.id_log_login

FROM log_login l
LEFT JOIN tipo_login t ON t.id_tipo_login = l.id_tipo_login
WHERE l.id_log_login > :desde AND l.id_log_login <= :hasta
-- Ordenado por el id que es la marca de agua. Si la carga se corta a la mitad,
-- lo que entro es un tramo seguido desde `:desde`, y la siguiente corrida
-- retoma justo ahi. Sin ORDER BY, un corte deja filas sueltas por encima del
-- maximo copiado y esas de abajo no se vuelven a pedir jamas.
ORDER BY l.id_log_login;

\else

-- ============================================================
-- log_registro  ->  evento_registro
-- ============================================================
-- La misma traduccion, sin `tipo`: un registro solo pasa una vez y no tiene
-- dos sentidos como el login. Los comentarios de la rama de arriba valen
-- igual para cada linea de aqui.
SELECT
    round(extract(epoch FROM r.fecha_registro)::numeric, 3),
    r.id_usuario,
    coalesce(host(r.ip_origen), '::'),
    'real',
    r.id_log_registro
FROM log_registro r
WHERE r.id_log_registro > :desde AND r.id_log_registro <= :hasta
ORDER BY r.id_log_registro;

\endif
