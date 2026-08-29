// A5_puntaje.cypher -- LA COMPUESTA: cuantas senales junta cada par
//
// QUE BUSCA: para cada par de cuentas que se hayan calificado en cualquier
// direccion, cuantas de las senales anteriores cumplen a la vez.
//
// POR QUE ESTA ES LA QUE SE LEE PRIMERO: las cuatro de arriba contestan
// preguntas sueltas y cada una tiene una explicacion inocente. Un par que junta
// tres o cuatro no la tiene. Esta consulta es la que convierte cuatro listas en
// una sola lista ordenada por cuanto hay que preocuparse.
//
// Las cuatro senales que suma:
//   se_califican_mutuamente   hay resena en las dos direcciones
//   sobre_el_mismo_producto   y al menos una vez sobre el mismo articulo
//   solo_notas_altas          todas las resenas entre los dos son 4 o 5
//   comparten_direccion       el domicilio normalizado es el mismo nodo Y ese
//                             nodo tiene calle. El `d.tiene_calle` esta por lo
//                             mismo que en A.4: sin el, esta columna daba TRUE
//                             para cualquier par de cuentas de la misma ciudad
//                             que no hubiera cargado su calle, que son 13 de
//                             las 16 filas de `direcciones`. Un punto de senal
//                             regalado.
//
// OPTIONAL MATCH en las tres ultimas, y no MATCH, porque un par que cumple una
// sola senal TIENE que aparecer en la lista con su puntaje bajo. Con MATCH
// desapareceria, y entonces la consulta ya no seria un ranking: seria otra vez
// un filtro, y quien la lea creeria que los que faltan estan limpios.
//
// LO QUE ESTA CONSULTA NO VE, dicho antes de que alguien lo suponga: el
// universo son los pares que se calificaron AL MENOS UNA VEZ, porque de ahi
// arranca el primer MATCH. Dos cuentas que comparten casa y nunca se
// calificaron no aparecen aqui con puntaje 1 -- no aparecen del todo. Eso lo
// contesta A.4, y por eso A.4 no sobra aunque su senal tambien sea una columna
// de esta.
RETURN '=== A.5  PUNTAJE COMPUESTO POR PAR DE CUENTAS ===' AS consulta;

MATCH (x:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(y:Usuario)
// EL PAR SE NORMALIZA AQUI, no con un WHERE, y esta es la trampa de esta
// consulta. En A.2 y A.4 el patron es SIMETRICO (los dos sentidos tienen que
// existir), asi que "a.id < b.id" solo elige cual de las dos versiones del
// mismo par se imprime. Aqui el patron es DIRIGIDO -- x escribio sobre y -- y
// ese mismo WHERE ya no ordena: BORRA. Todo par cuyo autor tenga id mayor que
// el de su vendedor desaparece del ranking.
//
// Y desaparece en silencio, que es lo peor: el resultado se ve bien, solo que
// mas corto. La primera version de esta consulta tenia exactamente ese error y
// listaba 4 de los 8 pares que hay en los datos de hoy -- se descubrio contando
// a mano los pares (autor, vendedor) en PostgreSQL, no leyendo el Cypher.
WITH DISTINCT CASE WHEN x.id < y.id THEN x ELSE y END AS a,
              CASE WHEN x.id < y.id THEN y ELSE x END AS b

// Los dos lados van con OPTIONAL MATCH, incluido el de "a". Despues de
// normalizar el par ya no se sabe cual de los dos escribio sobre el otro, asi
// que cualquiera de los dos sentidos puede estar vacio y tiene que poder
// estarlo. Un MATCH pelado aqui volveria a borrar la mitad de los pares por la
// puerta de atras.
OPTIONAL MATCH (a)-[:ESCRIBIO]->(ra:Resena)-[:CALIFICA_A]->(b)
WITH a, b, collect(ra) AS de_a_hacia_b

OPTIONAL MATCH (b)-[:ESCRIBIO]->(rb:Resena)-[:CALIFICA_A]->(a)
WITH a, b, de_a_hacia_b, collect(rb) AS de_b_hacia_a

OPTIONAL MATCH (ra2:Resena)-[:SOBRE]->(:Producto)<-[:SOBRE]-(rb2:Resena)
WHERE ra2 IN de_a_hacia_b AND rb2 IN de_b_hacia_a
WITH a, b, de_a_hacia_b, de_b_hacia_a, count(ra2) AS coincidencias_de_producto

OPTIONAL MATCH (a)-[:VIVE_EN]->(d:Direccion)<-[:VIVE_EN]-(b)
WHERE d.tiene_calle
WITH a, b, de_a_hacia_b, de_b_hacia_a, coincidencias_de_producto,
     count(d) AS direcciones_compartidas,
     de_a_hacia_b + de_b_hacia_a AS todas

WITH a, b, todas,
     // Los DOS sentidos, no solo el de vuelta. Con el par ya normalizado por
     // id, "a" no es necesariamente quien escribio: mirar unicamente
     // de_b_hacia_a marcaria como mutuo un par donde solo b califico a a.
     size(de_a_hacia_b) > 0 AND size(de_b_hacia_a) > 0 AS se_califican_mutuamente,
     coincidencias_de_producto > 0     AS sobre_el_mismo_producto,
     ALL (r IN todas WHERE r.calificacion >= 4) AS solo_notas_altas,
     direcciones_compartidas > 0       AS comparten_direccion

RETURN a.correo AS cuenta_a,
       b.correo AS cuenta_b,
       size(todas) AS resenas_entre_los_dos,
       se_califican_mutuamente,
       sobre_el_mismo_producto,
       solo_notas_altas,
       comparten_direccion,
       // El puntaje es una SUMA de banderas, no un modelo. Es a proposito:
       // cualquiera que lea el resultado puede reconstruir de donde salio el
       // numero, y eso importa mas que la precision cuando lo que sigue es que
       // una persona revise cuentas ajenas.
       (CASE WHEN se_califican_mutuamente THEN 1 ELSE 0 END) +
       (CASE WHEN sobre_el_mismo_producto THEN 1 ELSE 0 END) +
       (CASE WHEN solo_notas_altas        THEN 1 ELSE 0 END) +
       (CASE WHEN comparten_direccion     THEN 1 ELSE 0 END) AS senales
ORDER BY senales DESC, resenas_entre_los_dos DESC
LIMIT 20;
