// pruebas/producto_inactivo.mjs -- un producto que la tienda retira del
// catalogo ya no se vende, aunque su oferta siga activa y este en un carrito.
//
//   node pruebas/producto_inactivo.mjs
//
// El admin crea un producto de prueba, le publica una oferta (nace activa,
// es de la tienda) y la compradora la pone en su carrito. Despues el admin
// retira el producto: agregar y pagar contestan 409 y dicen por que. Al
// volverlo a activar, la misma oferta se puede comprar otra vez, sin tocarla.
//
// No compra nada. Deja el producto de prueba inactivo y su oferta retirada
// (no hay ruta para borrar un producto), vacia el carrito de la compradora y
// borra de ClickHouse sus eventos de carrito de esa oferta.

import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const requerir = createRequire(join(RAIZ, 'backend', 'package.json'));
requerir('dotenv').config({ path: join(RAIZ, 'backend', '.env'), quiet: true });
const { Pool } = requerir('pg');
const { createClient } = requerir('@clickhouse/client');

const API = process.env.API ?? 'http://localhost:3000';
const e = process.env;
const pg = new Pool({ host: e.DB_HOST, port: Number(e.DB_PORT ?? 5432), user: e.DB_USER, password: e.DB_PASSWORD, database: e.DB_NAME, max: 2 });
const sql = async (texto, valores) => (await pg.query(texto, valores)).rows;

function duenoClickHouse() {
  const local = ['localhost', '127.0.0.1'].includes(e.CLICKHOUSE_HOST ?? 'localhost');
  const archivo = local ? join(RAIZ, '.env') : join(RAIZ, 'remoto', '.env.remoto');
  if (!existsSync(archivo)) return null;
  const v = requerir('dotenv').parse(readFileSync(archivo));
  return v.CLICKHOUSE_USER && v.CLICKHOUSE_PASSWORD ? { username: v.CLICKHOUSE_USER, password: v.CLICKHOUSE_PASSWORD } : null;
}
const dueno = duenoClickHouse();
const ch = createClient({
  url: `http://${e.CLICKHOUSE_HOST ?? 'localhost'}:${e.CLICKHOUSE_PORT ?? 8123}`,
  username: dueno?.username ?? e.CLICKHOUSE_USER,
  password: dueno?.password ?? e.CLICKHOUSE_PASSWORD,
  database: e.CLICKHOUSE_DB,
});

let oks = 0;
let fallas = 0;
const revisar = (cond, texto, detalle = '') => {
  if (cond) {
    oks++;
    console.log(`  OK     ${texto}`);
  } else {
    fallas++;
    console.log(`  FALLA  ${texto}${detalle ? `  (${detalle})` : ''}`);
  }
};
const titulo = (t) => console.log(`\n=== ${t}`);
const espera = (ms) => new Promise((r) => setTimeout(r, ms));

async function entrar(correo, clave) {
  const r = await fetch(`${API}/usuario/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identificador: correo, contrasena: clave }),
  });
  return (r.headers.get('set-cookie') ?? '').split(';')[0];
}
async function pedir(ruta, { metodo = 'GET', galleta = '', cuerpo } = {}) {
  const r = await fetch(`${API}${ruta}`, {
    method: metodo,
    headers: { ...(galleta ? { Cookie: galleta } : {}), ...(cuerpo !== undefined ? { 'Content-Type': 'application/json' } : {}) },
    body: cuerpo !== undefined ? JSON.stringify(cuerpo) : undefined,
  });
  const j = r.headers.get('content-type')?.includes('json') ? await r.json() : null;
  return { codigo: r.status, j };
}
// La copia del catalogo en PostgreSQL la pone al dia un worker en segundos.
async function esperarEstado(idProducto, estado) {
  for (let i = 0; i < 40; i++) {
    const [fila] = await sql('SELECT estado FROM producto_catalogo WHERE id_producto_mongo = $1', [idProducto]);
    if (fila?.estado === estado) return true;
    await espera(500);
  }
  return false;
}

const inicio = new Date();
let admin = '';
let compradora = '';
let idProducto = null;
let idOferta = null;
let idCompradora = null;

try {
  titulo('0. Un producto de prueba con su oferta');
  admin = await entrar('admin@mesh.com', 'Admin123');
  compradora = await entrar('compradora.norte@mesh.com', 'Comprador123');
  if (!admin || !compradora) throw new Error(`El backend no responde en ${API} o no deja entrar a las cuentas de la semilla`);
  [{ id_usuario: idCompradora }] = await sql(`SELECT id_usuario::text FROM usuarios WHERE correo_electronico = 'compradora.norte@mesh.com'`);
  // Se reutiliza el producto de una corrida anterior, que quedo inactivo: no
  // hay ruta para borrar un producto y cada corrida dejaria uno mas.
  const [previo] = await sql(
    `SELECT pc.id_producto_mongo::int AS id, vc.id_producto_variante_mongo::int AS variante
       FROM producto_catalogo pc
       JOIN variante_catalogo vc ON vc.id_producto_mongo = pc.id_producto_mongo
      WHERE pc.nombre LIKE 'Prueba producto inactivo%'
      ORDER BY pc.id_producto_mongo DESC LIMIT 1`,
  );
  let idVariante = previo?.variante ?? null;
  let estadoCreado = null;
  if (previo) {
    idProducto = previo.id;
    revisar(true, `se reutiliza el producto de prueba ${idProducto}`);
  } else {
    const [cocina] = await sql(`SELECT id_categoria::int AS id FROM categorias WHERE nombre = 'Cocina'`);
    const creado = await pedir('/vendedor/productos', {
      metodo: 'POST',
      galleta: admin,
      cuerpo: {
        id_categoria: cocina.id,
        nombre: 'Prueba producto inactivo',
        descripcion: 'Lo crea pruebas/producto_inactivo.mjs y lo deja retirado',
        caracteristicas_adicionales: [],
        caracteristicas_personalizadas: [],
        variantes: [{ nombre_variante: 'Unica', descripcion: 'La unica variante de la prueba', imagenes: [] }],
      },
    });
    idProducto = creado.j?.payload?._id ?? creado.j?.payload?.id_producto ?? null;
    idVariante = creado.j?.payload?.variantes?.[0]?.id_producto_variante ?? null;
    estadoCreado = creado.j?.payload?.estado ?? null;
    revisar(creado.codigo === 201 && idProducto != null && idVariante != null, `el admin crea el producto ${idProducto}`, `${creado.codigo} ${creado.j?.mensaje}`);
  }
  if (estadoCreado !== 'activo') {
    const activar = await pedir(`/vendedor/productos/${idProducto}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'activo' } });
    revisar(activar.codigo === 200, 'lo deja activo', `${activar.codigo} ${activar.j?.mensaje}`);
  }
  revisar(await esperarEstado(idProducto, 'activo'), 'la copia del catalogo en PostgreSQL lo tiene activo');
  // Una oferta por variante y vendedor (UNIQUE de oferta): si la de la tienda
  // quedo retirada de otra corrida, se vuelve a activar.
  const [ofertaPrevia] = await sql(
    `SELECT o.id_oferta::int AS id FROM oferta o JOIN usuarios u ON u.id_usuario = o.id_usuario
      WHERE o.id_producto_variante_mongo = $1 AND u.correo_electronico = 'tienda@mesh.com'`,
    [idVariante],
  );
  if (ofertaPrevia) {
    const reactivar = await pedir(`/vendedor/ofertas/${ofertaPrevia.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'activa' } });
    idOferta = ofertaPrevia.id;
    revisar(reactivar.codigo === 200, `la tienda vuelve a activar su oferta ${idOferta}`, `${reactivar.codigo} ${reactivar.j?.mensaje}`);
  } else {
    const oferta = await pedir('/vendedor/ofertas', { metodo: 'POST', galleta: admin, cuerpo: { id_producto: idProducto, id_producto_variante: idVariante, precio: '10.00', stock_inicial: 5 } });
    idOferta = oferta.j?.payload?.id_oferta ?? null;
    revisar(oferta.codigo === 201 && idOferta != null, `la tienda le publica la oferta ${idOferta}`, `${oferta.codigo} ${oferta.j?.mensaje}`);
  }

  titulo('1. Con el producto activo se agrega');
  await pedir('/carrito', { metodo: 'DELETE', galleta: compradora });
  const agregar = await pedir(`/carrito/lineas/${idOferta}`, { metodo: 'PUT', galleta: compradora, cuerpo: { cantidad: 1 } });
  revisar(agregar.codigo === 200, 'la compradora la pone en su carrito', `${agregar.codigo} ${agregar.j?.mensaje}`);

  titulo('2. La tienda retira el producto');
  const retirar = await pedir(`/vendedor/productos/${idProducto}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'inactivo' } });
  revisar(retirar.codigo === 200, 'el admin lo deja inactivo', `${retirar.codigo} ${retirar.j?.mensaje}`);
  revisar(await esperarEstado(idProducto, 'inactivo'), 'la copia del catalogo lo tiene inactivo');
  const [{ e: estadoOferta }] = await sql(`SELECT eo.estado_oferta_nombre AS e FROM oferta o JOIN estado_oferta eo USING (id_estado_oferta) WHERE o.id_oferta = $1`, [idOferta]);
  revisar(estadoOferta === 'activa', 'la oferta sigue activa, no se toca');
  const [dir] = (await pedir('/direccion-usuario', { galleta: compradora })).j?.payload ?? [];
  const pagar = await pedir('/carrito/comprar', { metodo: 'POST', galleta: compradora, cuerpo: { id_direccion: dir?.id_direccion, metodo_pago: 'efectivo contra entrega' } });
  revisar(pagar.codigo === 409 && /retiro del catalogo/.test(pagar.j?.mensaje ?? ''), 'pagar contesta 409 y dice que la tienda lo retiro', `${pagar.codigo} ${pagar.j?.mensaje}`);
  // El carrito deja tener la linea, como con una oferta pausada, pero la marca
  // como no disponible y dice por que. El freno de verdad es pagar.
  // GET /carrito lee la foto que se guardo al agregar o al cambiar la
  // cantidad. Al cambiarla con el producto ya retirado, la foto nueva dice
  // que no se puede comprar y por que.
  await pedir(`/carrito/lineas/${idOferta}`, { metodo: 'PUT', galleta: compradora, cuerpo: { cantidad: 2 } });
  const carrito = (await pedir('/carrito', { galleta: compradora })).j?.payload;
  const linea = carrito?.lineas?.find((l) => Number(l.id_oferta) === Number(idOferta));
  revisar(linea?.disponible === false && linea?.motivo === 'producto_no_disponible', 'al cambiar la cantidad el carrito la marca no disponible, producto_no_disponible', `${linea?.disponible} ${linea?.motivo}`);
  const [{ n: pedidosNuevos }] = await sql(
    `SELECT count(*)::int AS n FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
      WHERE p.id_usuario = $1 AND ep.estado_pedido_nombre <> 'pendiente' AND p.fecha_creacion >= $2`,
    [idCompradora, inicio],
  );
  revisar(pedidosNuevos === 0, 'no se creo ningun pedido');

  titulo('3. Al activarlo otra vez, todo vuelve solo');
  const volver = await pedir(`/vendedor/productos/${idProducto}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'activo' } });
  revisar(volver.codigo === 200 && (await esperarEstado(idProducto, 'activo')), 'el admin lo vuelve a activar');
  const otraVez = await pedir(`/carrito/lineas/${idOferta}`, { metodo: 'PUT', galleta: compradora, cuerpo: { cantidad: 2 } });
  revisar(otraVez.codigo === 200, 'la misma oferta se puede agregar otra vez', `${otraVez.codigo} ${otraVez.j?.mensaje}`);
} catch (error) {
  fallas++;
  console.log(`  FALLA  ${error.message}`);
} finally {
  if (compradora) await pedir('/carrito', { metodo: 'DELETE', galleta: compradora });
  if (admin && idOferta) await pedir(`/vendedor/ofertas/${idOferta}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'retirada' } });
  if (admin && idProducto) await pedir(`/vendedor/productos/${idProducto}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'inactivo' } });
  if (idOferta && idCompradora && dueno) {
    try {
      const desde = inicio.toISOString().slice(0, 19).replace('T', ' ');
      await ch.command({
        query: `ALTER TABLE carrito_producto DELETE WHERE id_oferta = ${idOferta} AND id_usuario = ${idCompradora}
                  AND fecha >= toDateTime('${desde}', 'UTC') SETTINGS mutations_sync = 2`,
      });
    } catch (error) {
      console.log(`  No se borraron de ClickHouse los carritos de la prueba (${error.message})`);
    }
  }
  console.log(`\n  Queda el producto ${idProducto} inactivo y su oferta ${idOferta} retirada, el carrito vacio`);
  await pg.end();
  await ch.close();
}

console.log(`\n${oks} OK, ${fallas} FALLA`);
process.exit(fallas > 0 ? 1 : 0);
