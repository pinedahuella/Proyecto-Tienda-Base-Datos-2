-- ============================================================
-- 040_vectores_en_postgres.sql
-- ============================================================
-- Todos los vectores vuelven a PostgreSQL (pgvector), de Jose David
-- (25f0fe0, 2026-10-16). Es su vectores-pgvector.sql hecho migracion; el
-- plan esta en backend/elementos Generales/plan pendiente/vectores-pgvector.md.
--
-- El profesor pidio que las consultas por vectores se hagan con pgvector.
-- Revierte el traslado a Elasticsearch del 2026-10-02 (036): Elasticsearch se
-- queda con la busqueda por palabras de mesh_productos y el log de
-- autenticacion, y deja de guardar vectores y comentarios.
--
--   vector_producto    el vector de cada producto del catalogo (antes, los
--                      campos vector* de mesh_productos)
--   vector_comentario  el vector de cada comentario y la valoracion de su
--                      texto (antes, el indice mesh_comentarios entero)
--
-- Tablas aparte, 1 a 1 con FK y ON DELETE CASCADE, y no columnas: los
-- triggers de comentario encolan cada cambio del texto, y si el worker
-- escribiera en la misma fila se encolaria solo. El nombre NO es
-- producto_vector porque la 036 hace DROP TABLE IF EXISTS producto_vector en
-- cada arranque.
--
-- La llenan los workers del backend (VectoresSyncService y
-- EventoComentarioSyncService). En una base nueva los productos los carga
-- etl/cargar_vectores.ps1 (paso 7d de arrancar); en una que ya tenia los
-- vectores en Elasticsearch, arrancar los copia una vez sin Ollama (paso 7d).
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- La 024 ya la crea; se repite para que esta propuesta no dependa del orden.
CREATE EXTENSION IF NOT EXISTS vector;

-- ------------------------------------------------------------
-- vector_producto
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vector_producto (
    id_producto_mongo  bigint PRIMARY KEY
                       REFERENCES producto_catalogo(id_producto_mongo)
                       ON DELETE CASCADE,
    vector             vector(768)  NOT NULL,
    texto_hash         char(32)     NOT NULL,
    grupo              char(32)     NOT NULL,
    activo             boolean      NOT NULL,
    modelo             varchar(80)  NOT NULL,
    fecha_calculo      timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE vector_producto IS
    'El vector de contenido de cada producto (nombre, categoria y descripcion), para la recomendacion semantica y las busquedas por significado. Lo mantiene VectoresSyncService a partir de la bandera pendiente_vector de Mongo';
COMMENT ON COLUMN vector_producto.id_producto_mongo IS
    'El _id del producto en MongoDB. La FK a producto_catalogo asegura que el producto existe; si se borra de ahi, se va su vector';
COMMENT ON COLUMN vector_producto.vector IS
    'El vector de Ollama (paraphrase-multilingual, 768 dimensiones) del texto "nombre. Categoria X. descripcion"';
COMMENT ON COLUMN vector_producto.texto_hash IS
    'md5 del texto con que se calculo el vector. Si el texto cambia, el worker lo recalcula; si no, no llama a Ollama';
COMMENT ON COLUMN vector_producto.grupo IS
    'md5 de categoria y descripcion, sin el nombre. Las copias del mismo producto comparten grupo y no se recomiendan entre si';
COMMENT ON COLUMN vector_producto.activo IS
    'Copia de estado = activo en Mongo. Las busquedas solo devuelven los activos';
COMMENT ON COLUMN vector_producto.modelo IS
    'El modelo de Ollama con que se calculo el vector';

-- Distancia coseno, la que usa el modelo. HNSW no necesita entrenarse con los
-- datos ya cargados (a diferencia de IVFFlat), asi que se puede crear vacio.
CREATE INDEX IF NOT EXISTS idx_vector_producto_hnsw
    ON vector_producto USING hnsw (vector vector_cosine_ops);

-- ------------------------------------------------------------
-- vector_comentario
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vector_comentario (
    id_comentario      bigint PRIMARY KEY
                       REFERENCES comentario(id_comentario)
                       ON DELETE CASCADE,
    vector             vector(768)  NOT NULL,
    texto_hash         char(32)     NOT NULL,
    modelo             varchar(80)  NOT NULL,
    fecha_calculo      timestamptz  NOT NULL DEFAULT now(),
    valoracion_texto   varchar(10)  NULL
                       CHECK (valoracion_texto IN ('mala', 'buena', 'dudosa', 'corta')),
    prob_mala          numeric(4,3) NULL
                       CHECK (prob_mala BETWEEN 0 AND 1),
    valoracion_modelo  varchar(120) NULL,
    -- La valoracion se guarda entera o no se guarda: un texto sin modelo no
    -- se sabe con que se valoro. `prob_mala` va NULL tambien en `corta`.
    CHECK ((valoracion_texto IS NULL) = (valoracion_modelo IS NULL)),
    CHECK (prob_mala IS NULL OR valoracion_texto IS NOT NULL)
);

COMMENT ON TABLE vector_comentario IS
    'El vector de cada comentario (la raiz de una resena o una respuesta de 15 caracteres o mas) y la valoracion de su texto. Lo mantienen EventoComentarioSyncService (el vector, desde la cola evento_comentario) y ValoracionComentariosService (la valoracion)';
COMMENT ON COLUMN vector_comentario.vector IS
    'El vector de Ollama (paraphrase-multilingual, 768 dimensiones) del texto del comentario';
COMMENT ON COLUMN vector_comentario.texto_hash IS
    'md5 del texto con que se calculo el vector. Si el texto cambia, el worker lo recalcula';
COMMENT ON COLUMN vector_comentario.valoracion_texto IS
    'mala, buena o dudosa segun la regresion logistica sobre el vector; corta si el texto no llega al largo minimo. NULL = sin valorar todavia. Solo las raices de una resena se valoran';
COMMENT ON COLUMN vector_comentario.prob_mala IS
    'La probabilidad (0 a 1, 3 decimales) de que el texto sea malo. NULL si es corta o sin valorar';
COMMENT ON COLUMN vector_comentario.valoracion_modelo IS
    'La version del modelo de valoracion (incluye umbral y largo minimo). Si cambia, la resena se vuelve a valorar';

CREATE INDEX IF NOT EXISTS idx_vector_comentario_hnsw
    ON vector_comentario USING hnsw (vector vector_cosine_ops);

-- La cola ahora alimenta a vector_comentario, no a Elasticsearch.
COMMENT ON TABLE evento_comentario IS
    'Cola de outbox: comentarios (la raiz de cada resena y sus respuestas) cuyo vector hay que calcular o quitar en vector_comentario. La llenan triggers de comentario y resena en la misma transaccion; la vacia un worker. Una sola fila pendiente por comentario';
COMMENT ON COLUMN evento_comentario.id_comentario IS
    'El comentario que cambio. SIN FK a proposito: un AFTER DELETE apuntaria a una fila que ya no esta';
COMMENT ON COLUMN evento_comentario.procesado_en IS
    'NULL = pendiente. Con fecha = vector al dia (o quitado)';

DO $verificar$
BEGIN
    IF to_regclass('public.vector_producto') IS NULL
       OR to_regclass('public.vector_comentario') IS NULL THEN
        RAISE EXCEPTION 'vector_producto o vector_comentario no se crearon';
    END IF;
END
$verificar$;

COMMIT;
