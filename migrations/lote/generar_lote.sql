-- generar_lote.sql
-- Un generador INCREMENTAL de productos y ofertas, en SQL puro, que se puede
-- correr en CUALQUIER momento sobre una base ya cargada y sin borrar nada.
--
-- Es lo contrario de migrations/datos/001_catalogo.sql. Aquel retrata un
-- catalogo entero y solo entra en una base vacia: de sus veinte INSERT de
-- primer nivel, diecisiete no llevan guardia, asi que la segunda pasada choca
-- contra el UNIQUE de las categorias raiz y se deshace entera. Este archivo
-- existe para lo que aquel no puede hacer -- meter cien productos mas encima de
-- los que ya estan, para que las consultas de la entrega tengan volumen que
-- medir -- y por eso no toca ni una sola fila de las que ya existen.
--
--
-- NO es una migracion, y vive aqui a proposito
-- ============================================================
-- arrancar.ps1 recoge las migraciones con Get-ChildItem SIN -Recurse, sobre
-- migrations\ y sobre migrations\datos\. Una subcarpeta migrations\lote\ NO la
-- ve ningun bucle. Eso es exactamente lo que se quiere: este archivo CREA datos
-- cada vez que corre, asi que un arranque que lo ejecutara solo duplicaria el
-- catalogo en cada reinicio de la maquina y nadie sabria de donde salieron esos
-- productos. Se corre a mano, cuando alguien decide que quiere mas volumen.
--
-- El precio de vivir fuera del bucle es que tampoco lo protege el numero de
-- migracion, asi que el archivo trae su propia guardia contra correrse dos
-- veces (PASO 0). Un archivo que se invoca a mano necesita defenderse solo.
--
--
-- Por que en SQL y no en Node
-- ============================================================
-- Fuera de backend/ no hay ningun package.json en el repositorio, o sea que no
-- hay driver de PostgreSQL instalado del lado de las migraciones, y arrancar.ps1
-- no invoca node en ninguna de sus mas de mil trescientas lineas. Un solo
-- archivo .sql corrido con psql -f es el camino que ya usa todo el proyecto para
-- hablar con esta base, y es el unico que funciona en una maquina recien clonada
-- sin instalar nada. El generador de migrations/datos/ si es JavaScript, pero
-- ese ESCRIBE un .sql y no habla con la base: es otro oficio.
--
--
-- Como se corre
-- ============================================================
--   export MSYS_NO_PATHCONV=1
--   docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> -v ON_ERROR_STOP=1 \
--       -v productos=50 -v semilla=42 -v max_mongo_producto=106 \
--       -v max_mongo_variante=206 -f /migrations/lote/generar_lote.sql
--
-- ON_ERROR_STOP=1 no es opcional. Sin el, psql imprime el error y contesta que
-- todo fue bien -- sale con codigo 0 -- y quien llame a este archivo desde un
-- script no se entera de que la guardia lo rechazo. Es la misma trampa que
-- documenta migrations/README.md para el conjunto de datos.
--
-- Los cuatro parametros:
--
--   productos             cuantos productos crear. Entre 1 y 9999.
--   semilla               el CID, o cualquier entero. Misma semilla, mismos
--                         productos, en cualquier maquina y version.
--   max_mongo_producto    el mayor _id de producto que hay hoy en MongoDB.
--   max_mongo_variante    el mayor id_producto_variante que hay hoy en MongoDB.
--
-- Los dos ultimos se sacan de la base documental, que es la unica que los sabe:
--
--   db.productos.find().sort({_id:-1}).limit(1)
--   db.productos.aggregate([{$unwind:"$variantes"},
--       {$group:{_id:null,m:{$max:"$variantes.id_producto_variante"}}}])
--
-- Y esos dos NO se pueden inventar. El PASO 0 rechaza la corrida si cualquiera
-- de ellos va por debajo del maximo que ya tiene PostgreSQL, porque desde SQL no
-- hay forma de abrir MongoDB y comprobarlos contra su fuente: lo unico que se
-- puede exigir es que sean creibles. Ahi mismo esta escrito lo que esa
-- precondicion alcanza y lo que no.
--
--
-- Todo va dentro de una sola transaccion
-- ============================================================
-- Un BEGIN al principio y un COMMIT al final, igual que 001_catalogo.sql, que
-- abre en su linea 33. Este archivo escribe en once tablas en cadena, y un fallo
-- a la mitad -- una variante que choca contra su UNIQUE, una plantilla sin
-- imagen -- dejaria productos sin ofertas y ofertas sin kardex. Medio lote
-- escrito es peor que ningun lote: no falla nada, simplemente el catalogo
-- empieza a mentir. Con la transaccion, la pasada que falla no deja rastro.
--
-- La UNICA excepcion, y hay que saberla: setval() del PASO 1 NO se deshace con
-- el ROLLBACK. Las secuencias viven fuera de la transaccion a proposito, porque
-- si no dos sesiones que insertan a la vez se pelearian por el mismo numero. Por
-- eso la guardia del PASO 0 va ANTES del setval y no despues: una corrida
-- rechazada ni siquiera llega a tocar la secuencia.
--
--
-- Por que los parametros pasan por una tabla temporal
-- ============================================================
-- psql sustituye :variable en el SQL suelto, pero NO dentro de una cadena entre
-- comillas ni dentro de un bloque delimitado por dolares. Medido en esta misma
-- base: un DO $$ ... RAISE NOTICE ':prueba' ... $$ imprime el texto ":prueba"
-- tal cual, no el valor. Y este archivo necesita los cuatro parametros justo
-- ahi dentro, en la guardia y en el bloque que se comprueba a si mismo, que son
-- plpgsql y no pueden ser otra cosa.
--
-- Asi que los parametros se leen UNA vez, en SQL suelto, se castean ahi mismo, y
-- de ahi en adelante todo el archivo -- el SQL y los bloques -- los toma de la
-- misma fila. Ademas de resolver el problema del interpolado, eso deja un solo
-- lugar donde el valor se convierte y se valida: un parametro mal pasado falla
-- una vez y claro, en vez de fallar distinto en cada sitio donde se use.
--
-- La forma :'nombre' con comillas y el cast explicito tampoco son adorno. Sin
-- las comillas, :productos se pega al SQL como texto crudo y un valor con letras
-- se lee como el nombre de una columna, con un error que no se parece en nada al
-- problema real. Con ellas llega como literal y el cast lo rechaza diciendo lo
-- que pasa. Medido: -v productos=abc contesta
--
--   ERROR: invalid input syntax for type integer: "abc"
--   LINE 2: SELECT ('abc')::int AS productos,
--
-- Y un parametro que no se pasa NO se sustituye por vacio: psql deja el
-- :'semilla' tal cual y la consulta muere con un error de sintaxis que senala la
-- linea y el nombre del parametro que falta. No es un mensaje bonito, pero
-- apunta al parametro correcto y sale con codigo 3, que es lo que importa.


BEGIN;


-- ============================================================
-- Los parametros
-- ============================================================
-- ON COMMIT DROP: la tabla se va sola al confirmar, y con el ROLLBACK tambien.
-- No queda nada de este archivo colgando en la sesion.
CREATE TEMP TABLE lote_parametro ON COMMIT DROP AS
SELECT (:'productos')::int             AS productos,
       (:'semilla')::bigint            AS semilla,
       (:'max_mongo_producto')::bigint AS max_mongo_producto,
       (:'max_mongo_variante')::bigint AS max_mongo_variante;


-- ============================================================
-- PASO 0. Las guardias, y todas ANTES del setval
-- ============================================================
-- Aqui van los rangos de los cuatro parametros, la precondicion de los dos
-- maximos de MongoDB y la guardia contra repetir una semilla. Las tres cosas
-- comparten un motivo para estar en este paso y no mas abajo: el PASO 1 empuja
-- las secuencias con setval y setval sobrevive al ROLLBACK, asi que una corrida
-- que se va a rechazar tiene que rechazarse ANTES de llegar ahi.
--
-- La guardia de repeticion. Correr dos veces la misma semilla tiene que ser un
-- fallo RUIDOSO, no un lote duplicado en silencio.
--
-- No es una precaucion generica: es que sin ella este archivo se rompe solo.
-- productos.nombre NO tiene UNIQUE -- se puede comprobar en
-- migrations/003_productos.sql, donde la tabla solo declara la PK y dos indices
-- por categoria y por estado -- y este generador resuelve el id de cada producto
-- recien insertado buscandolo POR NOMBRE, que es lo que exige la regla de que
-- ningun id se escriba a mano. Dos productos con el mismo nombre convierten ese
-- JOIN en un producto cartesiano: cada variante, cada caracteristica y cada
-- oferta se escribiria dos veces, y el segundo intento de variante moriria
-- contra el UNIQUE (id_producto, nombre_variante) del 003 con un mensaje que no
-- explica nada.
--
-- Se reconocen por el marcador que el PASO 4 le pega al nombre. La expresion
-- regular exige el formato completo -- espacio, L, la semilla, guion y cuatro
-- digitos al final -- y no un LIKE amplio, para que un producto curado que por
-- casualidad lleve una L y un numero en su nombre no lo confunda con un lote.
DO $guardia$
DECLARE
    p           record;
    v_ya        bigint;
    v_max_pg    bigint;
    v_max_pg_pv bigint;
BEGIN
    SELECT * INTO p FROM lote_parametro;

    IF p.productos IS NULL OR p.productos < 1 OR p.productos > 9999 THEN
        RAISE EXCEPTION
            'productos = % esta fuera de rango. Tiene que estar entre 1 y 9999',
            p.productos
            USING HINT = 'El tope de 9999 es el del marcador de lote, que lleva cuatro digitos y es lo que hace unico el nombre de cada producto dentro del lote';
    END IF;

    IF p.semilla IS NULL OR p.semilla < 0 THEN
        RAISE EXCEPTION
            'semilla = % no sirve. Tiene que ser un entero mayor o igual que cero',
            p.semilla;
    END IF;

    IF p.max_mongo_producto IS NULL OR p.max_mongo_producto < 0
       OR p.max_mongo_variante IS NULL OR p.max_mongo_variante < 0 THEN
        RAISE EXCEPTION
            'max_mongo_producto = % y max_mongo_variante = % tienen que ser enteros mayores o iguales que cero',
            p.max_mongo_producto, p.max_mongo_variante;
    END IF;

    -- La precondicion de los dos maximos de MongoDB
    -- ------------------------------------------------------------
    -- Vive AQUI, en la guardia, y no en el bloque que comprueba al final, y esa
    -- posicion es la mitad del arreglo. El PASO 1 empuja las dos secuencias con
    -- setval, y setval NO se deshace con el ROLLBACK. Una vez empujadas ya da
    -- igual lo que diga una comprobacion posterior: el dano de un parametro
    -- mentiroso es haber dejado la secuencia donde no iba, y eso sobrevive a la
    -- transaccion que se cae. Comprobar el parametro DESPUES del setval es
    -- comprobarlo cuando ya no sirve de nada.
    --
    -- Lo que se exige es que el parametro sea CREIBLE, no que sea cierto. Desde
    -- SQL no se puede abrir la base documental y preguntarle, asi que esto no
    -- compara el valor contra su fuente y nunca podra. Lo que si puede es
    -- rechazar el valor que es IMPOSIBLE si alguien de verdad consulto Mongo.
    --
    -- El catalogo viaja en un solo sentido: cada producto de PostgreSQL llega a
    -- Mongo con SU MISMO id, porque el ETL escribe con replaceOne sobre _id. Al
    -- reves no viaja nada, y por eso los productos nacidos en el panel no tienen
    -- fila de este lado. De ahi sale la desigualdad: con el catalogo al dia, el
    -- maximo de Mongo es mayor o igual que el de PostgreSQL, nunca menor. Un
    -- parametro por debajo del maximo de PostgreSQL solo puede querer decir dos
    -- cosas, y las dos son malas -- o se escribio a mano sin mirar, o es una
    -- lectura vieja de antes del ultimo lote -- y las dos dejan el mismo
    -- agujero, que es un maximo real de Mongo por encima del que llego.
    --
    -- El caso del CERO a ciegas, que es el que mas asusta porque el parametro
    -- por omision de quien no consulto nada vale justo eso, no lleva
    -- comprobacion propia: con la tabla productos llena su maximo vale al menos
    -- uno, asi que un cero cae siempre por esta misma comparacion. Escribirle
    -- una rama aparte seria escribir una rama que no puede ser nunca la que
    -- salta, y una comprobacion que no se puede poner roja no es una
    -- comprobacion. Con la tabla vacia el cero si pasa, y esta bien que pase:
    -- ahi no hay ningun id que pisar, y quien aborta unas lineas mas abajo es el
    -- PASO 3, que sin plantillas no tiene nada que clonar.
    --
    -- La contrapartida honesta, y hay que saberla porque muerde: entre generar
    -- un lote y correr el ETL, PostgreSQL va por delante de Mongo a proposito.
    -- En esa ventana la lectura de Mongo es CIERTA y esta precondicion la
    -- rechaza igual. Es deliberado. Un parametro que no cubre lo que PostgreSQL
    -- ya tiene no puede demostrar que cubre lo que Mongo tiene, y aqui vale mas
    -- pararse que apostar. Se sale de la ventana corriendo el ETL, que es lo que
    -- arrancar.ps1 hace por su cuenta despues de generar el lote.
    SELECT coalesce(max(id_producto), 0)          INTO v_max_pg    FROM productos;
    SELECT coalesce(max(id_producto_variante), 0) INTO v_max_pg_pv FROM productos_variantes;

    IF p.max_mongo_producto < v_max_pg THEN
        RAISE EXCEPTION
            'max_mongo_producto = % va por detras del mayor id_producto de PostgreSQL, que es %. Ese parametro no puede ser el maximo real de MongoDB',
            p.max_mongo_producto, v_max_pg
            USING HINT = 'Cada producto de PostgreSQL llega a MongoDB con su mismo id, asi que Mongo nunca va por detras. O el valor se escribio sin consultar la base documental, o es una lectura de antes del ultimo lote. Vuelve a leerlo con db.productos.find().sort({_id:-1}).limit(1), y si acabas de generar un lote corre antes el ETL';
    END IF;

    IF p.max_mongo_variante < v_max_pg_pv THEN
        RAISE EXCEPTION
            'max_mongo_variante = % va por detras del mayor id_producto_variante de PostgreSQL, que es %. Ese parametro no puede ser el maximo real de MongoDB',
            p.max_mongo_variante, v_max_pg_pv
            USING HINT = 'Vuelve a leerlo con db.productos.aggregate([{$unwind:"$variantes"},{$group:{_id:null,m:{$max:"$variantes.id_producto_variante"}}}]), y si acabas de generar un lote corre antes el ETL';
    END IF;

    SELECT count(*) INTO v_ya
    FROM productos
    WHERE nombre ~ (' L' || p.semilla || '-[0-9]{4}$');

    IF v_ya > 0 THEN
        RAISE EXCEPTION
            'La semilla % ya genero % productos en esta base',
            p.semilla, v_ya
            USING HINT = 'Corre con otra semilla, o borra antes los productos cuyo nombre termina en el marcador de esa semilla, en el orden de las llaves foraneas';
    END IF;
END
$guardia$;


-- ============================================================
-- PASO 1. Alinear las secuencias con MongoDB
-- ============================================================
-- Este es el paso que justifica los dos parametros de Mongo, y el problema que
-- resuelve no se ve mirando PostgreSQL solo.
--
-- Un vendedor que publica un producto desde el panel NO escribe nada en
-- PostgreSQL: ese producto nace en MongoDB, y su _id se calcula como el mayor
-- _id que ya existe mas uno. O sea que en este sistema hay DOS asignadores de
-- id de producto que no se hablan entre si:
--
--   PostgreSQL   el bigserial de productos.id_producto
--   MongoDB      el maximo _id mas uno, calculado por el panel
--
-- Hoy ya divergieron, y esta medido: PostgreSQL tiene 102 productos y su
-- secuencia esta en 102, asi que entregaria el 103; en Mongo los _id 103, 104,
-- 105 y 106 ya estan ocupados por cuatro productos que nacieron en el panel y
-- que no existen de este lado. Si este generador dejara que la secuencia
-- eligiera a ciegas, su primer producto se llevaria el 103, y el ETL -- que
-- lleva el catalogo a Mongo con un replaceOne sobre el _id -- MACHACARIA ese
-- producto del panel. Sin un solo error, porque el ETL no tiene barrido ni aviso
-- para db.productos: un replaceOne que pisa una fila ajena se ve igual que uno
-- que actualiza la propia.
--
-- Por eso, antes de insertar nada, las dos secuencias se empujan al mayor de los
-- dos mundos. Lo que se pierde es un hueco de numeros en PostgreSQL -- del 103
-- al 106 no habra nunca una fila aqui -- y ese hueco es correcto y deliberado:
-- esos cuatro numeros son de Mongo, y reclamarlos seria justo el choque que este
-- paso viene a evitar.
--
-- Y no, esto NO viola la regla de que ningun id se escribe a mano. El valor no
-- esta clavado en el archivo: se CALCULA en el momento a partir del maximo real
-- de PostgreSQL y del maximo real de MongoDB que llega por parametro. Lo que la
-- regla prohibe es un numero copiado que funciona en una maquina y revienta en
-- la de al lado, y aqui no hay ninguno.
--
-- El nombre de la secuencia sale de pg_get_serial_sequence() y no escrito a
-- mano, por lo mismo: si algun dia la columna cambia de tipo o de nombre, esto
-- falla en voz alta en vez de empujar una secuencia que ya no es la que manda.
SELECT setval(
    pg_get_serial_sequence('productos', 'id_producto'),
    GREATEST(
        (SELECT coalesce(max(id_producto), 0) FROM productos),
        (SELECT max_mongo_producto FROM lote_parametro)
    )
);

SELECT setval(
    pg_get_serial_sequence('productos_variantes', 'id_producto_variante'),
    GREATEST(
        (SELECT coalesce(max(id_producto_variante), 0) FROM productos_variantes),
        (SELECT max_mongo_variante FROM lote_parametro)
    )
);


-- ============================================================
-- PASO 2. El azar determinista
-- ============================================================
-- Dados una semilla, un indice de fila y un canal, devuelve un double entre 0
-- inclusive y 1 exclusive. Es la fuente de TODO lo que este archivo decide: que
-- plantilla clona cada producto, cuantas variantes le pone, que vendedores
-- entran, a que precio y con cuanto stock.
--
-- Tres cosas la obligan a ser asi y no de la forma corta.
--
-- 1. NO usa setseed() ni random(). El orden en que PostgreSQL evalua random()
--    sobre las filas de un SELECT no esta garantizado -- el planificador puede
--    reordenar, paralelizar o materializar -- asi que la fila numero siete no
--    tiene por que recibir el septimo numero de la serie. Con setseed la salida
--    depende de un ESTADO que se arrastra, y arrastrar estado entre filas es
--    justo lo que aqui no se puede hacer. Encima la implementacion de random()
--    cambio entre versiones de PostgreSQL, asi que la misma semilla daria
--    catalogos distintos en dos maquinas y se acabaria la reproducibilidad.
--    Aqui cada fila calcula su numero a partir de su PROPIO indice y de nada
--    mas, asi que el orden de evaluacion deja de importar.
--
-- 2. Toda la aritmetica es numeric. numeric es exacta y no desborda: los
--    productos intermedios pasan de 2^62 y en bigint eso seria un error de
--    desbordamiento o, peor, una vuelta silenciosa. En double perderia digitos
--    bajos, que son precisamente los que llevan la informacion. Con numeric el
--    resultado es identico en 32 y en 64 bits, en cualquier version.
--
-- 3. El CANAL es lo que permite sacar varios sorteos INDEPENDIENTES de la misma
--    fila. Sin el, el precio y el stock de una variante saldrian del mismo
--    numero y quedarian correlacionados: lo caro seria siempre lo escaso, y el
--    catalogo tendria un patron que ningun catalogo real tiene. Cada decision de
--    este archivo usa su propio canal, y estan listados en el PASO 9.
--
-- El algoritmo tiene dos mitades, y la segunda esta como esta porque la version
-- corta se MIDIO y no servia. Vale la pena dejar la medicion escrita, porque el
-- fallo era invisible por el camino por el que uno mira primero.
--
--   ronda uno    combina los tres argumentos con constantes distintas
--                -- multiplicadores tipo Knuth y el valor inicial de FNV --
--                contra 4294967291, el primo mas grande que cabe en 32 bits.
--                Un primo como modulo es lo que evita que los factores comunes
--                de las entradas sobrevivan a la mezcla.
--
--   rondas dos y tres   el avalancha de murmur3: xor contra los propios bits
--                desplazados, y multiplicacion contra 2^32. El xor es lo que
--                importa, y es lo que la primera version de esta funcion no
--                tenia.
--
-- La primera version hacia tres multiplicaciones modulares plegando los bits
-- altos con una SUMA, h + div(h, 65536), en vez de con un xor. Contra 20000
-- filas de esta misma base daba un reparto impecable por donde uno mira primero
-- -- los diez deciles con 2000 filas cada uno, media 0.5001, el 41.9 por ciento
-- de los sorteos por debajo de 0.42 -- y sin embargo estaba rota:
--
--   correlacion entre el canal del precio y el del stock    -0.238
--   correlacion entre el canal de entrar y el de la suerte  -0.153
--   correlacion entre la fila n y la fila n+1               +0.203
--   correlacion entre la semilla 999 y la 1000              +0.272
--
-- O sea que el canal no estaba separando nada: lo caro habria salido
-- sistematicamente escaso, y dos semillas vecinas habrian dado dos catalogos
-- parecidos en vez de dos catalogos distintos. Una suma no rompe la linealidad
-- que la multiplicacion modular conserva; un xor si. Con el avalancha de murmur3
-- las mismas cuatro medidas quedan en -0.0015, -0.0030, -0.0039 y +0.0078, y el
-- reparto por deciles sigue igual de plano.
--
-- La leccion es la de siempre en este proyecto: un histograma plano NO demuestra
-- que un generador sea bueno. Solo demuestra que cada canal por separado esta
-- bien repartido, que es justo lo que la version rota tambien hacia.
--
-- Toda la aritmetica pesada va en numeric y las mezclas de bits en bigint. Cada
-- valor intermedio cabe en 32 bits, asi que el xor y el desplazamiento son
-- exactos en bigint; los productos, que llegan a 2^64, se hacen en numeric
-- porque en bigint eso seria un error de desbordamiento -- PostgreSQL no da la
-- vuelta en silencio, pero tampoco sirve de nada que falle.
--
-- IMMUTABLE porque lo es de verdad: mismos argumentos, mismo resultado, siempre.
-- Marcarla asi deja que el planificador la evalue donde quiera, que es seguro
-- precisamente porque no depende del orden.
--
-- Vive en pg_temp y no en public: es andamio de este archivo, no parte del
-- esquema. Se va sola al cerrar la sesion, asi que no ensucia la base ni obliga
-- a acordarse de borrarla.
CREATE FUNCTION pg_temp.azar(p_semilla bigint, p_n bigint, p_canal integer)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
AS $azar$
    WITH constante AS (
        SELECT 4294967291::numeric AS m,   -- el primo mas grande de 32 bits
               4294967296::numeric AS w,   -- 2^32, la ventana de las mezclas
               2654435761::numeric AS a,   -- 2^32 dividido por la razon aurea
               2246822519::numeric AS b,
               3266489917::numeric AS c,
               2166136261::numeric AS d,   -- el valor inicial de FNV
               2246822507::numeric AS e,   -- las dos de murmur3
               3266489909::numeric AS f
    ),
    ronda_uno AS (
        SELECT k.*,
               (( abs(p_semilla)::numeric * k.a
                + abs(p_n)::numeric       * k.b
                + abs(p_canal)::numeric   * k.c
                + k.d ) % k.m)::bigint AS h
        FROM constante k
    ),
    ronda_dos AS (
        SELECT r.*, ((( r.h # (r.h >> 16) )::numeric * r.e) % r.w)::bigint AS h2
        FROM ronda_uno r
    ),
    ronda_tres AS (
        SELECT r.*, ((( r.h2 # (r.h2 >> 13) )::numeric * r.f) % r.w)::bigint AS h3
        FROM ronda_dos r
    )
    SELECT ((h3 # (h3 >> 16))::numeric / w)::double precision FROM ronda_tres;
$azar$;


-- ============================================================
-- PASO 3. Las plantillas
-- ============================================================
-- Cada producto nuevo se genera CLONANDO uno que ya existe. Esta es la decision
-- central del archivo, y conviene defenderla, porque la alternativa obvia --
-- inventar el producto entero desde cero -- parece mas limpia y no lo es.
--
-- Clonando se heredan tres cosas que la base ya sabe y que inventadas saldrian
-- mal:
--
--   la categoria      tiene que ser una HOJA. El trigger trg_productos_solo_en_hoja
--                     del 003 rechaza una raiz, asi que elegir mal falla; pero
--                     elegir una hoja al azar deja un producto colgado de una
--                     categoria que no ofrece las caracteristicas que trae.
--
--   las caracteristicas  producto_caracteristica.valor es TEXT, pero la
--                     definicion en caracteristica lleva id_tipo_dato (1 texto,
--                     2 entero, 3 decimal, 4 booleano, 5 lista). Un valor del
--                     tipo equivocado -- "grande" donde va un entero -- NO da
--                     ningun error en PostgreSQL, porque la columna es texto, y
--                     revienta despues en las consultas del catalogo de Mongo,
--                     donde el ETL castea. Un fallo que aparece en otra base,
--                     dias mas tarde y sin nada que lo ligue a su causa.
--
--   la imagen         una URL inventada se ve como un hueco en la pagina. La de
--                     la plantilla ya se comprobo que carga.
--
-- Inventar esos tres datos seria escribir a mano lo que la base ya tiene bien.
--
-- Que producto puede ser plantilla, y por que cada filtro:
--
--   * NO puede ser un producto generado por un lote anterior. Si lo fuera, su
--     nombre volveria a recibir un marcador y crecerian sin fin hasta chocar
--     contra el varchar(200); y ademas la guardia del PASO 0 se volveria
--     ambigua, porque un producto llevaria dos marcadores de dos semillas.
--   * Tiene que tener al menos una caracteristica, o el producto nuevo saldria
--     mudo en la ficha.
--   * TODAS sus variantes tienen que tener imagen y oferta de la tienda. Se
--     exige sobre todas y no sobre la primera porque el PASO 6 cicla por las
--     variantes de la plantilla, asi que cualquiera de ellas puede tocarle a un
--     producto nuevo. Una plantilla a medias solo se notaria en la variante que
--     salio premiada, que es la peor forma de notarlo.
--
-- El indice se numera con row_number() ORDER BY id_producto, que es un orden
-- estable y no depende de como el planificador devuelva las filas. Sin ese
-- ORDER BY, la misma semilla elegiria plantillas distintas en dos corridas, que
-- es justo lo que el PASO 2 existe para impedir.
CREATE TEMP TABLE lote_plantilla ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY p.id_producto) - 1 AS indice,
       p.id_producto,
       p.nombre,
       p.descripcion,
       p.id_categoria
FROM productos p
WHERE p.nombre !~ ' L[0-9]+-[0-9]{4}$'
  AND EXISTS (SELECT 1 FROM producto_caracteristica pc
               WHERE pc.id_producto = p.id_producto)
  AND EXISTS (SELECT 1 FROM productos_variantes pv
               WHERE pv.id_producto = p.id_producto)
  AND NOT EXISTS (
      SELECT 1
      FROM productos_variantes pv
      WHERE pv.id_producto = p.id_producto
        AND ( NOT EXISTS (SELECT 1 FROM imagen_producto_producto i
                           WHERE i.id_producto_variante = pv.id_producto_variante)
              OR
              NOT EXISTS (SELECT 1
                          FROM oferta o
                          JOIN usuarios u ON u.id_usuario = o.id_usuario
                          WHERE o.id_producto_mongo          = pv.id_producto
                            AND o.id_producto_variante_mongo = pv.id_producto_variante
                            AND u.correo_electronico         = 'tienda@mesh.com') )
  );

-- Sin plantillas no hay nada que clonar, y el INSERT de mas abajo se quedaria
-- sin filas sin quejarse: cero productos creados y salida con codigo 0. Un
-- generador que no genera nada y dice que todo fue bien es peor que uno que
-- falla, asi que falla.
DO $hay_plantillas$
DECLARE
    v_cuantas bigint;
BEGIN
    SELECT count(*) INTO v_cuantas FROM lote_plantilla;

    IF v_cuantas = 0 THEN
        RAISE EXCEPTION
            'No hay ni un producto que sirva de plantilla en esta base'
            USING HINT = 'Una plantilla es un producto no generado, con caracteristicas, y con imagen y oferta de la tienda en TODAS sus variantes. Carga migrations/datos/001_catalogo.sql antes de generar un lote';
    END IF;
END
$hay_plantillas$;

-- Las variantes de cada plantilla, numeradas dentro de su producto. cuantas se
-- lleva al lado para poder ciclar en el PASO 6 sin volver a contarlas fila por
-- fila.
CREATE TEMP TABLE lote_plantilla_variante ON COMMIT DROP AS
SELECT pv.id_producto AS id_plantilla,
       row_number() OVER (PARTITION BY pv.id_producto
                          ORDER BY pv.id_producto_variante) - 1 AS indice,
       count(*)      OVER (PARTITION BY pv.id_producto)         AS cuantas,
       pv.id_producto_variante,
       pv.nombre_variante,
       pv.descripcion
FROM productos_variantes pv
WHERE pv.id_producto IN (SELECT id_producto FROM lote_plantilla);


-- ============================================================
-- PASO 4. El plan y los productos
-- ============================================================
-- El nombre lleva un MARCADOR de lote, con esta forma exacta:
--
--     <nombre de la plantilla> L<semilla>-<n con cuatro digitos>
--     Monitor Panorama 34 L42-0007
--
-- El marcador hace dos trabajos a la vez, y los dos importan.
--
-- El primero es cerrar el circulo con la guardia del PASO 0: es lo que convierte
-- "correr dos veces la misma semilla" en un fallo ruidoso en vez de en un
-- catalogo duplicado en silencio. Sin marcador no habria por donde reconocer un
-- lote ya generado.
--
-- El segundo es que deja ver de un vistazo, en cualquier pantalla y sin
-- consultar nada, que producto es generado y cual es del catalogo curado. Un
-- catalogo de prueba que no se distingue del de verdad acaba siendo citado como
-- si fuera de verdad.
--
-- Los cuatro digitos son lo que hace unico el nombre dentro del lote, y de ahi
-- sale el tope de 9999 productos por corrida que exige la guardia. Con el nombre
-- unico, el PASO 4 puede resolver el id de cada producto recien insertado
-- buscandolo por nombre, sin escribir ni un id a mano.
--
-- El nombre de la plantilla se recorta con left() para que el resultado quepa en
-- el varchar(200) de la columna. Se recorta la BASE y nunca el marcador: al
-- reves, el nombre quedaria sin sus cuatro digitos y dos productos del mismo
-- lote podrian llamarse igual, que es exactamente lo que el marcador existe para
-- impedir.
--
-- Categoria y descripcion salen de la plantilla. El estado es activo, porque un
-- producto en borrador no aparece en ninguna consulta y no aportaria volumen a
-- lo que estos datos vienen a medir.
--
-- fecha_creacion es now(). Estos productos nacen HOY y no tienen un pasado que
-- fingir: 001_catalogo.sql si escribe fechas viejas, porque su trabajo es dar
-- algo que reconstruir, pero inventarle historia a un lote de relleno seria
-- meter mentiras en el historial para nada. Dentro de una transaccion now()
-- devuelve el instante en que empezo, asi que todo el lote comparte la misma
-- marca de tiempo, que es lo correcto: nacio todo junto.
CREATE TEMP TABLE lote_plan ON COMMIT DROP AS
WITH
parametro AS (SELECT * FROM lote_parametro),
cuantas   AS (SELECT count(*)::bigint AS total FROM lote_plantilla),
serie     AS (SELECT generate_series(1, (SELECT productos FROM parametro)) AS n)
SELECT s.n,
       pl.id_producto AS id_plantilla,
       left(pl.nombre, 200 - length(marca.marcador)) || marca.marcador AS nombre_nuevo,
       pl.descripcion,
       pl.id_categoria,
       1 + floor(pg_temp.azar(pa.semilla, s.n, 2) * 3)::int AS cuantas_variantes
FROM serie s
CROSS JOIN parametro pa
CROSS JOIN LATERAL (
    SELECT ' L' || pa.semilla || '-' || to_char(s.n, 'FM0000') AS marcador
) marca
JOIN lote_plantilla pl
  ON pl.indice = floor(pg_temp.azar(pa.semilla, s.n, 1)
                       * (SELECT total FROM cuantas))::bigint;

INSERT INTO productos (nombre, descripcion, fecha_creacion, id_estado_producto, id_categoria)
SELECT lp.nombre_nuevo, lp.descripcion, now(), ep.id_estado_producto, lp.id_categoria
FROM lote_plan lp
JOIN estado_producto ep ON ep.estado_producto_nombre = 'activo';

-- El id de cada producto recien escrito, resuelto POR NOMBRE. Es la misma regla
-- que sigue todo el proyecto -- ningun id se escribe a mano -- y aqui funciona
-- porque el marcador acaba de hacer unico cada nombre y la guardia del PASO 0
-- garantiza que no habia otro lote de esta semilla con esos nombres.
CREATE TEMP TABLE lote_producto ON COMMIT DROP AS
SELECT lp.n, lp.id_plantilla, p.id_producto
FROM lote_plan lp
JOIN productos p ON p.nombre = lp.nombre_nuevo;


-- ============================================================
-- PASO 5. El historial del producto
-- ============================================================
-- La fila de nacimiento en productos_historial es OBLIGATORIA, y no por
-- prolijidad. etl/cargar.js reconstruye la linea de tiempo de cada producto a
-- partir de sus filas de historial, y cuando no encuentra ninguna no puede
-- inventar el evento de creacion: avisa "productos sin ninguna fila de
-- historial: no se pueden reconstruir" y ese producto se queda sin eventos en
-- productos_eventos. La coleccion de historia de Mongo tendria un hueco por cada
-- producto de este lote, y el aviso sale en la salida del ETL, donde nadie lo
-- esta mirando.
--
-- Las columnas son las del 003: id_producto, nombre, descripcion, id_categoria y
-- fecha_creacion. id_categoria esta ahi porque el historial tiene que saber en
-- que categoria estaba el producto ese dia; sin ella, mover un producto de
-- categoria reescribe su pasado.
--
-- La fila sale DERIVADA de la fila viva que se acaba de escribir, no de la lista
-- del plan. Escrita dos veces podrian discrepar, y entonces el historial diria
-- que el producto nacio llamandose de otra forma sin que nada avisara. Es el
-- mismo molde que usa 001_catalogo.sql para el kardex del anillo de fraude.
INSERT INTO productos_historial (id_producto, nombre, descripcion, id_categoria, fecha_creacion)
SELECT p.id_producto, p.nombre, p.descripcion, p.id_categoria, p.fecha_creacion
FROM lote_producto lpr
JOIN productos p ON p.id_producto = lpr.id_producto;


-- ============================================================
-- PASO 6. Las variantes
-- ============================================================
-- Entre una y tres por producto, sorteadas con el canal 2 en el PASO 4, y
-- clonadas de las variantes de la plantilla. Si a un producto le tocan tres
-- variantes y su plantilla solo tiene una, se cicla: la posicion k toma la
-- variante k modulo cuantas.
--
-- Ciclar choca de frente contra el UNIQUE (id_producto, nombre_variante) del
-- 003. En la segunda vuelta el nombre se repetiria dentro del MISMO producto
-- nuevo y el INSERT moriria entero. Por eso a partir de la segunda vuelta el
-- nombre lleva un sufijo con el numero de vuelta -- "Digital", "Digital 2",
-- "Digital 3" -- y la primera vuelta se queda con el nombre limpio, que es el
-- caso normal cuando la plantilla tiene suficientes variantes.
--
-- El sufijo se calcula una sola vez en un LATERAL y se usa dos veces: para
-- medir cuanto hay que recortar la base y para pegarlo. Calculado dos veces
-- podrian desincronizarse y el nombre se pasaria del varchar(100).
CREATE TEMP TABLE lote_plan_variante ON COMMIT DROP AS
SELECT lp.n,
       s.k,
       lpv.id_producto_variante AS id_variante_plantilla,
       left(lpv.nombre_variante, 100 - length(sx.sufijo)) || sx.sufijo AS nombre_nuevo,
       lpv.descripcion
FROM lote_plan lp
CROSS JOIN LATERAL generate_series(0, lp.cuantas_variantes - 1) AS s(k)
JOIN lote_plantilla_variante lpv
  ON lpv.id_plantilla = lp.id_plantilla
 AND lpv.indice       = s.k % lpv.cuantas
CROSS JOIN LATERAL (
    SELECT CASE WHEN s.k / lpv.cuantas > 0
                THEN ' ' || (s.k / lpv.cuantas + 1)::text
                ELSE '' END AS sufijo
) sx;

INSERT INTO productos_variantes (id_producto, nombre_variante, descripcion, fecha_creacion, id_estado_variantes)
SELECT lpr.id_producto, lpv.nombre_nuevo, lpv.descripcion, now(), ev.id_estado_variante
FROM lote_plan_variante lpv
JOIN lote_producto     lpr ON lpr.n = lpv.n
JOIN estado_variantes  ev  ON ev.estado_variante_nombre = 'activa';

-- El id de cada variante nueva, resuelto por el par (producto, nombre), que es
-- justo el UNIQUE de la tabla y por eso devuelve una sola fila.
--
-- orden es el indice global de la variante dentro del lote, y es el numero que
-- el PASO 9 le pasa al azar como n. Tiene que ser estable, por eso lleva su
-- ORDER BY explicito: si dependiera del orden en que el planificador devuelve
-- las filas, dos corridas con la misma semilla darian precios distintos.
CREATE TEMP TABLE lote_variante ON COMMIT DROP AS
SELECT lpv.n,
       lpv.k,
       lpr.id_plantilla,
       lpr.id_producto,
       lpv.id_variante_plantilla,
       pv.id_producto_variante,
       row_number() OVER (ORDER BY lpv.n, lpv.k) AS orden
FROM lote_plan_variante lpv
JOIN lote_producto lpr ON lpr.n = lpv.n
JOIN productos_variantes pv
  ON pv.id_producto     = lpr.id_producto
 AND pv.nombre_variante = lpv.nombre_nuevo;

-- Su fila de nacimiento, derivada de la fila viva por el mismo motivo que la del
-- producto. Corre por separado del historial del producto: son dos historiales
-- distintos y renombrar el producto no escribe nada aqui.
INSERT INTO productos_variantes_historial (id_producto_variante, nombre_variante, descripcion, fecha_creacion)
SELECT pv.id_producto_variante, pv.nombre_variante, pv.descripcion, pv.fecha_creacion
FROM lote_variante lv
JOIN productos_variantes pv ON pv.id_producto_variante = lv.id_producto_variante;


-- ============================================================
-- PASO 7. Las caracteristicas
-- ============================================================
-- Se copian tal cual de la plantilla, del producto al producto y de la variante
-- plantilla a la variante nueva.
--
-- Copiar y no inventar es lo que garantiza que el TIPO cuadre. valor es TEXT en
-- las dos tablas, asi que PostgreSQL acepta cualquier cosa; quien dice como hay
-- que leer ese texto es caracteristica.id_tipo_dato, y el que lo lee de verdad
-- es el ETL cuando arma el documento de Mongo. Un "azul" donde la definicion
-- dice entero no falla aqui y rompe alla, en otra base y otro dia.
--
-- Tampoco hace falta comprobar que la categoria ofrezca esa caracteristica: el
-- producto nuevo esta en la MISMA categoria que su plantilla, asi que hereda un
-- juego de caracteristicas que esa categoria ya ofrecia.
--
-- Ojo con el UNIQUE que aqui NO hay: producto_caracteristica no lo lleva sobre
-- (producto, caracteristica), a proposito, porque una caracteristica de tipo
-- lista son varias filas con el mismo nombre. Copiar todas las filas de la
-- plantilla respeta eso sin tener que saberlo.
INSERT INTO producto_caracteristica (id_producto, id_caracteristica, valor)
SELECT lpr.id_producto, pc.id_caracteristica, pc.valor
FROM lote_producto lpr
JOIN producto_caracteristica pc ON pc.id_producto = lpr.id_plantilla;

INSERT INTO producto_variante_caracteristica_variante (id_producto_variante, id_caracteristica_variante, valor)
SELECT lv.id_producto_variante, pvcv.id_caracteristica_variante, pvcv.valor
FROM lote_variante lv
JOIN producto_variante_caracteristica_variante pvcv
  ON pvcv.id_producto_variante = lv.id_variante_plantilla;


-- ============================================================
-- PASO 8. Las imagenes
-- ============================================================
-- Aqui NO se inserta ni una fila en imagen_producto, y es deliberado.
--
-- imagen_producto.imagen_producto_url tiene UNIQUE, asi que reinsertar una URL
-- que ya existe no da un aviso: tumba la transaccion entera y se pierde el lote
-- completo. Y el esquema ya esta hecho para no tener que reinsertarla. El
-- comentario de la tabla en migrations/003_productos.sql lo dice con todas sus
-- letras: la misma foto sirve para varias variantes, por eso es una tabla aparte
-- y no una columna, y por eso la URL es unica -- la foto se guarda UNA vez y se
-- apunta desde donde haga falta.
--
-- Lo que apunta es imagen_producto_producto, cuyo UNIQUE es
-- (id_producto_variante, numero_orden). Cada variante nueva recibe UNA fila con
-- numero_orden 1 -- la portada, segun el comentario de esa columna -- apuntando
-- a la MISMA fila de imagen_producto que ya usa la variante plantilla. Cero
-- filas nuevas de imagen, cero riesgo de chocar contra el UNIQUE de la URL, y la
-- variante nueva ensena una foto que ya se comprobo que carga.
--
-- Se toma la de numero_orden mas bajo de la plantilla, que es su portada, con un
-- desempate por id para que la eleccion sea estable si alguna vez hubiera dos
-- con el mismo orden.
INSERT INTO imagen_producto_producto (id_imagen_producto, id_producto_variante, numero_orden)
SELECT foto.id_imagen_producto, lv.id_producto_variante, 1
FROM lote_variante lv
CROSS JOIN LATERAL (
    SELECT i.id_imagen_producto
    FROM imagen_producto_producto i
    WHERE i.id_producto_variante = lv.id_variante_plantilla
    ORDER BY i.numero_orden, i.id_imagen_producto_producto
    LIMIT 1
) foto;


-- ============================================================
-- PASO 9. Las ofertas
-- ============================================================
-- Aqui vive el precio y el stock. Una fila por vendedor y variante, que es lo
-- que exige el UNIQUE del 005.
--
-- Los canales del azar, para que se vea de un golpe que ningun sorteo se pisa
-- con otro. Todos usan como n el orden global de la variante dentro del lote:
--
--   1   que plantilla clona el producto            (PASO 4)
--   2   cuantas variantes le tocan al producto     (PASO 4)
--   10  la tienda se queda sin unidades
--   11  cuanto se mueve el precio de la tienda respecto de la plantilla
--   12  cuantas unidades tiene la tienda
--   20+j  entra el vendedor j
--   30+j  cuanto se aparta su precio del de la tienda
--   40+j  su suerte: pausada, sin unidades, o normal
--   50+j  cuantas unidades tiene
--
-- j es el numero de orden del vendedor por su correo, asi que dos vendedores
-- nunca comparten canal y sus decisiones son independientes entre si.
--
-- Las fechas: fecha_creacion, fecha_actualizacion y fecha_aprobacion, todas
-- now(). Y NINGUNA nace pendiente, por lo mismo que en 001_catalogo.sql: este
-- lote retrata un catalogo que ya funciona, y una oferta esperando revision para
-- siempre no es eso. Para probar la cola de aprobacion se publica una desde el
-- panel, que el backend ya la crea pendiente sola.
CREATE TEMP TABLE lote_vendedor ON COMMIT DROP AS
SELECT u.id_usuario,
       row_number() OVER (ORDER BY u.correo_electronico) AS j
FROM usuarios u
WHERE u.correo_electronico LIKE 'ventas.%@mesh.com';

-- La oferta de la tienda, sobre TODAS las variantes nuevas y sin excepcion.
--
-- Es lo unico que garantiza que ningun producto de este lote quede sin precio
-- que ensenar: precio_tienda del documento de Mongo sale de esta oferta, y sin
-- ella la tarjeta del catalogo sale vacia. Ademas es la comprobacion 3 de
-- 001_catalogo.sql -- "N variantes no tienen oferta de la tienda" -- que corre
-- sobre productos_variantes ENTERA, no solo sobre las suyas: dejar una variante
-- nueva sin la oferta de la tienda no rompe nada hoy y tumba la carga completa
-- la proxima vez que alguien recargue desde cero.
--
-- El precio sale del de la tienda para la variante PLANTILLA, movido entre un
-- 15 por ciento abajo y un 15 por ciento arriba con el canal 11. Movido y no
-- copiado, porque cien productos clonados con el precio exacto de su plantilla
-- se ven como lo que serian: cien copias. Y greatest(1.00, ...) porque el 005
-- exige precio >= 0 y un articulo a cero no es un articulo barato, es un error.
--
-- Una de cada diez sale SIN unidades, igual que en el conjunto curado. Si la
-- tienda tuviera stock en todo, el filtro de disponibilidad devolveria el
-- catalogo entero siempre y nadie sabria si funciona.
--
-- id_usuario_aprobo va en NULL, y NULL aqui NO significa "sin aprobar" -- la
-- fecha ya dice que si. Significa que no hubo revisor: la tienda es la autoridad
-- y no tiene a quien pedirle permiso. Es justo lo que esa columna existe para
-- poder contar, los dos caminos de nacimiento de una oferta.
INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario,
                    precio, stock, id_estado_oferta,
                    fecha_creacion, fecha_actualizacion, fecha_aprobacion, id_usuario_aprobo)
SELECT lv.id_producto,
       lv.id_producto_variante,
       ut.id_usuario,
       greatest(1.00, round(base.precio
                * (0.85 + pg_temp.azar(pa.semilla, lv.orden, 11) * 0.30)::numeric, 2)),
       CASE WHEN pg_temp.azar(pa.semilla, lv.orden, 10) < 0.10 THEN 0
            ELSE 3 + floor(pg_temp.azar(pa.semilla, lv.orden, 12) * 38)::int END,
       eo.id_estado_oferta,
       now(), now(), now(),
       NULL
FROM lote_variante lv
CROSS JOIN lote_parametro pa
JOIN usuarios      ut ON ut.correo_electronico   = 'tienda@mesh.com'
JOIN estado_oferta eo ON eo.estado_oferta_nombre = 'activa'
CROSS JOIN LATERAL (
    SELECT o.precio
    FROM oferta o
    JOIN usuarios u ON u.id_usuario = o.id_usuario
    WHERE o.id_producto_mongo          = lv.id_plantilla
      AND o.id_producto_variante_mongo = lv.id_variante_plantilla
      AND u.correo_electronico         = 'tienda@mesh.com'
    ORDER BY o.id_oferta
    LIMIT 1
) base;

-- Los cuatro vendedores ventas.*@mesh.com. El criterio es el mismo del generador
-- de migrations/datos/generador.js, en su seccion "Las ofertas": cada uno entra
-- con un 42 por ciento de probabilidad, a un precio entre un 8 por ciento mas
-- barato y un 8 por ciento mas caro que el de la tienda, y una minoria sale
-- pausada o con cero unidades.
--
-- Esa minoria no es ruido. Si todas estuvieran activas y con stock, la pantalla
-- nunca ensenaria los casos que si van a pasar de verdad: el producto que la
-- tienda no tiene pero otro vendedor si, la oferta pausada que no se puede
-- comprar aunque el vendedor exista. Se copia el criterio y no se inventa otro
-- para que el lote generado y el catalogo curado se vean como la misma tienda.
--
-- El precio se calcula contra la oferta de la tienda de la MISMA variante nueva,
-- que se acaba de escribir arriba, y no contra la de la plantilla. Es lo que
-- hace que la ficha del producto tenga sentido: cinco precios agrupados
-- alrededor del de la tienda, que es como se ve una variante con competencia.
--
-- Los dos LATERAL que buscan un precio de la tienda -- este y el del INSERT de
-- arriba, que busca el de la variante plantilla -- estan escritos IGUAL, con el
-- mismo ORDER BY y el mismo LIMIT 1, y hasta hace poco no lo estaban. Estar
-- escritos distinto invitaba a buscarle un motivo a la diferencia, y no lo hay:
-- los dos filtran por el mismo trio de columnas que forma el UNIQUE
-- (id_usuario, id_producto_mongo, id_producto_variante_mongo) del 005, asi que
-- los dos devuelven como mucho una fila y ninguno de los dos NECESITA desempate.
-- El ORDER BY no elige nada, y por eso mismo se deja en los dos: si algun dia
-- ese UNIQUE se relaja, el que lo lleva sigue siendo determinista y el que no lo
-- llevara duplicaria la oferta del vendedor. Dos consultas que preguntan lo
-- mismo tienen que leerse igual, o la proxima persona pierde el rato buscando la
-- diferencia que las separa.
--
-- Aqui id_usuario_aprobo SI lleva el id de la tienda, y eso es lo que distingue
-- este camino del de arriba: estas ofertas pasaron por la cola y alguien las
-- reviso. Las dos columnas juntas cuentan la historia entera, la fecha dice
-- cuando y esta dice quien.
INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario,
                    precio, stock, id_estado_oferta,
                    fecha_creacion, fecha_actualizacion, fecha_aprobacion, id_usuario_aprobo)
SELECT d.id_producto,
       d.id_producto_variante,
       d.id_vendedor,
       d.precio,
       d.stock,
       eo.id_estado_oferta,
       now(), now(), now(),
       ut.id_usuario
FROM (
    SELECT lv.id_producto,
           lv.id_producto_variante,
           ven.id_usuario AS id_vendedor,
           greatest(1.00, round(tienda.precio
                    * (0.92 + pg_temp.azar(pa.semilla, lv.orden, 30 + ven.j::int) * 0.16)::numeric, 2)) AS precio,
           CASE WHEN suerte.s >= 0.08 AND suerte.s < 0.16 THEN 0
                ELSE 1 + floor(pg_temp.azar(pa.semilla, lv.orden, 50 + ven.j::int) * 25)::int END AS stock,
           CASE WHEN suerte.s < 0.08 THEN 'pausada' ELSE 'activa' END AS estado
    FROM lote_variante lv
    CROSS JOIN lote_parametro pa
    CROSS JOIN lote_vendedor  ven
    CROSS JOIN LATERAL (
        SELECT pg_temp.azar(pa.semilla, lv.orden, 40 + ven.j::int) AS s
    ) suerte
    CROSS JOIN LATERAL (
        SELECT o.precio
        FROM oferta o
        JOIN usuarios u ON u.id_usuario = o.id_usuario
        WHERE o.id_producto_mongo          = lv.id_producto
          AND o.id_producto_variante_mongo = lv.id_producto_variante
          AND u.correo_electronico         = 'tienda@mesh.com'
        ORDER BY o.id_oferta
        LIMIT 1
    ) tienda
    WHERE pg_temp.azar(pa.semilla, lv.orden, 20 + ven.j::int) <= 0.42
) d
JOIN estado_oferta eo ON eo.estado_oferta_nombre = d.estado
JOIN usuarios      ut ON ut.correo_electronico   = 'tienda@mesh.com';


-- ============================================================
-- PASO 10. El precio_historial NO se escribe
-- ============================================================
-- Y esto hay que dejarlo escrito, porque la tentacion de copiarlo de
-- 001_catalogo.sql es fuerte y seria un error.
--
-- migrations/005_ofertas.sql tiene trg_oferta_registrar_precio, un trigger
-- AFTER INSERT OR UPDATE OF precio ON oferta. En INSERT escribe la fila de
-- nacimiento de precio_historial el solo, con NEW.fecha_creacion. O sea que las
-- ofertas del PASO 9 ya tienen su historial escrito, sin que este archivo haga
-- nada.
--
-- 001_catalogo.sql lo APAGA y escribe esas filas a mano, y tiene su motivo: sus
-- ofertas son de meses pasados y el trigger les pondria la fecha de creacion que
-- el archivo declara, que ahi si sirve, pero el resto de su historial son
-- CAMBIOS de precio con fechas del pasado que el trigger fecharia con now().
-- Este archivo no tiene ese problema, porque sus ofertas nacen hoy y no cambian
-- de precio nunca.
--
-- Asi que el trigger se deja ENCENDIDO y aqui no se inserta nada. Escribir la
-- fila ademas dejaria DOS filas de nacimiento por oferta, con el mismo precio y
-- la misma fecha, y ninguna comprobacion lo veria: la del precio mira la ULTIMA
-- fila del historial, y las dos dicen lo mismo. El historial mentiria diciendo
-- que hubo un cambio de precio que nunca existio, y lo haria en verde.
--
-- La comprobacion 4 del PASO 12 no da esto por hecho: mira que el precio de cada
-- oferta nueva sea el ultimo de su historial, que es como se demuestra que el
-- trigger DE VERDAD corrio y no solo que existe.


-- ============================================================
-- PASO 11. El kardex
-- ============================================================
-- Una fila de apertura en stock_movimiento por cada oferta nueva CON unidades.
--
-- Sale DERIVADA de la propia fila de oferta que se acaba de escribir, no de una
-- lista aparte. Es el mismo molde que usa 001_catalogo.sql para el anillo de
-- fraude, el unico tramo de ese archivo que ya es incremental, y el motivo es
-- que dos listas escritas por separado pueden discrepar: la oferta diria 12
-- unidades y el kardex 9, y el saldo dejaria de tener explicacion.
--
-- Solo cuando stock > 0, porque stock_movimiento tiene CHECK (cantidad > 0) en
-- el 006. Una oferta que nace agotada no tiene nada que anotar, y forzar una
-- fila con cantidad 0 seria inventar un movimiento que no ocurrio.
--
-- El motivo es reposicion, que es el que suma (valor = 1). cantidad y
-- stock_resultante son los dos el stock de la oferta, porque es su primer
-- movimiento y el saldo antes era cero. id_usuario_modifico es el dueno de la
-- oferta -- quien repone es el vendedor -- y no el aprobador. id_pedido va en
-- NULL porque una reposicion no nace de una venta.
--
-- Sin esto falla la comprobacion 1 de 001_catalogo.sql, "N ofertas tienen un
-- stock que su kardex no explica". Y aqui esta lo importante: NO falla ahora.
-- Falla la proxima vez que alguien recargue la base desde cero, semanas
-- despues, en la corrida de otra persona y sin nada que la ligue a este lote.
-- Un dato que rompe a distancia es peor que uno que rompe de frente.
--
-- El NOT EXISTS no es decorativo aunque estas ofertas sean nuevas: es lo que
-- hace que este INSERT diga lo que quiere decir, que es "abre el kardex de las
-- que todavia no lo tienen", y no dependa de que quien lo lea sepa que arriba no
-- se escribio ningun movimiento.
INSERT INTO stock_movimiento (id_oferta, id_motivo_movimiento, id_usuario_modifico,
                              id_pedido, cantidad, stock_resultante, fecha_movimiento)
SELECT o.id_oferta, m.id_motivo_movimiento, o.id_usuario,
       NULL, o.stock, o.stock, o.fecha_creacion
FROM oferta o
JOIN lote_variante lv
  ON lv.id_producto          = o.id_producto_mongo
 AND lv.id_producto_variante = o.id_producto_variante_mongo
JOIN motivo_movimiento m ON m.motivo_nombre = 'reposicion'
WHERE o.stock > 0
  AND NOT EXISTS (SELECT 1 FROM stock_movimiento sm WHERE sm.id_oferta = o.id_oferta);


-- ============================================================
-- PASO 12. El lote se comprueba a si mismo
-- ============================================================
-- Un conjunto de datos que no se verifica es un conjunto de datos que miente en
-- silencio, y este ademas se mete encima de uno que ya funciona: si lo deja
-- torcido, lo que se rompe es la base de alguien mas.
--
-- Las ocho comprobaciones fallan la transaccion ENTERA. Miran solo lo que este
-- archivo escribio -- las filas del lote -- y no la base completa, a proposito:
-- si el conjunto curado ya venia con algo torcido de antes, este archivo no es
-- el que lo tiene que descubrir, y culparlo de eso solo lograria que nadie
-- pudiera generar un lote hasta arreglar algo que no tiene que ver.
DO $verificar$
DECLARE
    p              record;
    v_mal          bigint;
    v_productos    bigint;
    v_variantes    bigint;
    v_ofertas      bigint;
    v_movimientos  bigint;
    v_min_producto bigint;
    v_max_producto bigint;
BEGIN
    SELECT * INTO p FROM lote_parametro;

    -- 1. Se crearon exactamente los productos que se pidieron. Se cuentan
    --    contra la tabla viva y por el marcador de la semilla, no contra la
    --    tabla temporal del plan: contar el plan seria preguntarle al que
    --    escribio si escribio.
    SELECT count(*) INTO v_productos
    FROM productos
    WHERE nombre ~ (' L' || p.semilla || '-[0-9]{4}$');

    IF v_productos <> p.productos THEN
        RAISE EXCEPTION
            'Se pidieron % productos de la semilla % y en la base quedaron %',
            p.productos, p.semilla, v_productos;
    END IF;

    -- 2. Toda variante nueva tiene su oferta de la tienda. Sin ella el producto
    --    no tiene precio que ensenar y la tarjeta del catalogo sale vacia, y
    --    ademas tumbaria la comprobacion 3 de 001_catalogo.sql la proxima vez
    --    que alguien cargue la base desde cero.
    SELECT count(*) INTO v_mal
    FROM lote_variante lv
    WHERE NOT EXISTS (
        SELECT 1
        FROM oferta o
        JOIN usuarios u ON u.id_usuario = o.id_usuario
        WHERE o.id_producto_mongo          = lv.id_producto
          AND o.id_producto_variante_mongo = lv.id_producto_variante
          AND u.correo_electronico         = 'tienda@mesh.com'
    );

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% variantes nuevas no tienen oferta de la tienda', v_mal;
    END IF;

    -- 3. El saldo de cada oferta nueva es la suma de su kardex. Es la misma
    --    cuenta que hace la comprobacion 1 de 001_catalogo.sql, con el mismo
    --    signo sacado de motivo_movimiento.valor y no escrito a mano.
    SELECT count(*) INTO v_mal
    FROM oferta o
    JOIN lote_variante lv
      ON lv.id_producto          = o.id_producto_mongo
     AND lv.id_producto_variante = o.id_producto_variante_mongo
    LEFT JOIN (
        SELECT sm.id_oferta, sum(sm.cantidad * mm.valor) AS saldo
        FROM stock_movimiento sm
        JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento
        GROUP BY sm.id_oferta
    ) k ON k.id_oferta = o.id_oferta
    WHERE o.stock <> coalesce(k.saldo, 0);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas nuevas tienen un stock que su kardex no explica', v_mal;
    END IF;

    -- 4. El precio de cada oferta nueva es el ultimo de su precio_historial.
    --    Esta comprobacion NO valida el precio: valida que el trigger del 005 de
    --    verdad corrio, que no es lo mismo que suponer que existe. El PASO 10 no
    --    escribe esa fila y descansa entero en el trigger; si alguien lo dejara
    --    apagado -- 001_catalogo.sql lo apaga y lo vuelve a encender, y una
    --    corrida interrumpida a la mitad lo deja apagado para siempre y en
    --    silencio -- este lote naceria sin historial de precio y nada mas lo
    --    notaria.
    SELECT count(*) INTO v_mal
    FROM oferta o
    JOIN lote_variante lv
      ON lv.id_producto          = o.id_producto_mongo
     AND lv.id_producto_variante = o.id_producto_variante_mongo
    LEFT JOIN LATERAL (
        SELECT ph.precio
        FROM precio_historial ph
        WHERE ph.id_oferta = o.id_oferta
        ORDER BY ph.fecha_creacion DESC, ph.id_precio_historial DESC
        LIMIT 1
    ) ultimo ON true
    WHERE ultimo.precio IS NULL OR o.precio <> ultimo.precio;

    IF v_mal > 0 THEN
        RAISE EXCEPTION
            '% ofertas nuevas no tienen su precio como ultimo de su historial. El trigger trg_oferta_registrar_precio del 005 no corrio',
            v_mal;
    END IF;

    -- 5. Ninguna oferta nueva activa o pausada quedo sin fecha_aprobacion. A
    --    esos dos estados no se llega sin el visto bueno de la tienda, asi que
    --    una fila asi es un estado imposible. Y no es un dato de auditoria: esa
    --    columna es EL candado que decide si un vendedor puede activar su propia
    --    oferta sin que nadie la vea. Es la comprobacion 4 de 001_catalogo.sql.
    SELECT count(*) INTO v_mal
    FROM oferta o
    JOIN lote_variante lv
      ON lv.id_producto          = o.id_producto_mongo
     AND lv.id_producto_variante = o.id_producto_variante_mongo
    JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
    WHERE eo.estado_oferta_nombre IN ('activa', 'pausada')
      AND o.fecha_aprobacion IS NULL;

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas nuevas circulan sin fecha de aprobacion', v_mal;
    END IF;

    -- 6. Ningun producto nuevo quedo sin su fila de historial. Sin ella el ETL
    --    no puede reconstruir el producto y lo dice en un aviso que sale por la
    --    salida estandar, donde nadie lo esta mirando.
    SELECT count(*) INTO v_mal
    FROM lote_producto lpr
    WHERE NOT EXISTS (SELECT 1 FROM productos_historial h
                       WHERE h.id_producto = lpr.id_producto);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% productos nuevos se quedaron sin fila de historial', v_mal;
    END IF;

    -- 7. Ningun id nuevo cae dentro del rango que el PARAMETRO declara para
    --    MongoDB. Hay que leerla por lo que es y no por lo que su nombre invita
    --    a creer, porque las dos cosas no son la misma.
    --
    --    NO es una garantia contra MongoDB. Desde SQL no se puede abrir la base
    --    documental, asi que esto no compara contra Mongo: compara contra el
    --    numero que alguien dijo que era el maximo de Mongo. Es una comprobacion
    --    de COHERENCIA INTERNA -- que la secuencia entrego ids por encima de lo
    --    que el parametro declara -- y nada mas que eso.
    --
    --    La otra mitad, la que si trabaja sobre el parametro, esta arriba, en la
    --    precondicion del PASO 0: es la que exige que el valor sea CREIBLE antes
    --    de que el setval se lo crea. Y hay que decirlo entero, porque es el
    --    limite de las dos: ninguna sabe si el parametro corresponde al MongoDB
    --    que el ETL va a cargar despues. Quien pasa un parametro correcto es
    --    arrancar.ps1, que le pregunta a Mongo por sus dos maximos y se para si
    --    Mongo no contesta un numero. Eso es un ACUERDO, no un mecanismo, y este
    --    proyecto distingue las dos cosas a proposito.
    --
    --    Aun asi se queda, porque tiene un camino real por el que ponerse roja,
    --    y es un camino SILENCIOSO. El setval del PASO 1 saca el nombre de la
    --    secuencia de pg_get_serial_sequence(), y esa funcion devuelve NULL --
    --    no falla -- cuando la columna existe pero ya no cuelga de una
    --    secuencia. Medido en esta base: pg_get_serial_sequence sobre una
    --    columna que no es serial devuelve NULL, y setval(NULL, n) devuelve NULL
    --    sin error ninguno. O sea que el dia que esa columna deje de ser
    --    bigserial, el PASO 1 no empuja nada y no se queja, y el unico sitio
    --    donde eso se nota es aqui: la secuencia sigue en el maximo de
    --    PostgreSQL, el lote arranca justo encima de el, y si Mongo va por
    --    delante -- que es exactamente el caso que el PASO 1 existe para cubrir,
    --    el de los productos nacidos en el panel -- esos ids caen dentro del
    --    rango declarado y esta comprobacion salta. Un cambio de NOMBRE de la
    --    columna si falla en voz alta, que pg_get_serial_sequence sobre una
    --    columna que no existe da error; el que se cuela sin ruido es el otro.
    --
    --    Lo que esta comprobacion NO puede hacer es ponerse roja con el archivo
    --    intacto: ahi el setval deja la secuencia en el mayor de los dos mundos
    --    y el primer id del lote cae siempre despues. Esa mitad la garantiza el
    --    setval, no esta comprobacion, y es justo por eso por lo que no basta
    --    con ella sola.
    SELECT min(id_producto), max(id_producto) INTO v_min_producto, v_max_producto
    FROM lote_producto;

    IF v_min_producto <= p.max_mongo_producto THEN
        RAISE EXCEPTION
            'El producto nuevo % cae dentro del rango declarado para MongoDB, que llega hasta el %. La secuencia entrego un id que el PASO 1 tenia que haber dejado atras',
            v_min_producto, p.max_mongo_producto
            USING HINT = 'El setval del PASO 1 no surtio efecto. Comprueba que pg_get_serial_sequence(''productos'', ''id_producto'') no devuelve NULL: si la columna dejo de ser bigserial, setval(NULL, n) no empuja nada y tampoco da error';
    END IF;

    SELECT count(*) INTO v_mal
    FROM lote_variante
    WHERE id_producto_variante <= p.max_mongo_variante;

    IF v_mal > 0 THEN
        RAISE EXCEPTION
            '% variantes nuevas pisan el rango de MongoDB, que llega hasta la %',
            v_mal, p.max_mongo_variante;
    END IF;

    -- 8. Toda variante nueva ensena una imagen. El INSERT del PASO 8 va por un
    --    CROSS JOIN LATERAL contra la variante plantilla, y un LATERAL que no
    --    encuentra fila no falla: DESCARTA la variante en silencio. Hoy no puede
    --    pasar, porque el filtro del PASO 3 exige que TODAS las variantes de una
    --    plantilla tengan imagen; pero eso es una condicion que vive a
    --    cuatrocientas lineas de aqui y que alguien puede relajar sin ver la
    --    consecuencia. Un filtro que protege a distancia no es un mecanismo, es
    --    un acuerdo, asi que ademas se comprueba.
    SELECT count(*) INTO v_mal
    FROM lote_variante lv
    WHERE NOT EXISTS (SELECT 1 FROM imagen_producto_producto i
                       WHERE i.id_producto_variante = lv.id_producto_variante);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% variantes nuevas se quedaron sin imagen que ensenar', v_mal;
    END IF;

    -- El resumen. Se cuenta contra las tablas vivas, que es lo unico que
    -- demuestra algo.
    SELECT count(*) INTO v_variantes FROM lote_variante;

    SELECT count(*) INTO v_ofertas
    FROM oferta o
    JOIN lote_variante lv
      ON lv.id_producto          = o.id_producto_mongo
     AND lv.id_producto_variante = o.id_producto_variante_mongo;

    SELECT count(*) INTO v_movimientos
    FROM stock_movimiento sm
    JOIN oferta o ON o.id_oferta = sm.id_oferta
    JOIN lote_variante lv
      ON lv.id_producto          = o.id_producto_mongo
     AND lv.id_producto_variante = o.id_producto_variante_mongo;

    RAISE NOTICE
        'Lote de la semilla % verificado. % productos (id % al %), % variantes, % ofertas y % movimientos de apertura. Los id arrancan despues del % de MongoDB',
        p.semilla, v_productos, v_min_producto, v_max_producto,
        v_variantes, v_ofertas, v_movimientos, p.max_mongo_producto;
END
$verificar$;


COMMIT;
