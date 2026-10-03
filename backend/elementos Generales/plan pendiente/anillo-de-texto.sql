-- ============================================================
-- anillo-de-texto.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de la ultima migracion real -- mismo
-- workflow de siempre. El plan completo esta en anillo-de-texto.md.
--
-- Agrega al catalogo unico de senales (refactor-fraude-senales.sql) el tipo
-- `anillo_de_texto`: TRES O MAS cuentas que escribieron resenas casi iguales
-- (coseno 0.92 o mas entre los vectores de sus textos, en Elasticsearch,
-- indice mesh_comentarios) sobre el MISMO vendedor, con pocos dias de
-- diferencia. Es la firma de una red de bots o de cuentas coordinadas con la
-- misma plantilla. La hermana de `resenas_repetidas` (resenas-repetidas.sql),
-- que mira UNA cuenta que se repite.
--
-- Va en la familia `patron_resenas`, con la fuente `elastic` -- la misma que
-- `resenas_repetidas`. El archivo la crea si hace falta, asi que no depende de
-- haber corrido el otro.
--
-- La clave de la senal es el conjunto de cuentas del anillo, ordenadas y
-- unidas con guion (como los demas anillos), y las cuentas entran a
-- `senal_fraude_cuenta` como 'autor': son las sospechosas.
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
SELECT 'anillo_de_texto', fam.id_familia_senal_fraude, fu.id_fuente_senal_fraude
  FROM familia_senal_fraude fam, fuente_senal_fraude fu
 WHERE fam.familia_senal_fraude_nombre = 'patron_resenas'
   AND fu.fuente_senal_fraude_nombre = 'elastic'
ON CONFLICT (tipo_senal_fraude_nombre) DO NOTHING;

COMMIT;


-- ============================================================
-- Se comprueba a si misma
-- ============================================================
DO $verificar$
DECLARE
    v_familia text;
    v_fuente  text;
BEGIN
    SELECT f.familia_senal_fraude_nombre, fu.fuente_senal_fraude_nombre
      INTO v_familia, v_fuente
      FROM tipo_senal_fraude t
      JOIN familia_senal_fraude f ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
      JOIN fuente_senal_fraude fu ON fu.id_fuente_senal_fraude = t.id_fuente_senal_fraude
     WHERE t.tipo_senal_fraude_nombre = 'anillo_de_texto';

    IF v_familia IS DISTINCT FROM 'patron_resenas' OR v_fuente IS DISTINCT FROM 'elastic' THEN
        RAISE EXCEPTION 'anillo_de_texto no quedo en patron_resenas / elastic (quedo en % / %)', v_familia, v_fuente;
    END IF;

    RAISE NOTICE 'Tipo de senal anillo_de_texto listo.';
END
$verificar$;
