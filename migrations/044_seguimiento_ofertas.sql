-- ============================================================
-- 044_seguimiento_ofertas.sql
-- ============================================================
-- Los seguimientos de ofertas ("avisame"), de Jose David (25f0fe0,
-- 2026-10-17). Es su seguimiento-ofertas.sql hecho migracion, sin cambios; el
-- plan esta en backend/elementos Generales/plan pendiente/seguimiento-ofertas.md.
--
--   busqueda     busco algo, no lo encontro, y quiere saber cuando llegue
--                (con o sin precio maximo)
--   baja_precio  quiere saber cuando una variante baje de precio, solo la
--                oferta de la tienda o la de cualquier vendedor
--
-- Cada seguimiento vive aqui (la verdad) y como consulta guardada en el
-- percolator mesh_seguimientos (elastic/005_seguimientos.json). Cada oferta
-- que indexa EventoOfertaSyncService (043) pasa por el percolator; la primera
-- que coincide genera UN aviso (id_seguimiento es UNIQUE) y el seguimiento se
-- da por cumplido. Si el indice se crea de nuevo, arrancar.ps1 (paso 9e)
-- vuelve a cargar las consultas de los seguimientos vivos.
--
-- Los nombres evitan "alerta" y "notificacion": ya existen alerta_fraude y
-- notificacion_fraude, que son otra cosa.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- ============================================================
-- tipo_seguimiento_oferta
-- ============================================================
CREATE TABLE IF NOT EXISTS tipo_seguimiento_oferta (
    id_tipo_seguimiento_oferta      smallserial PRIMARY KEY,
    tipo_seguimiento_oferta_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE tipo_seguimiento_oferta IS
    'Catalogo de tipos de seguimiento: busqueda (avisame cuando llegue) y baja_precio (avisame cuando baje)';

INSERT INTO tipo_seguimiento_oferta (tipo_seguimiento_oferta_nombre)
VALUES ('busqueda'), ('baja_precio')
ON CONFLICT (tipo_seguimiento_oferta_nombre) DO NOTHING;


-- ============================================================
-- seguimiento_oferta
-- ============================================================
CREATE TABLE IF NOT EXISTS seguimiento_oferta (
    id_seguimiento  bigserial PRIMARY KEY,

    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    id_tipo_seguimiento_oferta  smallint NOT NULL
                REFERENCES tipo_seguimiento_oferta(id_tipo_seguimiento_oferta)
                ON DELETE RESTRICT,

    -- busqueda: lo que escribio.
    texto  text,

    -- baja_precio: el PAR producto + variante, no la variante sola (ver el
    -- comentario de oferta en 005_ofertas.sql). Sin FK, igual que oferta: el
    -- id viene del catalogo.
    id_producto_mongo           bigint,
    id_producto_variante_mongo  bigint,

    -- busqueda: opcional, "hasta este precio" (sobre el precio final).
    precio_maximo  numeric(12,2) CHECK (precio_maximo > 0),

    -- baja_precio: avisa cuando una oferta quede POR DEBAJO de este precio.
    -- Lo pone el comprador, o el backend con el mas bajo de ese momento.
    precio_referencia  numeric(12,2) CHECK (precio_referencia > 0),

    -- baja_precio: true = solo la oferta de la tienda; false = cualquiera.
    solo_tienda  boolean NOT NULL DEFAULT false,

    fecha_creacion  timestamptz NOT NULL DEFAULT now(),

    -- NULL = sigue esperando. Con fecha = ya aviso y salio del percolator.
    fecha_cumplido  timestamptz,

    -- La forma de cada tipo. No se compara contra el id del catalogo (el
    -- backend resuelve el tipo por nombre); basta con que una fila sea
    -- claramente de uno o de otro.
    CONSTRAINT seguimiento_oferta_forma CHECK (
        (texto IS NOT NULL AND btrim(texto) <> '' AND char_length(texto) <= 100
         AND id_producto_mongo IS NULL AND id_producto_variante_mongo IS NULL
         AND precio_referencia IS NULL AND NOT solo_tienda)
        OR
        (texto IS NULL AND precio_maximo IS NULL
         AND id_producto_mongo IS NOT NULL AND id_producto_variante_mongo IS NOT NULL
         AND precio_referencia IS NOT NULL)
    )
);

COMMENT ON TABLE seguimiento_oferta IS
    'Lo que un comprador pidio seguir: una busqueda (avisame cuando llegue) o una variante (avisame cuando baje). Tambien vive como consulta en el percolator mesh_seguimientos mientras no se cumple';
COMMENT ON COLUMN seguimiento_oferta.precio_referencia IS
    'baja_precio: avisa cuando una oferta quede por debajo. Lo pone el comprador o, si no, el precio final mas bajo al crear el seguimiento (de la tienda si solo_tienda)';
COMMENT ON COLUMN seguimiento_oferta.fecha_cumplido IS
    'NULL = sigue esperando. Con fecha = ya genero su unico aviso y se borro del percolator';

-- Los de un usuario (las rutas listan por aqui).
CREATE INDEX IF NOT EXISTS ix_seguimiento_oferta_usuario
    ON seguimiento_oferta (id_usuario, fecha_creacion DESC);

-- No dos seguimientos vivos iguales: la misma busqueda (sin importar
-- mayusculas) o la misma variante. Uno cumplido no cuenta: se puede volver
-- a pedir.
CREATE UNIQUE INDEX IF NOT EXISTS uq_seguimiento_oferta_busqueda_viva
    ON seguimiento_oferta (id_usuario, lower(btrim(texto)))
    WHERE fecha_cumplido IS NULL AND texto IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_seguimiento_oferta_variante_viva
    ON seguimiento_oferta (id_usuario, id_producto_mongo, id_producto_variante_mongo)
    WHERE fecha_cumplido IS NULL AND texto IS NULL;


-- ============================================================
-- aviso_seguimiento_oferta
-- ============================================================
CREATE TABLE IF NOT EXISTS aviso_seguimiento_oferta (
    id_aviso  bigserial PRIMARY KEY,

    -- UNIQUE: un seguimiento da UN aviso, nunca dos. Es lo que hace imposible
    -- el doble disparo aunque dos ofertas coincidan en el mismo lote.
    -- CASCADE: si el comprador borra el seguimiento, se va su aviso.
    id_seguimiento  bigint NOT NULL UNIQUE
                    REFERENCES seguimiento_oferta(id_seguimiento)
                    ON DELETE CASCADE,

    -- La oferta que lo cumplio: con ella se lleva directo a comprar. CASCADE y
    -- no RESTRICT para no trabar el borrado de productos generados
    -- (arrancar.ps1 -Borrar).
    id_oferta  bigint NOT NULL REFERENCES oferta(id_oferta)
               ON DELETE CASCADE,

    -- El precio final de la oferta cuando aviso (despues puede cambiar).
    precio_final  numeric(12,2) NOT NULL CHECK (precio_final >= 0),

    fecha_aviso  timestamptz NOT NULL DEFAULT now(),

    -- NULL = no leido. Marcar como no leido vuelve a ponerlo en NULL.
    fecha_leida  timestamptz
);

COMMENT ON TABLE aviso_seguimiento_oferta IS
    'El unico aviso de un seguimiento cumplido: que oferta lo cumplio y a que precio. fecha_leida NULL = no leido';
COMMENT ON COLUMN aviso_seguimiento_oferta.fecha_leida IS
    'NULL = no leido. Con fecha = cuando lo marco como leido';

CREATE INDEX IF NOT EXISTS ix_aviso_seguimiento_oferta_oferta
    ON aviso_seguimiento_oferta (id_oferta);

COMMIT;


-- ============================================================
-- Se comprueba a si misma
-- ============================================================
DO $verificar$
DECLARE
    v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM tipo_seguimiento_oferta
     WHERE tipo_seguimiento_oferta_nombre IN ('busqueda', 'baja_precio');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'Faltan tipos en tipo_seguimiento_oferta';
    END IF;

    SELECT count(*) INTO v_n FROM pg_indexes
     WHERE tablename = 'seguimiento_oferta'
       AND indexname IN ('uq_seguimiento_oferta_busqueda_viva', 'uq_seguimiento_oferta_variante_viva');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'Faltan los indices unicos de seguimientos vivos';
    END IF;

    SELECT count(*) INTO v_n FROM pg_constraint
     WHERE conrelid = 'aviso_seguimiento_oferta'::regclass AND contype = 'u';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'aviso_seguimiento_oferta.id_seguimiento debe ser UNIQUE: sin eso un seguimiento podria avisar dos veces';
    END IF;

    RAISE NOTICE 'Seguimiento de ofertas listo.';
END
$verificar$;
