-- ============================================================
-- 042_limpieza_fraude.sql
-- ============================================================
-- La limpieza del sistema de fraude, de Jose David (25f0fe0, 2026-10-17). Es
-- su limpieza-fraude.sql hecho migracion; el plan esta en
-- backend/elementos Generales/plan pendiente/limpieza-fraude.md.
--
--   1. Una senal de login puede ser evidencia de varios casos: la evidencia
--      es unica por (caso, senal). Cierra el C1 de docs/BACKEND-PENDIENTE.md.
--   2. Fuera cadena_abierta (B.1), favor_devuelto (B.5, ahora un bono de
--      mutuo) y carrito_acaparador (F4).
--   3. La granja de registros (F6) sale de Elasticsearch, no de ClickHouse.
--   4. Fuera R-CASI-4, y descripciones nuevas de R-CASI-1, 2 y 5.
--
-- VA ANTES que el backend nuevo: con el indice viejo, el ON CONFLICT
-- (id_caso_fraude, id_senal_fraude) del agrupador falla y no guarda ningun
-- caso.
--
-- La 031 vuelve a sembrar los tres tipos quitados y la 026 vuelve a poner
-- R-CASI-4 y las descripciones viejas en cada arranque (no se editan
-- migraciones corridas). Esta corre despues y los vuelve a quitar, asi que el
-- catalogo queda siempre igual; cuesta tres numeros de la secuencia de
-- tipo_senal_fraude por arranque, que no se usan para nada.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. Una senal de login puede ser evidencia de varios casos
-- ============================================================
-- Antes una senal era evidencia de UN solo caso (033). Una senal de login
-- (p. ej. multi_cuenta_ip) toca cuentas de varios casos que no tienen nada que
-- ver entre si, y al guardarla en el segundo la persistencia los fusionaba
-- (item C1 de docs/BACKEND-PENDIENTE.md). Ahora la unicidad es por caso y
-- senal. Que una senal de resenas/compras siga en un solo caso lo garantiza el
-- backend (PersistenciaCasoFraudeService), no el indice.

-- El indice viejo (de la 033) se llama igual que el nuevo sin UNIQUE, asi que
-- solo se tira si todavia es UNIQUE: tirarlo en cada arranque lo reconstruiria
-- cada vez. La 032 y la 033 no lo vuelven a crear (IF NOT EXISTS y \if).
DO $indice$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_index i
                 JOIN pg_class c ON c.oid = i.indexrelid
                WHERE c.relname = 'idx_evidencia_caso_fraude_senal'
                  AND i.indisunique) THEN
        DROP INDEX idx_evidencia_caso_fraude_senal;
    END IF;
END
$indice$;
CREATE UNIQUE INDEX IF NOT EXISTS idx_evidencia_caso_fraude_caso_senal
    ON evidencia_caso_fraude (id_caso_fraude, id_senal_fraude);
-- Para buscar en que caso esta una senal, y para el ON DELETE CASCADE desde
-- senal_fraude.
CREATE INDEX IF NOT EXISTS idx_evidencia_caso_fraude_senal
    ON evidencia_caso_fraude (id_senal_fraude);


-- ============================================================
-- 2. Fuera cadena_abierta, favor_devuelto y carrito_acaparador
-- ============================================================
-- cadena_abierta (B.1): una cadena A->B->C no concentra reputacion en nadie y
-- en los datos solo repetia anillos que ya salian como `ciclo`.
-- favor_devuelto (B.5): se fusiono en `mutuo` (las horas de ida y vuelta van en
-- su `detalle` y suman como bono).
-- carrito_acaparador (F4): la venta relampago reserva en PostgreSQL por 15 min;
-- apartar sin comprar ya no deja unidades secuestradas.
-- Borrar la senal se lleva sus pivotes, su evidencia en casos y sus avisos (ON
-- DELETE CASCADE). Un caso pendiente que se queda sin evidencia lo borra el
-- agrupador en su siguiente corrida.

DELETE FROM senal_fraude
 WHERE id_tipo_senal_fraude IN (
         SELECT id_tipo_senal_fraude FROM tipo_senal_fraude
          WHERE tipo_senal_fraude_nombre IN ('cadena_abierta', 'favor_devuelto', 'carrito_acaparador'));

DELETE FROM tipo_senal_fraude
 WHERE tipo_senal_fraude_nombre IN ('cadena_abierta', 'favor_devuelto', 'carrito_acaparador');


-- ============================================================
-- 3. La granja de registros sale de Elasticsearch
-- ============================================================
-- Los registros ya no llegan a ClickHouse (viven en Mongo y de ahi al indice
-- mesh_eventos_autenticacion). Sigue en la familia compras_navegacion.

UPDATE tipo_senal_fraude
   SET id_fuente_senal_fraude = (SELECT id_fuente_senal_fraude FROM fuente_senal_fraude
                                  WHERE fuente_senal_fraude_nombre = 'elastic')
 WHERE tipo_senal_fraude_nombre = 'granja_de_registros';


-- ============================================================
-- 4. Reglas R-CASI
-- ============================================================
-- R-CASI-4 (ciclo con dos olas) nunca se podia cumplir: las olas de B.4 no se
-- guardan en ninguna senal.

DELETE FROM caso_fraude_regla
 WHERE id_regla_casi_confirmado = (SELECT id_regla_casi_confirmado FROM regla_casi_confirmado
                                    WHERE regla_casi_confirmado_nombre = 'R-CASI-4');
DELETE FROM regla_casi_confirmado WHERE regla_casi_confirmado_nombre = 'R-CASI-4';

UPDATE regla_casi_confirmado
   SET descripcion = 'Un ciclo, un reiterado o una granja, y ademas las cuentas compraron desde la misma IP (F3) o nacieron desde la misma IP (granja de registros) -- se califican entre si y son la misma persona fisica'
 WHERE regla_casi_confirmado_nombre = 'R-CASI-1';
UPDATE regla_casi_confirmado
   SET descripcion = 'Un ciclo o un mutuo, y ademas al menos dos cuentas del nucleo recibieron resenas expres de autores con menos de 60 minutos de vida (B.7) -- nadie compra, recibe y califica en minutos, es un guion'
 WHERE regla_casi_confirmado_nombre = 'R-CASI-2';
UPDATE regla_casi_confirmado
   SET descripcion = 'Coordinados (B.6), y ademas las dos cuentas compraron o nacieron desde la misma IP (F3 o granja de registros) -- dos teclados, una mano'
 WHERE regla_casi_confirmado_nombre = 'R-CASI-5';

COMMIT;
