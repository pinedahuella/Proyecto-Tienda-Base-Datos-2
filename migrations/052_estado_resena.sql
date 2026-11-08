-- ============================================================
-- 052_estado_resena.sql
-- ============================================================
-- La tienda oculta una resena sin borrarla (2026-11-07). Hasta hoy una
-- resena falsa que el panel de Fraude senalaba seguia publicada en la ficha,
-- y borrarla habria borrado tambien la evidencia del anillo.
--
--   estado_resena      el catalogo de estados, como los otros nueve estado_*:
--                      publicada y oculta.
--   resena             suma id_estado_resena, publicada por defecto. Toda
--                      resena que ya existia queda publicada.
--   resena_moderacion  cada vez que la tienda oculta o vuelve a publicar una
--                      resena: quien, cuando y por que.
--   resenas.moderar    el permiso de la ruta nueva, solo el admin.
--
-- Una resena oculta sale de la ficha, del promedio de estrellas y de lo que
-- cuentan otros compradores en el buscador. Se queda en el grafo de Neo4j y en
-- las senales de fraude, porque es la evidencia. Y como la fila sigue en la
-- tabla, el UNIQUE (id_usuario, id_usuario_vendedor, id_producto_mongo) de la
-- 011 no deja que esa cuenta vuelva a resenar ese producto de ese vendedor.
--
-- El trigger trg_resena_al_producto de la 030 encola el producto en cada
-- UPDATE de resena, asi que al ocultarla el worker recalcula su promedio solo.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- ============================================================
-- estado_resena
-- ============================================================
CREATE TABLE IF NOT EXISTS estado_resena (
    id_estado_resena      smallint    PRIMARY KEY,
    estado_resena_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_resena IS
    'Si una resena se ve en la tienda. La oculta sigue en la base como evidencia';

-- Con id fijo: el DEFAULT de resena.id_estado_resena es 1 y tiene que ser
-- publicada en cualquier base.
INSERT INTO estado_resena (id_estado_resena, estado_resena_nombre)
VALUES (1, 'publicada'), (2, 'oculta')
ON CONFLICT (id_estado_resena) DO NOTHING;

-- ============================================================
-- resena.id_estado_resena
-- ============================================================
ALTER TABLE resena
    ADD COLUMN IF NOT EXISTS id_estado_resena smallint NOT NULL DEFAULT 1
        REFERENCES estado_resena(id_estado_resena) ON DELETE RESTRICT;

COMMENT ON COLUMN resena.id_estado_resena IS
    '1 publicada, 2 oculta. La cambia solo la tienda, y queda en resena_moderacion';

-- Las publicadas de un producto, que es lo que lee la ficha.
CREATE INDEX IF NOT EXISTS idx_resena_producto_publicada
    ON resena(id_producto_mongo)
    WHERE id_estado_resena = 1;

-- ============================================================
-- resena_moderacion
-- ============================================================
CREATE TABLE IF NOT EXISTS resena_moderacion (
    id_resena_moderacion  bigserial PRIMARY KEY,

    -- CASCADE: si una prueba borra su resena, su historia se va con ella.
    id_resena           bigint   NOT NULL REFERENCES resena(id_resena)
                        ON DELETE CASCADE,
    id_estado_anterior  smallint NOT NULL REFERENCES estado_resena(id_estado_resena)
                        ON DELETE RESTRICT,
    id_estado_nuevo     smallint NOT NULL REFERENCES estado_resena(id_estado_resena)
                        ON DELETE RESTRICT,
    -- SET NULL: si se borra la cuenta de quien la oculto, el cambio queda.
    id_usuario          bigint   REFERENCES usuarios(id_usuario)
                        ON DELETE SET NULL,
    motivo              varchar(300),
    fecha               timestamptz NOT NULL DEFAULT now(),

    CHECK (id_estado_anterior <> id_estado_nuevo)
);

COMMENT ON TABLE resena_moderacion IS
    'Cada vez que la tienda oculta o vuelve a publicar una resena, con quien y por que';

CREATE INDEX IF NOT EXISTS idx_resena_moderacion_resena
    ON resena_moderacion(id_resena, fecha);

-- ============================================================
-- moderar_resena()
-- ============================================================
CREATE OR REPLACE FUNCTION moderar_resena(
    p_id_resena   bigint,
    p_estado      varchar,
    p_id_usuario  bigint,
    p_motivo      varchar DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_actual   smallint;
    v_nuevo    smallint;
    v_producto bigint;
BEGIN
    SELECT id_estado_resena INTO v_nuevo
      FROM estado_resena WHERE estado_resena_nombre = p_estado;
    IF v_nuevo IS NULL THEN
        RAISE EXCEPTION 'El estado % no existe, tiene que ser publicada u oculta', p_estado
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT id_estado_resena, id_producto_mongo INTO v_actual, v_producto
      FROM resena WHERE id_resena = p_id_resena
       FOR UPDATE;
    IF v_actual IS NULL THEN
        RAISE EXCEPTION 'No existe la resena %', p_id_resena
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_actual = v_nuevo THEN
        RAISE EXCEPTION 'La resena % ya esta %', p_id_resena, p_estado
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE resena SET id_estado_resena = v_nuevo WHERE id_resena = p_id_resena;

    INSERT INTO resena_moderacion (id_resena, id_estado_anterior, id_estado_nuevo, id_usuario, motivo)
    VALUES (p_id_resena, v_actual, v_nuevo, p_id_usuario, NULLIF(btrim(p_motivo), ''));

    RETURN jsonb_build_object(
        'id_resena',    p_id_resena,
        'id_producto',  v_producto,
        'estado',       p_estado
    );
END;
$fn$;

COMMENT ON FUNCTION moderar_resena(bigint, varchar, bigint, varchar) IS
    'Oculta o vuelve a publicar una resena y lo anota en resena_moderacion';

-- ============================================================
-- El permiso
-- ============================================================
WITH v (modulo, permiso, descripcion, roles) AS (
    VALUES
    ('resenas', 'moderar', 'Ocultar una resena o volverla a publicar, sin borrarla', ARRAY['admin'])
),
nuevos AS (
    INSERT INTO permiso (id_modulo_permiso, permiso_nombre, descripcion)
    SELECT m.id_modulo_permiso, v.permiso, v.descripcion
      FROM v
      JOIN modulo_permiso m ON m.modulo_permiso_nombre = v.modulo
    ON CONFLICT (id_modulo_permiso, permiso_nombre) DO NOTHING
    RETURNING id_permiso, id_modulo_permiso, permiso_nombre
)
INSERT INTO rol_permiso (id_rol_usuario, id_permiso)
SELECT r.id_rol_usuario, n.id_permiso
  FROM nuevos n
  JOIN modulo_permiso m ON m.id_modulo_permiso = n.id_modulo_permiso
  JOIN v ON v.modulo = m.modulo_permiso_nombre AND v.permiso = n.permiso_nombre
  CROSS JOIN LATERAL unnest(v.roles) AS rn(nombre)
  JOIN rol_usuario r ON r.rol_usuario_nombre = rn.nombre
ON CONFLICT DO NOTHING;

COMMIT;
