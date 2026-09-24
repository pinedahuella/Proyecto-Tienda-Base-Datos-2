// B3_persistente.cypher -- LA CUENTA QUE CALIFICA AL MISMO VENDEDOR MES TRAS MES
//
// QUE BUSCA: un autor que le pone nota alta al mismo vendedor en al menos
// $min_meses meses distintos, y que ademas dedica a ese vendedor la mayor parte
// de lo que escribe (exclusividad >= $min_exclusividad).
//
// POR QUE ESA SENAL SIGNIFICA ALGO: A.3 busca la rafaga, muchas notas en pocos
// dias. Quien ya sabe que la rafaga se ve hace lo contrario: una nota cada
// tantas semanas, siempre al mismo, para que ninguna ventana corta lo junte.
// Esta consulta mira la historia entera y no una ventana, que es lo unico que
// lo alcanza.
//
// POR QUE NO ES UNA ACUSACION, Y EL NUMERO QUE LO SEPARA: el cliente fiel se
// ve IGUAL en el tiempo. Medido en los datos reales: comprador.sur califico a
// ventas.sur 10 veces en 5 meses, todas altas, y es el 63 % de lo que ese
// vendedor recibio. Por tiempo y por nota seria el primer sospechoso. Lo que lo
// separa es la exclusividad: esas 10 son solo el 23 % de lo que el escribe,
// porque le compra a cinco vendedores. Un inflador trabaja para uno.
//
//   exclusividad  = resenas de A a B / todas las que escribio A
//   dependencia   = resenas de A a B / todas las que recibio B
//
// La exclusividad filtra; la dependencia se informa para ordenar (cuanto de la
// reputacion de B se le cae si A resulta falsa).
//
// `cada_cuantos_dias` y `regularidad`: una persona compra cuando necesita; un
// guion califica cada siete dias exactos. `regularidad` es la desviacion de los
// intervalos entre resenas sobre su promedio: cerca de 0 es un reloj.
RETURN '=== B.3  PERSISTENTE (el mismo vendedor, mes tras mes) ===' AS consulta;

MATCH (a:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(b:Usuario)
WITH a, b, r ORDER BY r.fecha
WITH a, b, collect(r) AS rs
WHERE ALL (x IN rs WHERE x.calificacion >= $nota_alta)
WITH a, b, rs,
     reduce(ms = [], x IN rs |
       CASE WHEN (x.fecha.year * 100 + x.fecha.month) IN ms THEN ms
            ELSE ms + (x.fecha.year * 100 + x.fecha.month) END) AS meses
WHERE size(meses) >= $min_meses

WITH a, b, rs, meses,
     1.0 * size(rs) / COUNT { (a)-[:ESCRIBIO]->(:Resena) }  AS exclusividad,
     1.0 * size(rs) / COUNT { (b)<-[:CALIFICA_A]-(:Resena) } AS dependencia
WHERE exclusividad >= $min_exclusividad

WITH a, b, rs, meses, exclusividad, dependencia,
     [i IN range(1, size(rs) - 1) |
        (rs[i].fecha.epochSeconds - rs[i - 1].fecha.epochSeconds) / 86400.0] AS intervalos
WITH a, b, rs, meses, exclusividad, dependencia, intervalos,
     reduce(s = 0.0, x IN intervalos | s + x) / size(intervalos) AS media
WITH a, b, rs, meses, exclusividad, dependencia, media,
     sqrt(reduce(s = 0.0, x IN intervalos | s + (x - media) ^ 2) / size(intervalos)) AS desviacion
RETURN CASE WHEN a.id < b.id THEN toString(a.id) + '-' + toString(b.id)
            ELSE toString(b.id) + '-' + toString(a.id) END AS clave,
       a.correo                    AS autor,
       b.correo                    AS vendedor,
       size(rs)                    AS resenas_totales,
       [x IN rs | x.id]            AS resenas,
       size(meses)                 AS meses_distintos,
       round(exclusividad, 2)      AS exclusividad,
       round(dependencia, 2)       AS dependencia,
       round(media, 1)             AS cada_cuantos_dias,
       round(desviacion / media, 2) AS regularidad,
       // Si B tambien le devuelve notas a A, no es un fan: es un trato.
       EXISTS { (b)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(a) } AS es_mutuo
ORDER BY dependencia DESC, meses_distintos DESC;
