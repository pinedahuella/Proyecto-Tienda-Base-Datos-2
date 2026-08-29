// A3_rafaga.cypher -- MUCHAS NOTAS DE LA MISMA CUENTA A LA MISMA CUENTA, JUNTAS
//
// QUE BUSCA: una cuenta que califica a otra tres o mas veces dentro de una
// VENTANA de tres dias. No pide que haya circulo: es la version de una sola
// direccion.
//
// POR QUE ESA SENAL SIGNIFICA ALGO: la restriccion UNIQUE de PostgreSQL impide
// resenar dos veces al mismo vendedor por el mismo producto, asi que tres
// resenas de A hacia B son tres PRODUCTOS distintos comprados al mismo
// vendedor. Comprarle tres cosas distintas a la misma persona en tres dias y
// sentarse a resenar las tres es posible; que ademas todas lleven cinco
// estrellas empieza a parecer una tarea, no una compra.
//
//
// LA VERSION ANTERIOR MEDIA OTRA COSA, y hay que contarlo porque el error es
// facil de volver a escribir
// ============================================================
// Decia esto:
//
//     WITH a, b, count(r) AS cuantas,
//          min(r.fecha).epochSeconds AS primera,
//          max(r.fecha).epochSeconds AS ultima
//     WHERE cuantas >= 3 AND (ultima - primera) <= 3 * 86400
//
// O sea: el lapso entre la PRIMERA y la ULTIMA resena de TODA la historia del
// par. Eso no es una ventana, es un rango, y tiene la propiedad al reves de la
// que hace falta: agregar mas evidencia APAGA la alerta.
//
// Medido, no supuesto. Se sembro el par raf.autor -> raf.vend con tres notas de
// 5 el 2026-01-01 a las 09:00, 09:10 y 09:20 -- una rafaga de manual -- y una
// cuarta resena suelta cinco meses despues. La consulta vieja devolvio CERO
// filas. Se borro UNICAMENTE esa cuarta resena y la MISMA consulta, sin
// tocarle una coma, devolvio la rafaga. Cualquier anillo que ademas de la
// rafaga tenga una compra legitima al mismo vendedor queda invisible.
//
// Y en los datos reales era todavia peor: los pares establecidos tienen de 8 a
// 11 resenas repartidas en 70 a 140 dias, asi que la consulta vieja NO PODIA
// devolver una sola fila para ningun par con historia, tuviera la rafaga que
// tuviera. Su "0 filas" no significaba "no hay rafagas", significaba "ningun
// par tiene toda su historia dentro de 72 horas".
//
//
// COMO SE BUSCA LA VENTANA
// ============================================================
// El ORDER BY va ANTES del collect, no despues: en Cypher, ordenar las filas
// antes de agregarlas es lo que hace que la lista salga ordenada, y todo lo de
// abajo -- el salto de dos posiciones, el primero y el ultimo de la rafaga --
// depende de ese orden.
//
// range(0, size(historial) - 3) recorre cada resena que PUEDE ser el arranque
// de una rafaga: la comparacion es contra la que esta DOS posiciones despues,
// porque tres resenas dentro de la ventana son las posiciones i, i+1 e i+2. Si
// esa distancia cabe en 72 horas, hay rafaga, sin importar que haya antes o
// despues.
//
// Despues cada ventana se expande a todas las resenas que caen dentro de sus 72
// horas (pueden ser mas de tres) y por cada par se conserva la MAS GRANDE. Un
// par se lista una vez, con su peor rafaga.
RETURN '=== A.3  RAFAGA DE NOTAS EN POCOS DIAS ===' AS consulta;

MATCH (a:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(b:Usuario)
WITH a, b, r ORDER BY r.fecha
WITH a, b, collect(r) AS historial
WHERE size(historial) >= 3

UNWIND range(0, size(historial) - 3) AS i
WITH a, b, historial, i
WHERE historial[i + 2].fecha.epochSeconds - historial[i].fecha.epochSeconds <= 3 * 86400

WITH a, b,
     [x IN historial
      WHERE x.fecha.epochSeconds >= historial[i].fecha.epochSeconds
        AND x.fecha.epochSeconds - historial[i].fecha.epochSeconds <= 3 * 86400] AS rafaga
ORDER BY size(rafaga) DESC
WITH a, b, collect(rafaga)[0] AS rafaga

RETURN a.correo AS califica,
       b.correo AS al_vendedor,
       size(rafaga) AS cuantas,
       // La media se calcula con reduce y no con avg() porque a esta altura la
       // rafaga ya es una LISTA dentro de una fila, no un grupo de filas: avg()
       // agrega filas y aqui no hay nada que agregar.
       round(reduce(s = 0.0, x IN rafaga | s + x.calificacion) / size(rafaga), 2) AS nota_media,
       [x IN rafaga | x.calificacion] AS notas,
       // Se mide con epochSeconds y no con duration.between porque el resultado
       // tiene que ser un numero comparable en el ORDER BY. Una duracion de
       // Neo4j lleva meses, dias y segundos por separado y dos duraciones no se
       // ordenan solas.
       (rafaga[-1].fecha.epochSeconds - rafaga[0].fecha.epochSeconds) / 3600 AS horas_de_la_rafaga
ORDER BY horas_de_la_rafaga ASC, cuantas DESC;
