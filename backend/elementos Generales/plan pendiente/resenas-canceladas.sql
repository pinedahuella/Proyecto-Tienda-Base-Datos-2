-- ============================================================
-- resenas-canceladas.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de la ultima migracion real -- mismo
-- workflow de siempre. El plan completo esta en resenas-canceladas.md.
--
-- Agrega al catalogo unico de senales (refactor-fraude-senales.sql) una FUENTE
-- nueva, `postgres` (la deteccion sale de pedidos y reseñas de PostgreSQL, no
-- del grafo, ClickHouse, el login ni Elasticsearch), y DOS tipos para el fraude
-- de reseñar y cancelar la compra (se reembolsa):
--
--   resena_positiva_cancelada              una CUENTA con una reseña de 4-5
--                                          estrellas cuya compra cancelo poco
--                                          despues (infla las reseñas del vendedor)
--   resenas_negativas_canceladas_vendedor  un VENDEDOR con 5+ reseñas de 1-2
--                                          estrellas cuya compra se cancelo poco
--                                          despues (lo perjudican)
--
-- Van en la familia `patron_resenas`. La de la cuenta entra a los casos; la del
-- vendedor es solo alerta (no forma casos). En la del vendedor, el vendedor
-- entra a `senal_fraude_cuenta` como 'victima' y quienes reseñaron y cancelaron
-- como 'autor'.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente.
-- ============================================================

BEGIN;

INSERT INTO fuente_senal_fraude (fuente_senal_fraude_nombre)
VALUES ('postgres')
ON CONFLICT (fuente_senal_fraude_nombre) DO NOTHING;

INSERT INTO tipo_senal_fraude (tipo_senal_fraude_nombre, id_familia_senal_fraude, id_fuente_senal_fraude)
SELECT nuevo.nombre, fam.id_familia_senal_fraude, fu.id_fuente_senal_fraude
  FROM (VALUES ('resena_positiva_cancelada'),
               ('resenas_negativas_canceladas_vendedor')) AS nuevo (nombre),
       familia_senal_fraude fam, fuente_senal_fraude fu
 WHERE fam.familia_senal_fraude_nombre = 'patron_resenas'
   AND fu.fuente_senal_fraude_nombre = 'postgres'
ON CONFLICT (tipo_senal_fraude_nombre) DO NOTHING;

COMMIT;


-- ============================================================
-- Se comprueba a si misma
-- ============================================================
DO $verificar$
DECLARE
    v_buenos integer;
BEGIN
    SELECT count(*) INTO v_buenos
      FROM tipo_senal_fraude t
      JOIN familia_senal_fraude f ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
      JOIN fuente_senal_fraude fu ON fu.id_fuente_senal_fraude = t.id_fuente_senal_fraude
     WHERE t.tipo_senal_fraude_nombre IN ('resena_positiva_cancelada',
                                          'resenas_negativas_canceladas_vendedor')
       AND f.familia_senal_fraude_nombre = 'patron_resenas'
       AND fu.fuente_senal_fraude_nombre = 'postgres';

    IF v_buenos <> 2 THEN
        RAISE EXCEPTION 'faltan tipos de resenas canceladas en patron_resenas / postgres (hay %, deben ser 2)', v_buenos;
    END IF;

    RAISE NOTICE 'Fuente postgres y tipos de resenas canceladas listos.';
END
$verificar$;
