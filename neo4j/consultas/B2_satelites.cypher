// B2_satelites.cypher -- LA GRANJA: VARIAS CUENTAS DESECHABLES ALREDEDOR DE UN VENDEDOR
//
// QUE BUSCA: un vendedor rodeado de "satelites", cuentas que en toda su vida
// solo calificaron a ESE vendedor, siempre con nota alta, y que escribieron su
// primera resena a los pocos dias de abrirse. Hacen falta al menos
// $min_satelites alrededor del mismo vendedor.
//
// POR QUE ESA SENAL SIGNIFICA ALGO: es la forma de estrella del fraude, la que
// no tiene ni circulo ni cadena. El vendedor no le devuelve nada a nadie, asi
// que A.1, A.2 y B.1 no la ven. Lo que la delata es que las cuentas no tienen
// otra vida: nacen, califican a uno y se apagan.
//
// POR QUE NO ES UNA ACUSACION: una tienda chica con clientes nuevos y fieles
// se ve parecida. Por eso sale `peso_en_su_reputacion`: tres satelites en un
// vendedor con 200 resenas no mueven nada; tres en uno con cuatro resenas SON
// su reputacion.
//
//
// POR QUE "SOLO A ESE VENDEDOR" Y NO "MUCHAS RESENAS A ESE VENDEDOR"
// ============================================================
// Se midio con los dos compradores reales. comprador.sur le escribio 10
// resenas a ventas.sur y compradora.norte 15 a la tienda: por volumen serian
// los primeros sospechosos. Pero reparten sus resenas entre cinco vendedores
// (sus 10 son el 23 % de lo que escriben). Un satelite es lo contrario: pocas
// resenas y todas al mismo.
RETURN '=== B.2  SATELITES (granja alrededor de un vendedor) ===' AS consulta;

MATCH (s:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(v:Usuario)
WITH s, collect(DISTINCT v) AS vendedores, collect(r) AS resenas
WHERE size(vendedores) = 1
  AND ALL (x IN resenas WHERE x.calificacion >= $nota_alta)
WITH vendedores[0] AS v, s, resenas,
     reduce(m = resenas[0].fecha, x IN resenas | CASE WHEN x.fecha < m THEN x.fecha ELSE m END) AS primera
// Cuenta desechable: su primera resena llega a lo sumo $dias_cuenta_desechable
// dias despues de abrirla.
// El ">= 0" por lo mismo que en B.7: la semilla tiene resenas anteriores al
// alta de su autor, y con la resta negativa cualquier cuenta vieja pasaba por
// recien creada.
WHERE primera.epochSeconds >= s.fecha_alta.epochSeconds
  AND primera.epochSeconds - s.fecha_alta.epochSeconds <= $dias_cuenta_desechable * 86400

WITH v, collect(s) AS satelites, collect(primera) AS primeras,
     reduce(t = [], g IN collect(resenas) | t + g) AS resenas
WHERE size(satelites) >= $min_satelites

// Cuanto de lo que el vendedor recibio viene de sus satelites.
WITH v, satelites, primeras, resenas,
     COUNT { (v)<-[:CALIFICA_A]-(:Resena) } AS recibidas,
     reduce(m = primeras[0], f IN primeras | CASE WHEN f < m THEN f ELSE m END) AS desde,
     reduce(m = primeras[0], f IN primeras | CASE WHEN f > m THEN f ELSE m END) AS hasta,
     COLLECT { UNWIND [v] + satelites AS u RETURN u.id ORDER BY u.id } AS ordenados
RETURN reduce(s = '', x IN ordenados | s + CASE WHEN s = '' THEN '' ELSE '-' END + toString(x)) AS clave,
       v.correo                          AS vendedor,
       [u IN satelites | u.correo]       AS satelites,
       size(satelites)                   AS cuantos,
       [r IN resenas | r.id]             AS resenas,
       recibidas,
       round(1.0 * size(resenas) / recibidas, 2) AS peso_en_su_reputacion,
       // En cuantos dias aparecieron todos. Una granja que aparece en una tarde
       // es una tarea; una que tarda un ano puede ser clientela.
       (hasta.epochSeconds - desde.epochSeconds) / 86400 AS dias_en_aparecer
ORDER BY peso_en_su_reputacion DESC, cuantos DESC;
