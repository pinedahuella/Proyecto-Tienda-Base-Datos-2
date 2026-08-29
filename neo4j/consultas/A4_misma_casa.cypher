// A4_misma_casa.cypher -- LA MISMA CASA
//
// QUE BUSCA: dos cuentas cuyo domicilio, normalizado, es el mismo nodo Y ese
// domicilio tiene calle.
//
// POR QUE ESA SENAL SIGNIFICA ALGO: es la senal clasica de anillo, y la unica
// de este juego que no mira resenas. Las cuentas de un anillo se crean rapido y
// con los datos que el dueno tiene a mano, y la direccion de envio es el campo
// que mas se repite porque los paquetes tienen que llegar a algun lado.
//
// POR QUE NO ES UNA ACUSACION: una familia comparte casa. Esta consulta sola no
// senala a nadie; entra en juego cuando el mismo par ademas aparece en A.1 o en
// A.2, que es lo que hace A.5.
//
// EL DOS SALTOS QUE HACE POSIBLE ESTO: en PostgreSQL "misma direccion" es un
// join de `direcciones` contra si misma comparando cuatro columnas de texto,
// con el lower() y el quitar tildes DENTRO de la comparacion -- o sea sin
// indice util. Aqui la normalizacion ya la hizo el ETL y quedo convertida en la
// identidad de un nodo, asi que compartir casa es literalmente estar a dos
// saltos.
//
//
// EL `d.tiene_calle`, QUE ES LO UNICO NUEVO DE ESTA CONSULTA
// ============================================================
// Sin ese filtro esta consulta decia "misma casa" y media "misma ciudad", y no
// en teoria: 13 de las 16 filas de `direcciones` no tienen `direccion_exacta`.
// El ETL las junta igual en un nodo -- la clave queda
// "guatemala|sacatepequez|antigua guatemala|", con la calle vacia -- asi que
// CUALQUIER par de cuentas que solo declaro su ciudad caia en el mismo nodo.
//
// Los DOS unicos pares que esta consulta devolvia antes eran de ese tipo, y el
// README los publicaba como hallazgos reales de "la misma casa":
//
//     comprador.sur + compradora.norte   Antigua Guatemala, exacta NULL
//     tienda@mesh.com + Meme#gordo       San Jose Pinula,   exacta NULL
//
// Su propia salida imprimia direccion_exacta = NULL al lado. No comparten casa:
// comparten ciudad. Y A.5 les sumaba un punto de senal por eso, asi que con dos
// cuentas cualesquiera de la capital sin calle cargada el puntaje se disparaba
// solo.
//
// Una direccion sin calle no identifica una casa, y ese es todo el argumento.
// Los nodos se siguen cargando (el grafo tiene que poder contestar "donde vive
// esta cuenta"), pero solo los que tienen calle cuentan como senal.
//
// CONSECUENCIA, dicha de frente: contra los datos de hoy esta consulta devuelve
// VACIO. Eso no es que la consulta este rota -- es la respuesta correcta, y la
// que el arnes de neo4j/correr_fraude.sh demuestra sembrando un anillo con
// calle de verdad y comprobando que ahi si lo encuentra.
RETURN '=== A.4  CUENTAS QUE COMPARTEN DIRECCION (con calle) ===' AS consulta;

MATCH (a:Usuario)-[:VIVE_EN]->(d:Direccion)<-[:VIVE_EN]-(b:Usuario)
WHERE a.id < b.id
  AND d.tiene_calle
RETURN d.ciudad       AS ciudad,
       d.departamento AS departamento,
       d.exacta       AS direccion_exacta,
       collect(a.correo + ' + ' + b.correo) AS cuentas_que_la_comparten
ORDER BY ciudad;


// ------------------------------------------------------------
// Y lo que NO es senal, listado aparte para que nadie lo confunda
// ------------------------------------------------------------
// Los pares que solo coinciden en pais/departamento/ciudad. Se imprimen porque
// el dato existe y porque asi queda a la vista que la lista de arriba esta
// vacia por una razon y no por un fallo; NO suman en el puntaje de A.5 y no
// significan nada por si mismos. Dos personas de la Ciudad de Guatemala no
// tienen ninguna relacion entre si.
RETURN '=== A.4b (NO ES SENAL) misma ciudad, sin calle registrada ===' AS consulta;

MATCH (a:Usuario)-[:VIVE_EN]->(d:Direccion)<-[:VIVE_EN]-(b:Usuario)
WHERE a.id < b.id
  AND NOT d.tiene_calle
RETURN d.ciudad       AS ciudad,
       d.departamento AS departamento,
       collect(a.correo + ' + ' + b.correo) AS cuentas_de_la_misma_ciudad
ORDER BY ciudad;
