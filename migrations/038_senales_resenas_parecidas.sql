-- ============================================================
-- 038_senales_resenas_parecidas.sql
-- ============================================================
-- Las resenas parecidas de Jose David (3305cf3), su resenas-parecidas.sql
-- hecho migracion; el plan esta en
-- backend/elementos Generales/plan pendiente/resenas-parecidas.md.
--
-- Una resena tiene "gemela" si otra de OTRA cuenta se le parece (coseno 0,92
-- o mas, 30 dias o menos entre las dos, las dos de mas de 100 caracteres).
-- ResenasParecidasDetectorService las cuenta por vendedor y por producto:
--
--   resenas_parecidas_vendedor   5 o mas con gemela y el 20 % de las suyas
--   resenas_parecidas_producto   5 o mas con gemela y el 40 %
--
-- Las dos son solo alerta: no forman casos (TIPOS_SOLO_ALERTA del backend).
-- Familia patron_resenas y fuente elastic, como las de la 035 y la 037.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

INSERT INTO tipo_senal_fraude (tipo_senal_fraude_nombre, id_familia_senal_fraude, id_fuente_senal_fraude)
SELECT v.tipo, fam.id_familia_senal_fraude, fu.id_fuente_senal_fraude
  FROM (VALUES
               (31, 'resenas_parecidas_vendedor'),
               (32, 'resenas_parecidas_producto')) AS v(orden, tipo)
  JOIN familia_senal_fraude fam ON fam.familia_senal_fraude_nombre = 'patron_resenas'
  JOIN fuente_senal_fraude  fu  ON fu.fuente_senal_fraude_nombre   = 'elastic'
 WHERE NOT EXISTS (SELECT 1 FROM tipo_senal_fraude t WHERE t.tipo_senal_fraude_nombre = v.tipo)
 ORDER BY v.orden;

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
      JOIN familia_senal_fraude f  ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
      JOIN fuente_senal_fraude  fu ON fu.id_fuente_senal_fraude = t.id_fuente_senal_fraude
     WHERE t.tipo_senal_fraude_nombre IN ('resenas_parecidas_vendedor', 'resenas_parecidas_producto')
       AND f.familia_senal_fraude_nombre = 'patron_resenas'
       AND fu.fuente_senal_fraude_nombre = 'elastic';

    IF v_buenos <> 2 THEN
        RAISE EXCEPTION 'faltan tipos de resenas_parecidas en patron_resenas / elastic (hay %, deben ser 2)', v_buenos;
    END IF;

    RAISE NOTICE 'Tipos de senal de resenas_parecidas listos.';
END
$verificar$;
