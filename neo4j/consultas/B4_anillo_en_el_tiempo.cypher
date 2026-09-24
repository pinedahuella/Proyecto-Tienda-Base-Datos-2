// B4_anillo_en_el_tiempo.cypher -- EL ANILLO VISTO COMO HISTORIA, NO COMO FOTO
//
// QUE BUSCA: los mismos circulos que A.1, pero en vez de preguntar "existe",
// pregunta COMO VIVIO en el tiempo. Para cada anillo junta TODAS las resenas
// que van de una cuenta a la siguiente en el sentido del circulo (no solo las
// de un camino) y mide:
//
//   vueltas        cuantas veces se completo el circulo entero (el tramo con
//                  menos resenas manda: si A-B tiene 3, B-C 3 y C-A 1, dio 1)
//   olas           cuantas tandas separadas por mas de $dias_entre_olas dias
//   dias_de_vida   de la primera resena a la ultima
//   en_orden       si alguna vuelta sigue el orden del circulo en el reloj:
//                  A califica a B, DESPUES B a C, DESPUES C a A. Es la "ronda"
//                  de una sola persona manejando las cuentas una tras otra
//   visible_para_el_detector
//                  lo que haria HOY AnillosDetectorService, que solo ve un
//                  anillo si cada tramo tiene una resena en sus ultimos
//                  $dias_ventana_detector dias
//
// POR QUE ESA SENAL SIGNIFICA ALGO: un anillo que se reactiva cada tanto -- una
// vuelta en marzo, otra en junio -- no es un grupo de amigos que se compro algo
// una vez: es un recurso que alguien usa cuando lo necesita. Y un anillo lento,
// que tarda mas que la ventana en cerrar, es justo el que la ventana esconde.
//
// EL HALLAZGO QUE JUSTIFICA ESTA CONSULTA, medido en los datos reales: el
// anillo anillo.uno / dos / tres, el unico que se sembro en PostgreSQL como
// fraude de verdad, es de marzo de 2026. Con la ventana de 60 dias el detector
// del backend ya no lo ve, y por eso `alertas-resenas` sale vacio para el. Esta
// consulta lo lista con visible_para_el_detector = FALSE. No es un error del
// detector -- la ventana existe para no revivir anillos viejos --, es su punto
// ciego, y ahora esta a la vista.
RETURN '=== B.4  ANILLO EN EL TIEMPO (vueltas, olas y punto ciego) ===' AS consulta;

// La deteccion del circulo es la de A.1, con sus dos filtros: una sola
// rotacion por anillo y cuentas sin repetir.
MATCH anillo = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)
WITH [n IN nodes(anillo) WHERE n:Usuario][0..-1] AS ciclo
WHERE ALL (c IN ciclo WHERE ciclo[0].id <= c.id)
  AND size(ciclo) = size(reduce(vistas = [], c IN ciclo |
        CASE WHEN c.id IN vistas THEN vistas ELSE vistas + c.id END))
// Un par que se califico tres veces en cada sentido da nueve caminos con las
// mismas cuentas. Aqui interesa el circulo, no el camino: uno solo.
WITH DISTINCT ciclo

// Todas las resenas de cada tramo, no solo las que uso el camino.
UNWIND range(0, size(ciclo) - 1) AS i
MATCH (x:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(y:Usuario)
WHERE x = ciclo[i] AND y = ciclo[(i + 1) % size(ciclo)]
WITH ciclo, i, r ORDER BY r.fecha
WITH ciclo, i, collect(r) AS del_tramo
// El ORDER BY i no es adorno: collect() junta en el orden en que llegan las
// filas, y `en_orden` necesita que tramos[0] sea el que sale de ciclo[0].
WITH ciclo, i, del_tramo ORDER BY i
WITH ciclo, collect(del_tramo) AS tramos

WITH ciclo, tramos,
     reduce(m = size(tramos[0]), t IN tramos | CASE WHEN size(t) < m THEN size(t) ELSE m END) AS vueltas,
     reduce(v = true, t IN tramos |
       v AND ANY (r IN t WHERE r.fecha >= datetime() - duration({days: $dias_ventana_detector}))) AS visible,
     COLLECT { UNWIND tramos AS t UNWIND t AS r RETURN r ORDER BY r.fecha } AS todas

// Olas: se corta la historia donde dos resenas seguidas estan a mas de
// $dias_entre_olas dias.
WITH ciclo, tramos, vueltas, visible, todas,
     size([k IN range(1, size(todas) - 1)
           WHERE todas[k].fecha.epochSeconds - todas[k - 1].fecha.epochSeconds
                 > $dias_entre_olas * 86400]) + 1 AS olas

// En orden: existe alguna eleccion de una resena por tramo, siguiendo el
// circulo, con fechas crecientes. Se prueba arrancando en CADA tramo (la ronda
// de B a C, C a A, A a B tambien es ronda) y, desde ahi, eligiendo en cada
// tramo la primera resena posterior a la anterior: si se llega al final sin
// quedarse sin resenas, la ronda existe. Elegir siempre la mas temprana
// posible es lo que hace que no haga falta probar combinaciones.
WITH ciclo, vueltas, visible, todas, olas, tramos, size(tramos) AS n
WITH ciclo, vueltas, visible, todas, olas,
     ANY (k IN range(0, n - 1) WHERE
       reduce(t = datetime('0001-01-01T00:00:00Z'), j IN range(0, n - 1) |
         CASE WHEN t IS NULL THEN null
              ELSE head([r IN tramos[(k + j) % n] WHERE r.fecha > t | r.fecha]) END)
       IS NOT NULL) AS en_orden,
     COLLECT { UNWIND ciclo AS u RETURN u.id ORDER BY u.id } AS ordenados

RETURN reduce(s = '', x IN ordenados | s + CASE WHEN s = '' THEN '' ELSE '-' END + toString(x)) AS clave,
       [c IN ciclo | c.correo]  AS anillo,
       size(ciclo)              AS cuantas_cuentas,
       [r IN todas | r.id]      AS resenas,
       vueltas,
       olas,
       (todas[-1].fecha.epochSeconds - todas[0].fecha.epochSeconds) / 86400 AS dias_de_vida,
       en_orden,
       visible                  AS visible_para_el_detector,
       toString(date(todas[-1].fecha)) AS ultima_resena
ORDER BY olas DESC, vueltas DESC, dias_de_vida DESC;
