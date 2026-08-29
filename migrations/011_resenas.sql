-- 011_resenas.sql
-- La parte social: quien califica a quien, sobre que producto, y la
-- conversacion que cuelga de ahi.
--
-- Son las tres ultimas tablas del diagrama. Con estas, las 42 cajas del ER
-- estan construidas.
--
--
-- La resena es del VENDEDOR sobre un PRODUCTO, no de una oferta
-- ============================================================
-- Esto cambio, y conviene dejar escrito por que, porque
-- docs/base-de-datos.md defendia lo contrario durante la Entrega 1.
--
-- La decision original era colgar la resena de `oferta`, para que "A califica a
-- B" fuera un camino real entre cuentas. Ese motivo sigue siendo bueno y NO se
-- abandona: `id_usuario_vendedor` lo conserva entero, y ademas lo acorta.
--
-- Lo que se descarto fue el vehiculo. `oferta` es unica por
-- (usuario, producto, VARIANTE), asi que colgar la resena de ahi no la deja
-- sobre "Carlos me vendio bien esta laptop" sino sobre "Carlos me vendio bien
-- la laptop, version negra de 14 pulgadas". Un vendedor con tres variantes del
-- mismo producto termina con sus resenas repartidas en tres filas que el modelo
-- trata como cosas distintas, y la nota del vendedor pasa a ser un promedio de
-- promedios. Nadie resena una variante.
--
-- Cambiarlo ahora cuesta cero -- las tablas no existian. En tres semanas
-- costaba migracion, ETL y reescribir el informe.
--
--
-- Lo que se paga, dicho de frente
-- ============================================================
-- Con `id_oferta` la base garantizaba que la resena apuntaba a una oferta real.
-- Con `id_producto_mongo` no puede: el catalogo vive en MongoDB. Que ese
-- vendedor venda ese producto pasa a ser comprobacion de la aplicacion.
--
-- Es el MISMO precio que `oferta` ya paga y ya dejo escrito en la 005:
--   "la base ya no puede rechazar una oferta sobre una variante que no existe.
--    Eso pasa a ser trabajo de la aplicacion."
-- No es una excepcion nueva; es la regla de la casa aplicada otra vez.
--
-- Lo que si queda garantizado es la mitad que importa para la Entrega 2: las
-- dos cuentas son cuentas de verdad, con llave foranea, porque viven aqui.
--
--
-- Por que no exige haber comprado
-- ============================================================
-- No hay llave foranea a `pedido`, y es deliberado.
--
-- La Entrega 2 pide senalar cuentas que se califican entre si de forma
-- anomala. La resena SIN compra detras es la senal mas fuerte que existe de
-- eso. Exigir la compra la borraria del modelo: el fraude mas obvio dejaria de
-- poder representarse, y la consulta perderia su hallazgo mas util.
--
-- Es la diferencia entre un modelo que impide el fraude y uno que lo puede
-- OBSERVAR. Aqui hace falta el segundo.
--
--
-- Todo esto se queda en PostgreSQL
-- ============================================================
-- MongoDB entro a este sistema por una sola razon: los atributos cambian entre
-- categorias de producto. Un comentario tiene siempre los mismos cuatro campos.
-- Heterogeneidad cero. Llevarlo al documental seria usarlo porque esta, no
-- porque el dato lo pida.
--
-- Y embeberlo en el documento del producto contradice una decision ya tomada y
-- ya calificada: las resenas no van embebidas porque no tienen techo y porque
-- cada una reescribiria el producto entero. Los comentarios son peores -- hay
-- mas y llegan mas seguido.
--
-- La velocidad de LECTURA, que es lo que de verdad preocupa aqui, no se
-- resuelve cambiando de base: se resuelve con un contador denormalizado (abajo,
-- `cantidad_likes`) y con cache. Es lo que hacen los sistemas que tienen este
-- problema de verdad -- TAO de Facebook es un cache de grafo delante de MySQL,
-- no un reemplazo de MySQL. El cache le toca a Redis en la Entrega 2.


-- ============================================================
-- comentario
-- ============================================================
-- Un texto escrito por alguien, en un momento. Si tiene padre es una respuesta;
-- si no lo tiene, es la raiz de una resena.
--
-- El arbol vive en una sola tabla y no en dos porque una respuesta y un texto
-- de resena son la misma cosa: alguien escribio algo. Partirlos obligaria a
-- tener dos tablas de likes o una referencia polimorfica, y el like sobre la
-- RESENA es justo el que importa para detectar manipulacion.
CREATE TABLE IF NOT EXISTS comentario (
    id_comentario  bigserial PRIMARY KEY,

    -- NULL = es la raiz de una resena. No NULL = es una respuesta.
    --
    -- RESTRICT y no CASCADE: borrar un comentario con respuestas colgando
    -- dejaria huerfana una conversacion entera sin que nadie se entere. Si
    -- alguna vez hace falta borrar un hilo, se borra de abajo hacia arriba y a
    -- proposito.
    id_comentario_padre  bigint REFERENCES comentario(id_comentario)
                         ON DELETE RESTRICT,

    -- QUIEN lo escribio.
    --
    -- Esta columna NO esta en el diagrama, y es un hueco del diagrama, no una
    -- licencia. Sin ella una RESPUESTA no tiene autor: la raiz podria sacarlo
    -- de `resena.id_usuario`, pero una respuesta no cuelga de ninguna resena y
    -- se quedaria sin forma de saber quien la escribio. No se podria ni pintar
    -- "Carlos respondio: ..." ni contar cuentas que se comentan entre si, que
    -- es una de las senales de la Entrega 2.
    --
    -- Para la raiz queda repetido con `resena.id_usuario`. Es redundancia real
    -- y se acepta a sabiendas: la alternativa era dejar las respuestas sin
    -- autor. La coherencia entre las dos la comprueba el conjunto de datos.
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    -- Obligatorio y no vacio. Un comentario en blanco no es un comentario, y el
    -- CHECK es lo que impide que una ruta nueva mande la cadena vacia.
    comentario  text NOT NULL CHECK (length(trim(comentario)) > 0),

    fecha_publicacion  timestamptz NOT NULL DEFAULT now(),

    -- Los dos contadores son una COPIA de lo que dice `likes`, y existen por
    -- una razon medida, no por comodidad: contar en cada lectura
    -- (`count(*) FROM likes WHERE ...`) es el patron que se rompe primero
    -- cuando la ficha de un producto se pide todo el tiempo. Instagram y
    -- Reddit resuelven esto igual, con un contador al lado.
    --
    -- Al ser una copia, PUEDE desincronizarse -- y por eso no se actualizan a
    -- mano desde ningun lado: los mantiene el trigger de mas abajo, y el
    -- conjunto de datos falla al cargar si no cuadran. Un contador derivado sin
    -- mecanismo que lo sostenga es un dato que miente en silencio.
    --
    -- Se separan en dos columnas y no en una suma porque "40 a favor y 38 en
    -- contra" y "2 a favor y 0 en contra" dan lo mismo restando, y no son lo
    -- mismo: la primera es una pelea y la segunda es un comentario tranquilo.
    cantidad_likes     integer NOT NULL DEFAULT 0 CHECK (cantidad_likes    >= 0),
    cantidad_dislikes  integer NOT NULL DEFAULT 0 CHECK (cantidad_dislikes >= 0)
);

COMMENT ON TABLE comentario IS
    'Un texto de alguien. Sin padre es la raiz de una resena; con padre es una respuesta';
COMMENT ON COLUMN comentario.id_comentario_padre IS
    'NULL = raiz de una resena. No NULL = respuesta a otro comentario';
COMMENT ON COLUMN comentario.id_usuario IS
    'Quien lo escribio. Para la raiz coincide con resena.id_usuario, a proposito';
COMMENT ON COLUMN comentario.cantidad_likes IS
    'Copia derivada de likes(valor=1). La mantiene el trigger, no la aplicacion';
COMMENT ON COLUMN comentario.cantidad_dislikes IS
    'Copia derivada de likes(valor=-1). La mantiene el trigger, no la aplicacion';

-- "las respuestas de este comentario": es como se arma el hilo.
--
-- PARCIAL: solo indexa las respuestas. Las raices son NULL en esta columna y
-- nunca se buscan por ella, asi que meterlas seria pagar por guardar lo que no
-- se consulta. Con una resena por producto y varias respuestas cada una, las
-- raices son una parte grande de la tabla.
CREATE INDEX IF NOT EXISTS idx_comentario_padre
    ON comentario(id_comentario_padre)
    WHERE id_comentario_padre IS NOT NULL;

-- "todo lo que escribio esta cuenta, de lo mas nuevo a lo mas viejo".
--
-- Es la consulta del panel de fraude: cuentas que se comentan entre si. Sin
-- este indice recorre la tabla entera, y el panel la hace una vez por cuenta
-- sospechosa.
CREATE INDEX IF NOT EXISTS idx_comentario_usuario
    ON comentario(id_usuario, fecha_publicacion DESC);


-- ============================================================
-- resena
-- ============================================================
-- Una cuenta califica a un vendedor, sobre un producto.
CREATE TABLE IF NOT EXISTS resena (
    id_resena  bigserial PRIMARY KEY,

    -- Quien califica.
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    -- A quien califica. Es la columna que hace posible la Entrega 2: con ella
    -- "A califica a B" es un dato, no un recorrido.
    --
    -- Apunta a `usuarios` y no a una tabla de vendedores porque no hay tal
    -- tabla, y no la hay a proposito: en Mesh comprar no pide rol, asi que un
    -- vendedor tambien compra. Son la misma cuenta.
    id_usuario_vendedor  bigint NOT NULL REFERENCES usuarios(id_usuario)
                         ON DELETE RESTRICT,

    -- El id del catalogo, con el sufijo _mongo y SIN llave foranea, igual que
    -- en `oferta`, `pedido_producto` y `propuesta_producto`. El catalogo se lee
    -- desde MongoDB y PostgreSQL no puede garantizar integridad referencial
    -- contra otra base; el sufijo esta para que quien lea la tabla lo sepa y no
    -- busque una FK que no existe.
    --
    -- Es el PRODUCTO y no la variante: ver la cabecera del archivo.
    id_producto_mongo  bigint NOT NULL,

    calificacion  smallint NOT NULL CHECK (calificacion BETWEEN 1 AND 5),

    -- El texto y la fecha viven en el comentario raiz. La resena no lleva fecha
    -- propia: seria una segunda verdad sobre cuando se escribio.
    --
    -- UNIQUE: dos resenas no pueden compartir la misma raiz. Sin esto, dos
    -- calificaciones distintas podrian colgar del mismo texto y la
    -- conversacion tendria dos duenos.
    id_comentario  bigint NOT NULL UNIQUE REFERENCES comentario(id_comentario)
                   ON DELETE RESTRICT,

    -- Una resena por comprador, vendedor y producto.
    --
    -- Sin esto el fraude se puede fingir con una sola relacion repetida
    -- cincuenta veces, y la consulta de varios saltos deja de demostrar nada:
    -- encontraria "reiteracion" donde solo hubo una cuenta apretando un boton.
    -- La reiteracion que interesa es sobre productos DISTINTOS.
    UNIQUE (id_usuario, id_usuario_vendedor, id_producto_mongo),

    -- Nadie se califica a si mismo. Es barato, es correcto de cara al usuario,
    -- y en el grafo evita un bucle sobre el mismo nodo que ensuciaria la
    -- deteccion de ciclos sin aportar nada.
    CHECK (id_usuario <> id_usuario_vendedor)
);

COMMENT ON TABLE resena IS
    'Una cuenta califica a un vendedor sobre un producto. No exige compra, a proposito';
COMMENT ON COLUMN resena.id_usuario IS
    'Quien califica';
COMMENT ON COLUMN resena.id_usuario_vendedor IS
    'A quien califica. Es un usuario: en Mesh un vendedor tambien compra';
COMMENT ON COLUMN resena.id_producto_mongo IS
    'Del catalogo en MongoDB. NO es llave foranea. Es el producto, no la variante';
COMMENT ON COLUMN resena.id_comentario IS
    'La raiz del hilo: ahi viven el texto y la fecha. Debe tener id_comentario_padre NULL';

-- "las resenas de este producto": es la ficha, la pantalla que las ensena.
CREATE INDEX IF NOT EXISTS idx_resena_producto
    ON resena(id_producto_mongo);

-- "las resenas de este vendedor": es su reputacion, y es el primer salto de la
-- consulta de fraude. Va tambien el autor, porque el panel entra por el par:
-- "quienes calificaron a B" se contesta desde el indice sin tocar la tabla.
CREATE INDEX IF NOT EXISTS idx_resena_vendedor
    ON resena(id_usuario_vendedor, id_usuario);

-- La invariante que NO se puede escribir como CHECK:
--
--   resena.id_comentario tiene que apuntar a una RAIZ (id_comentario_padre
--   NULL), nunca a una respuesta.
--
-- Un CHECK no puede mirar otra fila, asi que no hay forma de exigirlo en la
-- definicion de la tabla -- es el mismo caso que la invariante de `oferta` en
-- la 010. Queda como regla de la aplicacion MAS una verificacion en el
-- conjunto de datos, que es lo que la vuelve comprobable en vez de un deseo.
--
-- Si algun dia una resena apunta a una respuesta, el hilo se dibuja dentro de
-- si mismo y no da ningun error.


-- ============================================================
-- likes
-- ============================================================
-- Un voto de una cuenta sobre un comentario. Sirve igual para una resena (su
-- raiz) que para una respuesta.
CREATE TABLE IF NOT EXISTS likes (
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    id_comentario  bigint NOT NULL REFERENCES comentario(id_comentario)
                   ON DELETE RESTRICT,

    -- 1 a favor, -1 en contra.
    --
    -- Sin CHECK, por decision del equipo: el rango lo valida la aplicacion, en
    -- la misma linea que la variante de `oferta`. Lo que si queda amarrado es
    -- que los contadores y esta columna no se puedan contradecir: el trigger
    -- cuenta EXACTAMENTE valor = 1 y valor = -1, asi que un valor fuera de
    -- rango no suma en ningun lado en vez de sumar donde no debe.
    valor  smallint NOT NULL,

    -- Lleva fecha propia porque no es un comentario y no tiene de donde
    -- heredarla. Y es el campo que hace posible detectar manipulacion:
    -- cuarenta likes en tres minutos, o cuentas creadas el mismo dia dandose
    -- like entre si.
    fecha_creacion  timestamptz NOT NULL DEFAULT now(),

    -- La llave es el par, y eso ES la regla: un voto por cuenta y comentario.
    -- Cambiar de opinion es un UPDATE de `valor`, no una fila nueva.
    --
    -- Sin esta llave una cuenta puede votar cuarenta veces lo mismo, y
    -- entonces "cuarenta likes en tres minutos" deja de ser una senal de
    -- fraude: es un boton apretado cuarenta veces.
    PRIMARY KEY (id_usuario, id_comentario)
);

COMMENT ON TABLE likes IS
    'Un voto por cuenta y comentario. Cambiar de opinion es un UPDATE, no otra fila';
COMMENT ON COLUMN likes.valor IS
    '1 a favor, -1 en contra. El rango lo valida la aplicacion';
COMMENT ON COLUMN likes.fecha_creacion IS
    'Cuando se voto. Es el campo que permite ver rafagas de votos sospechosas';

-- "los votos de este comentario", que es como se recuentan.
--
-- La llave primaria empieza por id_usuario, asi que NO sirve para entrar por
-- comentario: la base tendria que recorrerla entera. Este indice es lo que hace
-- que el trigger de abajo cueste dos busquedas y no dos recorridos.
CREATE INDEX IF NOT EXISTS idx_likes_comentario
    ON likes(id_comentario);


-- ============================================================
-- El trigger que sostiene los contadores
-- ============================================================
-- `cantidad_likes` y `cantidad_dislikes` son una copia derivada, y una copia
-- derivada sin mecanismo es un dato que se desincroniza en silencio. Un aviso
-- en la documentacion ("acordate de recalcular") no es un mecanismo: caduca el
-- dia que alguien escribe la segunda ruta que toca `likes`.
--
-- RECUENTA en vez de sumar y restar. Sumar seria mas barato, pero un contador
-- incremental acumula error para siempre: basta un camino que se salte el
-- trigger, o una corrida a medias, para que quede desviado sin forma de
-- notarlo. Recontar es correcto por construccion -- el contador no puede
-- apartarse de lo que dice la tabla -- y a esta escala cuesta dos busquedas por
-- indice.
--
-- Cuenta valor = 1 y valor = -1 EXPLICITAMENTE. Como el rango no tiene CHECK,
-- un valor fuera de rango no cae en ninguno de los dos en vez de contaminar
-- uno: los contadores pueden quedarse cortos, nunca torcidos.
CREATE OR REPLACE FUNCTION recontar_votos_comentario()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_ids  bigint[];
    v_id   bigint;
BEGIN
    -- Se decide por TG_OP y no con un CASE sobre NEW/OLD: en un DELETE la fila
    -- NEW no existe, y nombrarla revienta en tiempo de ejecucion aunque la rama
    -- no se use.
    IF TG_OP = 'INSERT' THEN
        v_ids := ARRAY[NEW.id_comentario];
    ELSIF TG_OP = 'DELETE' THEN
        v_ids := ARRAY[OLD.id_comentario];
    ELSE
        -- Un UPDATE puede mover el voto de un comentario a otro. Se recuentan
        -- los DOS, o el de origen se queda con el voto que ya no tiene.
        IF NEW.id_comentario = OLD.id_comentario THEN
            v_ids := ARRAY[NEW.id_comentario];
        ELSE
            v_ids := ARRAY[OLD.id_comentario, NEW.id_comentario];
        END IF;
    END IF;

    FOREACH v_id IN ARRAY v_ids LOOP
        UPDATE comentario c
        SET cantidad_likes =
                (SELECT count(*) FROM likes l
                  WHERE l.id_comentario = v_id AND l.valor = 1),
            cantidad_dislikes =
                (SELECT count(*) FROM likes l
                  WHERE l.id_comentario = v_id AND l.valor = -1)
        WHERE c.id_comentario = v_id;
    END LOOP;

    -- AFTER trigger: lo que devuelva no se usa.
    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION recontar_votos_comentario() IS
    'Recuenta cantidad_likes y cantidad_dislikes del comentario tocado. No suma: recuenta';

-- DROP y CREATE porque no existe CREATE TRIGGER IF NOT EXISTS, y el archivo
-- tiene que poder correrse dos veces: arrancar.ps1 lo reejecuta en cada
-- arranque.
DROP TRIGGER IF EXISTS trg_likes_recontar ON likes;

CREATE TRIGGER trg_likes_recontar
    AFTER INSERT OR UPDATE OR DELETE ON likes
    FOR EACH ROW
    EXECUTE FUNCTION recontar_votos_comentario();
