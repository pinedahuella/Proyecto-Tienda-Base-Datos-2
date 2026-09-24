// B6_coordinados.cypher -- DOS CUENTAS QUE CALIFICAN LO MISMO, A LA VEZ
//
// QUE BUSCA: dos autores que calificaron el MISMO producto del MISMO vendedor
// con menos de $horas_sincronia horas de diferencia, al menos
// $min_coincidencias veces.
//
// POR QUE ESA SENAL SIGNIFICA ALGO: es fraude sin ninguna relacion entre las
// dos cuentas. No se califican entre si, no forman circulo ni cadena: van
// juntas, como una sola mano con dos teclados. En el grafo son dos autores que
// llegan por caminos distintos al mismo par (producto, vendedor) casi al mismo
// tiempo, y eso en SQL es un self-join de `resena` con una condicion de fecha;
// aqui es un patron de cuatro nodos.
//
// POR QUE "A LA VEZ" Y NO "LO MISMO", MEDIDO: los dos compradores reales,
// comprador.sur y compradora.norte, coinciden en 14 pares (producto, vendedor)
// -- son los que mas compran y los productos populares son pocos. Pero solo 2
// de esas 14 cayeron dentro de 24 horas. Coincidir en lo que se compra es
// normal; coincidir en el MOMENTO, tres veces, no.
RETURN '=== B.6  COORDINADOS (misma resena, mismo momento) ===' AS consulta;

MATCH (a:Usuario)-[:ESCRIBIO]->(ra:Resena)-[:SOBRE]->(p:Producto)<-[:SOBRE]-(rb:Resena)<-[:ESCRIBIO]-(b:Usuario)
WHERE a.id < b.id
  AND abs(ra.fecha.epochSeconds - rb.fecha.epochSeconds) <= $horas_sincronia * 3600
MATCH (ra)-[:CALIFICA_A]->(v:Usuario)<-[:CALIFICA_A]-(rb)
WITH a, b, ra, rb, v, p
WITH a, b,
     count(*) AS coincidencias,
     collect(DISTINCT v.correo) AS vendedores,
     collect(ra.id) + collect(rb.id) AS resenas,
     sum(CASE WHEN ra.calificacion = rb.calificacion THEN 1 ELSE 0 END) AS con_la_misma_nota,
     max(abs(ra.fecha.epochSeconds - rb.fecha.epochSeconds)) AS peor_separacion
WHERE coincidencias >= $min_coincidencias
RETURN toString(a.id) + '-' + toString(b.id) AS clave,
       a.correo AS cuenta_a,
       b.correo AS cuenta_b,
       coincidencias,
       con_la_misma_nota,
       vendedores,
       resenas,
       round(peor_separacion / 3600.0, 2) AS horas_de_separacion_maxima
ORDER BY coincidencias DESC, horas_de_separacion_maxima ASC;
