-- ============================================================
-- 035_senales_fraude_por_texto.sql
-- ============================================================
-- Las dos senales de fraude que salen del TEXTO de las resenas, de Jose David
-- (fa3281c). Son resenas-repetidas.sql y anillo-de-texto.sql juntas, porque
-- las dos hacen lo mismo: la fuente `elastic` y un tipo nuevo en
-- tipo_senal_fraude, familia `patron_resenas`.
--
--   resenas_repetidas  UNA cuenta con 5 o mas resenas casi iguales (coseno
--                      0,92 o mas). Un bot o alguien que copia y pega.
--                      ResenasRepetidasDetectorService, 15 puntos base.
--   anillo_de_texto    TRES o mas cuentas con resenas casi iguales sobre el
--                      MISMO vendedor, con 30 dias o menos entre ellas. Una
--                      red de cuentas con la misma plantilla.
--                      AnilloDeTextoDetectorService, 25 puntos base.
--
-- Los vectores viven en el indice mesh_comentarios de Elasticsearch (la cola
-- es la 034). El grafo de Neo4j ve quien resena a quien; esto ve lo que dicen.
-- La fuente es nueva para que el puntaje la cuente como un motor aparte.
--
-- Lo unico distinto de su SQL de referencia: los INSERT van con WHERE NOT
-- EXISTS, como la 031, y no solo con ON CONFLICT DO NOTHING, que quema un
-- nextval por fila en cada arranque (ver migrations/README.md, la 016). El
-- backend busca los tipos por NOMBRE, asi que el id no importa, pero la
-- secuencia no tiene por que crecer sola.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- Solo para una base donde la fuente se aplico a mano con el nombre que tuvo
-- primero (`elasticsearch`): conserva su id y los tipos que ya la apuntan. En
-- una base limpia no hace nada.
UPDATE fuente_senal_fraude SET fuente_senal_fraude_nombre = 'elastic'
 WHERE fuente_senal_fraude_nombre = 'elasticsearch'
   AND NOT EXISTS (SELECT 1 FROM fuente_senal_fraude WHERE fuente_senal_fraude_nombre = 'elastic');

INSERT INTO fuente_senal_fraude (fuente_senal_fraude_nombre)
SELECT 'elastic'
 WHERE NOT EXISTS (SELECT 1 FROM fuente_senal_fraude WHERE fuente_senal_fraude_nombre = 'elastic');

INSERT INTO tipo_senal_fraude (tipo_senal_fraude_nombre, id_familia_senal_fraude, id_fuente_senal_fraude)
SELECT v.tipo, fam.id_familia_senal_fraude, fu.id_fuente_senal_fraude
  FROM (VALUES (26, 'resenas_repetidas'),
               (27, 'anillo_de_texto')) AS v(orden, tipo)
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
    v_tipo    text;
    v_familia text;
    v_fuente  text;
BEGIN
    FOREACH v_tipo IN ARRAY ARRAY['resenas_repetidas', 'anillo_de_texto'] LOOP
        v_familia := NULL;
        v_fuente  := NULL;
        SELECT f.familia_senal_fraude_nombre, fu.fuente_senal_fraude_nombre
          INTO v_familia, v_fuente
          FROM tipo_senal_fraude t
          JOIN familia_senal_fraude f  ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
          JOIN fuente_senal_fraude  fu ON fu.id_fuente_senal_fraude = t.id_fuente_senal_fraude
         WHERE t.tipo_senal_fraude_nombre = v_tipo;

        IF v_familia IS DISTINCT FROM 'patron_resenas' OR v_fuente IS DISTINCT FROM 'elastic' THEN
            RAISE EXCEPTION '% no quedo en patron_resenas / elastic (quedo en % / %)', v_tipo, v_familia, v_fuente;
        END IF;
    END LOOP;

    RAISE NOTICE 'Senales de fraude por texto listas.';
END
$verificar$;
