// extraer_busqueda.js
// Saca del catalogo de MongoDB lo que el buscador necesita, ya en el formato
// que come la API _bulk de Elasticsearch.
//
// Corre dentro de mesh-mongo con mongosh, igual que cargar.js.
//
// SALE DE MONGO Y NO DE POSTGRESQL, y es la decision que sostiene todo el
// archivo. El catalogo vive en MongoDB y hay productos que existen SOLO ahi:
// los que publica un vendedor desde el panel no dejan fila en PostgreSQL. Un
// indice construido con `FROM productos` no los tendria, y el sintoma seria un
// producto que se vende y que el buscador jura que no existe. Sin ningun error.
// Es el mismo agujero que tenia la nota del catalogo (docs/PENDIENTES.md,
// punto 6).
//
// LO QUE ESCRIBE son DOS lineas por producto, que es como se le habla a _bulk:
//
//   {"index":{"_id":42}}
//   {"nombre":"Laptop Ambar Campus 14", ...}
//
// La primera dice que hacer y la segunda es el documento. El _id es el mismo
// que en Mongo y que en PostgreSQL, asi que correr esto dos veces actualiza en
// vez de duplicar.

const SALIDA = '/tmp/mesh-busqueda.ndjson';

// Se indexa TODO el catalogo, en cualquier estado.
//
// Antes esto era `{ estado: 'activo' }`, y el razonamiento era bueno: filtrando
// al extraer, una ruta que se olvidara del filtro no podia ensenarle un
// producto rechazado a un comprador, porque no habia nada que ensenar. El
// precio era que un administrador tampoco los podia buscar.
//
// Ese precio dejo de ser aceptable: el admin necesita encontrar lo que NO
// circula, que es justo lo que va a revisar. Asi que el filtro se mudo al
// backend, y ahi no vive en un parametro que se pueda pedir del otro lado --
// `GET /buscador/productos` arma su consulta con `filter: [{ term: { estado:
// "activo" } }]` FIJO en el codigo, y la unica ruta sin ese filtro,
// `/buscador/productos/admin`, exige sesion y rol de admin. Un olvido ahora es
// un cambio a proposito en una linea que se ve, no una omision silenciosa.
//
// `estado: p.estado` ya se proyecta en cada documento mas abajo, asi que no
// hace falta agregar ningun campo: solo dejar de excluir por el.
//
// Detalle: el worker `BuscadorSyncService` del backend ya indexa todos los
// estados producto por producto a medida que se editan. Mientras esta linea
// dijera `activo`, una reconstruccion completa del indice DESHACIA ese trabajo
// y dejaba fuera todo lo que no estuviera activo -- sin dar ningun error.
//
// Ver backend/cambio_propuestas/2026-09-04_2208-elastic-indexar-todos-los-estados.md
const FILTRO = {};

/**
 * Los decimales de Mongo llegan como { $numberDecimal: "4269.00" } y
 * Elasticsearch necesita un numero de verdad. Un `double` con la cadena dentro
 * lo rechaza el mapeo entero y el bulk falla por documento, en silencio si
 * nadie mira `errors`.
 *
 * null cuando no hay precio, que NO es lo mismo que cero: un producto sin
 * oferta no vale Q0, es que no se vende. Un cero lo pondria primero al ordenar
 * por precio.
 */
function aNumero(v) {
  if (v === null || v === undefined) return null;
  if (typeof v === 'number') return v;
  if (typeof v === 'string') return Number(v);
  if (v.$numberDecimal !== undefined) return Number(v.$numberDecimal);
  // Decimal128 de verdad, que es lo que devuelve mongosh sin serializar.
  return Number(v.toString());
}

const cursor = db.productos.find(FILTRO, {
  _id: 1,
  nombre: 1,
  descripcion: 1,
  estado: 1,
  categoria: 1,
  precio_desde: 1,
  precio_tienda: 1,
  stock_total: 1,
  total_ofertas: 1,
  resenas_promedio: 1,
  resenas_total: 1,
  'variantes.nombre_variante': 1
});

const fs = require('fs');
const lineas = [];
let cuantos = 0;

cursor.forEach(function (p) {
  // Los nombres de las variantes van a un solo campo de texto. Quien busca
  // "8 GB" espera encontrar la laptop que tiene esa presentacion, y esa cadena
  // no esta en el nombre del producto.
  const variantes = (p.variantes || [])
    .map((v) => v.nombre_variante)
    .filter((n) => typeof n === 'string' && n.trim().length > 0);

  const doc = {
    nombre: p.nombre,
    descripcion: p.descripcion,
    estado: p.estado,

    id_categoria: p.categoria ? p.categoria.id_categoria : null,
    categoria_nombre: p.categoria ? p.categoria.nombre : null,
    categoria_padre: p.categoria ? p.categoria.categoria_padre : null,

    precio_desde: aNumero(p.precio_desde),
    precio_tienda: aNumero(p.precio_tienda),
    stock_total: p.stock_total ?? 0,
    total_ofertas: p.total_ofertas ?? 0,

    // Salen del refresco de notas del ETL (etl/cargar_notas.js). Sirven para
    // desempatar dos productos que casan igual de bien con lo que se escribio.
    resenas_promedio: p.resenas_promedio ?? 0,
    resenas_total: p.resenas_total ?? 0,

    variantes: variantes
  };

  lineas.push(JSON.stringify({ index: { _id: p._id } }));
  lineas.push(JSON.stringify(doc));
  cuantos++;
});

// _bulk EXIGE que el archivo termine en salto de linea. Sin el, el ultimo
// documento se pierde y la respuesta no se queja: dice que todo fue bien y
// entran N-1. Cuesta una tarde encontrarlo.
fs.writeFileSync(SALIDA, lineas.join('\n') + '\n');

print('productos para el buscador: ' + cuantos);
