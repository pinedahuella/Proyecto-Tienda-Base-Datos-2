// B5_favor_devuelto.cypher -- "YO TE CALIFICO, TU ME CALIFICAS", CON RELOJ
//
// QUE BUSCA: A le pone nota alta a B y B le devuelve nota alta a A en menos
// de $horas_devolucion horas.
//
// POR QUE ESA SENAL SIGNIFICA ALGO: A.2 pide que el intercambio sea sobre el
// MISMO producto, que es la version mas fuerte pero tambien la mas facil de
// esquivar: basta con calificar productos distintos. Esta consulta no mira el
// producto, mira el reloj. Para que B califique a A, B tiene que haberle
// comprado a A, recibido el paquete y sentarse a escribir. Que eso pase horas
// despues de que A lo califico no es una compra, es una respuesta.
//
// POR QUE NO ES UNA ACUSACION: dos vendedores que se compran entre si de verdad
// pueden calificarse la misma semana. Por eso se informan las horas exactas y
// cuantas veces paso; una devolucion en 2 segundos no admite otra lectura, una
// en 70 horas si.
//
// Se lista el PAR una vez (clave ordenada) y se dice quien empezo el primer
// intercambio, que es quien pidio el favor.
RETURN '=== B.5  FAVOR DEVUELTO (reciprocidad rapida) ===' AS consulta;

MATCH (a:Usuario)-[:ESCRIBIO]->(ra:Resena)-[:CALIFICA_A]->(b:Usuario),
      (b)-[:ESCRIBIO]->(rb:Resena)-[:CALIFICA_A]->(a)
WHERE rb.fecha >= ra.fecha
  AND rb.fecha.epochSeconds - ra.fecha.epochSeconds <= $horas_devolucion * 3600
  AND ra.calificacion >= $nota_alta
  AND rb.calificacion >= $nota_alta
WITH a, b, ra, rb,
     (rb.fecha.epochSeconds - ra.fecha.epochSeconds) AS segundos,
     EXISTS { (ra)-[:SOBRE]->(:Producto)<-[:SOBRE]-(rb) } AS mismo_producto
ORDER BY ra.fecha
WITH CASE WHEN a.id < b.id THEN a ELSE b END AS x,
     CASE WHEN a.id < b.id THEN b ELSE a END AS y,
     collect({quien: a.correo, ida: ra.id, vuelta: rb.id,
              segundos: segundos, mismo: mismo_producto}) AS favores
RETURN toString(x.id) + '-' + toString(y.id) AS clave,
       x.correo AS cuenta_a,
       y.correo AS cuenta_b,
       favores[0].quien AS empezo,
       size(favores) AS veces,
       reduce(t = [], f IN favores | t + [id IN [f.ida, f.vuelta] WHERE NOT id IN t]) AS resenas,
       round(reduce(m = favores[0].segundos, f IN favores |
         CASE WHEN f.segundos < m THEN f.segundos ELSE m END) / 3600.0, 2) AS horas_hasta_devolver,
       ANY (f IN favores WHERE f.mismo) AS sobre_el_mismo_producto
ORDER BY horas_hasta_devolver ASC, veces DESC;
