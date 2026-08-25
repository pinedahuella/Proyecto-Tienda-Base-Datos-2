-- 005_ofertas.sql
-- La oferta: quien vende que, a como y cuantas le quedan.
--
-- Es la tabla que aparece al volverse multi-vendedor, y es la que sostiene
-- todo lo demas. El catalogo (003) dice QUE cosa es; la oferta dice QUIEN la
-- vende y en que condiciones.
--
--   Productos          la laptop, compartida
--   Productos Variantes  la laptop de 16 GB, compartida
--   Oferta             la laptop de 16 GB que vende Juan a Q5000, con 9
--                      unidades. Y otra fila para la de Maria a Q4800.
--
-- El orden importa: primero el catalogo de estado, luego oferta (que referencia
-- usuarios, del 001) y al final su historial de precio.
--
-- La oferta apunta al catalogo por los ids de MongoDB y sin llave foranea,
-- igual que pedido_producto: una sola forma de identificar una variante en todo
-- el sistema. Y NO se copia a MongoDB: precio, stock y estado cambian en cada
-- venta, y sostenerlos al dia en dos bases a la vez es el riesgo de
-- inconsistencia que el proyecto quiere evitar. La ficha del producto pide sus
-- ofertas aqui.


-- ============================================================
-- Por que precio y stock viven juntos
-- ============================================================
-- Antes eran dos tablas: el precio en una pivote de usuario-variante y el
-- stock en inventario. Tenian la MISMA llave logica (vendedor + variante) y
-- ningun enlace entre si, asi que se podia tener stock sin precio (invendible
-- y sin que nada avisara) o precio sin stock.
--
-- Juntas son una sola cosa: la oferta. Y ademas le da casa al estado, que
-- antes no tenia ninguna.


-- ============================================================
-- Por que hay dos libros y no uno
-- ============================================================
-- El stock es ADITIVO: el saldo es la suma de los movimientos, y por eso
-- stock_movimiento (006) es un kardex con cantidad y signo.
--
-- El precio NO es aditivo: un cambio de precio no suma ni resta, reemplaza.
-- Meterlo en el mismo libro dejaria cada fila de precio con el motivo, la
-- cantidad y el pedido en NULL, que es justo el antipatron de "columnas
-- mayormente nulas" que critica el enunciado del curso.
--
-- Por eso precio_historial va aparte, y es un SNAPSHOT y no un delta:
-- misma regla que el resto de los historiales del proyecto.


-- ============================================================
-- estado_oferta
-- ============================================================
-- No incluye "agotada": eso se deduce de stock = 0 y guardarlo seria un dato
-- derivado, el mismo motivo por el que pedido no lleva total.
--
-- retirada existe porque una oferta que ya vendio algo NO SE PUEDE BORRAR: la
-- linea del pedido llega hasta el vendedor pasando por aqui. Retirar es
-- cambiar el estado, nunca un DELETE.
CREATE TABLE estado_oferta (
    id_estado_oferta      smallserial PRIMARY KEY,
    estado_oferta_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_oferta IS 'Catalogo de estados de una oferta: activa, pausada, retirada';


-- ============================================================
-- oferta
-- ============================================================
CREATE TABLE oferta (
    id_oferta  bigserial PRIMARY KEY,

    -- Los dos id del catalogo, con el sufijo _mongo y SIN llave foranea, igual
    -- que en pedido_producto. El catalogo se lee desde MongoDB y PostgreSQL no
    -- puede garantizar integridad referencial contra otra base; el sufijo esta
    -- para que quien lea la tabla lo sepa de un vistazo y no busque una FK que
    -- no existe.
    --
    -- Se guardan los DOS, producto y variante, no solo el de la variante: en
    -- Mongo las variantes van embebidas dentro del producto y no hay indice
    -- unico sobre variantes.id_producto_variante, asi que dos productos
    -- distintos pueden tener una variante con el mismo id. El PAR si es
    -- inequivoco, y por eso el par entra en el UNIQUE y en el indice, no solo
    -- la variante.
    --
    -- El precio de tener una sola forma de identificar la variante en todo el
    -- sistema es que la base ya no puede rechazar una oferta sobre una variante
    -- que no existe. Eso pasa a ser trabajo de la aplicacion.
    id_producto_mongo           bigint NOT NULL,
    id_producto_variante_mongo  bigint NOT NULL,

    -- RESTRICT: el vendedor no se borra mientras exista una oferta suya. Es lo
    -- que sostiene que la linea del pedido pueda llegar al vendedor sin copiar
    -- su id.
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    precio  numeric(12,2) NOT NULL CHECK (precio >= 0),
    stock   integer       NOT NULL DEFAULT 0 CHECK (stock >= 0),

    id_estado_oferta  smallint NOT NULL REFERENCES estado_oferta(id_estado_oferta)
                      ON DELETE RESTRICT,

    fecha_creacion       timestamptz NOT NULL DEFAULT now(),
    fecha_actualizacion  timestamptz NOT NULL DEFAULT now(),

    -- LA restriccion del modelo. Un vendedor tiene UNA oferta por variante:
    -- dos filas serian dos precios para lo mismo y nadie sabria cual rige.
    --
    -- Van las TRES columnas y no solo vendedor + variante. El motivo es el
    -- mismo por el que se guarda el id del producto: en Mongo las variantes van
    -- embebidas y no hay indice unico sobre variantes.id_producto_variante, asi
    -- que dos productos distintos PUEDEN tener una variante con el mismo id.
    -- Con solo (usuario, variante) esos dos casos se pisarian: el vendedor no
    -- podria ofertar la variante 5 de la laptop y la variante 5 de la camisa a
    -- la vez, y la base rechazaria la segunda sin que nada este mal.
    UNIQUE (id_usuario, id_producto_mongo, id_producto_variante_mongo)
);

COMMENT ON TABLE oferta IS 'Quien vende que variante, a que precio y con cuantas unidades';
COMMENT ON COLUMN oferta.id_producto_mongo IS 'Del catalogo en MongoDB. NO es llave foranea: PostgreSQL no puede garantizarla contra otra base';
COMMENT ON COLUMN oferta.id_producto_variante_mongo IS 'Del catalogo en MongoDB. NO es llave foranea, igual que en pedido_producto';
COMMENT ON COLUMN oferta.precio IS 'numeric y no float: el dinero no admite el redondeo binario';
COMMENT ON COLUMN oferta.stock IS 'Saldo. Se DERIVA del kardex de stock_movimiento, no al reves';
COMMENT ON COLUMN oferta.fecha_creacion IS 'Cuando nacio la oferta';
COMMENT ON COLUMN oferta.fecha_actualizacion IS 'Ultimo cambio de precio, stock o estado. La mantiene un trigger';

-- "las ofertas de esta variante, de la mas barata a la mas cara": es la
-- consulta de la ficha del producto y la que elige que precio se ensena.
--
-- La ficha la pide AQUI y no a Mongo. Las ofertas no se copian a la base
-- documental: precio, stock y estado cambian en cada venta, y mantenerlos al
-- dia en dos bases a la vez es justo el riesgo de inconsistencia que el
-- proyecto quiere evitar. Lo unico que viaja a Mongo son cuatro numeros
-- agregados que la LISTA del catalogo necesita en cada tarjeta.
-- Lleva los dos ids del catalogo por lo mismo que el UNIQUE: el id de la
-- variante no identifica nada por si solo, hace falta el par. Y sirve tambien
-- para "todas las ofertas de este producto", porque el id del producto va
-- primero y un indice compuesto se puede usar por su prefijo.
CREATE INDEX idx_oferta_catalogo_precio
    ON oferta(id_producto_mongo, id_producto_variante_mongo, precio);

-- "las ofertas de este vendedor": su panel
CREATE INDEX idx_oferta_usuario ON oferta(id_usuario);

CREATE INDEX idx_oferta_estado ON oferta(id_estado_oferta);


-- ============================================================
-- precio_historial
-- ============================================================
-- Un snapshot por cada precio que ha tenido la oferta. Con esto se contesta
-- "a como estaba esta oferta el 3 de marzo" leyendo una fila.
--
-- La linea del pedido apunta AQUI y no copia el numero: una fila de este
-- historial no se actualiza nunca, asi que el precio queda congelado igual,
-- y copiarlo seria guardar un dato deducible.
CREATE TABLE precio_historial (
    id_precio_historial  bigserial PRIMARY KEY,

    id_oferta  bigint NOT NULL REFERENCES oferta(id_oferta)
               ON DELETE RESTRICT,

    precio  numeric(12,2) NOT NULL CHECK (precio >= 0),

    -- Quien lo cambio, que NO es necesariamente el dueno de la oferta: un
    -- admin puede corregir un precio. El dueno se saca de oferta.id_usuario.
    -- Se llama distinto justamente para que nadie lea el vendedor de aqui.
    id_usuario_modifico  bigint NOT NULL REFERENCES usuarios(id_usuario)
                         ON DELETE RESTRICT,

    fecha_creacion  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE precio_historial IS 'Cada precio por el que ha pasado una oferta. Snapshot, no delta';
COMMENT ON COLUMN precio_historial.fecha_creacion IS 'Desde cuando rige este precio';
COMMENT ON COLUMN precio_historial.id_usuario_modifico IS 'Quien lo cambio. El vendedor sale de oferta.id_usuario, no de aqui';

-- "a como estaba esta oferta el 3 de marzo": entra al indice y lee una fila
CREATE INDEX idx_precio_historial_oferta
    ON precio_historial(id_oferta, fecha_creacion DESC);


-- ============================================================
-- El precio de nacimiento se escribe solo
-- ============================================================
-- Si la primera fila del historial dependiera de que alguien se acuerde de
-- insertarla, preguntar por una fecha anterior al primer CAMBIO devolveria
-- vacio, y "no existia" se leeria igual que "nunca cambio". Es el mismo
-- motivo por el que el inventario nace con un movimiento de reposicion.
--
-- Un aviso no es un mecanismo: lo escribe la base, no la costumbre.
--
-- Quien lo cambio sale de mesh.id_usuario si la aplicacion lo puso en la
-- transaccion (SET LOCAL mesh.id_usuario = '5'); si no, se atribuye al dueno
-- de la oferta, que es el caso normal.
CREATE OR REPLACE FUNCTION oferta_registrar_precio()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_actor bigint;
BEGIN
    v_actor := COALESCE(
        NULLIF(current_setting('mesh.id_usuario', true), '')::bigint,
        NEW.id_usuario
    );

    IF TG_OP = 'INSERT' THEN
        INSERT INTO precio_historial (id_oferta, precio, id_usuario_modifico, fecha_creacion)
        VALUES (NEW.id_oferta, NEW.precio, v_actor, NEW.fecha_creacion);

    ELSIF NEW.precio IS DISTINCT FROM OLD.precio THEN
        INSERT INTO precio_historial (id_oferta, precio, id_usuario_modifico)
        VALUES (NEW.id_oferta, NEW.precio, v_actor);
    END IF;

    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_oferta_registrar_precio
    AFTER INSERT OR UPDATE OF precio ON oferta
    FOR EACH ROW EXECUTE FUNCTION oferta_registrar_precio();

COMMENT ON FUNCTION oferta_registrar_precio() IS
    'Escribe el precio de nacimiento y cada cambio en precio_historial. La base, no la costumbre';


-- ============================================================
-- fecha_actualizacion
-- ============================================================
-- La mantiene un trigger y no la aplicacion: si dependiera de que cada UPDATE
-- se acuerde de ponerla, el dia que una ruta nueva no lo haga la fecha miente
-- sin dar ningun error.
CREATE OR REPLACE FUNCTION oferta_tocar_fecha()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    NEW.fecha_actualizacion := now();
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_oferta_tocar_fecha
    BEFORE UPDATE ON oferta
    FOR EACH ROW EXECUTE FUNCTION oferta_tocar_fecha();

COMMENT ON FUNCTION oferta_tocar_fecha() IS
    'Pone fecha_actualizacion en cada cambio de la oferta';


-- ============================================================
-- Valores del catalogo
-- ============================================================
-- No son datos de prueba: sin ellos no se puede crear una oferta.

INSERT INTO estado_oferta (estado_oferta_nombre) VALUES
    ('activa'),
    ('pausada'),
    ('retirada');
