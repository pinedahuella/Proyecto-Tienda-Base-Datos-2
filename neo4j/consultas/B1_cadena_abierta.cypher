// B1_cadena_abierta.cypher -- EL ANILLO QUE NO SE CIERRA
//
// QUE BUSCA: una cadena de 3 a 5 cuentas donde cada una le pone nota alta a
// la siguiente -- A a B, B a C, C a D -- y la reputacion NUNCA vuelve al
// origen: no hay ningun camino de resenas de D de vuelta a A.
//
// POR QUE ESA SENAL SIGNIFICA ALGO: A.1 solo ve circulos. Quien arma cuentas
// para inflar a un vendedor no necesita cerrar el circulo; le basta con una
// fila de cuentas que se pasan las estrellas hasta llegar a la que vende. Es
// el anillo con un eslabon de menos, y A.1 no lo ve por construccion.
//
// POR QUE NO ES UNA ACUSACION: en una tienda real A le compra a B y B le
// compra a C sin conocerse. Por eso se piden tres cosas a la vez: todas las
// notas altas, toda la cadena dentro de $dias_cadena dias, y se informan dos
// agravantes -- que las cuentas hayan nacido juntas y que los extremos
// compartan casa (el eslabon que "cierra" la cadena fuera de las resenas).
//
//
// LAS TRES DECISIONES QUE NO SE VEN EN EL PATRON
// ============================================================
// 1. "ABIERTA" QUIERE DECIR SIN VUELTA, NO SIN UNA RESENA DIRECTA. La primera
//    version pedia solo que el ultimo no calificara al primero. Asi, dentro de
//    un anillo de cuatro A-B-C-D-A, el tramo A-B-C salia como "cadena abierta"
//    aunque la reputacion vuelve a A por D. Ahora se exige que no haya NINGUN
//    camino de vuelta de hasta tres cuentas: si lo hay, es un anillo y es
//    asunto de A.1.
//
// 2. SOLO LA CADENA MAS LARGA. Si A-B-C-D es cadena, A-B-C y B-C-D tambien lo
//    son. Listar las tres es contar tres hallazgos donde hay uno. Al final se
//    quita toda cadena que este contenida, seguida y en el mismo orden, dentro
//    de otra mas larga.
//
// 3. UN CAMINO POR SECUENCIA DE CUENTAS. Si A califico a B dos veces hay dos
//    caminos con las mismas cuentas; se juntan y se cuentan sus resenas.
//
// Las cuentas del camino tienen que ser todas distintas por la misma razon que
// en A.1: un camino de largo variable no repite relaciones, pero SI nodos.
RETURN '=== B.1  CADENA ABIERTA (anillo sin cerrar) ===' AS consulta;

MATCH camino = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(fin:Usuario)
WHERE inicio <> fin
WITH inicio, fin,
     [n IN nodes(camino) WHERE n:Usuario] AS cuentas,
     [n IN nodes(camino) WHERE n:Resena]  AS resenas
WHERE size(cuentas) = size(reduce(vistas = [], c IN cuentas |
        CASE WHEN c.id IN vistas THEN vistas ELSE vistas + c.id END))
  AND ALL (r IN resenas WHERE r.calificacion >= $nota_alta)
  // Decision 1: sin camino de vuelta. *2..6 son de 1 a 3 cuentas de regreso,
  // lo que junto con la cadena no pasa de los 8 saltos de A.1.
  AND NOT EXISTS { (fin)-[:ESCRIBIO|CALIFICA_A*2..6]->(inicio) }

WITH cuentas, resenas,
     reduce(m = resenas[0].fecha, r IN resenas | CASE WHEN r.fecha < m THEN r.fecha ELSE m END) AS primera,
     reduce(m = resenas[0].fecha, r IN resenas | CASE WHEN r.fecha > m THEN r.fecha ELSE m END) AS ultima
WHERE ultima.epochSeconds - primera.epochSeconds <= $dias_cadena * 86400

// Decision 3: un renglon por secuencia de cuentas.
WITH [c IN cuentas | c.id] AS ids, cuentas,
     collect(resenas) AS grupos, min(primera) AS primera, max(ultima) AS ultima
WITH ids, cuentas, primera, ultima,
     reduce(t = [], g IN grupos | t + [r IN g WHERE NOT r IN t]) AS resenas

// Decision 2: solo las maximas.
WITH collect({ids: ids, cuentas: cuentas, resenas: resenas,
              primera: primera, ultima: ultima}) AS todas
UNWIND todas AS c
WITH c, todas
WHERE NONE (o IN todas WHERE size(o.ids) > size(c.ids)
        AND ANY (i IN range(0, size(o.ids) - size(c.ids))
                 WHERE o.ids[i..i + size(c.ids)] = c.ids))

// Los dos agravantes. OPTIONAL porque una cadena sin ellos TIENE que salir.
WITH c, c.cuentas[0] AS inicio, c.cuentas[-1] AS fin
OPTIONAL MATCH (inicio)-[:VIVE_EN]->(d:Direccion)<-[:VIVE_EN]-(fin)
WHERE d.tiene_calle
WITH c, count(d) > 0 AS extremos_comparten_casa,
     reduce(m = c.cuentas[0].fecha_alta, u IN c.cuentas | CASE WHEN u.fecha_alta < m THEN u.fecha_alta ELSE m END) AS alta_min,
     reduce(m = c.cuentas[0].fecha_alta, u IN c.cuentas | CASE WHEN u.fecha_alta > m THEN u.fecha_alta ELSE m END) AS alta_max

// `clave` es la misma que usa anillo_fraude.clave en PostgreSQL: los ids
// ordenados y unidos con "-". Asi el backend puede guardar lo que encuentra
// esta consulta en la misma tabla, y el arnes la compara contra el SQL.
// Se ordena con COLLECT {} y no con apoc.coll.sort, por la misma razon que A.1
// usa reduce: que corra en un Neo4j sin APOC.
WITH c, extremos_comparten_casa,
     (alta_max.epochSeconds - alta_min.epochSeconds) <= $horas_alta_juntas * 3600 AS nacieron_juntas,
     COLLECT { UNWIND c.ids AS x RETURN x ORDER BY x } AS ordenados,
     // La cadena desemboca en un anillo cerrado (alguna de sus cuentas esta en
     // un circulo de A.1). Medido en los datos reales: las cuatro cadenas que
     // salen son "colas" de anillos de prueba -- una cuenta de mas que alimenta
     // el circulo desde afuera. Se informa aparte porque cambia la lectura: no
     // es un anillo sin cerrar, es un anillo que recluta.
     ANY (u IN c.cuentas WHERE EXISTS { (u)-[:ESCRIBIO|CALIFICA_A*4..8]->(u) }) AS entra_a_un_anillo
RETURN reduce(s = '', x IN ordenados | s + CASE WHEN s = '' THEN '' ELSE '-' END + toString(x)) AS clave,
       [u IN c.cuentas | u.correo]       AS cadena,
       size(c.ids)                       AS cuantas_cuentas,
       [r IN c.resenas | r.id]           AS resenas,
       (c.ultima.epochSeconds - c.primera.epochSeconds) / 3600 AS horas_de_la_cadena,
       nacieron_juntas,
       extremos_comparten_casa,
       entra_a_un_anillo
ORDER BY cuantas_cuentas DESC, horas_de_la_cadena ASC;
