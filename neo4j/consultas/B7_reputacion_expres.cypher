// B7_reputacion_expres.cypher -- CUENTAS QUE CALIFICAN ANTES DE PODER HABER COMPRADO
//
// QUE BUSCA: resenas altas escritas por una cuenta con menos de
// $horas_cuenta_nueva horas de vida, a un vendedor con menos de
// $dias_vendedor_nuevo dias de vida. Se agrupan por vendedor.
//
// POR QUE ESA SENAL SIGNIFICA ALGO: para calificar, el backend exige una
// compra pagada. Una persona de verdad se registra, busca, compra, espera el
// paquete y despues califica. Hacer todo eso en minutos es lo que hace un
// guion. Y un vendedor que recibe sus primeras estrellas el mismo dia en que
// abrio la cuenta esta comprando reputacion, no ganandola.
//
// ES LA UNICA CONSULTA DE ESTA FAMILIA QUE NO NECESITA SEMBRAR NADA PARA
// DISPARAR, y lo que encuentra en los datos reales es verdad: los anillos que
// dejan los arneses de prueba (pruebas/anillos.sh y los demas) son cuentas que
// un guion crea, hace comprar y hace calificar en SEGUNDOS. `minutos_de_vida`
// lo dice: el autor mas rapido califico con menos de un minuto de vida.
//
// SOLA NO ACUSA: una cuenta nueva que califica a un vendedor nuevo el mismo dia
// puede pasar si el vendedor entrega en mano. Pesa cuando se suma a un anillo o
// a una granja, y asi lo usan las reglas del backend.
RETURN '=== B.7  REPUTACION EXPRES (cuentas recien nacidas) ===' AS consulta;

MATCH (a:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(v:Usuario)
WHERE r.calificacion >= $nota_alta
  // El ">= 0" no sobra, y costo un resultado falso: la semilla del proyecto
  // carga resenas de febrero a agosto sobre cuentas cuya fecha_alta es el dia
  // en que se cargo la base, asi que 86 resenas quedan ANTES de que su autor
  // existiera. Sin este limite la resta sale negativa, "menor que 24 horas", y
  // los dos compradores reales salian como cuentas recien nacidas con -296 674
  // minutos de vida. Una resena anterior al alta no es expres: es un dato
  // imposible, y se cuenta aparte en el documento.
  AND r.fecha.epochSeconds >= a.fecha_alta.epochSeconds
  AND r.fecha.epochSeconds - a.fecha_alta.epochSeconds <= $horas_cuenta_nueva * 3600
  AND r.fecha.epochSeconds >= v.fecha_alta.epochSeconds
  AND r.fecha.epochSeconds - v.fecha_alta.epochSeconds <= $dias_vendedor_nuevo * 86400
WITH v, a, r, (r.fecha.epochSeconds - a.fecha_alta.epochSeconds) / 60.0 AS minutos
WITH v, collect(DISTINCT a) AS autores, collect(r) AS resenas, min(minutos) AS minutos_min
WITH v, autores, resenas, minutos_min,
     COLLECT { UNWIND [v] + autores AS u RETURN DISTINCT u.id AS id ORDER BY id } AS ordenados
RETURN reduce(s = '', x IN ordenados | s + CASE WHEN s = '' THEN '' ELSE '-' END + toString(x)) AS clave,
       v.correo                  AS vendedor,
       [u IN autores | u.correo] AS autores,
       size(resenas)             AS resenas_expres,
       [r IN resenas | r.id]     AS resenas,
       round(minutos_min, 1)     AS minutos_de_vida,
       COUNT { (v)<-[:CALIFICA_A]-(:Resena) } AS recibidas_en_total
ORDER BY resenas_expres DESC, minutos_de_vida ASC;
