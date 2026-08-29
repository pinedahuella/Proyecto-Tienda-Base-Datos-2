// siembra.cypher -- el anillo de mentira que demuestra que las consultas sirven
//
// Las cinco consultas de neo4j/consultas/A*.cypher, contra el grafo real,
// devuelven casi nada. Y una consulta que nunca encontro nada no esta
// demostrada: podria estar mal escrita y devolver vacio por eso. Aqui se
// siembra lo que tendrian que encontrar, correr_fraude.sh las vuelve a correr
// -- LAS MISMAS, no copias -- y comprobar.cypher exige que las encuentren.
//
//
// POR QUE SE SIEMBRA EN NEO4J Y NO EN POSTGRESQL
// ============================================================
// Porque el grafo es una PROYECCION y se puede ensuciar sin consecuencias: se
// tira entero y el ETL lo reconstruye. Meter cuentas falsas en PostgreSQL seria
// meterlas en la fuente de verdad, donde las ve el backend, el catalogo de
// Mongo y cualquier otra consulta del proyecto -- y donde borrarlas obliga a
// deshacer resenas, comentarios y usuarios en el orden correcto por las llaves
// foraneas con ON DELETE RESTRICT.
//
//
// LOS IDS NEGATIVOS Y LA REGLA DE NO ESCRIBIR IDS A MANO
// ============================================================
// La regla de la casa dice que ningun id se escribe a mano: todo se busca por
// correo o por nombre. Aqui se escriben, y no es una excepcion a la regla sino
// un caso donde no aplica: estas cuentas NO EXISTEN en PostgreSQL, asi que no
// hay ningun id que buscar -- hay que inventarlo.
//
// Son negativos por una razon concreta: usuarios.id_usuario es un bigserial y
// nunca va a dar un negativo, asi que un id de prueba no puede chocar jamas con
// uno de verdad. Y como el ETL hace MERGE por id, la proxima corrida no los
// toca ni los pisa.
//
//
// LA ETIQUETA :Prueba
// ============================================================
// Todo lo sembrado lleva una etiqueta extra. Sirve para dos cosas: borrarlo
// entero con una sola linea sin tener que acordarse de que se creo, y que las
// consultas de A*.cypher lo sigan encontrando -- un nodo con :Usuario:Prueba SI
// cumple el patron (:Usuario), que es justo lo que se quiere demostrar.


// ---------- Se limpia primero, por si quedo algo de otra corrida
// Va ANTES de sembrar y no solo despues. Si una corrida anterior se corto a la
// mitad -- se cayo la conexion, alguien apreto Ctrl+C -- el anillo se quedo
// puesto, y sembrar encima dejaria el conteo final mintiendo.
MATCH (n:Prueba) DETACH DELETE n;


// ---------- Las cuentas
//
// SEIS, y las dos ultimas existen por un fallo concreto que hay que seguir
// vigilando; esta contado abajo, en el bloque de resenas.
CREATE (:Usuario:Prueba {id: -101, correo: 'anillo.a@prueba.local', usuario: 'anillo_a', nombre: 'Anillo', apellido: 'A'})
CREATE (:Usuario:Prueba {id: -102, correo: 'anillo.b@prueba.local', usuario: 'anillo_b', nombre: 'Anillo', apellido: 'B'})
CREATE (:Usuario:Prueba {id: -103, correo: 'anillo.c@prueba.local', usuario: 'anillo_c', nombre: 'Anillo', apellido: 'C'})
CREATE (:Usuario:Prueba {id: -104, correo: 'anillo.d@prueba.local', usuario: 'anillo_d', nombre: 'Anillo', apellido: 'D'})
CREATE (:Usuario:Prueba {id: -105, correo: 'doble.a@prueba.local',  usuario: 'doble_a',  nombre: 'Doble',  apellido: 'A'})
CREATE (:Usuario:Prueba {id: -106, correo: 'doble.b@prueba.local',  usuario: 'doble_b',  nombre: 'Doble',  apellido: 'B'});

CREATE (:Producto:Prueba {id: -901, nombre: 'Producto de prueba del anillo'})
CREATE (:Producto:Prueba {id: -902, nombre: 'Segundo producto de prueba'})
CREATE (:Producto:Prueba {id: -903, nombre: 'Tercer producto de prueba'})
CREATE (:Producto:Prueba {id: -904, nombre: 'Cuarto producto de prueba'});

// La direccion de mentira usa el mismo formato de clave que arma el ETL
// (minusculas, campos separados por barra) para que no se distinga en nada de
// una real: si A.4 la encontrara por venir con otro formato, la demostracion no
// probaria nada.
//
// Y lleva CALLE, que es lo que la hace senal. Desde que A.4 exige
// `d.tiene_calle` -- porque sin eso "misma casa" media "misma ciudad" -- una
// direccion de prueba sin calle no dispararia nada y la demostracion pasaria a
// probar lo contrario de lo que dice.
CREATE (:Direccion:Prueba {clave: 'guatemala|guatemala|prueba anillo|casa 1',
                           pais: 'Guatemala', departamento: 'Guatemala',
                           ciudad: 'Prueba Anillo', exacta: 'Casa 1',
                           tiene_calle: true});

// Solo las CUATRO del anillo viven ahi. Las dos de `doble` quedan sin
// direccion a proposito: asi A.5 tiene que darles 3 senales y no 4, y se ve que
// el puntaje distingue en vez de darle el maximo a todo lo sembrado.
MATCH (d:Direccion:Prueba), (u:Usuario:Prueba)
WHERE u.id >= -104
MERGE (u)-[:VIVE_EN]->(d);


// ---------- Las resenas
//
// Cada bloque esta puesto para disparar una consulta, y los dos ultimos existen
// porque una version anterior de las consultas los contestaba MAL:
//
//   -101 -> -102 -> -103 -> -101   el triangulo                        (A.1, 6 saltos)
//   -102 -> -101                   ademas el par mutuo, mismo producto (A.1 4 saltos, A.2)
//
//   -104 -> -101, tres veces en 20 minutos                             (A.3)
//   -104 -> -101, una cuarta MESES DESPUES.
//       Esta cuarta resena es la prueba de regresion de A.3. La version vieja
//       comparaba el lapso entre la primera y la ultima resena del par entero,
//       asi que esta sola linea APAGABA la rafaga: medido, cero filas con ella
//       y una fila al borrarla. Si alguien vuelve a escribir A.3 con max-min,
//       comprobar.cypher se pone rojo aqui.
//
//   -105 <-> -106, DOS resenas en cada sentido.
//       La prueba de regresion de A.1. Un camino de largo variable en Cypher
//       garantiza que no se repita una RELACION, no que no se repita un NODO:
//       con cuatro resenas entre dos cuentas existe tambien el camino
//       A->B->A->B->A de 8 saltos, y A.1 reportaba ese par DOS veces, una como
//       anillo de 2 cuentas (verdad) y otra como anillo de 4 (mentira, con los
//       mismos dos correos repetidos). Sembrado aqui, comprobar.cypher exige
//       que ningun anillo repita cuenta.
UNWIND [
  {id: -801, autor: -101, vendedor: -102, producto: -901, nota: 5, fecha: '2026-07-01T09:00:00+00:00'},
  {id: -802, autor: -102, vendedor: -103, producto: -901, nota: 5, fecha: '2026-07-01T09:20:00+00:00'},
  {id: -803, autor: -103, vendedor: -101, producto: -901, nota: 5, fecha: '2026-07-01T09:40:00+00:00'},
  {id: -804, autor: -102, vendedor: -101, producto: -901, nota: 5, fecha: '2026-07-01T10:05:00+00:00'},

  {id: -805, autor: -104, vendedor: -101, producto: -901, nota: 5, fecha: '2026-07-02T08:00:00+00:00'},
  {id: -806, autor: -104, vendedor: -101, producto: -902, nota: 5, fecha: '2026-07-02T08:10:00+00:00'},
  {id: -807, autor: -104, vendedor: -101, producto: -903, nota: 5, fecha: '2026-07-02T08:20:00+00:00'},
  {id: -808, autor: -104, vendedor: -101, producto: -904, nota: 5, fecha: '2026-12-15T11:00:00+00:00'},

  {id: -811, autor: -105, vendedor: -106, producto: -901, nota: 5, fecha: '2026-07-03T09:00:00+00:00'},
  {id: -812, autor: -105, vendedor: -106, producto: -902, nota: 5, fecha: '2026-07-03T09:10:00+00:00'},
  {id: -813, autor: -106, vendedor: -105, producto: -901, nota: 5, fecha: '2026-07-03T09:20:00+00:00'},
  {id: -814, autor: -106, vendedor: -105, producto: -902, nota: 5, fecha: '2026-07-03T09:30:00+00:00'}
] AS f
MATCH (a:Usuario:Prueba {id: f.autor})
MATCH (v:Usuario:Prueba {id: f.vendedor})
MATCH (p:Producto:Prueba {id: f.producto})
CREATE (r:Resena:Prueba {id: f.id, calificacion: f.nota, fecha: datetime(f.fecha),
                         texto: 'Excelente vendedor, todo perfecto.'})
CREATE (a)-[:ESCRIBIO]->(r)
CREATE (r)-[:CALIFICA_A]->(v)
CREATE (r)-[:SOBRE]->(p);
