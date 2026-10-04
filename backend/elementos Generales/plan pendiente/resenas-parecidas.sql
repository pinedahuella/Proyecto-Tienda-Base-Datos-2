-- ============================================================
-- resenas-parecidas.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de la ultima migracion real -- mismo
-- workflow de siempre. El plan completo esta en resenas-parecidas.md.
--
-- Agrega al catalogo unico de senales (refactor-fraude-senales.sql) DOS tipos
-- para las resenas copiadas o automatizadas:
--
--   resenas_parecidas_vendedor   un VENDEDOR con 5+ resenas que tienen una
--                                "gemela" de otra cuenta, el 20 % o mas de las
--                                que recibieron sus productos
--   resenas_parecidas_producto   un PRODUCTO con 5+ resenas con gemela de otra
--                                cuenta, el 40 % o mas de las que recibio
--
-- Una "gemela" es otra resena de OTRA cuenta con coseno 0.92 o mas entre sus
-- vectores y 30 dias o menos de diferencia. Van en la familia `patron_resenas`
-- con la fuente `elastic`, igual que `resenas_repetidas` y `anillo_de_texto`.
-- El archivo crea la fuente si hace falta, asi que no depende de los otros.
--
-- La clave de la senal: el id del vendedor; para el producto, `p<id>` (con la
-- "p" para que NO se tome por una cuenta). Son solo alerta para el admin (no
-- forman casos). El producto se liga en `senal_fraude_producto`.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente.
-- ============================================================

BEGIN;

INSERT INTO fuente_senal_fraude (fuente_senal_fraude_nombre)
VALUES ('elastic')
ON CONFLICT (fuente_senal_fraude_nombre) DO NOTHING;

INSERT INTO tipo_senal_fraude (tipo_senal_fraude_nombre, id_familia_senal_fraude, id_fuente_senal_fraude)
SELECT nuevo.nombre, fam.id_familia_senal_fraude, fu.id_fuente_senal_fraude
  FROM (VALUES ('resenas_parecidas_vendedor'),
               ('resenas_parecidas_producto')) AS nuevo (nombre),
       familia_senal_fraude fam, fuente_senal_fraude fu
 WHERE fam.familia_senal_fraude_nombre = 'patron_resenas'
   AND fu.fuente_senal_fraude_nombre = 'elastic'
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
     WHERE t.tipo_senal_fraude_nombre IN ('resenas_parecidas_vendedor',
                                          'resenas_parecidas_producto')
       AND f.familia_senal_fraude_nombre = 'patron_resenas'
       AND fu.fuente_senal_fraude_nombre = 'elastic';

    IF v_buenos <> 2 THEN
        RAISE EXCEPTION 'faltan tipos resenas_parecidas_* en patron_resenas / elastic (hay %, deben ser 2)', v_buenos;
    END IF;

    RAISE NOTICE 'Tipos de senal resenas_parecidas_* listos.';
END
$verificar$;
