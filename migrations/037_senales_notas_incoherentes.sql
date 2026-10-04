-- ============================================================
-- 037_senales_notas_incoherentes.sql
-- ============================================================
-- Las notas incoherentes de Jose David (3305cf3): resenas cuyo texto dice lo
-- contrario de sus estrellas (texto malo con 4 o 5, o bueno con 1 o 2; el 3
-- no cuenta), contadas por cuenta, por producto y por vendedor. Es su
-- notas-incoherentes.sql hecho migracion; el plan esta en
-- backend/elementos Generales/plan pendiente/notas-incoherentes.md.
--
-- Quien dice si un texto es malo es el clasificador de resenas
-- (clasificador-resenas/, regresion logistica). ValoracionComentariosService
-- le pone a cada resena raiz de mas de 100 caracteres su valoracion en
-- mesh_comentarios, desde el vector que ya estaba ahi, y
-- NotasIncoherentesDetectorService cuenta con agregaciones de Elasticsearch:
--
--   notas_incoherentes_cuenta     5 o mas contradictorias y el 20 % de las suyas
--   notas_incoherentes_producto   5 o mas y el 40 %, solo alerta, no forma casos
--   notas_incoherentes_vendedor   5 o mas y el 20 %, solo alerta, no forma casos
--
-- Familia patron_resenas y fuente elastic, como las de la 035. Lo unico
-- distinto de su SQL: WHERE NOT EXISTS en vez de ON CONFLICT DO NOTHING, para
-- no quemar la secuencia en cada arranque (ver la 035).
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

INSERT INTO tipo_senal_fraude (tipo_senal_fraude_nombre, id_familia_senal_fraude, id_fuente_senal_fraude)
SELECT v.tipo, fam.id_familia_senal_fraude, fu.id_fuente_senal_fraude
  FROM (VALUES
               (28, 'notas_incoherentes_cuenta'),
               (29, 'notas_incoherentes_producto'),
               (30, 'notas_incoherentes_vendedor')) AS v(orden, tipo)
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
     WHERE t.tipo_senal_fraude_nombre IN ('notas_incoherentes_cuenta', 'notas_incoherentes_producto', 'notas_incoherentes_vendedor')
       AND f.familia_senal_fraude_nombre = 'patron_resenas'
       AND fu.fuente_senal_fraude_nombre = 'elastic';

    IF v_buenos <> 3 THEN
        RAISE EXCEPTION 'faltan tipos de notas_incoherentes en patron_resenas / elastic (hay %, deben ser 3)', v_buenos;
    END IF;

    RAISE NOTICE 'Tipos de senal de notas_incoherentes listos.';
END
$verificar$;
