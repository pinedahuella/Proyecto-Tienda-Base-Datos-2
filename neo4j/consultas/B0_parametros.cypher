// B0_parametros.cypher -- LOS UMBRALES DE LA FAMILIA B, EN UN SOLO LUGAR
//
// Las consultas B.1 a B.7 no llevan numeros escritos adentro: leen $parametros.
// Es a proposito, por dos razones.
//
//   1. El backend las puede copiar TAL CUAL. El detector de anillos de hoy
//      (anillos-detector.service.ts) tiene su propia copia de A.1 y A.2 con la
//      ventana escrita a mano, y por eso las del repo y las del backend ya no
//      son el mismo texto. Con parametros, el texto es uno y cada quien le pasa
//      sus numeros.
//   2. Cada umbral salio de MEDIR los datos reales (ver
//      docs/fraude-entrega3/01-consultas-cypher.md). Si alguien lo cambia, lo
//      cambia aqui y queda a la vista.
//
// COMO SE USA
//   En el navegador de Neo4j (http://localhost:7474): pegar este archivo
//   primero, despues la consulta.
//   Por consola: bash neo4j/correr_patrones.sh, que lo antepone solo.
//   Desde el backend: los mismos nombres como parametros del driver.

// Una nota "alta" es de 4 o 5 estrellas. Los anillos regalan 5; se acepta 4
// para que bajar una estrella a proposito no alcance para esconderse.
:param nota_alta => 4;

// B.1 cadena abierta: lapso maximo entre la primera y la ultima resena de la
// cadena, y cuanto pueden separarse las altas de sus cuentas para decir que
// "nacieron juntas".
:param dias_cadena => 30;
:param horas_alta_juntas => 48;

// B.2 satelites: una cuenta es desechable si su primera resena llega a lo sumo
// estos dias despues de crearla; y hacen falta al menos tantas alrededor del
// mismo vendedor para llamarlo granja.
:param dias_cuenta_desechable => 7;
:param min_satelites => 3;

// B.3 persistente: meses distintos con resena, y que parte de lo que escribe
// el autor va a ese vendedor. 0.6 deja fuera a los dos compradores reales, que
// estan entre 0.09 y 0.37 (medido).
:param min_meses => 3;
:param min_exclusividad => 0.6;

// B.4 anillo en el tiempo: dos resenas separadas por mas de estos dias son
// "olas" distintas; y la ventana que usa hoy el detector del backend
// (AnillosDetectorService.VENTANA_DIAS), para decir que anillo no ve.
:param dias_entre_olas => 14;
:param dias_ventana_detector => 60;

// B.5 favor devuelto: horas maximas entre que A califica a B y B le devuelve.
:param horas_devolucion => 72;

// B.6 coordinados: dos autores que califican el mismo producto del mismo
// vendedor con menos de estas horas de diferencia, al menos tantas veces.
:param horas_sincronia => 24;
:param min_coincidencias => 3;

// B.7 reputacion expres: edad maxima del autor al resenar, y del vendedor al
// recibir la resena.
:param horas_cuenta_nueva => 24;
:param dias_vendedor_nuevo => 7;
