-- 003_productos.sql
-- El catalogo: categorias, productos, variantes, imagenes y los dos
-- historiales del alcance de productos.
--
-- Solo esquema. Los datos viven en migrations/datos/, que corre despues. Los
-- valores de estado_producto y estado_variantes si se quedan aqui, porque sin
-- ellos no se puede insertar un producto.
--
-- El orden importa: primero los catalogos y categorias, que no dependen de
-- nada; luego productos, luego las variantes, y al final los historiales, que
-- referencian a la fila viva.


-- ============================================================
-- Lo que cambio al volverse multi-vendedor
-- ============================================================
-- Antes un producto era de un vendedor y llevaba su precio en la variante.
-- Ahora el catalogo es COMPARTIDO: el producto describe una cosa del mundo
-- (una laptop, una camisa) y cualquier vendedor puede ofertarla.
--
--   productos.id_usuario            se fue. El producto no es de nadie.
--   productos_variantes.precio      se fue. Cada vendedor pone el suyo.
--   categorias.porcentaje_comision  se fue. El profesor la dejo fuera del
--                                   alcance, asi que no hay comision que
--                                   cobrar.
--   categorias_historial            se fue con ella: era la tabla que existia
--                                   solo para congelar la comision del dia de
--                                   la venta.
--
-- El precio y el stock viven ahora en oferta (005_ofertas.sql), que es de un
-- vendedor y una variante. Ver docs/base-de-datos.md.
--
-- Lo que si se gano: productos_historial ahora guarda id_categoria. Antes, un
-- producto que cambiaba de categoria reescribia su historial hacia atras,
-- porque el historial no sabia en que categoria estaba ese dia.


-- ============================================================
-- estado_producto
-- ============================================================
-- El estado de la ENTRADA DEL CATALOGO, que es de la tienda y no de ningun
-- vendedor. Que un vendedor se retire no baja el producto: para eso esta el
-- estado de la oferta, que es otro.
CREATE TABLE estado_producto (
    id_estado_producto      smallserial PRIMARY KEY,
    estado_producto_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_producto IS 'Catalogo de estados de una entrada del catalogo';


-- ============================================================
-- estado_variantes
-- ============================================================
-- La llave se llama id_estado_variante en singular y la FK que la apunta
-- desde productos_variantes se llama id_estado_variantes en plural. Asi esta
-- en el diagrama; se respeta para que el codigo y el diagrama digan lo mismo.
CREATE TABLE estado_variantes (
    id_estado_variante      smallserial PRIMARY KEY,
    estado_variante_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_variantes IS 'Catalogo de estados de una variante';


-- ============================================================
-- categorias
-- ============================================================
-- El arbol tiene EXACTAMENTE DOS NIVELES y no mas:
--
--   Electronica            raiz. No tiene caracteristicas ni productos.
--     Laptops              hoja. Aqui cuelgan las caracteristicas y los
--     Audifonos            productos.
--
-- Una hoja no puede tener hijas. La raiz es solo un rotulo para agrupar; no
-- se publica en ella. Eso ya lo daba por hecho el backend, que solo ofrece
-- las categorias con padre y contesta 404 para una raiz; aqui queda
-- garantizado por la base y no por la costumbre.
--
-- La regla la aplica un trigger y no una columna nivel, porque el ER no tiene
-- esa columna y el ER manda.
CREATE TABLE categorias (
    id_categoria    bigserial PRIMARY KEY,
    nombre          varchar(100) NOT NULL,
    fecha_creacion  timestamptz  NOT NULL DEFAULT now(),

    -- RESTRICT: no se borra una categoria que todavia tiene hijas colgando
    id_categoria_padre  bigint REFERENCES categorias(id_categoria)
                        ON DELETE RESTRICT
);

COMMENT ON TABLE categorias IS 'Arbol de categorias de dos niveles. La version vigente';
COMMENT ON COLUMN categorias.id_categoria_padre IS 'NULL solo en las raices. Una hoja siempre apunta a una raiz';

-- "las hijas de esta categoria" es como se recorre el arbol
CREATE INDEX idx_categorias_padre ON categorias(id_categoria_padre);

-- Dos hermanas no se pueden llamar igual. Sin esto, dos "Audio" bajo
-- Electronica dejarian al formulario sin saber cual ofrece que. Van como dos
-- indices parciales y no como un UNIQUE normal porque en SQL dos NULL no son
-- iguales: un UNIQUE (id_categoria_padre, nombre) dejaria pasar dos raices
-- con el mismo nombre.
CREATE UNIQUE INDEX idx_categorias_nombre_hermanas
    ON categorias(id_categoria_padre, nombre)
    WHERE id_categoria_padre IS NOT NULL;

CREATE UNIQUE INDEX idx_categorias_nombre_raiz
    ON categorias(nombre)
    WHERE id_categoria_padre IS NULL;


-- El trigger de los dos niveles. Un CHECK no sirve: no puede mirar otra fila.
CREATE OR REPLACE FUNCTION categorias_solo_dos_niveles()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    -- No se puede colgar de una categoria que ya tiene padre
    IF NEW.id_categoria_padre IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM categorias
           WHERE id_categoria = NEW.id_categoria_padre
             AND id_categoria_padre IS NOT NULL
       )
    THEN
        RAISE EXCEPTION
            'El arbol de categorias solo admite dos niveles: la categoria % ya es una hoja y no puede tener hijas',
            NEW.id_categoria_padre
            USING ERRCODE = 'check_violation';
    END IF;

    -- Y al reves: una raiz que ya tiene hijas no se puede volver hoja, porque
    -- sus hijas quedarian en un tercer nivel sin que nadie lo note.
    IF TG_OP = 'UPDATE'
       AND NEW.id_categoria_padre IS NOT NULL
       AND OLD.id_categoria_padre IS NULL
       AND EXISTS (SELECT 1 FROM categorias WHERE id_categoria_padre = NEW.id_categoria)
    THEN
        RAISE EXCEPTION
            'La categoria % tiene hijas: no se puede colgar de otra sin dejarlas en un tercer nivel',
            NEW.id_categoria
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_categorias_solo_dos_niveles
    BEFORE INSERT OR UPDATE ON categorias
    FOR EACH ROW EXECUTE FUNCTION categorias_solo_dos_niveles();

COMMENT ON FUNCTION categorias_solo_dos_niveles() IS
    'Impide un tercer nivel en el arbol de categorias, en los dos sentidos';


-- ============================================================
-- productos
-- ============================================================
-- Una entrada del catalogo. Describe una cosa, no una venta: no tiene dueno,
-- no tiene precio y no tiene stock. Quien la vende y a como, eso es oferta.
--
-- Cuelga de una categoria HOJA. Colgarlo de una raiz lo dejaria fuera de todo
-- formulario, porque las caracteristicas viven en las hojas.
CREATE TABLE productos (
    id_producto     bigserial PRIMARY KEY,
    nombre          varchar(200) NOT NULL,
    descripcion     text,
    fecha_creacion  timestamptz  NOT NULL DEFAULT now(),

    id_estado_producto  smallint NOT NULL REFERENCES estado_producto(id_estado_producto)
                        ON DELETE RESTRICT,
    id_categoria        bigint   NOT NULL REFERENCES categorias(id_categoria)
                        ON DELETE RESTRICT
);

COMMENT ON TABLE productos IS 'Entradas del catalogo. Compartidas: un producto no es de ningun vendedor';
COMMENT ON COLUMN productos.descripcion IS 'Prosa del producto. Las caracteristicas con nombre y valor van en producto_caracteristica';

CREATE INDEX idx_productos_categoria ON productos(id_categoria);
CREATE INDEX idx_productos_estado    ON productos(id_estado_producto);


-- El producto va en una hoja. Mismo motivo que el trigger de arriba: un CHECK
-- no puede mirar la fila de categorias.
CREATE OR REPLACE FUNCTION productos_solo_en_hoja()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM categorias
        WHERE id_categoria = NEW.id_categoria
          AND id_categoria_padre IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'La categoria % es una raiz: los productos van en las hojas, que son las que ofrecen caracteristicas',
            NEW.id_categoria
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_productos_solo_en_hoja
    BEFORE INSERT OR UPDATE OF id_categoria ON productos
    FOR EACH ROW EXECUTE FUNCTION productos_solo_en_hoja();

COMMENT ON FUNCTION productos_solo_en_hoja() IS
    'Impide publicar un producto en una categoria raiz';


-- ============================================================
-- productos_variantes
-- ============================================================
-- Lo que realmente se compra: una talla, una capacidad, un color. Es del
-- catalogo y no del vendedor: los cuatro vendedores de la misma laptop
-- ofertan LA MISMA variante, cada uno con su precio y su stock.
--
-- Aqui ya no hay precio. Vive en oferta.
CREATE TABLE productos_variantes (
    id_producto_variante  bigserial PRIMARY KEY,

    id_producto      bigint       NOT NULL REFERENCES productos(id_producto)
                     ON DELETE RESTRICT,
    nombre_variante  varchar(100) NOT NULL,
    fecha_creacion   timestamptz  NOT NULL DEFAULT now(),

    -- El nombre en plural es el del diagrama; apunta a la llave singular
    id_estado_variantes  smallint NOT NULL REFERENCES estado_variantes(id_estado_variante)
                         ON DELETE RESTRICT,

    descripcion  text,

    -- Un producto no puede tener dos veces la misma presentacion
    UNIQUE (id_producto, nombre_variante)
);

COMMENT ON TABLE productos_variantes IS 'Las presentaciones de un producto. Compartidas entre todos sus vendedores';

CREATE INDEX idx_productos_variantes_producto ON productos_variantes(id_producto);
CREATE INDEX idx_productos_variantes_estado   ON productos_variantes(id_estado_variantes);


-- ============================================================
-- imagen_producto
-- ============================================================
-- Solo guarda la URL. La misma foto sirve para varias variantes, por eso es
-- una tabla aparte y no una columna, y por eso la URL es unica: la foto se
-- guarda una vez y se apunta desde donde haga falta.
CREATE TABLE imagen_producto (
    id_imagen_producto   bigserial PRIMARY KEY,
    imagen_producto_url  varchar(500) NOT NULL UNIQUE
);

COMMENT ON TABLE imagen_producto IS 'Las imagenes del catalogo, una fila por URL';


-- ============================================================
-- imagen_producto_producto
-- ============================================================
-- La tabla que une imagen_producto con productos_variantes. Se llama asi por
-- su llave, id_imagen_producto_producto, tal como esta en el diagrama.
--
-- Las fotos son del catalogo, no del vendedor: los cuatro que venden la misma
-- laptop ensenan las mismas fotos. Es lo que hace util un catalogo compartido.
CREATE TABLE imagen_producto_producto (
    id_imagen_producto_producto  bigserial PRIMARY KEY,

    id_imagen_producto    bigint NOT NULL REFERENCES imagen_producto(id_imagen_producto)
                          ON DELETE RESTRICT,
    id_producto_variante  bigint NOT NULL REFERENCES productos_variantes(id_producto_variante)
                          ON DELETE RESTRICT,

    numero_orden  smallint NOT NULL,

    -- Dos imagenes no pueden pelearse la misma posicion en la misma variante:
    -- sin esto el orden de la galeria dependeria del azar
    UNIQUE (id_producto_variante, numero_orden)
);

COMMENT ON TABLE imagen_producto_producto IS 'Que imagenes muestra cada variante y en que orden';
COMMENT ON COLUMN imagen_producto_producto.numero_orden IS 'La 1 es la portada de la variante';

CREATE INDEX idx_imagen_producto_producto_imagen
    ON imagen_producto_producto(id_imagen_producto);


-- ============================================================
-- productos_historial
-- ============================================================
-- Solo se inserta, nunca se actualiza ni se borra: cada fila es la version
-- del producto que regia desde su fecha_creacion.
--
-- Guarda el estado completo, no el cambio. En SQL es lo natural: saber que
-- decia el producto un dia cualquiera es leer una fila, no sumar filas. El
-- ETL es el que traduce esto al registro de eventos que vive en Mongo.
--
-- No lleva estado: el estado vive en la fila viva, que si cambia.
--
-- SI lleva id_categoria, y es nuevo. Sin el, mover un producto de categoria
-- reescribia su pasado: el historial de enero contestaba con la categoria de
-- hoy. Apunta a la fila viva de categorias, asi que si alguien RENOMBRA una
-- categoria, la reconstruccion muestra el nombre nuevo. Se acepta a
-- proposito: una categoria se renombra cada nunca, y el historial de
-- categorias existia solo por la comision, que ya no esta.
CREATE TABLE productos_historial (
    id_producto_historial  bigserial PRIMARY KEY,

    id_producto     bigint       NOT NULL REFERENCES productos(id_producto)
                    ON DELETE RESTRICT,
    nombre          varchar(200) NOT NULL,
    descripcion     text,
    id_categoria    bigint       NOT NULL REFERENCES categorias(id_categoria)
                    ON DELETE RESTRICT,
    fecha_creacion  timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE productos_historial IS 'Cada version por la que ha pasado una entrada del catalogo';
COMMENT ON COLUMN productos_historial.fecha_creacion IS 'Desde cuando rige esta version, no cuando se toco por ultima vez';
COMMENT ON COLUMN productos_historial.id_categoria IS 'En que categoria estaba ese dia. Sin esto, mover un producto reescribe su pasado';

-- "que decia este producto el 3 de marzo": con este indice la base entra
-- directo y lee una fila, sin recorrer el historial completo
CREATE INDEX idx_productos_historial_producto
    ON productos_historial(id_producto, fecha_creacion DESC);


-- ============================================================
-- productos_variantes_historial
-- ============================================================
-- Corre por separado del historial del producto: renombrar el producto no
-- escribe nada aqui.
--
-- Ya no lleva precio. El precio dejo de ser del catalogo al volverse
-- multi-vendedor: cada oferta tiene el suyo y su historia vive en
-- precio_historial. Lo que queda aqui es como se llamaba y que decia la
-- presentacion ese dia.
CREATE TABLE productos_variantes_historial (
    id_producto_variante_historial  bigserial PRIMARY KEY,

    id_producto_variante  bigint       NOT NULL REFERENCES productos_variantes(id_producto_variante)
                          ON DELETE RESTRICT,
    nombre_variante       varchar(100) NOT NULL,
    descripcion           text,
    fecha_creacion        timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE productos_variantes_historial IS 'Cada version por la que ha pasado una variante. El precio NO esta aqui: es de la oferta';

CREATE INDEX idx_productos_variantes_historial_variante
    ON productos_variantes_historial(id_producto_variante, fecha_creacion DESC);


-- ============================================================
-- Valores de los catalogos
-- ============================================================
-- No son datos de prueba: sin ellos no se puede crear un producto.

INSERT INTO estado_producto (estado_producto_nombre) VALUES
    ('borrador'),
    ('activo'),
    ('inactivo');

INSERT INTO estado_variantes (estado_variante_nombre) VALUES
    ('activa'),
    ('inactiva');


-- ============================================================
-- Los datos
-- ============================================================
-- No estan en este archivo. Estan en migrations/datos/, un archivo por
-- conjunto, y se corren despues de todas las migraciones. Ver
-- migrations/README.md.
