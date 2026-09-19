-- ============================================================
-- 017_alertas_fraude_extendidas.sql
-- ============================================================
-- Amplia tipo_alerta_fraude de 3 a 9 filas. La 016 solo tenia las tres
-- senales de Redis (fuerza_bruta_ip, fuerza_bruta_cuenta, multi_cuenta_ip).
-- El resto del pull del 2026-09-18 trae seis senales mas, todas contra
-- Elasticsearch (mesh_eventos_autenticacion): tres retrospectivas con su
-- espejo _lenta, y dos que comparan el login actual contra el historial de
-- la cuenta (toma_cuenta, viaje_imposible).
--
-- DE DONDE SALE
-- ============================================================
-- El backend ya usa los nueve tipos. La definicion es la del SQL de
-- referencia del companero, en
-- `backend/elementos Generales/plan pendiente/fraude-login-eventos.sql`,
-- que ya trae las 9 filas en el orden final. Esta migracion NO repite las
-- tres primeras (ya estan, desde la 016, con sus ids 1-3 ya comprobados
-- alli) ni el UPDATE de renombre que trae esa referencia (existe solo para
-- reconciliar la base LOCAL de desarrollo del companero, que en algun
-- momento tuvo una fila 'ip_rotacion_cuenta' sin sufijo antes de que
-- naciera su version corta en Redis; una migracion real, sobre una tabla
-- que ya tiene 001-003 y nunca tuvo esa fila vieja, no encuentra nada que
-- renombrar).
--
-- Una migracion ya corrida no se edita (regla de migrations/README.md), por
-- eso esto es un archivo nuevo y no un ALTER a la 016.
--
--
-- EL ORDEN FIJA LOS IDS, IGUAL QUE LA 016
-- ============================================================
-- `backend/src/models/alerta-fraude.ts` fija los nueve ids como constantes.
-- Los tres primeros ya los aseguro el candado de la 016. Este candado
-- comprueba los seis nuevos: 4 toma_cuenta, 5 fuerza_bruta_cuenta_lenta,
-- 6 multi_cuenta_ip_lenta, 7 ip_rotacion_cuenta_lenta, 8 ip_rotacion_cuenta,
-- 9 viaje_imposible.
--
-- Mismo motivo que la 016 para usar WHERE NOT EXISTS en vez de solo
-- ON CONFLICT: este archivo corre en cada arranque, y ON CONFLICT DO NOTHING
-- pide el nextval de la secuencia ANTES de descubrir el choque -- en una
-- base ya migrada eso quemaria seis numeros por arranque sin necesidad.
--
-- Sin BEGIN/COMMIT, mismo criterio que la 016: todo es NOT EXISTS, asi que
-- una corrida a la mitad la termina la siguiente.
-- ============================================================


INSERT INTO tipo_alerta_fraude (tipo_alerta_fraude_nombre)
SELECT v.nombre
  FROM (VALUES (4, 'toma_cuenta'),
               (5, 'fuerza_bruta_cuenta_lenta'),
               (6, 'multi_cuenta_ip_lenta'),
               (7, 'ip_rotacion_cuenta_lenta'),
               (8, 'ip_rotacion_cuenta'),
               (9, 'viaje_imposible')) AS v(orden, nombre)
 WHERE NOT EXISTS (SELECT 1 FROM tipo_alerta_fraude t
                    WHERE t.tipo_alerta_fraude_nombre = v.nombre)
 ORDER BY v.orden
ON CONFLICT DO NOTHING;

COMMENT ON TABLE tipo_alerta_fraude IS
    'Catalogo de senales de fraude de login: fuerza_bruta_ip, fuerza_bruta_cuenta, multi_cuenta_ip, ip_rotacion_cuenta (Redis, sincronas, camino del login); toma_cuenta, viaje_imposible (Elasticsearch, comparan contra el historial de la cuenta); fuerza_bruta_cuenta_lenta, multi_cuenta_ip_lenta, ip_rotacion_cuenta_lenta (Elasticsearch, retrospectivas cada 15 min sobre 24h). El backend fija sus ids (models/alerta-fraude.ts); la 016 y esta migracion lo comprueban';


-- ============================================================
-- El candado
-- ============================================================
DO $candado$
DECLARE
    r    record;
    v_id integer;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('toma_cuenta',               4),
            ('fuerza_bruta_cuenta_lenta', 5),
            ('multi_cuenta_ip_lenta',     6),
            ('ip_rotacion_cuenta_lenta',  7),
            ('ip_rotacion_cuenta',        8),
            ('viaje_imposible',           9)
        ) AS c(nombre, id_esperado)
    LOOP
        SELECT id_tipo_alerta_fraude INTO v_id
          FROM tipo_alerta_fraude
         WHERE tipo_alerta_fraude_nombre = r.nombre;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Falta % en tipo_alerta_fraude: el backend lo usa con el id %',
                r.nombre, r.id_esperado;
        END IF;

        IF v_id <> r.id_esperado THEN
            RAISE EXCEPTION '% en tipo_alerta_fraude tiene el id % y el backend espera el % (models/alerta-fraude.ts). Las alertas de este tipo se guardarian con el tipo cambiado',
                r.nombre, v_id, r.id_esperado;
        END IF;
    END LOOP;

    RAISE NOTICE 'tipo_alerta_fraude ampliado a 9 filas, ids 1-9 correctos';
END
$candado$;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT id_tipo_alerta_fraude, tipo_alerta_fraude_nombre
FROM tipo_alerta_fraude ORDER BY id_tipo_alerta_fraude;
