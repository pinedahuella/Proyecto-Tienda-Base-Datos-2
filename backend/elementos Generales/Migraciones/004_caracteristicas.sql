-- 004_caracteristicas.sql
-- Las caracteristicas de producto y de variante: su definicion, cuales
-- ofrece cada categoria, y que valor les pone cada producto.
--
-- Son las siete tablas que se agregaron al ER. Resuelven el problema del que
-- trata la Entrega 1: sin ellas toda caracteristica variable cae dentro de
-- productos.descripcion, que es texto libre y no se puede filtrar.
--
-- Las caracteristicas son del CATALOGO, no del vendedor: los cuatro que
-- venden la misma laptop describen la misma laptop. Por eso cuelgan de
-- productos y de productos_variantes, y no de oferta.
--
-- Solo esquema. Los valores de tipo_dato se quedan aqui, como los estados
-- del 003, porque sin ellos no se puede definir ni una caracteristica. Las
-- definiciones concretas (Marca, RAM, Talla) y los valores de los productos
-- son datos y viven en migrations/datos/.
--
-- El orden importa: primero tipo_dato, que no depende de nada; luego las dos
-- tablas de definicion; al final los cuatro cruces, que dependen de
-- categorias, productos y productos_variantes, todas del 003.


-- ============================================================
-- La idea
-- ============================================================
-- Una caracteristica se define una vez (nombre, de que tipo es, en que
-- unidad se mide) y se usa muchas. La categoria dice cuales ofrece y el
-- producto dice cuales usa y con que valor.
--
-- Quien ofrece caracteristicas es siempre una categoria HOJA. Las raices son
-- rotulos para agrupar y no llevan ninguna: por eso tampoco llevan productos.
-- Lo garantiza el trigger del 003. La categoria no sabe que
-- caracteristicas tiene un producto concreto, porque de las que ofrece no
-- se llenan todas.
--
-- La unidad va en la definicion y no en cada valor. Que la RAM se mide en GB
-- se dice una sola vez, no una por producto. Asi el valor queda limpio (16 y
-- no "16 GB") y se puede comparar y ordenar como numero. Guardar "16 GB"
-- dentro del valor obliga a partir la cadena para filtrar por rango, que es
-- justo lo que estas tablas existen para evitar.


-- ============================================================
-- tipo_dato
-- ============================================================
-- De que tipo es el valor. El valor siempre se guarda como texto, y esta
-- tabla es la que dice como hay que leerlo: 16 es entero, 1.85 es decimal,
-- true es booleano.
CREATE TABLE tipo_dato (
    id_tipo_dato  smallserial PRIMARY KEY,
    tipo_dato     varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE tipo_dato IS 'Catalogo de tipos de valor de una caracteristica';


-- ============================================================
-- caracteristica
-- ============================================================
-- La definicion de una caracteristica del producto entero: la que no cambia
-- entre sus variantes. La marca de una laptop es la misma en todas sus
-- configuraciones; su RAM no.
--
-- Lleva bigserial y no smallserial como los catalogos de estado porque no es
-- una lista cerrada: se agregan definiciones nuevas cada vez que aparece una
-- categoria que necesita un atributo que nadie habia usado.
CREATE TABLE caracteristica (
    id_caracteristica  bigserial    PRIMARY KEY,
    nombre             varchar(100) NOT NULL UNIQUE,

    -- RESTRICT: no se borra un tipo que alguna definicion todavia usa
    id_tipo_dato  smallint NOT NULL REFERENCES tipo_dato(id_tipo_dato)
                  ON DELETE RESTRICT,

    -- NULL cuando la caracteristica no se mide en nada: Marca, Color, Pais
    -- de origen. No es un dato que falte, es que no aplica.
    unidad  varchar(20)
);

COMMENT ON TABLE caracteristica IS 'Definicion de una caracteristica del producto entero';
COMMENT ON COLUMN caracteristica.unidad IS 'En que se mide, dicho una sola vez. NULL si no se mide en nada';


-- ============================================================
-- caracteristica_variante
-- ============================================================
-- Lo mismo para lo que distingue una variante de otra: talla, color,
-- capacidad, RAM. Es una tabla aparte y no una columna que diga de que clase
-- es, porque las dos se cruzan con tablas distintas: una con productos y
-- otra con productos_variantes.
--
-- La llave se llama id_caracteristica, sin el sufijo, y las FK que la
-- apuntan si se llaman id_caracteristica_variante. Asi esta en el ER, y es
-- el mismo caso de estado_variantes en el 003: se respeta para que el codigo
-- y el diagrama digan lo mismo.
CREATE TABLE caracteristica_variante (
    id_caracteristica  bigserial    PRIMARY KEY,
    nombre             varchar(100) NOT NULL UNIQUE,

    id_tipo_dato  smallint NOT NULL REFERENCES tipo_dato(id_tipo_dato)
                  ON DELETE RESTRICT,

    unidad  varchar(20)
);

COMMENT ON TABLE caracteristica_variante IS 'Definicion de una caracteristica que distingue una variante de otra';
COMMENT ON COLUMN caracteristica_variante.id_caracteristica IS 'Sin sufijo, como en el ER. Las FK que la apuntan si lo llevan';


-- ============================================================
-- categoria_caracteristica
-- ============================================================
-- Que caracteristicas ofrece cada categoria. Es lo que arma el formulario de
-- crear un producto de esa categoria.
--
-- No dice que tiene el producto. Una laptop ofrece veinte atributos y un
-- vendedor llena seis; los catorce que no llena no se guardan vacios, no
-- existen en ninguna parte.
CREATE TABLE categoria_caracteristica (
    id_categoria_caracteristica  bigserial PRIMARY KEY,

    id_categoria       bigint NOT NULL REFERENCES categorias(id_categoria)
                       ON DELETE RESTRICT,
    id_caracteristica  bigint NOT NULL REFERENCES caracteristica(id_caracteristica)
                       ON DELETE RESTRICT,

    -- Una categoria no puede ofrecer dos veces lo mismo: el formulario
    -- sacaria el campo repetido
    UNIQUE (id_categoria, id_caracteristica)
);

COMMENT ON TABLE categoria_caracteristica IS 'Que caracteristicas de producto ofrece cada categoria';

-- "que ofrece esta categoria" es como se arma el formulario
CREATE INDEX idx_categoria_caracteristica_categoria
    ON categoria_caracteristica(id_categoria);


-- ============================================================
-- categoria_caracteristica_variante
-- ============================================================
-- Lo mismo para las caracteristicas de variante.
--
-- En el ER esta llave aparece como id_categoria_caracteristica, con el mismo
-- nombre que la de la tabla de arriba: se copio el cuadro y no se renombro
-- la fila. Es la misma clase de errata de rotulo que el &nbsp; que quedo
-- pegado al campo de abajo. Aqui se llama
-- id_categoria_caracteristica_variante, porque una llave primaria con el
-- nombre de la de otra tabla se lee como si fuera una FK hacia ella.
CREATE TABLE categoria_caracteristica_variante (
    id_categoria_caracteristica_variante  bigserial PRIMARY KEY,

    id_categoria  bigint NOT NULL REFERENCES categorias(id_categoria)
                  ON DELETE RESTRICT,

    id_caracteristica_variante  bigint NOT NULL
                                REFERENCES caracteristica_variante(id_caracteristica)
                                ON DELETE RESTRICT,

    UNIQUE (id_categoria, id_caracteristica_variante)
);

COMMENT ON TABLE categoria_caracteristica_variante IS 'Que caracteristicas de variante ofrece cada categoria';

CREATE INDEX idx_categoria_caracteristica_variante_categoria
    ON categoria_caracteristica_variante(id_categoria);


-- ============================================================
-- producto_caracteristica
-- ============================================================
-- El valor: que dice este producto de esta caracteristica.
--
-- valor es texto y no una columna por tipo. Una sola tabla guarda "Lenovo",
-- "16" y "true", y tipo_dato dice como leer cada uno. La alternativa es una
-- columna por tipo con tres de cada cuatro en NULL, o una tabla por tipo, y
-- las dos obligan a saber a donde ir antes de poder preguntar.
--
-- No lleva UNIQUE sobre (producto, caracteristica) a proposito. Hay
-- caracteristicas que son una lista, y una lista son varias filas con el
-- mismo nombre: "Materiales principales: aluminio, plastico" son dos filas.
-- El tipo_dato lista es el que avisa que repetirse ahi es legitimo y no un
-- error de carga.
CREATE TABLE producto_caracteristica (
    id_producto_caracteristica  bigserial PRIMARY KEY,

    id_producto        bigint NOT NULL REFERENCES productos(id_producto)
                       ON DELETE RESTRICT,
    id_caracteristica  bigint NOT NULL REFERENCES caracteristica(id_caracteristica)
                       ON DELETE RESTRICT,

    valor  text NOT NULL
);

COMMENT ON TABLE producto_caracteristica IS 'El valor que le da un producto a una caracteristica';
COMMENT ON COLUMN producto_caracteristica.valor IS 'Siempre texto y sin la unidad: la unidad esta en la definicion';

-- "todo lo de este producto": arma la ficha y es por donde lee el ETL
CREATE INDEX idx_producto_caracteristica_producto
    ON producto_caracteristica(id_producto);

-- "todos los productos con RAM = 16": el filtro por atributo, que es lo que
-- no se podia hacer mientras esto vivia dentro de descripcion
CREATE INDEX idx_producto_caracteristica_busqueda
    ON producto_caracteristica(id_caracteristica, valor);


-- ============================================================
-- producto_variante_caracteristica_variante
-- ============================================================
-- Lo mismo entre una variante y una caracteristica de variante. El nombre
-- largo es el de su llave en el ER, como imagen_producto_producto en el 003.
CREATE TABLE producto_variante_caracteristica_variante (
    id_producto_variante_caracteristica_variante  bigserial PRIMARY KEY,

    id_producto_variante  bigint NOT NULL
                          REFERENCES productos_variantes(id_producto_variante)
                          ON DELETE RESTRICT,

    id_caracteristica_variante  bigint NOT NULL
                                REFERENCES caracteristica_variante(id_caracteristica)
                                ON DELETE RESTRICT,

    valor  text NOT NULL
);

COMMENT ON TABLE producto_variante_caracteristica_variante IS 'El valor que le da una variante a una caracteristica de variante';

CREATE INDEX idx_pvcv_variante
    ON producto_variante_caracteristica_variante(id_producto_variante);

CREATE INDEX idx_pvcv_busqueda
    ON producto_variante_caracteristica_variante(id_caracteristica_variante, valor);


-- ============================================================
-- Valores de tipo_dato
-- ============================================================
-- No son datos de prueba: sin ellos no se puede definir una caracteristica.
--
-- lista no es un tipo distinto de texto, es una cardinalidad: dice que esa
-- caracteristica se guarda en varias filas y que el ETL la lleva a Mongo
-- como varias entradas. Va aqui y no en una columna nueva de caracteristica
-- porque el ER no tiene esa columna.

INSERT INTO tipo_dato (tipo_dato) VALUES
    ('texto'),
    ('entero'),
    ('decimal'),
    ('booleano'),
    ('lista');


-- ============================================================
-- Las definiciones y los valores
-- ============================================================
-- No estan en este archivo. Marca, RAM, Talla y los valores de los productos
-- son datos y viven en migrations/datos/. Ver migrations/README.md.
