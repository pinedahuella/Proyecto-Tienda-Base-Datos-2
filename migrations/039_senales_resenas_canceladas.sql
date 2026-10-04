-- ============================================================
-- 039_senales_resenas_canceladas.sql
-- ============================================================
-- Resenar y cancelar la compra, de Jose David (1f1f480). Es su
-- resenas-canceladas.sql hecho migracion; el plan esta en
-- backend/elementos Generales/plan pendiente/resenas-canceladas.md.
--
-- Un comprador puede pagar, resenar y cancelar el pedido (cancelar_pedido(),
-- solo en pendiente o comprado), y se le devuelve el dinero. La resena se
-- queda aunque la compra ya no exista. ResenasCanceladasDetectorService cruza
-- el stock_movimiento de motivo `devolucion` con la resena del mismo comprador
-- al mismo vendedor por el mismo producto, cancelada despues de la resena y
-- dentro de 72 horas:
--
--   resena_positiva_cancelada              una de 4 o 5 estrellas basta. Fuerte,
--                                          entra a los casos
--   resenas_negativas_canceladas_vendedor  5 o mas de 1 o 2 estrellas contra un
--                                          vendedor, que sale como victima. Solo alerta
--
-- La FUENTE es nueva, `postgres`: la deteccion sale de pedidos y kardex, no de
-- un grafo ni de un texto, y el puntaje la cuenta como un motor aparte. Lo
-- unico distinto de su SQL: WHERE NOT EXISTS en vez de ON CONFLICT DO NOTHING,
-- para no quemar las secuencias en cada arranque (ver la 035).
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

INSERT INTO fuente_senal_fraude (fuente_senal_fraude_nombre)
SELECT 'postgres'
 WHERE NOT EXISTS (SELECT 1 FROM fuente_senal_fraude WHERE fuente_senal_fraude_nombre = 'postgres');

INSERT INTO tipo_senal_fraude (tipo_senal_fraude_nombre, id_familia_senal_fraude, id_fuente_senal_fraude)
SELECT v.tipo, fam.id_familia_senal_fraude, fu.id_fuente_senal_fraude
  FROM (VALUES
               (33, 'resena_positiva_cancelada'),
               (34, 'resenas_negativas_canceladas_vendedor')) AS v(orden, tipo)
  JOIN familia_senal_fraude fam ON fam.familia_senal_fraude_nombre = 'patron_resenas'
  JOIN fuente_senal_fraude  fu  ON fu.fuente_senal_fraude_nombre   = 'postgres'
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
     WHERE t.tipo_senal_fraude_nombre IN ('resena_positiva_cancelada', 'resenas_negativas_canceladas_vendedor')
       AND f.familia_senal_fraude_nombre = 'patron_resenas'
       AND fu.fuente_senal_fraude_nombre = 'postgres';

    IF v_buenos <> 2 THEN
        RAISE EXCEPTION 'faltan tipos de resenas canceladas en patron_resenas / postgres (hay %, deben ser 2)', v_buenos;
    END IF;

    RAISE NOTICE 'Fuente postgres y tipos de resenas canceladas listos.';
END
$verificar$;
