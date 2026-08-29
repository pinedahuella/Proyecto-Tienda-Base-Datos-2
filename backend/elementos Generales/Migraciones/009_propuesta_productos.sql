-- 009_propuesta_productos.sql
-- Un vendedor propone una entrada del catalogo y la tienda la aprueba o la
-- rechaza con un motivo.
--
-- Hasta ahora solo `tienda@mesh.com` (y un admin, que el backend trata igual)
-- podia crear productos. Se decidio asi para que dos vendedores no acabaran
-- subiendo la misma laptop dos veces y el catalogo compartido dejara de servir.
-- El precio de esa regla es que un vendedor que trae algo que no esta en el
-- catalogo no tiene por donde meterlo.
--
-- Lo que se abre es la PROPUESTA, no la edicion: el vendedor crea el producto y
-- nace `en_revision`, que no circula; la tienda lo aprueba (pasa a `activo`) o
-- lo rechaza diciendo por que. Editar el catalogo compartido sigue siendo de la
-- tienda. El permiso se parte en dos en vez de abrirse entero.
--
--
-- Esto NO devuelve el dueno al producto
-- ============================================================
-- Es la pregunta incomoda, porque el giro multi-vendedor quito
-- `productos.id_usuario` a proposito: un producto describe una cosa del mundo y
-- no es de nadie (ver docs/base-de-datos.md, "El catalogo es compartido").
-- `propuesta_producto` parece devolver ese vinculo, y no lo hace.
--
-- Lo que guarda es ATRIBUCION DEL CICLO DE REVISION, no propiedad, y se nota en
-- que no da ningun derecho: en cuanto el producto es `activo` la fila deja de
-- decidir nada -- cualquier vendedor puede ofertarlo, incluido o no el que lo
-- propuso, y el que lo propuso no puede editarlo ni bloquearlo. Solo sirve para
-- saber a quien avisarle del rechazo y a quien dejarle re-enviar la suya.
--
-- Es la misma figura que `pedido_producto`, que guarda a quien se le compro ese
-- dia sin que eso convierta al comprador en dueno de nada.
--
--
-- Por que la propuesta vive aqui y no en el documento de Mongo
-- ============================================================
-- El catalogo se mudo a MongoDB y el documento del producto NO tiene campo de
-- dueno -- no lo tiene desde el giro multi-vendedor, y quitarlo fue deliberado.
-- Meter ahi al proponente lo reintroduciria por la puerta de atras, y ademas
-- obligaria a reescribir el documento entero del producto cada vez que cambia
-- algo del ciclo de revision.
--
-- Colgandolo de una tabla relacional, el documento de Mongo se queda como
-- estaba: describe la cosa del mundo y nada mas. Quien la trajo es un hecho
-- administrativo, y los hechos administrativos con fecha y con responsable son
-- justo lo que el modelo relacional sabe guardar bien.


-- ============================================================
-- Los dos estados nuevos del catalogo
-- ============================================================
-- `en_revision` -- propuesto y esperando. No circula.
-- `rechazado`   -- revisado y devuelto, con su motivo en rechazo_producto.
--
-- Ojo con una diferencia respecto de la 010: el backend NO consulta esta tabla.
-- El estado de un producto se guarda como texto dentro del documento de
-- MongoDB, asi que proponer un producto funcionaria aunque estas dos filas no
-- existieran. Estan aqui porque `estado_producto` es el catalogo del modelo
-- relacional -- lo que da el vocabulario valido y lo que lee el ETL -- y dejarlo
-- corto significaria que la base declara tres estados mientras el sistema usa
-- cinco.
--
-- Ninguno de los dos se cuela al catalogo publico, y no hay que acordarse de
-- excluirlos: la busqueda y la ficha filtran por LISTA BLANCA (solo `activo`
-- pasa, ver ESTADO_PRODUCTO_VISIBLE en el backend), asi que un estado nuevo
-- queda oculto por defecto en vez de visible por defecto.
--
-- ON CONFLICT DO NOTHING para que la migracion se pueda volver a correr sobre
-- una base que ya los tenga; estado_producto_nombre es UNIQUE.
INSERT INTO estado_producto (estado_producto_nombre) VALUES
    ('en_revision'),
    ('rechazado')
ON CONFLICT (estado_producto_nombre) DO NOTHING;

COMMENT ON TABLE estado_producto IS
    'Catalogo de estados de un producto: borrador, activo, inactivo, en_revision, rechazado';


-- ============================================================
-- propuesta_producto
-- ============================================================
-- Quien propuso una entrada del catalogo, y como termino su revision.
CREATE TABLE IF NOT EXISTS propuesta_producto (
    id_propuesta_producto  bigserial PRIMARY KEY,

    -- RESTRICT como toda la cadena: el vendedor no se borra mientras quede
    -- rastro suyo en el catalogo.
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    -- El id del catalogo, con el sufijo _mongo y SIN llave foranea, igual que en
    -- `oferta` y en `pedido_producto`. El catalogo se lee desde MongoDB y
    -- PostgreSQL no puede garantizar integridad referencial contra otra base; el
    -- sufijo esta para que quien lea la tabla lo sepa y no busque una FK que no
    -- existe.
    id_producto_mongo  bigint NOT NULL,

    -- Nota opcional de quien aprueba ("ya existia como Laptop Aurora, la uni").
    -- El motivo del RECHAZO no va aqui: va en rechazo_producto, porque un
    -- rechazo puede pasar varias veces y una aprobacion solo una.
    comentario_aprobacion  text,

    fecha_propuesta   timestamptz NOT NULL DEFAULT now(),

    -- Las dos van juntas y las dos son NULL hasta que alguien aprueba. Se
    -- guardan las dos y no solo la fecha porque "quien aprobo" es la mitad util
    -- del dato: sin ella no se puede pedir cuentas de una aprobacion.
    fecha_aprobacion   timestamptz,
    id_usuario_aprobo  bigint REFERENCES usuarios(id_usuario)
                       ON DELETE RESTRICT,

    -- Un producto se propone UNA vez. Dos filas para el mismo producto serian
    -- dos proponentes para la misma cosa y nadie sabria a quien avisarle. El
    -- re-envio tras un rechazo reusa esta fila, no crea otra.
    UNIQUE (id_producto_mongo),

    -- Aprobar es un solo hecho: o estan las dos columnas o no esta ninguna. Aqui
    -- el CHECK SI se puede escribir -- no necesita subconsulta ni ningun id a
    -- mano -- y por eso va, a diferencia de la invariante de `oferta`, que no se
    -- puede expresar sin mirar el catalogo de estados (ver la 010).
    --
    -- Sin el, el dia que aparezca una segunda ruta que toque estas columnas
    -- queda una propuesta que dice estar aprobada y no dice por quien.
    CHECK ((fecha_aprobacion IS NULL) = (id_usuario_aprobo IS NULL))
);

COMMENT ON TABLE propuesta_producto IS
    'Quien propuso una entrada del catalogo y como termino su revision. Atribucion, no propiedad';
COMMENT ON COLUMN propuesta_producto.id_producto_mongo IS
    'Del catalogo en MongoDB. NO es llave foranea: PostgreSQL no puede garantizarla contra otra base';
COMMENT ON COLUMN propuesta_producto.comentario_aprobacion IS
    'Nota opcional de quien aprueba. El motivo del rechazo va en rechazo_producto';
COMMENT ON COLUMN propuesta_producto.fecha_aprobacion IS
    'Cuando se aprobo. NULL = todavia en revision, o rechazada';
COMMENT ON COLUMN propuesta_producto.id_usuario_aprobo IS
    'Quien la aprobo. El proponente sale de id_usuario, no de aqui';

-- Sobre esta tabla hay tres formas de entrar, y cada una necesita lo suyo:
--
--   por producto   -> lo cubre el UNIQUE (id_producto_mongo) de arriba
--   por vendedor   -> "mis propuestas", ordenadas de la mas nueva a la mas vieja
--   por la cola    -> "lo que falta revisar", que no entra por ninguna de las dos
--
-- "las propuestas de este vendedor, de la mas nueva a la mas vieja": la fecha va
-- en el indice y no solo el usuario, porque la consulta ordena por ella; sin esa
-- segunda columna la base entra al indice y despues ordena en memoria.
CREATE INDEX IF NOT EXISTS idx_propuesta_producto_usuario
    ON propuesta_producto(id_usuario, fecha_propuesta DESC);

-- "lo que falta por revisar, lo mas viejo primero": es la cola de la tienda, y
-- es la pantalla que se abre en CADA revision. Sin este indice recorre la tabla
-- entera y ordena en memoria.
--
-- Es un indice PARCIAL: solo indexa las filas sin aprobar, que son las unicas
-- que la cola mira. Lo aprobado se acumula para siempre y la cola no lo lee
-- nunca, asi que meterlo en el indice seria pagar por guardar lo que no se
-- consulta.
CREATE INDEX IF NOT EXISTS idx_propuesta_producto_cola
    ON propuesta_producto(fecha_propuesta)
    WHERE fecha_aprobacion IS NULL;


-- ============================================================
-- rechazo_producto
-- ============================================================
-- Cada vez que se rechaza una propuesta, con el motivo. Solo se inserta.
--
-- Es una tabla aparte y no dos columnas en propuesta_producto porque un rechazo
-- puede repetirse: el vendedor corrige, re-envia, y se le puede volver a
-- rechazar. Con columnas, el segundo rechazo pisaria al primero y se perderia la
-- historia justo cuando empieza a ser interesante.
--
-- Es la misma regla que ya siguen precio_historial y stock_movimiento: lo que
-- pasa varias veces va en filas, no en columnas.
CREATE TABLE IF NOT EXISTS rechazo_producto (
    id_rechazo_producto  bigserial PRIMARY KEY,

    id_propuesta_producto  bigint NOT NULL
        REFERENCES propuesta_producto(id_propuesta_producto)
        ON DELETE RESTRICT,

    -- Obligatorio y no vacio: quien rechaza tiene que explicar. Un rechazo sin
    -- motivo deja al vendedor adivinando, y el CHECK es lo que impide que una
    -- ruta nueva mande la cadena vacia y se salga con la suya.
    razon_rechazo  text NOT NULL CHECK (length(trim(razon_rechazo)) > 0),

    fecha_rechazo  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE rechazo_producto IS
    'Cada rechazo de una propuesta, con su motivo. Solo insercion: es un historial';
COMMENT ON COLUMN rechazo_producto.razon_rechazo IS
    'Por que se rechazo. Obligatorio y no vacio -- quien rechaza tiene que explicar';
COMMENT ON COLUMN rechazo_producto.fecha_rechazo IS
    'Cuando se rechazo esta vez. Puede haber varias filas por propuesta';

-- "los rechazos de esta propuesta, del mas nuevo al mas viejo": es como se le
-- ensena al vendedor por que se la devolvieron.
CREATE INDEX IF NOT EXISTS idx_rechazo_producto_propuesta
    ON rechazo_producto(id_propuesta_producto, fecha_rechazo DESC);
