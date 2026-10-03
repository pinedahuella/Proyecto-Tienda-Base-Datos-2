-- ============================================================
-- resenas-repetidas.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de la ultima migracion real -- mismo
-- workflow de siempre. El plan completo esta en resenas-repetidas.md.
--
-- Agrega al catalogo unico de senales (refactor-fraude-senales.sql) el tipo
-- `resenas_repetidas`: una CUENTA que escribio 5 o mas resenas casi iguales
-- (coseno 0.92 o mas entre los vectores de sus textos, que viven en
-- Elasticsearch, indice mesh_comentarios). Es la senal de un bot o de alguien
-- que copia y pega la misma resena.
--
-- Va en la familia `patron_resenas` (junto a satelites, coordinados, etc.),
-- asi que las rutas de admin de anillos y el agrupador de casos la toman sin
-- mas cambios. La FUENTE es nueva: `elastic` -- la deteccion sale del texto,
-- no del grafo ni de ClickHouse, y el puntaje la cuenta como un motor aparte.
--
-- La clave de la senal es el id de la cuenta (una senal por cuenta), y la
-- cuenta entra a `senal_fraude_cuenta` como 'autor': es la sospechosa.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente.
-- ============================================================

BEGIN;

-- Solo para la base local, donde la fuente se llamo `elasticsearch` antes de
-- decidir el nombre: conserva su id y el tipo que ya la apunta. En una base
-- limpia no hace nada.
UPDATE fuente_senal_fraude SET fuente_senal_fraude_nombre = 'elastic'
 WHERE fuente_senal_fraude_nombre = 'elasticsearch';

INSERT INTO fuente_senal_fraude (fuente_senal_fraude_nombre)
VALUES ('elastic')
ON CONFLICT (fuente_senal_fraude_nombre) DO NOTHING;

INSERT INTO tipo_senal_fraude (tipo_senal_fraude_nombre, id_familia_senal_fraude, id_fuente_senal_fraude)
SELECT 'resenas_repetidas', fam.id_familia_senal_fraude, fu.id_fuente_senal_fraude
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
     WHERE t.tipo_senal_fraude_nombre = 'resenas_repetidas';

    IF v_familia IS DISTINCT FROM 'patron_resenas' OR v_fuente IS DISTINCT FROM 'elastic' THEN
        RAISE EXCEPTION 'resenas_repetidas no quedo en patron_resenas / elastic (quedo en % / %)', v_familia, v_fuente;
    END IF;

    RAISE NOTICE 'Tipo de senal resenas_repetidas listo.';
END
$verificar$;
