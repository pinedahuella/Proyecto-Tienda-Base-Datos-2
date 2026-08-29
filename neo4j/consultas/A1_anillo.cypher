// A1_anillo.cypher -- LA CONSULTA DE VARIOS SALTOS DE LA ENTREGA.
//
// Este archivo tiene UNA sola copia de la consulta y se corre DOS veces:
// contra el grafo real y contra el grafo con el anillo de prueba sembrado. Lo
// hace neo4j/correr_fraude.sh. Antes habia dos copias -- una en la "parte A" y
// otra en la "parte B" del mismo archivo -- y eso no probaba nada: se midio,
// cambiando *4..8 por *40..80 SOLO en la copia de arriba la salida no cambiaba
// ni un caracter, porque la demostracion corria la copia de abajo, intacta.
//
//
// QUE BUSCA: un grupo de cuentas donde la calificacion vuelve al punto de
// partida. A califica a B, B a C, C a A. Ninguna se califica a si misma -- la
// base lo prohibe con un CHECK -- pero el circulo consigue el mismo efecto
// repartido entre varias, y ninguna fila de `resena`, mirada sola, se ve rara.
//
// POR QUE ESA SENAL SIGNIFICA ALGO: la reputacion en Mesh se compra vendiendo.
// Un anillo la fabrica sin vender: cada cuenta le sube la nota a la siguiente y
// recibe la suya de vuelta. Es la forma mas barata de convertir cuentas nuevas
// en vendedores con estrellas, y es invisible fila por fila porque cada resena
// tiene autor distinto, vendedor distinto y nota legitima.
//
// COMO SE LEE EL PATRON: "*4..8" son SALTOS, no cuentas. El camino alterna
// obligatoriamente Usuario -> Resena -> Usuario, asi que hacen falta DOS saltos
// por cuenta: 4 saltos = 2 cuentas que se califican mutuamente, 6 = triangulo,
// 8 = cuadrado. Se para en 8 a proposito: mas alla el numero de caminos crece
// muy rapido y un "anillo" de siete cuentas ya es un grupo de gente que se
// conoce, no una maquina de estrellas.
//
// No hace falta nombrar el orden de las etiquetas: desde un :Usuario la unica
// relacion que sale es ESCRIBIO, y desde una :Resena la unica de las dos que
// sale es CALIFICA_A. La estructura del grafo fuerza la alternancia. SOBRE
// queda fuera de la lista justamente para que la caminata no se escape al
// producto y vuelva por otro lado.
//
// El RETURN de rotulo no es adorno: con --format plain, una consulta que
// devuelve CERO filas no imprime nada, ni el encabezado. Sin el, "la consulta
// dio vacio" y "la consulta no se corrio" se ven exactamente igual, y este
// archivo tiene que poder demostrar lo primero.
RETURN '=== A.1  EL ANILLO (varios saltos) ===' AS consulta;

MATCH anillo = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)
WITH nodes(anillo) AS paso
WITH [n IN paso WHERE n:Usuario] AS cuentas,
     [n IN paso WHERE n:Resena]  AS resenas

// cuentas[0] es la de arranque y aparece otra vez al final, porque el camino
// cierra sobre ella. `ciclo` es el anillo sin ese duplicado de cierre.
WITH cuentas[0..-1] AS ciclo, resenas

// LA TRAMPA DEL DUPLICADO: el mismo anillo se encuentra una vez por cada cuenta
// desde la que se arranque -- un triangulo saldria tres veces con las mismas
// tres cuentas rotadas. Este filtro ancla cada anillo en su cuenta mas vieja y
// lo deja apareciendo UNA vez. Sin el, el informe cuenta el triple de anillos.
WHERE ALL (c IN ciclo WHERE ciclo[0].id <= c.id)

  // LA TRAMPA QUE COSTO UN ANILLO INVENTADO, y es la razon de estas tres
  // lineas: en Cypher, un camino de largo variable garantiza que no se repita
  // una RELACION, pero NO que no se repita un NODO. Dos cuentas que se
  // califican dos veces en cada sentido son cuatro relaciones distintas, asi
  // que ademas del camino correcto A->B->A de 4 saltos existe A->B->A->B->A de
  // 8, con relaciones todas distintas. Medido: ese par salia DOS veces, una
  // como anillo de 2 cuentas (verdad) y otra como anillo de 4 cuentas
  // ["rev.b","rev.a","rev.b","rev.a"] (mentira), y quien lee el informe cuenta
  // un anillo de cuatro donde hay dos.
  //
  // Y el caso que lo dispara es JUSTO el que la consulta busca -- calificacion
  // mutua reiterada -- no un caso raro. El filtro de rotacion de arriba no lo
  // corta: ancla la rotacion, no exige que las cuentas sean distintas.
  //
  // El reduce arma la lista de ids sin repetir; si mide lo mismo que el ciclo,
  // no hay cuenta repetida. Va con reduce y no con apoc.coll.toSet a proposito:
  // esta es la consulta que vale los 3 puntos y no tiene por que dejar de
  // correr en un Neo4j sin APOC instalado.
  AND size(ciclo) = size(reduce(vistas = [], c IN ciclo |
        CASE WHEN c.id IN vistas THEN vistas ELSE vistas + c.id END))

UNWIND resenas AS r
WITH [c IN ciclo | c.correo]  AS anillo_de_cuentas,
     count(DISTINCT r)        AS resenas_del_anillo,
     avg(r.calificacion)      AS nota_media,
     min(r.fecha).epochSeconds AS primera,
     max(r.fecha).epochSeconds AS ultima
RETURN anillo_de_cuentas,
       size(anillo_de_cuentas) AS cuantas_cuentas,
       resenas_del_anillo,
       round(nota_media, 2)    AS nota_media,
       // Cuantos dias tardo el anillo en cerrarse. Un circulo que se completa
       // en horas es una sesion de trabajo; uno que tarda meses puede ser gente
       // que de verdad se compro cosas. Esto es lo que separa las dos cosas.
       (ultima - primera) / 86400 AS dias_en_cerrarse
ORDER BY dias_en_cerrarse ASC, nota_media DESC;
