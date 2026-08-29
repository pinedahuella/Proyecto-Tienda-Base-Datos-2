// 001_esquema.cypher
// Las restricciones y los indices del grafo de Mesh.
//
// Se corre ANTES que el ETL y se puede correr las veces que sea: todo lleva
// IF NOT EXISTS. Lo aplica etl/cargar_grafo.sh en cada corrida, a proposito:
// si alguien borra el grafo entero con DETACH DELETE, las restricciones NO se
// van (viven en el esquema, no en los datos), pero si alguien levanta el
// contenedor con el volumen vacio si se van, y el ETL empezaria a duplicar
// nodos sin avisar. Reaplicarlo siempre cuesta milisegundos y cierra ese hueco.
//
//
// Por que la restriccion de unicidad es OBLIGATORIA aqui y no un adorno
// ============================================================
// El ETL carga con MERGE, no con CREATE, para que correrlo dos veces deje el
// mismo grafo. Pero MERGE sin restriccion de unicidad NO garantiza unicidad:
// hace un MATCH y, si no encuentra, un CREATE. Sin indice ese MATCH es un
// barrido de etiqueta, y con dos corridas al mismo tiempo los dos MERGE pueden
// no encontrar nada y crear dos nodos con el mismo id.
//
// La restriccion hace dos cosas de una: crea el indice que el MERGE necesita
// para encontrar el nodo, y toma el candado que impide el duplicado en la
// carrera. Por eso son restricciones y no simples indices.
//
// Y esto no es teorico para este proyecto: la idempotencia del ETL es lo que
// se mide en la entrega ("correrlo dos veces deja los mismos conteos"). Sin
// estas cuatro lineas esa medicion pasa por casualidad, no por diseno.
//
//
// Neo4j community no tiene restricciones de existencia ni de tipo
// ============================================================
// NOT NULL sobre una propiedad (existence constraint) y el tipo de dato son
// de la edicion Enterprise. Aqui no se pueden declarar, asi que "toda Resena
// tiene calificacion" NO lo garantiza el grafo: lo garantiza PostgreSQL, que
// es de donde salen los datos y que si tiene el CHECK (calificacion 1..5).
//
// Es el precio de que el grafo sea una PROYECCION y no una fuente de verdad,
// y conviene decirlo antes de que alguien lo descubra por su cuenta.


// ============================================================
// Unicidad por id: las tres clases del modelo
// ============================================================
// El id es el MISMO de PostgreSQL (usuarios.id_usuario, resena.id_resena,
// productos.id_producto). No se inventa uno nuevo: si el grafo tuviera su
// propia identidad, volver del grafo a la fila que lo origino -- que es lo
// primero que hace alguien cuando la consulta senala una cuenta -- obligaria a
// una tabla de equivalencias que nadie va a mantener.

CREATE CONSTRAINT usuario_id IF NOT EXISTS
FOR (u:Usuario) REQUIRE u.id IS UNIQUE;

CREATE CONSTRAINT resena_id IF NOT EXISTS
FOR (r:Resena) REQUIRE r.id IS UNIQUE;

CREATE CONSTRAINT producto_id IF NOT EXISTS
FOR (p:Producto) REQUIRE p.id IS UNIQUE;


// ============================================================
// La direccion se identifica por su TEXTO normalizado, no por su id
// ============================================================
// Esta es la unica clase cuyo id NO viene de PostgreSQL, y es deliberado.
//
// En el relacional, dos cuentas que viven en la misma casa tienen DOS filas
// distintas en `direcciones`, con dos id_direccion distintos. Si el nodo se
// identificara por id_direccion, serian dos nodos y "comparten direccion"
// seguiria siendo invisible -- exactamente el mismo error que partir
// :Usuario en :Usuario y :Vendedor, y que el README ya explica.
//
// Asi que la identidad del nodo es la direccion normalizada (minusculas, sin
// tildes, espacios colapsados), que es lo que hace que las dos filas caigan en
// UN nodo y que el camino de dos saltos
//     (a:Usuario)-[:VIVE_EN]->(:Direccion)<-[:VIVE_EN]-(b:Usuario)
// exista. La normalizacion la hace etl/extraer_grafo.sql, no aqui.
//
// LO QUE ESE CAMINO NO DICE POR SI SOLO, y hay que leerlo antes de usarlo: la
// clave incluye la calle, y 13 de las 16 filas de `direcciones` no tienen
// calle. Sin calle la clave queda en "guatemala|sacatepequez|antigua guatemala|"
// y el camino de dos saltos deja de significar "la misma casa" para significar
// "la misma ciudad", que no es senal de nada. Por eso el ETL le pone al nodo la
// propiedad `tiene_calle` y las consultas de fraude la exigen. Aqui no hay
// restriccion que lo obligue -- Neo4j community no tiene restricciones de
// existencia de propiedad -- asi que queda dicho: un :Direccion sin
// `tiene_calle` es un nodo cargado por un ETL viejo.

CREATE CONSTRAINT direccion_clave IF NOT EXISTS
FOR (d:Direccion) REQUIRE d.clave IS UNIQUE;


// ============================================================
// Indices de ENTRADA: por donde se empieza a mano
// ============================================================
// La regla de la casa dice que ningun id se escribe a mano: toda consulta que
// una persona teclea entra por el correo de la cuenta o por el nombre del
// producto. Esos dos son los unicos puntos donde el planificador tiene que
// encontrar UN nodo entre todos, y son los unicos que se indexan por eso.
//
// La caceria de anillos NO usa estos indices y no hay que fingir que si: esa
// consulta arranca de TODOS los :Usuario y camina relaciones, y recorrer
// relaciones en Neo4j no pasa por indice ninguno -- cada nodo guarda punteros
// a las suyas. Ese es justamente el argumento de la evaluacion grafos contra
// columnar: el costo no crece con el tamano del grafo sino con el del vecindario.

CREATE INDEX usuario_correo IF NOT EXISTS
FOR (u:Usuario) ON (u.correo);

CREATE INDEX producto_nombre IF NOT EXISTS
FOR (p:Producto) ON (p.nombre);


// ============================================================
// Indice por fecha de resena
// ============================================================
// Este si es para una consulta del 002: la de RAFAGAS, que corta primero por
// ventana de tiempo ("resenas de los ultimos N dias") y solo despues junta las
// cuentas. Sin el indice ese corte es un barrido de todas las :Resena.
//
// Con las 86 resenas de hoy no cambia nada medible, y decirlo importa: el
// indice esta puesto para cuando el grafo crezca, no porque se haya medido una
// mejora. Un indice que se defiende con un numero inventado es peor que no
// tenerlo.

CREATE INDEX resena_fecha IF NOT EXISTS
FOR (r:Resena) ON (r.fecha);


// Lo que NO se indexa, y por que:
//
//   :Resena(calificacion)  Solo tiene cinco valores posibles. Un indice sobre
//                          una columna de cinco valores devuelve la quinta
//                          parte del grafo y el planificador prefiere el
//                          barrido; ademas nunca es el punto de entrada, es un
//                          filtro sobre lo que la caminata ya encontro.
//
//   :Resena(texto)         Un indice normal no sirve para "dos resenas dicen
//                          lo mismo": eso pide igualdad exacta sobre un texto
//                          largo, y se resuelve agrupando por texto en la
//                          propia consulta. Para buscar DENTRO del texto haria
//                          falta un indice de texto completo, que es otra cosa
//                          y ninguna consulta del 002 lo pide.
