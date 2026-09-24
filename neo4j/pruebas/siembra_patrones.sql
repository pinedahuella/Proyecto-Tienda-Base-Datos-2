-- siembra_patrones.sql -- lo que las consultas B.1 a B.7 tienen que encontrar, y lo que NO
--
-- Se siembra en POSTGRESQL, no en Neo4j, y dentro de una transaccion que el
-- arnes deshace con ROLLBACK. Asi las dos bases ven EXACTAMENTE los mismos
-- datos: el extractor del grafo (etl/extraer_grafo.sql) corre en la misma
-- sesion, antes del ROLLBACK, y ve estas filas como si fueran de verdad; y las
-- consultas SQL equivalentes (equivalentes.sql) tambien. Si el Cypher y el SQL
-- dicen lo mismo sobre lo mismo, el Cypher mide lo que dice medir.
--
-- La siembra vieja de neo4j/consultas/siembra.cypher va directo al grafo, y por
-- eso no se puede comparar contra PostgreSQL: alla no existe.
--
-- IDS NEGATIVOS, igual que en siembra.cypher: los bigserial nunca dan un
-- negativo, asi que no chocan con nada real, y despues del ROLLBACK el arnes
-- borra del grafo todo lo que tenga id < 0. No se consume ninguna secuencia.
--
-- LAS FECHAS VAN RELATIVAS A now(), que dentro de una transaccion es un solo
-- instante. B.4 compara contra "hoy menos 60 dias"; con fechas fijas la prueba
-- dejaria de pasar sola dentro de dos meses.
--
-- Cada escenario tiene su CONTROL, un caso que se parece y NO tiene que salir.
-- Una consulta que encuentra lo sembrado pero tambien el control no esta
-- detectando: esta contando.

SET TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.cuenta(p_id bigint, p_nombre text, p_alta timestamptz)
RETURNS void AS $$
    INSERT INTO usuarios (id_usuario, correo_electronico, usuario, nombre, apellido,
                          contrasena_hash, fecha_creacion, id_rol_usuario, id_estado_usuario)
    VALUES (p_id, p_nombre || '@patrones.prueba', p_nombre, 'Patron', p_nombre,
            'no-es-un-hash', p_alta, 2, 1);
$$ LANGUAGE sql;

-- La resena y su comentario llevan el mismo id negativo. La fecha de la resena
-- es la del comentario (asi la lee el extractor del grafo).
CREATE FUNCTION pg_temp.resena(p_id bigint, p_autor bigint, p_vendedor bigint,
                               p_producto bigint, p_nota int, p_fecha timestamptz)
RETURNS void AS $$
    INSERT INTO comentario (id_comentario, id_usuario, comentario, fecha_publicacion)
    VALUES (p_id, p_autor, 'Resena sembrada por neo4j/pruebas/siembra_patrones.sql', p_fecha);
    INSERT INTO resena (id_resena, id_usuario, id_usuario_vendedor, id_producto_mongo,
                        calificacion, id_comentario)
    VALUES (p_id, p_autor, p_vendedor, p_producto, p_nota, p_id);
$$ LANGUAGE sql;

CREATE FUNCTION pg_temp.casa(p_usuario bigint, p_exacta text)
RETURNS void AS $$
    INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, direccion_exacta,
                             id_estado_direccion)
    VALUES (p_usuario, 'Guatemala', 'Guatemala', 'Prueba Patrones', p_exacta, 1);
$$ LANGUAGE sql;


-- ============================================================
-- LAS CUENTAS, TODAS PRIMERO
-- ============================================================
-- Van juntas y antes que cualquier resena porque varios controles cruzan de
-- escenario (el cliente fiel de S3 tambien le compra a la granja de S2 y a la
-- tienda de S6), y la llave foranea de `resena` exige que el vendedor ya
-- exista. El escenario al que pertenece cada una lo dice su nombre.
SELECT pg_temp.cuenta(-201, 'cadena1', now() - interval '40 days');
SELECT pg_temp.cuenta(-202, 'cadena2', now() - interval '40 days');
SELECT pg_temp.cuenta(-203, 'cadena3', now() - interval '40 days');
SELECT pg_temp.cuenta(-204, 'cadena4', now() - interval '40 days');
SELECT pg_temp.cuenta(-205, 'nota1', now() - interval '40 days');
SELECT pg_temp.cuenta(-206, 'nota2', now() - interval '40 days');
SELECT pg_temp.cuenta(-207, 'nota3', now() - interval '40 days');
SELECT pg_temp.cuenta(-208, 'lenta1', now() - interval '200 days');
SELECT pg_temp.cuenta(-209, 'lenta2', now() - interval '200 days');
SELECT pg_temp.cuenta(-210, 'lenta3', now() - interval '200 days');
SELECT pg_temp.cuenta(-220, 'granja0', now() - interval '90 days');
SELECT pg_temp.cuenta(-221, 'satelite1', now() - interval '33 days');
SELECT pg_temp.cuenta(-222, 'satelite2', now() - interval '32 days');
SELECT pg_temp.cuenta(-223, 'satelite3', now() - interval '31 days');
SELECT pg_temp.cuenta(-224, 'satelite4', now() - interval '30 days');
SELECT pg_temp.cuenta(-225, 'noesatelite', now() - interval '31 days');
SELECT pg_temp.cuenta(-226, 'granjachica', now() - interval '90 days');
SELECT pg_temp.cuenta(-227, 'chico1', now() - interval '12 days');
SELECT pg_temp.cuenta(-228, 'chico2', now() - interval '12 days');
SELECT pg_temp.cuenta(-230, 'constante0', now() - interval '400 days');
SELECT pg_temp.cuenta(-231, 'constante1', now() - interval '400 days');
SELECT pg_temp.cuenta(-232, 'fiel', now() - interval '400 days');
SELECT pg_temp.cuenta(-241, 'recurrente1', now() - interval '300 days');
SELECT pg_temp.cuenta(-242, 'recurrente2', now() - interval '300 days');
SELECT pg_temp.cuenta(-243, 'recurrente3', now() - interval '300 days');
SELECT pg_temp.cuenta(-244, 'lento1', now() - interval '300 days');
SELECT pg_temp.cuenta(-245, 'lento2', now() - interval '300 days');
SELECT pg_temp.cuenta(-246, 'lento3', now() - interval '300 days');
SELECT pg_temp.cuenta(-251, 'favor1', now() - interval '200 days');
SELECT pg_temp.cuenta(-252, 'favor2', now() - interval '200 days');
SELECT pg_temp.cuenta(-253, 'tarde1', now() - interval '200 days');
SELECT pg_temp.cuenta(-254, 'tarde2', now() - interval '200 days');
SELECT pg_temp.cuenta(-260, 'coord0', now() - interval '500 days');
SELECT pg_temp.cuenta(-261, 'coord1', now() - interval '500 days');
SELECT pg_temp.cuenta(-262, 'coord2', now() - interval '500 days');
SELECT pg_temp.cuenta(-263, 'coord3', now() - interval '500 days');
SELECT pg_temp.cuenta(-270, 'expres0', now() - interval '2 days');
SELECT pg_temp.cuenta(-271, 'expres1', now() - interval '2 days' + interval '1 hour');
SELECT pg_temp.cuenta(-272, 'expres2', now() - interval '2 days' + interval '1 hour');
SELECT pg_temp.cuenta(-273, 'nuevo', now() - interval '1 day');
SELECT pg_temp.cuenta(-274, 'imposible', now() - interval '1 day');


-- ============================================================
-- S1  B.1 CADENA ABIERTA: c1 -> c2 -> c3 -> c4, sin vuelta
-- ============================================================
-- Cuatro cuentas nacidas el mismo dia, notas de 5 en seis dias, y los dos
-- extremos viven en la misma casa (escrita distinto, para que la cierre la
-- normalizacion del ETL y no una coincidencia de texto).
-- Tiene que salir UNA fila de 4 cuentas: ni c1-c2-c3 ni c2-c3-c4 por separado.
SELECT pg_temp.resena(-2001, -201, -202, -951, 5, now() - interval '20 days');
SELECT pg_temp.resena(-2002, -202, -203, -952, 5, now() - interval '17 days');
SELECT pg_temp.resena(-2003, -203, -204, -953, 5, now() - interval '14 days');
SELECT pg_temp.casa(-201, 'Calle de la Cadena 7');
SELECT pg_temp.casa(-204, 'calle de la  cadena 7');

-- CONTROL S1a: la misma forma con un 3 en medio. No sale (nota baja).
SELECT pg_temp.resena(-2004, -205, -206, -951, 5, now() - interval '20 days');
SELECT pg_temp.resena(-2005, -206, -207, -952, 3, now() - interval '19 days');

-- CONTROL S1b: cadena de tres con 60 dias entre sus notas. No sale (lenta).
SELECT pg_temp.resena(-2006, -208, -209, -951, 5, now() - interval '100 days');
SELECT pg_temp.resena(-2007, -209, -210, -952, 5, now() - interval '40 days');


-- ============================================================
-- S2  B.2 GRANJA: cuatro satelites alrededor de g0
-- ============================================================
-- Cada satelite nace tres dias antes de su primera resena (desechable, pero
-- mas de 24 horas: asi NO dispara B.7 y los escenarios no se pisan).
SELECT pg_temp.resena(-2020, -221, -220, -954, 5, now() - interval '30 days');
SELECT pg_temp.resena(-2021, -222, -220, -954, 5, now() - interval '29 days');
SELECT pg_temp.resena(-2022, -223, -220, -954, 5, now() - interval '28 days');
SELECT pg_temp.resena(-2023, -224, -220, -954, 5, now() - interval '27 days');
SELECT pg_temp.resena(-2024, -224, -220, -955, 4, now() - interval '26 days');

-- CONTROL S2a: una quinta cuenta nueva que tambien califica a g0 pero ademas
-- a otro vendedor (-230, de S3). No es satelite: tiene otra vida.
SELECT pg_temp.resena(-2025, -225, -220, -955, 5, now() - interval '28 days');

-- CONTROL S2b: otro vendedor con solo DOS satelites. Por debajo del minimo.
SELECT pg_temp.resena(-2026, -227, -226, -954, 5, now() - interval '10 days');
SELECT pg_temp.resena(-2027, -228, -226, -954, 5, now() - interval '10 days');


-- ============================================================
-- S3  B.3 PERSISTENTE: p1 califica a p0 una vez al mes, cinco meses
-- ============================================================
-- Cada 30 dias exactos: `regularidad` tiene que dar 0, un reloj. p1 escribe
-- ademas una sola resena a otro vendedor: exclusividad 5 de 6.
SELECT pg_temp.resena(-2028, -225, -230, -967, 5, now() - interval '27 days');
SELECT pg_temp.resena(-2030, -231, -230, -961, 5, now() - interval '150 days');
SELECT pg_temp.resena(-2031, -231, -230, -962, 5, now() - interval '120 days');
SELECT pg_temp.resena(-2032, -231, -230, -963, 5, now() - interval '90 days');
SELECT pg_temp.resena(-2033, -231, -230, -964, 5, now() - interval '60 days');
SELECT pg_temp.resena(-2034, -231, -230, -965, 5, now() - interval '30 days');
SELECT pg_temp.resena(-2035, -231, -220, -966, 5, now() - interval '45 days');

-- CONTROL S3a: el cliente fiel. Califica a p0 en cuatro meses, pero tambien a
-- cinco vendedores mas: 4 de 10 (0.4). No sale.
SELECT pg_temp.resena(-2040, -232, -230, -961, 5, now() - interval '140 days');
SELECT pg_temp.resena(-2041, -232, -230, -962, 5, now() - interval '110 days');
SELECT pg_temp.resena(-2042, -232, -230, -963, 4, now() - interval '80 days');
SELECT pg_temp.resena(-2043, -232, -230, -964, 5, now() - interval '50 days');
-- Las otras seis van a vendedores que NO escriben resenas. La primera version
-- las mandaba a cuentas de S1, y fiel -> lenta1 -> lenta2 formaba una cadena
-- abierta de verdad que nadie habia sembrado a proposito: un control que
-- dispara otro escenario ya no controla nada.
SELECT pg_temp.resena(-2044, -232, -220, -961, 5, now() - interval '100 days');
SELECT pg_temp.resena(-2045, -232, -226, -961, 5, now() - interval '100 days');
SELECT pg_temp.resena(-2046, -232, -260, -961, 5, now() - interval '100 days');
SELECT pg_temp.resena(-2047, -232, -220, -962, 4, now() - interval '100 days');
SELECT pg_temp.resena(-2048, -232, -226, -962, 5, now() - interval '100 days');
SELECT pg_temp.resena(-2049, -232, -260, -962, 5, now() - interval '70 days');


-- ============================================================
-- S4  B.4 ANILLO EN EL TIEMPO
-- ============================================================
-- S4a EL RECURRENTE: r1 -> r2 -> r3 -> r1 da tres vueltas, en tres olas
-- separadas por meses. La ultima es reciente: el detector lo ve.
SELECT pg_temp.resena(-2101, -241, -242, -971, 5, now() - interval '150 days');
SELECT pg_temp.resena(-2102, -242, -243, -971, 5, now() - interval '150 days' + interval '1 hour');
SELECT pg_temp.resena(-2103, -243, -241, -971, 5, now() - interval '150 days' + interval '2 hours');
SELECT pg_temp.resena(-2104, -241, -242, -972, 5, now() - interval '90 days');
SELECT pg_temp.resena(-2105, -242, -243, -972, 5, now() - interval '90 days' + interval '1 hour');
SELECT pg_temp.resena(-2106, -243, -241, -972, 5, now() - interval '90 days' + interval '2 hours');
SELECT pg_temp.resena(-2107, -241, -242, -973, 5, now() - interval '10 days');
SELECT pg_temp.resena(-2108, -242, -243, -973, 5, now() - interval '10 days' + interval '1 hour');
SELECT pg_temp.resena(-2109, -243, -241, -973, 5, now() - interval '10 days' + interval '2 hours');

-- S4b EL LENTO: s1 -> s2 -> s3 -> s1 tarda 95 dias en cerrarse, y ademas NO
-- sigue el orden del circulo desde ningun arranque: s2 -> s3 se escribe
-- primero, s1 -> s2 despues y s3 -> s1 al final. (La primera version ponia
-- s3 -> s1 primero, y eso SI es una ronda, la que arranca en s3: la consulta
-- tenia razon y el comentario no.) Dos de sus tres tramos tienen mas de 60
-- dias: el detector del backend no lo ve.
SELECT pg_temp.resena(-2111, -244, -245, -974, 5, now() - interval '70 days');
SELECT pg_temp.resena(-2112, -245, -246, -974, 5, now() - interval '100 days');
SELECT pg_temp.resena(-2113, -246, -244, -974, 5, now() - interval '5 days');


-- ============================================================
-- S5  B.5 FAVOR DEVUELTO: f1 califica a f2 y cinco horas despues f2 a f1,
-- sobre productos distintos (asi A.2 no lo ve y B.5 si)
-- ============================================================
SELECT pg_temp.resena(-2201, -251, -252, -981, 5, now() - interval '8 days');
SELECT pg_temp.resena(-2202, -252, -251, -982, 5, now() - interval '8 days' + interval '5 hours');

-- CONTROL S5a: el mismo intercambio con diez dias de espera. No sale.
SELECT pg_temp.resena(-2203, -253, -254, -981, 5, now() - interval '30 days');
SELECT pg_temp.resena(-2204, -254, -253, -982, 5, now() - interval '20 days');


-- ============================================================
-- S6  B.6 COORDINADOS: k1 y k2 califican los mismos tres productos de k0,
-- cada vez con menos de una hora de diferencia
-- ============================================================
-- Cuentas viejas a proposito: asi no son satelites nuevos (B.2) ni expres
-- (B.7), y lo unico que las une es el reloj.
-- Las tres coincidencias caben en 20 dias a proposito: asi no pueden caer en
-- tres meses distintos sea cual sea el dia en que se corra, y B.3 no las toma.
SELECT pg_temp.resena(-2301, -261, -260, -991, 5, now() - interval '25 days');
SELECT pg_temp.resena(-2302, -262, -260, -991, 5, now() - interval '25 days' + interval '20 minutes');
SELECT pg_temp.resena(-2303, -261, -260, -992, 5, now() - interval '15 days');
SELECT pg_temp.resena(-2304, -262, -260, -992, 5, now() - interval '15 days' + interval '40 minutes');
SELECT pg_temp.resena(-2305, -261, -260, -993, 4, now() - interval '5 days');
SELECT pg_temp.resena(-2306, -262, -260, -993, 5, now() - interval '5 days' + interval '10 minutes');

-- CONTROL S6a: k3 califica los MISMOS tres productos del mismo vendedor, pero
-- una semana despues cada vez. Mismo objetivo, otro momento: no sale.
SELECT pg_temp.resena(-2307, -263, -260, -991, 5, now() - interval '32 days');
SELECT pg_temp.resena(-2308, -263, -260, -992, 5, now() - interval '22 days');
SELECT pg_temp.resena(-2309, -263, -260, -993, 5, now() - interval '12 days');


-- ============================================================
-- S7  B.7 REPUTACION EXPRES: e0 abre la cuenta y en su primer dia recibe dos
-- notas de 5 de cuentas con minutos de vida
-- ============================================================
SELECT pg_temp.resena(-2401, -271, -270, -995, 5, now() - interval '2 days' + interval '1 hour 3 minutes');
SELECT pg_temp.resena(-2402, -272, -270, -995, 5, now() - interval '2 days' + interval '1 hour 9 minutes');

-- CONTROL S7a: una cuenta nueva que califica a un vendedor VIEJO (k0, de S6).
-- Es un cliente nuevo de una tienda establecida: no sale.
SELECT pg_temp.resena(-2403, -273, -260, -995, 5, now() - interval '1 day' + interval '30 minutes');

-- CONTROL S7b: una resena fechada ANTES del alta de su autor. Es el dato
-- imposible que trae la semilla del proyecto (86 resenas asi, ver B.7), aqui
-- aislado: el vendedor es nuevo y la resena cae dentro de su primera semana, asi
-- que el unico freno es exigir que la resena sea posterior al alta del autor.
-- Existe porque se saboteo B.7 quitando ese freno y el arnes siguio en verde:
-- en los datos reales el alta del VENDEDOR tapaba el error. Con este control,
-- sin el freno expres0 pasa de 2 resenas a 3, y granja de satelites de expres0
-- (B.2) pasa de 2 cuentas a 3, que es el minimo.
SELECT pg_temp.resena(-2404, -274, -270, -996, 5, now() - interval '1 day 12 hours');
