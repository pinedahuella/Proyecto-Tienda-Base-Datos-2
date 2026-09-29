-- ============================================================
-- 029_catalogo_en_oferta.sql
-- ============================================================
-- La oferta guarda su propia copia de lo que el checkout le pedia a MongoDB.
-- Es la decision 5 de docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md (seccion 2), la
-- propuesta del profesor, y cierra la fila 12 de docs/PENDIENTES.md y la 11 de
-- docs/CONSISTENCIA-CHECKOUT.md.
--
-- Hasta aqui las dos rutas de compra leian de MongoDB antes del COMMIT el
-- nombre del producto, el de la variante, la imagen y el estado de la
-- variante. MongoDB no escribe nada del pedido y aun asi, caido, dejaba la
-- tienda sin vender (503 en unos 5 s, medido por pruebas/falla_checkout.sh,
-- escenario B). Con estas columnas comprar necesita solo PostgreSQL y Redis.
--
--   nombre_producto      el nombre del producto, igual que en MongoDB
--   nombre_variante      el nombre de la variante
--   imagen_variante      la primera imagen de la variante, o NULL
--   producto_visible     el producto esta 'activo' (no borrador ni inactivo)
--   variante_activa      la variante esta 'activa'
--   catalogo_copiado_en  cuando se copio por ultima vez desde MongoDB
--
-- MongoDB SIGUE SIENDO EL DUENO de estos datos. Esto es una copia de lectura,
-- igual que nombre_producto y nombre_variante en pedido_producto. Quien edita
-- un producto lo edita en MongoDB y despues pone al dia la copia con la
-- funcion de abajo. Nadie la edita a mano.
--
-- Los largos son los mismos de pedido_producto (006) y de las validaciones
-- del backend (helpers/validaciones-crear-producto.ts, 200 y 100), asi que un
-- nombre que cabe en el catalogo cabe aqui y en la linea del pedido.
--
-- Nacen NULL a proposito. PostgreSQL no puede leer MongoDB, asi que una
-- migracion no tiene de donde sacar los nombres. Los llena el paso 7e de
-- arrancar.ps1 (etl/extraer_catalogo_oferta.js) y, en adelante, el backend al
-- crear una oferta y al editar un producto. Cuando el backend ya las escriba
-- siempre, una migracion posterior puede ponerles NOT NULL.
--
-- Es idempotente, con IF NOT EXISTS y CREATE OR REPLACE, porque arrancar.ps1
-- la vuelve a correr en cada arranque.
--
-- El plan entero, con lo que le toca al backend, esta en
-- docs/PLAN-COMPRAR-SIN-MONGO.md
-- ============================================================

BEGIN;

ALTER TABLE oferta
  ADD COLUMN IF NOT EXISTS nombre_producto     varchar(200) NULL,
  ADD COLUMN IF NOT EXISTS nombre_variante     varchar(100) NULL,
  ADD COLUMN IF NOT EXISTS imagen_variante     text         NULL,
  ADD COLUMN IF NOT EXISTS producto_visible    boolean      NULL,
  ADD COLUMN IF NOT EXISTS variante_activa     boolean      NULL,
  ADD COLUMN IF NOT EXISTS catalogo_copiado_en timestamptz  NULL;

COMMENT ON COLUMN oferta.nombre_producto IS
  'Copia del nombre del producto en MongoDB, para comprar sin MongoDB. El dueno es MongoDB; se pone al dia con copiar_catalogo_a_oferta()';
COMMENT ON COLUMN oferta.nombre_variante IS
  'Copia del nombre de la variante en MongoDB. Mismo trato que nombre_producto';
COMMENT ON COLUMN oferta.imagen_variante IS
  'Copia de la primera imagen de la variante en MongoDB, o NULL si no tiene';
COMMENT ON COLUMN oferta.producto_visible IS
  'Copia de estado = activo del producto en MongoDB. false = borrador o inactivo, no se puede comprar';
COMMENT ON COLUMN oferta.variante_activa IS
  'Copia de estado = activa de la variante en MongoDB. false = no se puede comprar';
COMMENT ON COLUMN oferta.catalogo_copiado_en IS
  'Cuando se copio por ultima vez desde MongoDB. NULL = nunca, la copia no es confiable y el backend debe tratarla como falta de dato';


-- ============================================================
-- La fecha de la oferta no se mueve por la copia
-- ============================================================
-- trg_oferta_tocar_fecha (005) pone fecha_actualizacion en CADA UPDATE. Si la
-- copia del catalogo pasara por ahi, renombrar un producto haria que sus 30
-- ofertas parecieran editadas por sus vendedores en ese momento, y el panel
-- del vendedor y el historial dirian algo falso. Se reescribe para que solo
-- cuente lo que cambio fuera de las columnas de la copia.
CREATE OR REPLACE FUNCTION oferta_tocar_fecha()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_copia CONSTANT text[] := ARRAY[
        'nombre_producto', 'nombre_variante', 'imagen_variante',
        'producto_visible', 'variante_activa', 'catalogo_copiado_en',
        'fecha_actualizacion'
    ];
BEGIN
    -- Solo se salta cuando el resto de la fila quedo igual Y la copia si
    -- cambio. Un UPDATE que no cambia nada sigue moviendo la fecha, igual que
    -- antes de la 029, para no cambiar lo que ya hacia ninguna otra ruta.
    IF (to_jsonb(NEW) - v_copia) IS NOT DISTINCT FROM (to_jsonb(OLD) - v_copia)
       AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
        RETURN NEW;
    END IF;
    NEW.fecha_actualizacion := now();
    RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION oferta_tocar_fecha() IS
    'Pone fecha_actualizacion en cada cambio de la oferta, salvo cuando lo unico que cambia es la copia del catalogo (029)';


-- ============================================================
-- copiar_catalogo_a_oferta(p_catalogo jsonb)
-- ============================================================
-- Pone al dia la copia en todas las ofertas de las variantes que recibe. La
-- usan los dos lados, para que haya una sola forma de escribir la copia:
--
--   arrancar.ps1, paso 7e   con el catalogo entero, sacado de MongoDB
--   el backend              con el producto que acaba de crear o editar
--
-- Recibe un arreglo, una entrada por variante:
--
--   [{"id_producto": 12, "id_producto_variante": 3,
--     "nombre_producto": "...", "nombre_variante": "...",
--     "imagen": "https://..." o null,
--     "producto_visible": true, "variante_activa": true}, ...]
--
-- Solo escribe las filas donde algo cambio (IS DISTINCT FROM), asi que
-- correrla dos veces seguidas no toca nada la segunda. catalogo_copiado_en si
-- se pone en todas las que coinciden, porque dice cuando se comprobo, no
-- cuando cambio.
--
-- Una variante que no tiene ninguna oferta no hace nada. Una oferta cuya
-- variante no viene en el arreglo no se toca: el paso 7e cuenta esas aparte,
-- porque son ofertas sobre algo que ya no existe en el catalogo.
--
-- Devuelve cuantas ofertas cambiaron de verdad.
CREATE OR REPLACE FUNCTION copiar_catalogo_a_oferta(p_catalogo jsonb)
RETURNS integer
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_cambiadas integer;
BEGIN
    IF p_catalogo IS NULL OR jsonb_typeof(p_catalogo) <> 'array' THEN
        RAISE EXCEPTION 'copiar_catalogo_a_oferta espera un arreglo JSON';
    END IF;

    WITH entrada AS (
        SELECT (e->>'id_producto')::bigint           AS id_producto,
               (e->>'id_producto_variante')::bigint  AS id_producto_variante,
               -- varchar SIN largo: comparar filas exige el mismo tipo que la
               -- columna, y un ::varchar(200) explicito recortaria un nombre
               -- largo en silencio. Asi, uno que no cabe falla al asignarse.
               (e->>'nombre_producto')::varchar      AS nombre_producto,
               (e->>'nombre_variante')::varchar      AS nombre_variante,
               NULLIF(e->>'imagen', '')              AS imagen,
               COALESCE((e->>'producto_visible')::boolean, false) AS producto_visible,
               COALESCE((e->>'variante_activa')::boolean, false)  AS variante_activa
          FROM jsonb_array_elements(p_catalogo) AS e
    ),
    -- `viejo` es la misma tabla otra vez. Dentro del UPDATE se lee con la foto
    -- de antes de la sentencia, y es la unica forma de saber que habia: el
    -- RETURNING de `o` ya devuelve los valores NUEVOS.
    cambio AS (
        UPDATE oferta o
           SET nombre_producto     = en.nombre_producto,
               nombre_variante     = en.nombre_variante,
               imagen_variante     = en.imagen,
               producto_visible    = en.producto_visible,
               variante_activa     = en.variante_activa,
               catalogo_copiado_en = now()
          FROM entrada en
          JOIN oferta viejo
            ON viejo.id_producto_mongo = en.id_producto
           AND viejo.id_producto_variante_mongo = en.id_producto_variante
         WHERE o.id_oferta = viejo.id_oferta
        RETURNING (viejo.nombre_producto, viejo.nombre_variante, viejo.imagen_variante,
                   viejo.producto_visible, viejo.variante_activa) AS antes,
                  (en.nombre_producto, en.nombre_variante, en.imagen,
                   en.producto_visible, en.variante_activa) AS despues
    )
    SELECT count(*) FILTER (WHERE antes IS DISTINCT FROM despues)
      INTO v_cambiadas
      FROM cambio;

    RETURN v_cambiadas;
END;
$fn$;

COMMENT ON FUNCTION copiar_catalogo_a_oferta(jsonb) IS
    'Copia nombre, imagen y estados del catalogo de MongoDB a las ofertas de cada variante recibida. Unica forma de escribir la copia (029)';

COMMIT;
