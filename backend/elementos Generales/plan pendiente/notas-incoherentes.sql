-- ============================================================
-- notas-incoherentes.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de la ultima migracion real -- mismo
-- workflow de siempre. El plan completo esta en notas-incoherentes.md.
--
-- Agrega al catalogo unico de senales (refactor-fraude-senales.sql) TRES tipos
-- para las resenas "contradictorias" (el texto dice una cosa y las estrellas
-- otra: texto malo con 4-5 estrellas, o texto bueno con 1-2):
--
--   notas_incoherentes_cuenta     una CUENTA con 5+ resenas contradictorias que
--                                 son el 20 % o mas de las que escribio
--   notas_incoherentes_producto   un PRODUCTO con 5+ contradictorias, el 40 % o
--                                 mas de las que recibio
--   notas_incoherentes_vendedor   un VENDEDOR con 5+ contradictorias, el 20 % o
--                                 mas de las que recibieron sus productos
--
-- Van en la familia `patron_resenas` con la fuente `elastic` (la deteccion sale
-- del texto, indice mesh_comentarios), igual que `resenas_repetidas` y
-- `anillo_de_texto`. El archivo crea la fuente si hace falta, asi que no depende
-- de haber corrido los otros.
--
-- La clave de la senal: el id de la cuenta o del vendedor; para el producto,
-- `p<id>` (con la "p" para que NO se tome por una cuenta). Las de producto y
-- vendedor son solo alerta para el admin (no forman casos). El producto se liga
-- en `senal_fraude_producto`.
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
  FROM (VALUES ('notas_incoherentes_cuenta'),
               ('notas_incoherentes_producto'),
               ('notas_incoherentes_vendedor')) AS nuevo (nombre),
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
     WHERE t.tipo_senal_fraude_nombre IN ('notas_incoherentes_cuenta',
                                          'notas_incoherentes_producto',
                                          'notas_incoherentes_vendedor')
       AND f.familia_senal_fraude_nombre = 'patron_resenas'
       AND fu.fuente_senal_fraude_nombre = 'elastic';

    IF v_buenos <> 3 THEN
        RAISE EXCEPTION 'faltan tipos notas_incoherentes_* en patron_resenas / elastic (hay %, deben ser 3)', v_buenos;
    END IF;

    RAISE NOTICE 'Tipos de senal notas_incoherentes_* listos.';
END
$verificar$;
