-- equivalentes.sql -- LAS SIETE PREGUNTAS DE LA FAMILIA B, CONTESTADAS POR POSTGRESQL
--
-- Para que existe: una consulta de grafo que nadie comparo contra la fuente de
-- verdad solo esta demostrada contra si misma. PostgreSQL es la verdad (el
-- grafo es una proyeccion), asi que cada consulta B.x de neo4j/consultas/ tiene
-- aqui su version en SQL, con la MISMA regla, y el arnes
-- (neo4j/correr_patrones.sh) exige que las dos devuelvan las mismas filas.
--
-- Cada linea que sale es "B.x|clave|metricas", el mismo formato que el arnes
-- arma con la salida de Cypher. Si difieren en una fila, el arnes dice cual.
--
-- LO QUE ESTE ARCHIVO ENSENA DE PASO: el largo. Lo que en Cypher es un patron
-- de una linea, aqui es un CTE recursivo con control de ciclos a mano (B.1,
-- B.4) o un self-join de `resena` con la condicion de tiempo (B.5, B.6). Es la
-- comparacion que pide la entrega entre el modelo de grafos y el relacional.
--
-- Los umbrales llegan como variables de psql (:nota_alta, :dias_cadena...) que
-- el arnes saca de neo4j/consultas/B0_parametros.cypher. Un solo lugar para los
-- numeros, las dos bases leen el mismo.
--
-- Corre DESPUES de etl/extraer_grafo.sql en la misma sesion, y reusa su
-- funcion pg_temp.clave_direccion(): la identidad de una casa se calcula una
-- sola vez en todo el proyecto.

SET TIME ZONE 'UTC';

-- La resena tal como la ve el grafo: la fecha es la de su comentario.
CREATE TEMP VIEW rv AS
SELECT r.id_resena AS id, r.id_usuario AS autor, r.id_usuario_vendedor AS vend,
       r.id_producto_mongo AS prod, r.calificacion AS nota, c.fecha_publicacion AS fecha
  FROM resena r JOIN comentario c USING (id_comentario);

-- La relacion cuenta -> cuenta, sin repetir, con cualquier nota.
CREATE TEMP VIEW arista AS SELECT DISTINCT autor AS a, vend AS b FROM rv;

CREATE FUNCTION pg_temp.b(v boolean) RETURNS text AS
$$ SELECT CASE WHEN v THEN 'TRUE' ELSE 'FALSE' END $$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pg_temp.clave(ids bigint[]) RETURNS text AS
$$ SELECT string_agg(x::text, '-' ORDER BY x) FROM (SELECT DISTINCT unnest(ids) AS x) s $$
LANGUAGE sql IMMUTABLE;

-- Hay camino de resenas de x a y en 1 a 3 pasos (el "*2..6" de B.1).
CREATE FUNCTION pg_temp.hay_vuelta(x bigint, y bigint) RETURNS boolean AS $$
    SELECT EXISTS (SELECT 1 FROM arista WHERE a = x AND b = y)
        OR EXISTS (SELECT 1 FROM arista e1 JOIN arista e2 ON e2.a = e1.b
                    WHERE e1.a = x AND e2.b = y)
        OR EXISTS (SELECT 1 FROM arista e1 JOIN arista e2 ON e2.a = e1.b
                                           JOIN arista e3 ON e3.a = e2.b
                    WHERE e1.a = x AND e3.b = y);
$$ LANGUAGE sql STABLE;


-- ============================================================
-- B.1 CADENA ABIERTA
-- ============================================================
WITH RECURSIVE camino AS (
    SELECT ARRAY[autor, vend] AS cuentas, ARRAY[id] AS resenas,
           fecha AS primera, fecha AS ultima
      FROM rv WHERE nota >= :nota_alta AND autor <> vend
    UNION ALL
    SELECT c.cuentas || r.vend, c.resenas || r.id,
           least(c.primera, r.fecha), greatest(c.ultima, r.fecha)
      FROM camino c JOIN rv r ON r.autor = c.cuentas[cardinality(c.cuentas)]
     WHERE r.nota >= :nota_alta
       AND NOT r.vend = ANY (c.cuentas)
       AND cardinality(c.cuentas) < 5
),
valido AS (
    SELECT * FROM camino
     WHERE cardinality(cuentas) >= 3
       AND extract(epoch FROM ultima - primera) <= :dias_cadena * 86400
       AND NOT pg_temp.hay_vuelta(cuentas[cardinality(cuentas)], cuentas[1])
),
por_secuencia AS (
    SELECT cuentas FROM valido GROUP BY cuentas
),
maximas AS (
    SELECT c.cuentas FROM por_secuencia c
     WHERE NOT EXISTS (
        SELECT 1 FROM por_secuencia o
         WHERE cardinality(o.cuentas) > cardinality(c.cuentas)
           AND ',' || array_to_string(o.cuentas, ',') || ','
               LIKE '%,' || array_to_string(c.cuentas, ',') || ',%')
)
SELECT 'B.1|' || pg_temp.clave(m.cuentas) || '|' || cardinality(m.cuentas) || '|' ||
       pg_temp.b(extract(epoch FROM max(u.fecha_creacion) - min(u.fecha_creacion))
                 <= :horas_alta_juntas * 3600) || '|' ||
       pg_temp.b(EXISTS (
           SELECT 1 FROM direcciones d1 JOIN direcciones d2
             ON pg_temp.clave_direccion(d1.pais, d1.departamento, d1.ciudad, d1.direccion_exacta)
              = pg_temp.clave_direccion(d2.pais, d2.departamento, d2.ciudad, d2.direccion_exacta)
            WHERE d1.id_usuario = m.cuentas[1]
              AND d2.id_usuario = m.cuentas[cardinality(m.cuentas)]
              AND btrim(coalesce(d1.direccion_exacta, '')) <> ''))
  FROM maximas m JOIN usuarios u ON u.id_usuario = ANY (m.cuentas)
 GROUP BY m.cuentas;


-- ============================================================
-- B.2 SATELITES
-- ============================================================
WITH por_autor AS (
    SELECT autor, min(vend) AS vend, count(DISTINCT vend) AS vendedores,
           bool_and(nota >= :nota_alta) AS altas, min(fecha) AS primera, count(*) AS n
      FROM rv GROUP BY autor
),
satelite AS (
    SELECT p.* FROM por_autor p JOIN usuarios u ON u.id_usuario = p.autor
     WHERE p.vendedores = 1 AND p.altas
       AND p.primera >= u.fecha_creacion
       AND extract(epoch FROM p.primera - u.fecha_creacion) <= :dias_cuenta_desechable * 86400
)
SELECT 'B.2|' || pg_temp.clave(array_agg(autor) || vend) || '|' || count(*)
  FROM satelite GROUP BY vend HAVING count(*) >= :min_satelites;


-- ============================================================
-- B.3 PERSISTENTE
-- ============================================================
WITH par AS (
    SELECT autor, vend, count(*) AS n,
           count(DISTINCT extract(year FROM fecha) * 100 + extract(month FROM fecha)) AS meses
      FROM rv GROUP BY autor, vend
    HAVING bool_and(nota >= :nota_alta)
)
SELECT 'B.3|' || ua.correo_electronico || '|' || uv.correo_electronico || '|' || p.meses
  FROM par p
  JOIN usuarios ua ON ua.id_usuario = p.autor
  JOIN usuarios uv ON uv.id_usuario = p.vend
 WHERE p.meses >= :min_meses
   AND p.n::numeric / (SELECT count(*) FROM rv WHERE autor = p.autor) >= :min_exclusividad;


-- ============================================================
-- B.4 ANILLO EN EL TIEMPO
-- ============================================================
-- La ronda en orden: probar cada arranque y, tramo por tramo, quedarse con la
-- primera resena posterior a la anterior. Es el mismo algoritmo que el reduce
-- de Cypher, escrito como funcion porque en SQL no hay reduce sobre listas.
CREATE FUNCTION pg_temp.en_orden(ciclo bigint[]) RETURNS boolean AS $$
DECLARE
    n int := cardinality(ciclo);
    t timestamptz;
    k int; j int; i int;
BEGIN
    FOR k IN 0 .. n - 1 LOOP
        t := '-infinity';
        FOR j IN 0 .. n - 1 LOOP
            i := (k + j) % n;
            SELECT min(fecha) INTO t FROM rv
             WHERE autor = ciclo[i + 1] AND vend = ciclo[(i + 1) % n + 1] AND fecha > t;
            EXIT WHEN t IS NULL;
        END LOOP;
        IF t IS NOT NULL THEN RETURN true; END IF;
    END LOOP;
    RETURN false;
END $$ LANGUAGE plpgsql STABLE;

WITH RECURSIVE ciclo AS (
    -- Se arranca en la cuenta de id menor del anillo (el mismo filtro de
    -- rotacion que A.1) y solo se avanza a cuentas de id mayor que ella.
    SELECT ARRAY[a, b] AS cuentas FROM arista WHERE b > a
    UNION ALL
    SELECT c.cuentas || e.b FROM ciclo c
      JOIN arista e ON e.a = c.cuentas[cardinality(c.cuentas)]
     WHERE e.b > c.cuentas[1] AND NOT e.b = ANY (c.cuentas) AND cardinality(c.cuentas) < 4
),
cerrado AS (
    SELECT c.cuentas FROM ciclo c
     WHERE EXISTS (SELECT 1 FROM arista e
                    WHERE e.a = c.cuentas[cardinality(c.cuentas)] AND e.b = c.cuentas[1])
),
tramo AS (
    SELECT c.cuentas, i, r.id, r.fecha
      FROM cerrado c
     CROSS JOIN generate_series(1, cardinality(c.cuentas)) AS i
      JOIN rv r ON r.autor = c.cuentas[i]
               AND r.vend = c.cuentas[i % cardinality(c.cuentas) + 1]
),
por_tramo AS (
    SELECT cuentas, i, count(*) AS n,
           bool_or(fecha >= now() - :dias_ventana_detector * interval '1 day') AS reciente
      FROM tramo GROUP BY cuentas, i
),
olas AS (
    SELECT cuentas, 1 + count(*) FILTER (
               WHERE extract(epoch FROM fecha - anterior) > :dias_entre_olas * 86400) AS olas
      FROM (SELECT cuentas, fecha, lag(fecha) OVER (PARTITION BY cuentas ORDER BY fecha) AS anterior
              FROM tramo) s
     GROUP BY cuentas
)
SELECT 'B.4|' || (SELECT string_agg(u.correo_electronico, ',' ORDER BY k)
                    FROM unnest(p.cuentas) WITH ORDINALITY AS x(id, k)
                    JOIN usuarios u ON u.id_usuario = x.id)
       || '|' || min(p.n) || '|' || o.olas || '|' || pg_temp.b(bool_and(p.reciente))
       || '|' || pg_temp.b(pg_temp.en_orden(p.cuentas))
  FROM por_tramo p JOIN olas o USING (cuentas)
 GROUP BY p.cuentas, o.olas;


-- ============================================================
-- B.5 FAVOR DEVUELTO
-- ============================================================
SELECT 'B.5|' || least(ra.autor, ra.vend) || '-' || greatest(ra.autor, ra.vend)
       || '|' || count(*) || '|' || pg_temp.b(bool_or(ra.prod = rb.prod))
  FROM rv ra JOIN rv rb ON rb.autor = ra.vend AND rb.vend = ra.autor
 WHERE rb.fecha >= ra.fecha
   AND extract(epoch FROM rb.fecha - ra.fecha) <= :horas_devolucion * 3600
   AND ra.nota >= :nota_alta AND rb.nota >= :nota_alta
 GROUP BY least(ra.autor, ra.vend), greatest(ra.autor, ra.vend);


-- ============================================================
-- B.6 COORDINADOS
-- ============================================================
SELECT 'B.6|' || ra.autor || '-' || rb.autor || '|' || count(*)
  FROM rv ra JOIN rv rb ON rb.prod = ra.prod AND rb.vend = ra.vend AND rb.autor > ra.autor
 WHERE abs(extract(epoch FROM ra.fecha - rb.fecha)) <= :horas_sincronia * 3600
 GROUP BY ra.autor, rb.autor
HAVING count(*) >= :min_coincidencias;


-- ============================================================
-- B.7 REPUTACION EXPRES
-- ============================================================
SELECT 'B.7|' || uv.correo_electronico || '|' || count(*)
  FROM rv r
  JOIN usuarios ua ON ua.id_usuario = r.autor
  JOIN usuarios uv ON uv.id_usuario = r.vend
 WHERE r.nota >= :nota_alta
   AND r.fecha >= ua.fecha_creacion
   AND extract(epoch FROM r.fecha - ua.fecha_creacion) <= :horas_cuenta_nueva * 3600
   AND r.fecha >= uv.fecha_creacion
   AND extract(epoch FROM r.fecha - uv.fecha_creacion) <= :dias_vendedor_nuevo * 86400
 GROUP BY uv.correo_electronico;
