// clasificador-resenas/semilla/generar.js
// Escribe clasificador-resenas/semilla/resenas.sql.
//
//   node clasificador-resenas/semilla/generar.js
//
// Necesita los vectores de las resenas (python clasificador-resenas/1_vectorizar.py,
// que los deja en clasificador-resenas/vectores/) y Elasticsearch arriba con los
// vectores de los productos (los deja arrancar.ps1). arrancar.ps1 NO lo corre:
// usa el resenas.sql que sale de aqui, que va en el repo.
//
// Siembra en la tienda las 480 resenas escritas a mano para el clasificador
// (clasificador-resenas/datos/), como resenas de verdad: 40 cuentas de
// compradores, cada una con su direccion, su compra pagada de cada producto y
// su resena encima. Hasta aqui la semilla tenia 86 resenas de dos
// compradores, con 20 textos que se repetian, y las senales de fraude por
// texto (resenas_repetidas, anillo_de_texto) no se podian calibrar con eso.
//
// La corre arrancar.ps1 en cada arranque (paso "Resenas del clasificador") y
// es idempotente: cada resena se reconoce por su autor y su texto, asi que en
// el segundo arranque no entra nada. Por eso entra tambien en una base que ya
// estaba cargada, al reves que migrations/datos/, que solo entra en una vacia.
//
// Es determinista, como migrations/datos/generador.js: el azar sale de una
// semilla fija y correrlo dos veces da el mismo archivo. Y no lleva un solo id
// a mano: cuentas por correo, vendedores por correo, productos por categoria.
//
// COMO SE EVITA PLANTAR FRAUDE
// Las cuentas sembradas no pueden parecerse a ninguno de los patrones que
// busca la Entrega 2, o cada arranque dejaria senales falsas:
//   satelites (B.2)        cada cuenta resena a los CINCO vendedores, nunca a uno
//   persistente (B.3)      los vendedores se turnan, ninguno pasa de 3 de las 12
//   coordinados (B.6)      las fechas se reparten de enero a septiembre, y dos
//                          cuentas no coinciden 3 veces en el mismo producto
//                          el mismo dia
//   reputacion_expres (B.7) la cuenta nace meses antes de su primera resena
// Las dos de texto se dejan correr a proposito: los textos son distintos y
// ninguna cuenta repite el suyo, asi que lo que salte es un falso positivo
// de los umbrales, que es justo lo que hay que poder medir.
//
// LA RESENA VA DONDE TIENE SENTIDO
// Cada texto se escribio para una categoria (Laptops, Cocina, Belleza...) y
// habla de una cosa concreta: un casco, un comal, unas cortinas. Va al producto
// de esa categoria (o de sus hojas, si es una raiz) cuyo vector mas se parece
// al del texto, solo entre los originales del catalogo y no las copias que
// fabrica el generador de arrancar (llevan un sufijo como L1-0043). La primera
// version los repartia al azar dentro de la categoria y la resena de unas
// cortinas quedaba en una olla arrocera; en la ficha se veia falso y la
// busqueda por intencion recomendaba la olla para dormir mejor.
//
// Si ese producto no tiene una oferta con stock de ningun vendedor, la SQL cae
// a otro de la misma categoria. Las estrellas son las del texto: los casos
// nota_no_cuadra llevan a proposito estrellas contrarias a lo que dicen.

const fs = require('fs');
const path = require('path');

const RAIZ = path.join(__dirname, '..');
const SALIDA = path.join(__dirname, 'resenas.sql');

function crearAzar(semilla) {
  let a = semilla >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const azar = crearAzar(20261004);
const entre = (min, max) => min + Math.floor(azar() * (max - min + 1));

// Comprador123, el mismo hash que los compradores de migrations/datos/generador.js.
const CLAVE_COMPRADOR = '9f8e7d6c5b4a39281706f5e4d3c2b1a0:d3af92a164ee8d7608de4ccb96f35d5295245949d9eefffe9dbe892d2cad0cad2fb0c921d6c561264f3a0895242d86893173d1aa9235f77703ef61c86eb13d35';

// Los cinco que venden en la semilla. Los del anillo de la Entrega 2 quedan
// fuera: sus resenas son la prueba de un fraude y no se mezclan.
const VENDEDORES = [
  'tienda@mesh.com',
  'ventas.norte@mesh.com',
  'ventas.sur@mesh.com',
  'ventas.oriente@mesh.com',
  'ventas.poniente@mesh.com',
];

const NOMBRES = [
  ['Sofia', 'Ramirez'], ['Diego', 'Morales'], ['Valeria', 'Castillo'], ['Jorge', 'Mendez'],
  ['Andrea', 'Pineda'], ['Luis', 'Barrios'], ['Gabriela', 'Orellana'], ['Fernando', 'Cifuentes'],
  ['Daniela', 'Monterroso'], ['Ricardo', 'Juarez'], ['Mariela', 'Estrada'], ['Pablo', 'Godinez'],
  ['Karla', 'Aguilar'], ['Esteban', 'Solorzano'], ['Lucia', 'Velasquez'], ['Hector', 'Mazariegos'],
  ['Ximena', 'Paredes'], ['Oscar', 'Quinonez'], ['Natalia', 'Rodas'], ['Mario', 'Cabrera'],
  ['Paula', 'Arriaga'], ['Rodrigo', 'Samayoa'], ['Camila', 'Galindo'], ['Javier', 'Asturias'],
  ['Elena', 'Fuentes'], ['Sergio', 'Coronado'], ['Rocio', 'Marroquin'], ['Alejandro', 'Toledo'],
  ['Ines', 'Cordova'], ['Manuel', 'Batres'], ['Beatriz', 'Lemus'], ['Raul', 'Escobar'],
  ['Carolina', 'Sandoval'], ['Emilio', 'Recinos'], ['Silvia', 'Arevalo'], ['Tomas', 'Villatoro'],
  ['Adriana', 'Polanco'], ['Ivan', 'Chacon'], ['Monica', 'Duarte'], ['Gustavo', 'Alvarado'],
];

const LUGARES = [
  ['Guatemala', 'Guatemala', '01010'], ['Guatemala', 'Mixco', '01057'],
  ['Guatemala', 'Villa Nueva', '01064'], ['Sacatepequez', 'Antigua Guatemala', '03001'],
  ['Quetzaltenango', 'Quetzaltenango', '09001'], ['Escuintla', 'Escuintla', '05001'],
  ['Alta Verapaz', 'Coban', '16001'], ['Huehuetenango', 'Huehuetenango', '13001'],
  ['Izabal', 'Puerto Barrios', '18001'], ['Peten', 'Flores', '17001'],
];

// ------------------------------------------------------------
// Los vectores: los de las resenas del clasificador y los de los productos
// ------------------------------------------------------------
const ES = process.env.ES ?? 'http://localhost:9200';
const SUFIJO_COPIA = / [A-Z][0-9]+-[0-9]+$/;

const VECTORES_RESENAS = new Map(
  JSON.parse(fs.readFileSync(path.join(RAIZ, 'vectores', 'vectores.json'), 'utf8')).items.map((x) => [x.id, x.vector]),
);

async function productosOriginales() {
  const pedir = async (ruta, cuerpo) => {
    const r = await fetch(`${ES}${ruta}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(cuerpo) });
    if (!r.ok) throw new Error(`Elasticsearch contesto ${r.status} en ${ruta}`);
    return r.json();
  };
  const salida = [];
  let pagina = await pedir('/mesh_productos/_search?scroll=1m', {
    size: 500, sort: ['_doc'],
    query: { bool: { filter: [{ term: { estado: 'activo' } }, { exists: { field: 'vector' } }] } },
    _source: ['nombre', 'categoria_nombre', 'categoria_padre', 'vector'],
  });
  while (pagina.hits.hits.length) {
    for (const h of pagina.hits.hits) {
      if (!SUFIJO_COPIA.test(h._source.nombre)) salida.push(h._source);
    }
    pagina = await pedir('/_search/scroll', { scroll: '1m', scroll_id: pagina._scroll_id });
  }
  // Por nombre: el orden de Elasticsearch no es estable entre maquinas.
  return salida.sort((a, b) => (a.nombre < b.nombre ? -1 : a.nombre > b.nombre ? 1 : 0));
}

function coseno(a, b) {
  let p = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { p += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return p / Math.sqrt(na * nb);
}

(async () => {
const PRODUCTOS = await productosOriginales();
if (PRODUCTOS.length === 0) throw new Error('No hay productos con vector en Elasticsearch. Corre .\\arrancar.ps1');

// ------------------------------------------------------------
// Las resenas, en orden fijo
// ------------------------------------------------------------
const RESENAS = [];
for (const archivo of fs.readdirSync(path.join(RAIZ, 'datos')).filter((f) => f.endsWith('.json')).sort()) {
  for (const r of JSON.parse(fs.readFileSync(path.join(RAIZ, 'datos', archivo), 'utf8'))) {
    if (r.texto.length > 250) throw new Error(`${r.id} tiene ${r.texto.length} caracteres y la app acepta hasta 250`);
    RESENAS.push(r);
  }
}
RESENAS.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
// Se barajan con la semilla para que a una cuenta no le toquen solo malas o
// solo de una categoria.
for (let i = RESENAS.length - 1; i > 0; i--) {
  const j = Math.floor(azar() * (i + 1));
  [RESENAS[i], RESENAS[j]] = [RESENAS[j], RESENAS[i]];
}
const POR_CUENTA = Math.ceil(RESENAS.length / NOMBRES.length);

const CUENTAS = NOMBRES.map(([nombre, apellido], i) => {
  const base = `${nombre}.${apellido}`.toLowerCase();
  const lugar = LUGARES[i % LUGARES.length];
  return {
    correo: `${base}@mesh.com`,
    usuario: base.replace('.', '_'),
    nombre,
    apellido,
    // Entre octubre y diciembre de 2025: meses antes de su primera compra.
    alta: `2025-${String(entre(10, 12)).padStart(2, '0')}-${String(entre(1, 28)).padStart(2, '0')} ${String(entre(8, 21)).padStart(2, '0')}:${String(entre(0, 59)).padStart(2, '0')}:00-06`,
    departamento: lugar[0],
    ciudad: lugar[1],
    postal: lugar[2],
    calle: `${entre(1, 20)}a. Calle ${entre(1, 30)}-${String(entre(1, 99)).padStart(2, '0')}, Zona ${entre(1, 18)}`,
  };
});

// Fecha de compra entre el 10 de enero y el 10 de septiembre de 2026, y la
// resena de 2 a 15 dias despues. La SQL la corre hacia adelante si la oferta
// se aprobo despues, y nunca la deja en el futuro.
const INICIO = Date.UTC(2026, 0, 10);
const FIN = Date.UTC(2026, 8, 10);
function fechaCompra() {
  const t = new Date(INICIO + Math.floor(azar() * (FIN - INICIO)));
  t.setUTCHours(entre(8, 21), entre(0, 59), 0, 0);
  return t.toISOString().slice(0, 19).replace('T', ' ') + '-06';
}

const FILAS = RESENAS.map((r, i) => {
  const cuenta = CUENTAS[Math.floor(i / POR_CUENTA)];
  const n = i % POR_CUENTA;
  const vector = VECTORES_RESENAS.get(r.id);
  if (!vector) throw new Error(`${r.id} no tiene vector. Corre python clasificador-resenas/1_vectorizar.py`);
  const candidatos = PRODUCTOS.filter((p) => p.categoria_nombre === r.categoria || p.categoria_padre === r.categoria);
  if (candidatos.length === 0) throw new Error(`Ningun producto original en la categoria ${r.categoria}`);
  let mejor = candidatos[0];
  let mejorParecido = -2;
  for (const p of candidatos) {
    const c = coseno(vector, p.vector);
    if (c > mejorParecido) { mejor = p; mejorParecido = c; }
  }
  return {
    correo: cuenta.correo,
    producto: mejor.nombre,
    // Los vendedores se turnan dentro de cada cuenta, empezando en uno distinto
    // por cuenta: 12 resenas dan 3, 3, 2, 2 y 2.
    vendedor: (Math.floor(i / POR_CUENTA) + n) % VENDEDORES.length,
    categoria: r.categoria,
    estrellas: r.estrellas,
    texto: r.texto,
    elegir: entre(0, 999),
    compra: fechaCompra(),
    dias: entre(2, 15),
  };
});

// ------------------------------------------------------------
// El SQL
// ------------------------------------------------------------
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`;
const lineas = [];
const w = (s) => lineas.push(s);

w(`-- ============================================================`);
w(`-- clasificador-resenas/semilla/resenas.sql`);
w(`-- ============================================================`);
w(`-- GENERADO por clasificador-resenas/semilla/generar.js. No se edita a mano:`);
w(`-- se cambia el generador o los datos y se vuelve a generar.`);
w(`--`);
w(`-- ${RESENAS.length} resenas de clientes, escritas a mano, de ${CUENTAS.length} cuentas de compradores, cada`);
w(`-- una con su compra pagada. El por que y como se evita plantar fraude esta en`);
w(`-- el generador. Idempotente: arrancar.ps1 la corre en cada arranque.`);
w(`-- ============================================================`);
w(``);
w(`-- Las cuentas. NOT EXISTS sobre las dos restricciones unicas, igual que la`);
w(`-- semilla: si alguien ya se registro con ese nombre de usuario no se toca.`);
w(`INSERT INTO usuarios (correo_electronico, usuario, nombre, apellido, contrasena_hash, fecha_creacion, id_rol_usuario, id_estado_usuario)`);
w(`SELECT v.correo, v.usuario, v.nombre, v.apellido, ${lit(CLAVE_COMPRADOR)}, v.alta::timestamptz, r.id_rol_usuario, e.id_estado_usuario`);
w(`FROM (VALUES`);
w(CUENTAS.map((c, i) => `    (${lit(c.correo)}, ${lit(c.usuario)}, ${lit(c.nombre)}, ${lit(c.apellido)}, ${lit(c.alta)})` + (i < CUENTAS.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(correo, usuario, nombre, apellido, alta)`);
w(`JOIN rol_usuario    r ON r.rol_usuario_nombre    = 'comprador'`);
w(`JOIN estado_usuario e ON e.estado_usuario_nombre = 'activo'`);
w(`WHERE NOT EXISTS (SELECT 1 FROM usuarios u WHERE u.correo_electronico = v.correo)`);
w(`  AND NOT EXISTS (SELECT 1 FROM usuarios u WHERE u.usuario            = v.usuario);`);
w(``);
w(`-- Su direccion y su primera version en el historial: el pedido apunta ahi.`);
w(`INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, direccion_exacta, codigo_postal, id_estado_direccion)`);
w(`SELECT u.id_usuario, 'Guatemala', v.departamento, v.ciudad, v.calle, v.postal, ed.id_estado_direccion`);
w(`FROM (VALUES`);
w(CUENTAS.map((c, i) => `    (${lit(c.correo)}, ${lit(c.departamento)}, ${lit(c.ciudad)}, ${lit(c.calle)}, ${lit(c.postal)})` + (i < CUENTAS.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(correo, departamento, ciudad, calle, postal)`);
w(`JOIN usuarios u ON u.correo_electronico = v.correo`);
w(`JOIN estado_direccion ed ON ed.estado_direccion_nombre = 'activa'`);
w(`WHERE NOT EXISTS (SELECT 1 FROM direcciones d WHERE d.id_usuario = u.id_usuario);`);
w(``);
w(`INSERT INTO direccion_historial (id_direccion, pais, departamento, ciudad, direccion_exacta, codigo_postal)`);
w(`SELECT d.id_direccion, d.pais, d.departamento, d.ciudad, d.direccion_exacta, d.codigo_postal`);
w(`FROM direcciones d`);
w(`JOIN usuarios u ON u.id_usuario = d.id_usuario`);
w(`WHERE u.correo_electronico IN (${CUENTAS.map((c) => lit(c.correo)).join(', ')})`);
w(`  AND NOT EXISTS (SELECT 1 FROM direccion_historial h WHERE h.id_direccion = d.id_direccion);`);
w(``);
w(`-- La compra y la resena, una por fila.`);
w(`--`);
w(`-- La compra va por comprar_carrito() de la 012, como en la semilla, y despues`);
w(`-- se le corrigen las tres fechas que escribe con now(). El producto se elige`);
w(`-- aqui y no en el generador: entre los originales de la categoria del texto`);
w(`-- que ese vendedor oferta activos, aprobados, sin inventario limitado y con`);
w(`-- stock, y que la cuenta todavia no reseno con ese vendedor. Si ese vendedor`);
w(`-- no tiene ninguno, prueba con el siguiente.`);
w(`DO $resenas_clasificador$`);
w(`DECLARE`);
w(`    v_fila       record;`);
w(`    v_oferta     record;`);
w(`    v_autor      bigint;`);
w(`    v_dir        bigint;`);
w(`    v_vendedor   bigint;`);
w(`    v_pedido     bigint;`);
w(`    v_comentario bigint;`);
w(`    v_compra     timestamptz;`);
w(`    v_fecha      timestamptz;`);
w(`    v_vendedores text[] := ARRAY[${VENDEDORES.map(lit).join(', ')}];`);
w(`    v_nuevas     integer := 0;`);
w(`    v_por_texto  integer := 0;`);
w(`    v_sin_oferta integer := 0;`);
w(`BEGIN`);
w(`    FOR v_fila IN`);
w(`        SELECT * FROM (VALUES`);
w(FILAS.map((f, i) => `            (${lit(f.correo)}, ${f.vendedor}, ${lit(f.producto)}, ${lit(f.categoria)}, ${f.estrellas}, ${lit(f.texto)}, ${f.elegir}, ${lit(f.compra)}, ${f.dias})` + (i < FILAS.length - 1 ? ',' : '')).join('\n'));
w(`        ) AS t(correo, vendedor, producto, categoria, estrellas, texto, elegir, compra, dias)`);
w(`    LOOP`);
w(`        SELECT u.id_usuario, dh.id_direccion_historial INTO v_autor, v_dir`);
w(`        FROM usuarios u`);
w(`        JOIN direcciones d          ON d.id_usuario = u.id_usuario`);
w(`        JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion`);
w(`        WHERE u.correo_electronico = v_fila.correo`);
w(`        ORDER BY dh.id_direccion_historial`);
w(`        LIMIT 1;`);
w(`        CONTINUE WHEN v_autor IS NULL OR v_dir IS NULL;`);
w(``);
w(`        -- Ya sembrada: la reconoce su autor y su texto.`);
w(`        CONTINUE WHEN EXISTS (`);
w(`            SELECT 1 FROM comentario c`);
w(`            WHERE c.id_usuario = v_autor AND c.id_comentario_padre IS NULL AND c.comentario = v_fila.texto);`);
w(``);
w(`        -- 1. El producto del que habla el texto, con el vendedor que le toca o el`);
w(`        --    siguiente que lo tenga.`);
w(`        v_oferta := NULL;`);
w(`        FOR i IN 0..array_length(v_vendedores, 1) - 1 LOOP`);
w(`            SELECT id_usuario INTO v_vendedor FROM usuarios`);
w(`            WHERE correo_electronico = v_vendedores[1 + (v_fila.vendedor + i) % array_length(v_vendedores, 1)];`);
w(`            CONTINUE WHEN v_vendedor IS NULL;`);
w(``);
w(`            SELECT p.id_producto, p.nombre, o.id_oferta, pv.id_producto_variante, pv.nombre_variante,`);
w(`                   COALESCE(o.fecha_aprobacion, o.fecha_creacion) AS desde`);
w(`              INTO v_oferta`);
w(`              FROM productos p`);
w(`              JOIN oferta o           ON o.id_producto_mongo = p.id_producto AND o.id_usuario = v_vendedor`);
w(`              JOIN estado_oferta eo   ON eo.id_estado_oferta = o.id_estado_oferta AND eo.estado_oferta_nombre = 'activa'`);
w(`              JOIN productos_variantes pv ON pv.id_producto_variante = o.id_producto_variante_mongo`);
w(`             WHERE p.nombre = v_fila.producto`);
w(`               AND o.fecha_aprobacion IS NOT NULL`);
w(`               AND NOT o.es_inventario_limitado`);
w(`               AND o.stock >= 3`);
w(`               AND NOT EXISTS (SELECT 1 FROM resena r`);
w(`                               WHERE r.id_usuario = v_autor AND r.id_usuario_vendedor = v_vendedor`);
w(`                                 AND r.id_producto_mongo = p.id_producto)`);
w(`             ORDER BY o.stock DESC, o.id_oferta`);
w(`             LIMIT 1;`);
w(`            EXIT WHEN v_oferta.id_oferta IS NOT NULL;`);
w(`        END LOOP;`);
w(``);
w(`        -- 2. Si nadie lo tiene, otro producto de la misma categoria.`);
w(`        IF v_oferta.id_oferta IS NOT NULL THEN`);
w(`            v_por_texto := v_por_texto + 1;`);
w(`        ELSE`);
w(`        FOR i IN 0..array_length(v_vendedores, 1) - 1 LOOP`);
w(`            SELECT id_usuario INTO v_vendedor FROM usuarios`);
w(`            WHERE correo_electronico = v_vendedores[1 + (v_fila.vendedor + i) % array_length(v_vendedores, 1)];`);
w(`            CONTINUE WHEN v_vendedor IS NULL;`);
w(``);
w(`            SELECT x.* INTO v_oferta`);
w(`            FROM (`);
w(`                SELECT d.*, row_number() OVER (ORDER BY d.id_producto) - 1 AS n, count(*) OVER () AS total`);
w(`                FROM (`);
w(`                    SELECT DISTINCT ON (p.id_producto)`);
w(`                           p.id_producto, p.nombre, o.id_oferta, pv.id_producto_variante, pv.nombre_variante,`);
w(`                           COALESCE(o.fecha_aprobacion, o.fecha_creacion) AS desde`);
w(`                    FROM productos p`);
w(`                    JOIN categorias c       ON c.id_categoria = p.id_categoria`);
w(`                    LEFT JOIN categorias cp ON cp.id_categoria = c.id_categoria_padre`);
w(`                    JOIN oferta o           ON o.id_producto_mongo = p.id_producto AND o.id_usuario = v_vendedor`);
w(`                    JOIN estado_oferta eo   ON eo.id_estado_oferta = o.id_estado_oferta AND eo.estado_oferta_nombre = 'activa'`);
w(`                    JOIN productos_variantes pv ON pv.id_producto_variante = o.id_producto_variante_mongo`);
w(`                    WHERE (c.nombre = v_fila.categoria OR cp.nombre = v_fila.categoria)`);
w(`                      AND p.nombre !~ ' [A-Z][0-9]+-[0-9]+$'`);
w(`                      AND o.fecha_aprobacion IS NOT NULL`);
w(`                      AND NOT o.es_inventario_limitado`);
w(`                      AND o.stock >= 3`);
w(`                      AND NOT EXISTS (SELECT 1 FROM resena r`);
w(`                                      WHERE r.id_usuario = v_autor AND r.id_usuario_vendedor = v_vendedor`);
w(`                                        AND r.id_producto_mongo = p.id_producto)`);
w(`                    ORDER BY p.id_producto, o.stock DESC, o.id_oferta`);
w(`                ) d`);
w(`            ) x`);
w(`            WHERE x.n = v_fila.elegir % x.total;`);
w(`            EXIT WHEN v_oferta.id_oferta IS NOT NULL;`);
w(`        END LOOP;`);
w(`        END IF;`);
w(``);
w(`        IF v_oferta.id_oferta IS NULL THEN`);
w(`            v_sin_oferta := v_sin_oferta + 1;`);
w(`            CONTINUE;`);
w(`        END IF;`);
w(``);
w(`        v_compra := GREATEST(v_fila.compra::timestamptz, v_oferta.desde + interval '1 day');`);
w(`        v_fecha  := LEAST(v_compra + make_interval(days => v_fila.dias), now() - interval '1 hour');`);
w(`        CONTINUE WHEN v_fecha <= v_compra;`);
w(``);
w(`        v_pedido := (comprar_carrito(v_autor, v_dir, jsonb_build_array(jsonb_build_object(`);
w(`            'id_oferta',            v_oferta.id_oferta,`);
w(`            'cantidad',             1,`);
w(`            'id_producto',          v_oferta.id_producto,`);
w(`            'id_producto_variante', v_oferta.id_producto_variante,`);
w(`            'nombre_producto',      v_oferta.nombre,`);
w(`            'nombre_variante',      v_oferta.nombre_variante`);
w(`        )), 'tarjeta'::varchar)->>'id_pedido')::bigint;`);
w(``);
w(`        UPDATE pedido           SET fecha_creacion    = v_compra WHERE id_pedido = v_pedido;`);
w(`        UPDATE pago             SET fecha_cancelacion = v_compra WHERE id_pedido = v_pedido;`);
w(`        UPDATE stock_movimiento SET fecha_movimiento  = v_compra WHERE id_pedido = v_pedido;`);
w(``);
w(`        INSERT INTO comentario (id_usuario, comentario, fecha_publicacion)`);
w(`        VALUES (v_autor, v_fila.texto, v_fecha)`);
w(`        RETURNING id_comentario INTO v_comentario;`);
w(``);
w(`        INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo, calificacion, id_comentario)`);
w(`        VALUES (v_autor, v_vendedor, v_oferta.id_producto, v_fila.estrellas, v_comentario);`);
w(`        v_nuevas := v_nuevas + 1;`);
w(`    END LOOP;`);
w(``);
w(`    RAISE NOTICE 'resenas del clasificador: % nuevas, % sin oferta donde caer, % en el producto del que habla el texto', v_nuevas, v_sin_oferta, v_por_texto;`);
w(`END`);
w(`$resenas_clasificador$;`);
w(``);

fs.writeFileSync(SALIDA, lineas.join('\n'), 'utf8');

// ------------------------------------------------------------
// quitar.sql: deshace la siembra
// ------------------------------------------------------------
// Borra las resenas de las 40 cuentas y las compras que las respaldan, y
// devuelve el stock. Las cuentas y sus direcciones se quedan: el siguiente
// arranque vuelve a sembrar encima. Sirve para cambiar el reparto (como el
// 2026-10-04, de producto al azar a producto por parecido) sin restaurar la
// base.
//
// Todo pasa por las tablas de siempre, asi que los triggers dejan cada cambio
// en sus colas: evento_grafo quita las resenas de Neo4j, evento_comentario las
// quita de mesh_comentarios y evento_producto recalcula en Mongo la nota y el
// stock de cada producto tocado. Lo hacen los workers del backend.
const q = [];
const v = (x) => q.push(x);
v(`-- ============================================================`);
v(`-- clasificador-resenas/semilla/quitar.sql`);
v(`-- ============================================================`);
v(`-- GENERADO por clasificador-resenas/semilla/generar.js. Deshace resenas.sql:`);
v(`-- las resenas de las ${CUENTAS.length} cuentas, sus respuestas y votos, y sus compras, con el`);
v(`-- stock devuelto. Las cuentas se quedan. Se corre a mano:`);
v(`--   docker cp clasificador-resenas/semilla/quitar.sql mesh-postgres:/tmp/quitar.sql`);
v(`--   docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> -v ON_ERROR_STOP=1 -f /tmp/quitar.sql`);
v(`-- ============================================================`);
v(``);
v(`BEGIN;`);
v(``);
v(`CREATE TEMP TABLE sembradas ON COMMIT DROP AS`);
v(`SELECT id_usuario FROM usuarios WHERE correo_electronico IN (`);
v(CUENTAS.map((c, i) => `    ${lit(c.correo)}` + (i < CUENTAS.length - 1 ? ',' : '')).join('\n'));
v(`);`);
v(``);
v(`-- Los comentarios raiz de sus resenas y todo lo que cuelga de ellos.`);
v(`CREATE TEMP TABLE hilo ON COMMIT DROP AS`);
v(`WITH RECURSIVE h AS (`);
v(`    SELECT r.id_comentario, 0 AS nivel FROM resena r WHERE r.id_usuario IN (SELECT id_usuario FROM sembradas)`);
v(`    UNION ALL`);
v(`    SELECT c.id_comentario, h.nivel + 1 FROM comentario c JOIN h ON c.id_comentario_padre = h.id_comentario`);
v(`)`);
v(`SELECT id_comentario, nivel FROM h;`);
v(``);
v(`DELETE FROM senal_fraude_resena WHERE id_resena IN (SELECT id_resena FROM resena WHERE id_usuario IN (SELECT id_usuario FROM sembradas));`);
v(`DELETE FROM likes WHERE id_comentario IN (SELECT id_comentario FROM hilo);`);
v(`DELETE FROM resena WHERE id_usuario IN (SELECT id_usuario FROM sembradas);`);
v(`-- De las hojas a la raiz: la llave al padre es RESTRICT.`);
v(`DO $hilo$`);
v(`DECLARE v_nivel integer;`);
v(`BEGIN`);
v(`    FOR v_nivel IN SELECT DISTINCT nivel FROM hilo ORDER BY nivel DESC LOOP`);
v(`        DELETE FROM comentario WHERE id_comentario IN (SELECT id_comentario FROM hilo WHERE nivel = v_nivel);`);
v(`    END LOOP;`);
v(`END`);
v(`$hilo$;`);
v(``);
v(`-- Las compras: el stock vuelve a la oferta (el trigger de oferta avisa a Mongo).`);
v(`CREATE TEMP TABLE pedidos_sembrados ON COMMIT DROP AS`);
v(`SELECT id_pedido FROM pedido WHERE id_usuario IN (SELECT id_usuario FROM sembradas);`);
v(``);
v(`UPDATE oferta o SET stock = o.stock + m.cantidad`);
v(`  FROM (SELECT sm.id_oferta, sum(sm.cantidad * -mm.valor) AS cantidad`);
v(`          FROM stock_movimiento sm`);
v(`          JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento`);
v(`         WHERE sm.id_pedido IN (SELECT id_pedido FROM pedidos_sembrados)`);
v(`         GROUP BY sm.id_oferta) m`);
v(` WHERE o.id_oferta = m.id_oferta;`);
v(``);
v(`DELETE FROM senal_fraude_pedido WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);`);
v(`DELETE FROM stock_movimiento WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);`);
v(`DELETE FROM pago WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);`);
v(`DELETE FROM pedido_producto WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);`);
v(`DELETE FROM pedido WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);`);
v(``);
v(`DO $comprobar$`);
v(`BEGIN`);
v(`    IF EXISTS (SELECT 1 FROM resena WHERE id_usuario IN (SELECT id_usuario FROM sembradas))`);
v(`       OR EXISTS (SELECT 1 FROM pedido WHERE id_usuario IN (SELECT id_usuario FROM sembradas)) THEN`);
v(`        RAISE EXCEPTION 'Quedaron resenas o pedidos de las cuentas sembradas';`);
v(`    END IF;`);
v(`    RAISE NOTICE 'Siembra del clasificador quitada';`);
v(`END`);
v(`$comprobar$;`);
v(``);
v(`COMMIT;`);
v(``);
fs.writeFileSync(path.join(__dirname, 'quitar.sql'), q.join('\n'), 'utf8');
const distintos = new Set(FILAS.map((f) => f.producto)).size;
console.log(`${path.relative(process.cwd(), SALIDA)}: ${RESENAS.length} resenas, ${CUENTAS.length} cuentas, sobre ${distintos} de ${PRODUCTOS.length} productos originales`);
})().catch((e) => { console.error(e.message); process.exit(1); });
