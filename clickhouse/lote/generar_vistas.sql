-- generar_vistas.sql
-- Siembra eventos DE MENTIRA en ClickHouse, deterministas por semilla, para
-- poder ensenar el panel de tendencias y el de fraude antes de que el portal
-- mande un solo evento de verdad.
--
-- `vista_producto` es la unica de las cuatro tablas que NACE en ClickHouse, y
-- nadie la escribe todavia porque falta `POST /eventos/vista` del backend. Las
-- otras dos de eventos SI se llenan solas desde el 2026-09-06, con
-- etl/cargar_eventos.sh, pero lo que traen es el dato de desarrollo y ese no
-- sirve para calibrar nada (abajo esta el porque).
--
-- Un panel contra una tabla vacia no se puede ensenar ni se puede corregir, asi
-- que este archivo le pone datos con la forma que van a tener.
--
--
-- Y hay un segundo motivo, que es el que de verdad lo vuelve obligatorio
-- ============================================================
-- Medido el 2026-09-06 sobre esta misma base. `log_login` tiene 317 logueos
-- reales y TODOS salen de la misma IP, 127.0.0.1, porque todo el desarrollo se
-- ha hecho en local. `log_registro` tiene UNA fila. Las cuentas de verdad son
-- doce, de la 1 a la 12.
--
-- Contra eso no se puede probar ningun analisis de fraude. La pregunta que
-- `evento_login` existe para contestar es cuantas cuentas distintas salen de
-- una misma IP, y con esos datos la respuesta seria "doce cuentas desde
-- 127.0.0.1", o sea que el propio equipo saldria marcado como anillo por
-- construccion. Un detector que acusa a todo el mundo no se puede calibrar,
-- porque no hay forma de saber si funciona.
--
-- Por eso este archivo siembra tambien logueos y registros con IP variadas, y
-- por eso el esquema tiene la columna `lote`.
--
--
-- TODO LO QUE ESCRIBE VA MARCADO, Y NUNCA COMO 'real'
-- ============================================================
-- Cada fila que sale de aqui lleva  lote = 'generado-<semilla>'. El valor
-- 'real', que es el DEFAULT de las cuatro tablas, queda reservado para lo que
-- mande el portal y para lo que trae etl/cargar_eventos.sh desde PostgreSQL.
--
-- Esa marca es la unica frontera entre lo medido y lo inventado, y sube hasta
-- el resumen `vistas_por_producto_dia` porque esta en su ORDER BY. Sin ella el
-- panel leeria un solo numero por producto y por dia sin poder decir que parte
-- se la invento un script.
--
-- Es el mismo marcador que ya usan los otros dos generadores del proyecto, la L
-- de migrations/lote y la M de mongo/lote.
--
--
-- CLICKHOUSE NO TIENE TRANSACCION, Y ESO CAMBIA COMO SE ESCRIBE ESTE ARCHIVO
-- ============================================================
-- No hay BEGIN, no hay COMMIT, no hay ROLLBACK y no hay forma de deshacer a
-- medias. generar_lote.sql de PostgreSQL puede permitirse escribir en once
-- tablas en cadena y fallar tranquilo en la ultima, porque el ROLLBACK borra el
-- rastro. Aqui una corrida que muere a la mitad DEJA lo que ya escribio.
--
-- De ahi salen las dos reglas que gobiernan la forma del archivo, y las dos son
-- consecuencia de lo mismo.
--
--   1. Toda guardia corre ANTES del primer INSERT. Una comprobacion despues de
--      escribir no sirve de nada, porque ya no se puede retirar lo escrito.
--
--   2. UN SOLO INSERT por tabla. Los tres bloques que se siembran en
--      `vista_producto` (el fondo, la tendencia y el anillo) van unidos con
--      UNION ALL dentro del mismo INSERT, y no como tres sentencias seguidas.
--      Un INSERT en ClickHouse escribe una parte de disco de una vez, asi que o
--      entran los tres bloques o no entra ninguno. Tres INSERT seguidos pueden
--      dejar el fondo puesto y la senal sin poner, que es la peor mitad
--      posible, porque el panel se pinta entero y no ensena nada.
--
-- Si aun asi una corrida muere entre el INSERT de una tabla y el de la
-- siguiente, la salida es correr borrar_lote.sql con esa misma semilla y
-- volver a empezar. Esta escrito en el README.
--
--
-- Como se corre
-- ============================================================
-- El contenedor de ClickHouse NO tiene el repositorio montado dentro, asi que
-- el archivo entra por la entrada estandar y no por una ruta.
--
--   export MSYS_NO_PATHCONV=1
--
--   docker exec -i mesh-clickhouse clickhouse-client \
--       --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
--       --database "$CLICKHOUSE_DB" \
--       --param_semilla=42 --param_vistas=3000 \
--       --multiquery < clickhouse/lote/generar_vistas.sql
--
-- Los parametros de ClickHouse no se parecen a los de psql. Se pasan con
-- --param_<nombre> y se leen dentro del SQL como {nombre:Tipo}, con el tipo
-- escrito ahi mismo. Eso es mejor que el :'variable' de psql en una cosa
-- concreta, y es que el tipo lo valida el servidor. Medido el 2026-09-06,
-- --param_semilla=abc contesta
--
--   Code: 457. Value abc cannot be parsed as UInt64 for query parameter
--   'semilla' because it isn't parsed completely
--
-- y sale con codigo distinto de cero, sin haber tocado ni una tabla.
--
-- Los dos parametros
--
--   semilla   cualquier entero sin signo. La misma semilla dibuja el mismo
--             sorteo, en cualquier maquina.
--   vistas    cuantas vistas de FONDO sembrar. Es el volumen del ruido de
--             abajo. Las dos senales que se plantan encima se escalan solas
--             a partir de este numero, y abajo esta explicado como.
--
-- --multiquery se deja puesto, pero NO por el motivo que aqui decia antes.
--
-- Decia que sin el, clickhouse-client leyendo de la entrada estandar se queda
-- con la primera sentencia. Se comprobo el 2026-09-06 contra mesh-clickhouse
-- 25.3.14.14 y es FALSO: dos sentencias por tuberia sin la bandera corren las
-- dos. En las versiones de esta epoca la ejecucion multiple desde la entrada
-- estandar ya es el comportamiento normal.
--
-- Lo que SI se sostiene, y es lo que de verdad hace util a la guardia del PASO
-- 0, es la otra mitad: la primera sentencia que falla para el archivo entero.
-- Un throwIf que dispara aborta lo que viene detras en vez de dejar el lote a
-- medias, y eso importa mucho aqui porque ClickHouse no tiene transaccion.
--
-- La bandera se queda por compatibilidad con versiones mas viejas, no porque
-- esta la necesite.
--
-- Un aviso que se paga caro si se olvida. Todos los INSERT de aqui son
-- INSERT ... SELECT. Un INSERT ... VALUES en un archivo que entra por la
-- entrada estandar se comeria el resto del archivo creyendo que son sus datos,
-- y no fallaria, simplemente insertaria basura y se callaria.
--
--
-- LA SEMILLA REPRODUCE EL MISMO SORTEO, NO LA MISMA BASE
-- ============================================================
-- Esto es lo mismo que ya advierte migrations/lote/README.md y conviene decirlo
-- igual de fuerte aqui.
--
-- Correr dos veces la semilla 42 no deja la base como estaba, deja EL DOBLE. El
-- sorteo es identico, si, las mismas fechas y los mismos productos, pero se
-- aplica encima de lo que ya hay y las filas se suman. El producto en ascenso
-- pasaria a tener el doble de vistas, el anillo el doble de clics, y todo
-- seguiria pareciendo coherente.
--
-- Como aqui no hay transaccion que lo arregle despues, la unica defensa es
-- mirar antes. Eso es el PASO 0, y sin el este archivo seria peligroso.
--
--
-- Por que cityHash64 y no rand()
-- ============================================================
-- rand() en ClickHouse devuelve un numero distinto en cada evaluacion y no
-- acepta semilla, asi que dos corridas de la misma semilla darian dos lotes
-- distintos y la palabra "determinista" seria mentira. cityHash64 es una
-- funcion pura, el mismo par de argumentos da el mismo entero de 64 bits
-- siempre, en cualquier version y en cualquier maquina.
--
-- Cada campo pide su hash con una etiqueta de texto propia ('producto',
-- 'sesion', 'ip1', ...). Sin esa etiqueta todos los campos de una fila saldrian
-- del mismo numero y quedarian correlacionados, o sea que la sesion 7 miraria
-- siempre el producto 7 desde la misma IP, y eso se nota a simple vista en el
-- panel.
--
--
-- Los ids de producto son REALES, del 1 al 100
-- ============================================================
-- El catalogo de PostgreSQL tiene 1101 productos, con ids del 1 al 1105, y los
-- cien primeros existen todos. Medido el 2026-09-06 con
--
--   SELECT count(*) FROM productos WHERE id_producto BETWEEN 1 AND 100;   -> 100
--
-- Se usan ids bajos y comprobados a proposito. Un panel de tendencias que
-- ensena el producto 8341 manda a quien lo mire a una ficha que da 404, y a
-- partir de ahi ya no se sabe si lo que falla es el panel o el catalogo.
--
-- Ese rango se reparte en tres bandas para que las dos senales no se pisen
-- entre ellas ni se escondan dentro del ruido.
--
--   del 1 al 60     el fondo, el ruido normal repartido
--   del 61 al 80    de ahi sale EL producto en ascenso
--   del 81 al 100   de ahi sale EL producto inflado por el anillo
--
-- Cual de los veinte toca en cada banda lo decide la semilla, y el resumen del
-- final lo imprime. Si tendencia y fraude pudieran caer en el mismo producto,
-- las dos senales se sumarian en la misma fila y el panel no ensenaria ninguna
-- de las dos limpia. Las bandas lo impiden por construccion, sin tener que
-- comprobarlo.
--
--
-- Las cuentas, y por que este archivo NO le pone ni un evento a las doce reales
-- ============================================================
-- Los usuarios de verdad son doce, del 1 al 12. Este archivo no escribe ni una
-- fila a nombre de ninguno de ellos, ni en las vistas ni en los logueos.
--
-- El motivo esta en el propio esquema, que ya lo advierte. Un anillo de fraude
-- dibujado por un generador y colgado del id de una persona real es una
-- acusacion inventada, y en un panel de fraude eso no se distingue de un
-- hallazgo hasta que alguien va a mirar la columna `lote`. Nadie mira esa
-- columna cuando el numero rojo ya esta en pantalla.
--
-- Asi que las cuentas generadas viven en dos bandas altisimas, muy por encima
-- de cualquier id que la secuencia de PostgreSQL vaya a repartir en anos.
--
--   1000000 y arriba   las OCHO cuentas del anillo, todas desde una sola IP
--   2000000 y arriba   las 200 cuentas de fondo, cada una con su propia IP
--
-- La contrapartida honesta es que esas cuentas no existen en `usuarios`, asi
-- que el panel ensenara ids que no se pueden abrir. Es el mismo problema que
-- con los productos, y aqui se acepta al reves que alli por una razon concreta.
-- Un id de producto falso solo rompe un enlace. Un id de usuario tomado
-- prestado senala a una persona.
--
--
-- Las IP, que son el dato entero de este archivo
-- ============================================================
--   10.100.x.y    una cuenta de fondo, y cada cuenta tiene SIEMPRE la suya
--   10.200.x.y    visitantes sin sesion iniciada, sueltos
--   10.66.x.y     el anillo ENTERO, una sola IP para las ocho cuentas
--
-- Que la IP de una cuenta de fondo sea funcion de su numero y de nada mas es lo
-- que hace que el registro y los logueos de esa cuenta cuadren entre ellos. Si
-- cada fila sorteara su IP aparte, cada cuenta de fondo saldria de decenas de
-- IP distintas y el panel de "cuantas cuentas por IP" daria uno en todas las
-- filas, con lo cual no habria contra que comparar al anillo.


-- ============================================================
-- PASO 0 -- LA GUARDIA, y corre antes de tocar nada
-- ============================================================
-- Sin transaccion, esta comprobacion es lo UNICO que separa un lote de dos
-- lotes superpuestos. Mira las CUATRO tablas, porque una corrida anterior pudo
-- morir despues de escribir en una y antes de escribir en otra, y en ese caso
-- lo que hay que hacer es borrar y repetir, no seguir escribiendo encima.
--
-- EL RESUMEN CUENTA COMO CUARTA TABLA, y aqui hubo un error que casi se queda.
-- Antes decia que no hacia falta mirarlo "porque se llena solo desde
-- vista_producto, asi que si aquella esta limpia este tambien lo esta". Es
-- falso, y lo desmiente el archivo de al lado: `vistas_por_producto_dia` se
-- llena por una vista materializada, y una vista materializada solo ve lo que
-- ENTRA. No ve los DELETE.
--
-- O sea que se puede llegar perfectamente a `vista_producto` vacia con el
-- resumen todavia lleno -- pasa con un TRUNCATE de la tabla cruda, o con una
-- limpieza a mano hecha a medias. Con la guardia mirando solo tres tablas, esa
-- corrida pasaba y sembraba el resumen POR SEGUNDA VEZ. Y el resumen es
-- justamente de donde lee el panel, asi que el numero que se ensena habria
-- salido doblado sin que nada lo delatara.
--
-- Es la misma trampa que obliga a que borrar_lote.sql borre de las dos, dicha
-- por el otro extremo.
--
-- FORMAT Null tira la salida. La guardia solo tiene que decir algo cuando
-- dispara, y una fila con un cero por pantalla en cada corrida buena es ruido
-- que acaba haciendo que nadie lea la salida.

WITH concat('generado-', toString({semilla:UInt64})) AS marca
SELECT throwIf(
    (SELECT count() FROM vista_producto          WHERE lote = marca) +
    (SELECT count() FROM vistas_por_producto_dia WHERE lote = marca) +
    (SELECT count() FROM evento_login            WHERE lote = marca) +
    (SELECT count() FROM evento_registro         WHERE lote = marca) > 0,
    concat('La semilla ', toString({semilla:UInt64}), ' ya sembro en esta base. ',
           'Correrla otra vez deja el doble, no lo mismo. ',
           'Usa otra semilla, o deshaz esta antes con borrar_lote.sql')
)
FORMAT Null;

-- Y la otra guardia, la del volumen. Un cero deja el archivo escribiendo las
-- dos senales sobre un fondo vacio, o sea dos productos con todas las vistas
-- del mundo y los 60 productos del fondo a cero, que no se parece a nada. El
-- tope de arriba
-- no es una limitacion del motor, es que a partir de ahi conviene que quien lo
-- pide lo escriba dos veces con dos semillas y sepa lo que esta haciendo.

SELECT throwIf(
    ({vistas:UInt64} < 840) OR ({vistas:UInt64} > 5000000),
    'El parametro vistas va de 840 a 5000000. Por debajo de 840 el fondo no llega a una vista por producto y por dia, y las dos senales quedan solas en el panel'
)
FORMAT Null;


-- ============================================================
-- PASO 1 -- evento_registro, las cuentas naciendo
-- ============================================================
-- Se siembra PRIMERO porque es el orden de la historia que cuenta el lote. Las
-- cuentas nacen, despues entran, y despues miran productos. Si una corrida
-- muere a la mitad, lo que queda escrito es un prefijo de esa historia y no un
-- trozo del medio, que es mas facil de reconocer al mirarlo.
--
-- Dos bloques, un solo INSERT.
--
-- EL FONDO son 200 cuentas repartidas por los ultimos 60 dias, cada una con su
-- IP y a horas distintas. Es lo normal, y existe para tener contra que comparar
-- al anillo. Una senal de fraude sin fondo deja de ser una senal y se queda en
-- el unico dato que hay.
--
-- EL ANILLO son ocho cuentas nacidas la misma manana, desde la MISMA IP, con
-- 47 segundos entre una y la siguiente. Esa es la forma mas barata que hay de
-- destapar un anillo y se ve antes de que esas cuentas escriban una sola
-- resena, que es justo lo que dice el comentario de esta tabla en el esquema.
--
-- id_log_registro apunta a la fila de PostgreSQL de la que salio la copia, y
-- estas no salieron de ninguna. Se les pone un numero por encima de los mil
-- millones a proposito. `log_registro` tiene HOY una sola fila, con lo cual
-- cualquier numero bajo podria chocar manana con una copia de verdad y las dos
-- filas se colapsarian entre ellas, porque la tabla es ReplacingMergeTree y ese
-- campo esta en su ORDER BY. Un cero seria todavia peor, porque las ocho del
-- anillo comparten IP y minuto y se aplastarian unas a otras.

INSERT INTO evento_registro (fecha, id_usuario, ip, id_log_registro, lote)
WITH
    {semilla:UInt64}                                            AS semilla,
    concat('generado-', toString(semilla))                      AS marca,
    200                                                         AS cuentas_fondo,
    8                                                           AS cuentas_anillo,
    toUInt64(1000000 + (cityHash64(semilla, 'anillo') % 100000) * 10) AS primera_cuenta_anillo,
    toIPv6(concat('::ffff:10.66.',
                  toString(cityHash64(semilla, 'ip-anillo-c') % 250), '.',
                  toString(1 + (cityHash64(semilla, 'ip-anillo-d') % 250)))) AS ip_anillo,
    toStartOfDay(now())                                         AS hoy_cero
SELECT fecha, id_usuario, ip, id_log_registro, marca
FROM
(
    -- El fondo. La IP sale del numero de cuenta y de nada mas, para que los
    -- logueos del PASO 2 puedan reconstruir exactamente la misma. La division
    -- entre 250 esta para que subir cuentas_fondo por encima de 250 siga dando
    -- octetos validos en vez de escribir un 10.100.0.300 que no existe.
    SELECT
        hoy_cero - toIntervalSecond(cityHash64(semilla, 'reg-cuando', number) % (60 * 86400)) AS fecha,
        toUInt64(2000000 + number)                                                            AS id_usuario,
        toIPv6(concat('::ffff:10.100.',
                      toString(intDiv(number, 250)), '.',
                      toString(1 + (number % 250))))                                          AS ip,
        toUInt64(1000000000 + (cityHash64(semilla, 'reg-log', number) % 500000000))            AS id_log_registro
    FROM numbers(cuentas_fondo)

    UNION ALL

    -- El anillo. Tres dias atras, a las once y pico de la manana, uno detras de
    -- otro. Las ocho comparten ip_anillo y eso es todo el hallazgo.
    SELECT
        hoy_cero - toIntervalDay(3) + toIntervalSecond(11 * 3600 + number * 47) AS fecha,
        toUInt64(primera_cuenta_anillo + number)                                AS id_usuario,
        ip_anillo                                                               AS ip,
        toUInt64(1500000000 + (cityHash64(semilla, 'anillo-reg', number) % 400000000)) AS id_log_registro
    FROM numbers(cuentas_anillo)
);


-- ============================================================
-- PASO 2 -- evento_login, las cuentas entrando
-- ============================================================
-- El fondo son 800 logueos de las 200 cuentas de fondo, repartidos por los
-- ultimos 30 dias, cada cuenta SIEMPRE desde su propia IP. Uno de cada cuatro
-- es un logout, que es lo que distingue `tipo_login` en PostgreSQL, donde los
-- dos unicos valores son 'login' y 'logout'. Medido el 2026-09-06 contra
-- `SELECT * FROM tipo_login`.
--
-- El anillo son las mismas ocho cuentas entrando seis veces cada una en los
-- ultimos dos dias, las 48 desde la unica IP del anillo. Eso deja el panel de
-- cuentas por IP con un 8 en una fila y un 1 en las otras doscientas, que es
-- exactamente el contraste que hoy no se puede tener con los 317 logueos
-- reales, porque comparten los 317 la misma 127.0.0.1.

INSERT INTO evento_login (fecha, id_usuario, ip, tipo, lote, id_log_login)
WITH
    {semilla:UInt64}                                            AS semilla,
    concat('generado-', toString(semilla))                      AS marca,
    200                                                         AS cuentas_fondo,
    800                                                         AS logueos_fondo,
    8                                                           AS cuentas_anillo,
    6                                                           AS logueos_por_cuenta_anillo,
    toUInt64(1000000 + (cityHash64(semilla, 'anillo') % 100000) * 10) AS primera_cuenta_anillo,
    toIPv6(concat('::ffff:10.66.',
                  toString(cityHash64(semilla, 'ip-anillo-c') % 250), '.',
                  toString(1 + (cityHash64(semilla, 'ip-anillo-d') % 250)))) AS ip_anillo,
    toStartOfDay(now())                                         AS hoy_cero
SELECT fecha, id_usuario, ip, tipo, marca, id_log_login
FROM
(
    SELECT
        hoy_cero - toIntervalSecond(cityHash64(semilla, 'log-cuando', number) % (30 * 86400)) AS fecha,
        toUInt64(2000000 + (cityHash64(semilla, 'log-quien', number) % cuentas_fondo))        AS id_usuario,
        -- La MISMA cuenta de arriba, reconstruida desde su numero. Tiene que
        -- ser el mismo hash con la misma etiqueta que en la linea anterior, o
        -- la cuenta y la IP dejarian de corresponderse y el fondo se llenaria
        -- de cuentas viajeras que ensucian justo la pregunta que se quiere
        -- contestar.
        toIPv6(concat('::ffff:10.100.',
                      toString(intDiv(cityHash64(semilla, 'log-quien', number) % cuentas_fondo, 250)), '.',
                      toString(1 + ((cityHash64(semilla, 'log-quien', number) % cuentas_fondo) % 250)))) AS ip,
        if(cityHash64(semilla, 'log-tipo', number) % 4 = 0, 'logout', 'login')                 AS tipo,
        toUInt64(1000000000 + (cityHash64(semilla, 'log-id', number) % 500000000))             AS id_log_login
    FROM numbers(logueos_fondo)

    UNION ALL

    SELECT
        hoy_cero - toIntervalSecond(cityHash64(semilla, 'anillo-log-cuando', number) % (2 * 86400)) AS fecha,
        toUInt64(primera_cuenta_anillo + (number % cuentas_anillo))                                 AS id_usuario,
        ip_anillo                                                                                   AS ip,
        if(number % 6 = 5, 'logout', 'login')                                                       AS tipo,
        toUInt64(1500000000 + (cityHash64(semilla, 'anillo-log-id', number) % 400000000))           AS id_log_login
    FROM numbers(cuentas_anillo * logueos_por_cuenta_anillo)
);


-- ============================================================
-- PASO 3 -- vista_producto, que es la tabla que importa
-- ============================================================
-- Un solo INSERT con tres bloques unidos por UNION ALL. Son tres y no uno
-- porque cada uno tiene una forma distinta que contar, pero entran juntos por
-- lo que dice la cabecera sobre la falta de transaccion.
--
-- Las constantes van en un WITH compartido arriba de la subconsulta, y desde ahi
-- alcanzan a los tres brazos. Eso importa mas de lo que parece. Con el WITH
-- repetido tres veces, alguien que cambie `productos_fondo` en un brazo y no en
-- los otros dos deja un archivo que corre perfecto y siembra otra cosa. Aqui la
-- constante se escribe una vez y no hay forma de que los brazos discrepen.
--
--
-- Como se escalan las dos senales
-- ============================================================
-- El fondo son `vistas` filas repartidas entre 60 productos y 14 dias, o sea
-- que la media es de  vistas / 840  vistas por producto y por dia. A ese numero
-- se le llama `factor`, y las dos senales se multiplican por el.
--
-- Sin eso, un lote grande esconderia sus propias senales. Con vistas=100000 el
-- fondo pone 119 vistas por producto y por dia, y una tendencia de 70 vistas en
-- su dia mas alto quedaria POR DEBAJO del ruido. Se veria un panel lleno de
-- datos donde no destaca nada, y lo primero que pensaria quien lo mire es que
-- la consulta de tendencia esta mal.
--
--
-- El fondo
-- ============================================================
-- Ruido. Vistas repartidas entre los productos del 1 al 60 y los ultimos 14
-- dias, un tercio de ellas sin cuenta iniciada, porque la ficha de producto es
-- publica y se puede mirar sin entrar. Ahi esta el motivo de que `id_usuario`
-- sea Nullable en el esquema.
--
-- Las sesiones son muchas, una cada dos vistas mas o menos, asi que el fondo se
-- queda cerca de dos vistas por sesion. Ese numero es el que le da sentido al
-- del anillo. Con vistas=3000 el anillo da 45 vistas por sesion contra las 1.1
-- que mide el panel en el fondo, y ese es el numero que hay que citar: sale de
-- medirlo, no de estimarlo.
--
-- El nombre de la sesion lleva la semilla dentro, y eso no es decoracion.
-- `vistas_por_producto_dia` cuenta sesiones distintas con uniqState, asi que
-- dos lotes que llamaran igual a sus sesiones se fundirian en el resumen y las
-- personas distintas saldrian de menos, sin que nada avisara.
--
--
-- La tendencia
-- ============================================================
-- UN producto de la banda 61 a 80 subiendo fuerte. La rampa esta escrita a mano
-- en un array, en vistas por dia y de hoy hacia atras, para que se pueda leer
-- de un vistazo lo que se sembro.
--
--   hoy 70,  ayer 44,  anteayer 26,  y de ahi para atras 16, 11, 8, 6, 5 ...
--
-- Cada numero de esa rampa es un multiplo del fondo, porque va multiplicado por
-- `factor`. O sea que hoy tiene 70 veces el ruido de un producto cualquiera y
-- hace dos semanas tenia el doble. Esa es la forma de una tendencia de verdad,
-- una curva que se dobla, y no un escalon.
--
-- Sus sesiones son casi todas distintas, alrededor de vista y media por sesion.
-- Eso es lo que separa una tendencia de un inflado, y es la razon de que
-- `vistas_por_producto_dia` guarde las dos cosas. Mucha gente mirando una vez
-- es moda. Poca gente mirando muchas veces es otra cosa.
--
--
-- El anillo
-- ============================================================
-- UN producto de la banda 81 a 100, machacado por las ocho cuentas del anillo
-- desde SEIS sesiones y una sola IP, todo dentro de los ultimos dos dias. El
-- origen es siempre 'directo', que es el tercer detalle del retrato. No llegan
-- por el catalogo ni por el buscador, van derechos a la ficha, que es lo que
-- hace alguien que trae el enlace escrito en una lista.
--
-- Con vistas=3000 eso son 270 vistas repartidas en seis sesiones, o sea 45
-- vistas por sesion contra las dos del fondo. Es lo que se puede senalar con el
-- dedo cuando alguien mire el panel.
--
--
-- Las fechas, y una trampa que se evito
-- ============================================================
-- Todo se ancla en toStartOfDay(now()) y se cuenta por dias de calendario, no
-- restando segundos a hoy. Es porque `vistas_por_producto_dia` agrupa por
-- toDate(fecha), asi que un lote que dijera "14 dias" restando 14 por 86400
-- segundos saldria en el resumen con QUINCE filas, dos de ellas a medias. No
-- fallaria nada, solo que la cuenta del panel no coincidiria con la del
-- generador y alguien perderia una tarde buscando el dia de mas.
--
-- Y el dia de hoy se reparte solo sobre los segundos que YA pasaron. Sumarle un
-- resto de hasta 86400 pondria vistas con hora futura, y esas se cuelan en
-- cualquier panel de "los ultimos N dias" con una fecha que todavia no ha
-- ocurrido.

INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen, lote)
WITH
    {semilla:UInt64}                                            AS semilla,
    {vistas:UInt64}                                             AS vistas_fondo,
    concat('generado-', toString(semilla))                      AS marca,
    60                                                          AS productos_fondo,
    14                                                          AS dias_fondo,
    200                                                         AS cuentas_fondo,
    greatest(intDiv(vistas_fondo, 2), 2)                        AS sesiones_fondo,
    greatest(intDiv(vistas_fondo, productos_fondo * dias_fondo), 1) AS factor,
    toUInt64(61 + (cityHash64(semilla, 'tendencia') % 20))      AS producto_tendencia,
    toUInt64(81 + (cityHash64(semilla, 'fraude') % 20))         AS producto_fraude,
    [70, 44, 26, 16, 11, 8, 6, 5, 4, 4, 3, 3, 2, 2]             AS rampa,
    greatest(toUInt64(arraySum(rampa)) * factor, 2)             AS sesiones_tendencia,
    6                                                           AS sesiones_anillo,
    8                                                           AS cuentas_anillo,
    90 * factor                                                 AS vistas_anillo,
    toUInt64(1000000 + (cityHash64(semilla, 'anillo') % 100000) * 10) AS primera_cuenta_anillo,
    toIPv6(concat('::ffff:10.66.',
                  toString(cityHash64(semilla, 'ip-anillo-c') % 250), '.',
                  toString(1 + (cityHash64(semilla, 'ip-anillo-d') % 250)))) AS ip_anillo,
    toStartOfDay(now())                                         AS hoy_cero,
    greatest(toUInt64(now()) - toUInt64(hoy_cero), 1)           AS segundos_de_hoy
SELECT fecha, id_producto, id_usuario, sesion, ip, origen, marca
FROM
(
    -- ---- El fondo -------------------------------------------------------
    SELECT
        hoy_cero
            - toIntervalDay(cityHash64(semilla, 'fondo-dia', number) % dias_fondo)
            + toIntervalSecond(cityHash64(semilla, 'fondo-hora', number)
                               % if(cityHash64(semilla, 'fondo-dia', number) % dias_fondo = 0,
                                    segundos_de_hoy, 86400))                              AS fecha,
        toUInt64(1 + (cityHash64(semilla, 'fondo-producto', number) % productos_fondo))   AS id_producto,
        if(cityHash64(semilla, 'fondo-quien', number) % 3 = 0,
           NULL,
           toUInt64(2000000 + (cityHash64(semilla, 'fondo-cuenta', number) % cuentas_fondo))) AS id_usuario,
        concat('g', toString(semilla), '-f',
               toString(cityHash64(semilla, 'fondo-sesion', number) % sesiones_fondo))    AS sesion,
        -- Con cuenta, la IP de su cuenta. Sin cuenta, un visitante suelto del
        -- 10.200, que es la banda que no le pertenece a nadie.
        if(cityHash64(semilla, 'fondo-quien', number) % 3 = 0,
           toIPv6(concat('::ffff:10.200.',
                         toString(cityHash64(semilla, 'fondo-ip-c', number) % 250), '.',
                         toString(1 + (cityHash64(semilla, 'fondo-ip-d', number) % 250)))),
           toIPv6(concat('::ffff:10.100.',
                         toString(intDiv(cityHash64(semilla, 'fondo-cuenta', number) % cuentas_fondo, 250)), '.',
                         toString(1 + ((cityHash64(semilla, 'fondo-cuenta', number) % cuentas_fondo) % 250))))) AS ip,
        ['catalogo', 'buscador', 'directo'][toUInt8(1 + (cityHash64(semilla, 'fondo-origen', number) % 3))] AS origen
    FROM numbers(vistas_fondo)

    UNION ALL

    -- ---- La tendencia ---------------------------------------------------
    -- El ARRAY JOIN sobre range() convierte cada numero de la rampa en tantas
    -- filas como dice. `dias_atras` y `k` juntos identifican la fila y son lo
    -- que se le da al hash, porque aqui no hay un `number` corrido que usar.
    SELECT
        hoy_cero
            - toIntervalDay(dias_atras)
            + toIntervalSecond(cityHash64(semilla, 'tend-hora', dias_atras, k)
                               % if(dias_atras = 0, segundos_de_hoy, 86400))              AS fecha,
        producto_tendencia                                                                AS id_producto,
        if(cityHash64(semilla, 'tend-quien', dias_atras, k) % 4 = 0,
           NULL,
           toUInt64(2000000 + (cityHash64(semilla, 'tend-cuenta', dias_atras, k) % cuentas_fondo))) AS id_usuario,
        concat('g', toString(semilla), '-t',
               toString(cityHash64(semilla, 'tend-sesion', dias_atras, k) % sesiones_tendencia)) AS sesion,
        if(cityHash64(semilla, 'tend-quien', dias_atras, k) % 4 = 0,
           toIPv6(concat('::ffff:10.200.',
                         toString(cityHash64(semilla, 'tend-ip-c', dias_atras, k) % 250), '.',
                         toString(1 + (cityHash64(semilla, 'tend-ip-d', dias_atras, k) % 250)))),
           toIPv6(concat('::ffff:10.100.',
                         toString(intDiv(cityHash64(semilla, 'tend-cuenta', dias_atras, k) % cuentas_fondo, 250)), '.',
                         toString(1 + ((cityHash64(semilla, 'tend-cuenta', dias_atras, k) % cuentas_fondo) % 250))))) AS ip,
        ['catalogo', 'buscador', 'directo'][toUInt8(1 + (cityHash64(semilla, 'tend-origen', dias_atras, k) % 3))] AS origen
    FROM
    (
        SELECT arrayJoin(range(14)) AS dias_atras
    )
    ARRAY JOIN range(toUInt64(rampa[dias_atras + 1] * factor)) AS k

    UNION ALL

    -- ---- El anillo ------------------------------------------------------
    SELECT
        hoy_cero
            - toIntervalDay(cityHash64(semilla, 'anillo-dia', number) % 2)
            + toIntervalSecond(cityHash64(semilla, 'anillo-hora', number)
                               % if(cityHash64(semilla, 'anillo-dia', number) % 2 = 0,
                                    segundos_de_hoy, 86400))                              AS fecha,
        producto_fraude                                                                   AS id_producto,
        toUInt64(primera_cuenta_anillo + (cityHash64(semilla, 'anillo-quien', number) % cuentas_anillo)) AS id_usuario,
        concat('g', toString(semilla), '-anillo',
               toString(cityHash64(semilla, 'anillo-sesion', number) % sesiones_anillo))  AS sesion,
        ip_anillo                                                                         AS ip,
        'directo'                                                                         AS origen
    FROM numbers(vistas_anillo)
);


-- ============================================================
-- PASO 4 -- el resumen, contado contra las tablas vivas
-- ============================================================
-- Ninguno de estos numeros esta calculado a partir de lo que el archivo creia
-- que iba a escribir. Todos salen de un count() sobre lo que quedo en la base,
-- que es la unica fuente que no miente. Un resumen que repite los parametros de
-- entrada da por bueno el lote incluso cuando el INSERT no entro.
--
-- FORMAT PrettyCompact esta puesto a mano porque por docker exec la salida no
-- es una terminal y ClickHouse cae en TabSeparated, que se lee mal cuando lo
-- que se quiere es mirar cuatro numeros y decidir si el lote sirve.

SELECT 'Lote sembrado' AS titulo FORMAT PrettyCompact;

WITH
    {semilla:UInt64}                                            AS semilla,
    {vistas:UInt64}                                             AS vistas_fondo,
    concat('generado-', toString(semilla))                      AS marca,
    greatest(intDiv(vistas_fondo, 60 * 14), 1)                  AS factor,
    toUInt64(1000000 + (cityHash64(semilla, 'anillo') % 100000) * 10) AS primera_cuenta_anillo
SELECT
    marca                                                       AS lote,
    factor                                                      AS factor_de_escala,
    toUInt64(61 + (cityHash64(semilla, 'tendencia') % 20))      AS producto_en_ascenso,
    toUInt64(81 + (cityHash64(semilla, 'fraude') % 20))         AS producto_inflado,
    IPv6NumToString(toIPv6(concat('::ffff:10.66.',
                  toString(cityHash64(semilla, 'ip-anillo-c') % 250), '.',
                  toString(1 + (cityHash64(semilla, 'ip-anillo-d') % 250))))) AS ip_del_anillo,
    concat(toString(primera_cuenta_anillo), ' a ',
           toString(primera_cuenta_anillo + 7))                 AS cuentas_del_anillo
FORMAT PrettyCompact;

WITH concat('generado-', toString({semilla:UInt64})) AS marca
SELECT tabla, filas
FROM
(
    SELECT 'vista_producto'          AS tabla, count() AS filas FROM vista_producto          WHERE lote = marca
    UNION ALL
    SELECT 'evento_login'            AS tabla, count() AS filas FROM evento_login            WHERE lote = marca
    UNION ALL
    SELECT 'evento_registro'         AS tabla, count() AS filas FROM evento_registro         WHERE lote = marca
    UNION ALL
    SELECT 'vistas_por_producto_dia' AS tabla, count() AS filas FROM vistas_por_producto_dia WHERE lote = marca
)
ORDER BY tabla
FORMAT PrettyCompact;

-- La senal de tendencia, medida sobre lo que quedo escrito. El producto en
-- ascenso y el inflado tienen que salir los dos arriba, y por motivos
-- distintos. El primero porque su rampa se dobla, el segundo porque todo lo
-- suyo cabe en dos dias.

SELECT 'Tendencia, los ultimos 3 dias contra los 11 anteriores' AS titulo FORMAT PrettyCompact;

WITH concat('generado-', toString({semilla:UInt64})) AS marca
SELECT
    id_producto,
    countIf(toDate(fecha) >= today() - 2)                       AS ultimos_3_dias,
    countIf(toDate(fecha) <  today() - 2)                       AS los_11_anteriores,
    round(ultimos_3_dias / greatest(los_11_anteriores, 1), 2)   AS veces
FROM vista_producto
WHERE lote = marca
GROUP BY id_producto
ORDER BY veces DESC, ultimos_3_dias DESC
LIMIT 5
FORMAT PrettyCompact;

-- La senal de fraude, y sale del RESUMEN y no de la tabla cruda a proposito.
-- Asi el resumen queda comprobado de paso. Si la vista materializada no
-- estuviera creada, o si alguien la hubiera borrado y vuelto a crear despues de
-- sembrar, esta tabla saldria vacia mientras la de arriba sigue dando numeros.

SELECT 'Fraude, vistas por persona segun el resumen que se mantiene solo' AS titulo FORMAT PrettyCompact;

WITH concat('generado-', toString({semilla:UInt64})) AS marca
SELECT
    id_producto,
    countMerge(vistas)                                          AS vistas,
    uniqMerge(sesiones)                                         AS personas,
    round(vistas / greatest(personas, 1), 1)                    AS vistas_por_persona
FROM vistas_por_producto_dia
WHERE lote = marca
GROUP BY id_producto
ORDER BY vistas_por_persona DESC
LIMIT 5
FORMAT PrettyCompact;

-- Y el anillo por donde de verdad se ve, que son las cuentas por IP. Aqui hay
-- que ver un ocho en la primera fila y unos en todas las demas.

SELECT 'Fraude, cuentas distintas por IP en los logueos' AS titulo FORMAT PrettyCompact;

WITH concat('generado-', toString({semilla:UInt64})) AS marca
SELECT
    IPv6NumToString(ip)                                         AS ip,
    uniq(id_usuario)                                            AS cuentas,
    count()                                                     AS logueos
FROM evento_login
WHERE lote = marca
GROUP BY ip
ORDER BY cuentas DESC, logueos DESC
LIMIT 5
FORMAT PrettyCompact;
