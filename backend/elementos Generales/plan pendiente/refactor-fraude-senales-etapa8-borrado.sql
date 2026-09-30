-- ============================================================
-- refactor-fraude-senales-etapa8-borrado.sql  --  SOLO REFERENCIA / NO APLICADO
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de refactor-fraude-senales-etapa8.sql.
--
-- ETAPA 8, PASO 4 del refactor de fraude (ver refactor-fraude-senales.md): se
-- borran las tablas viejas que reemplazo senal_fraude. NO hay vistas de por
-- medio (paso 3 omitido, decision del 2026-09-30).
--
-- NO TIENE VUELTA ATRAS. Lo que solo vivia en estas tablas se pierde: por
-- ejemplo, la historia por ventana de alerta_fraude (una fila por minuto u hora,
-- que la senal resume en una sola). En una base real, respaldar antes y dejar
-- pasar un tiempo con el paso 1 aplicado.
--
-- Requiere: las tres migraciones anteriores aplicadas, y que nada lea ni escriba
-- estas tablas: el backend ya no lo hace; los scripts de pruebas/ y los demos
-- .ps1 de fraude SI, y fallaran con "no existe la tabla" hasta que se
-- actualicen.
--
-- Que NO se borra:
--   * estado_alerta_fraude: lo usan caso_fraude y senal_fraude.
--
-- Los tres catalogos viejos (tipo_anillo_fraude, tipo_hallazgo_evento y
-- tipo_alerta_fraude) SI se borran: el codigo ya no los consulta (los helpers
-- registrar-alerta-fraude.ts y registrar-hallazgo-evento-fraude.ts reciben el
-- nombre del tipo y lo buscan en tipo_senal_fraude; los ID_TIPO_* de models/
-- desaparecieron).
--
-- Sin CASCADE a proposito: si algo mas dependiera de estas tablas, el DROP
-- falla y avisa en vez de llevarse el objeto por delante.
--
-- Probado en local SOLO con ROLLBACK (no se aplico). Es idempotente (IF EXISTS).
-- ============================================================


BEGIN;

-- Pivotes primero (apuntan a las tablas principales).
DROP TABLE IF EXISTS anillo_fraude_resena;
DROP TABLE IF EXISTS hallazgo_evento_fraude_cuenta;

-- Las tablas principales.
DROP TABLE IF EXISTS anillo_fraude;
DROP TABLE IF EXISTS hallazgo_evento_fraude;
DROP TABLE IF EXISTS alerta_fraude;

-- Los catalogos de tipo, ya sin nadie que apunte a ellos.
DROP TABLE IF EXISTS tipo_anillo_fraude;
DROP TABLE IF EXISTS tipo_hallazgo_evento;
DROP TABLE IF EXISTS tipo_alerta_fraude;

COMMIT;
