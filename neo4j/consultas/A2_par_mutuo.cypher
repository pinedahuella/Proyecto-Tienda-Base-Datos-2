// A2_par_mutuo.cypher -- EL PAR MUTUO SOBRE EL MISMO PRODUCTO
//
// QUE BUSCA: la frase literal del enunciado -- cuentas que se califican entre
// si de forma reiterada SOBRE LOS MISMOS PRODUCTOS.
//
// POR QUE ESA SENAL SIGNIFICA ALGO: que A y B se califiquen mutuamente ya es
// raro, porque obliga a que cada uno le haya comprado al otro. Que ademas sea
// sobre el MISMO producto es casi imposible de explicar: significa que A le
// compro a B el articulo X y B le compro a A el mismo articulo X. Nadie
// intercambia el mismo producto consigo mismo; lo que si pasa es que dos
// cuentas del mismo dueno publiquen el mismo articulo y se resenen encima.
//
// ESTA CONSULTA ES LA QUE JUSTIFICA QUE LA RESENA SEA UN NODO. Con una relacion
// directa (a)-[:CALIFICA]->(b) el "mismo producto" no se podria escribir: una
// relacion conecta dos cosas y aqui hacen falta tres. La condicion es esa
// ultima linea del patron, donde las dos resenas se encuentran en el mismo
// :Producto.
//
// a.id < b.id para que el par salga una vez y no dos veces al reves. Aqui SI
// alcanza con eso, al reves que en A5: el patron es simetrico -- los dos
// sentidos tienen que existir -- asi que el filtro elige cual de las dos
// versiones del mismo par se imprime, no borra ninguna.
RETURN '=== A.2  PAR MUTUO SOBRE EL MISMO PRODUCTO ===' AS consulta;

MATCH (a:Usuario)-[:ESCRIBIO]->(ra:Resena)-[:CALIFICA_A]->(b:Usuario),
      (b)-[:ESCRIBIO]->(rb:Resena)-[:CALIFICA_A]->(a),
      (ra)-[:SOBRE]->(p:Producto)<-[:SOBRE]-(rb)
WHERE a.id < b.id
RETURN a.correo        AS cuenta_a,
       b.correo        AS cuenta_b,
       p.nombre        AS producto_compartido,
       ra.calificacion AS nota_de_a_a_b,
       rb.calificacion AS nota_de_b_a_a,
       abs(ra.fecha.epochSeconds - rb.fecha.epochSeconds) / 3600 AS horas_entre_las_dos
ORDER BY horas_entre_las_dos ASC;
