// pruebas/pedidos_tienda.mjs -- la tienda gestiona los pedidos de todos
// (migracion 051, POST /admin/pedidos/:id/cancelar|enviado|entregado).
//
//   node pruebas/pedidos_tienda.mjs
//
// Compra como compradora.norte una unidad de la oferta activa mas barata, y
// comprueba que:
//   - solo el admin entra a /admin/pedidos (401 sin sesion, 403 a comprador y
//     vendedor);
//   - el pedido pasa a enviado y a entregado solo hacia adelante;
//   - la compradora ya no puede cancelar lo enviado, y la tienda si;
//   - al cancelar la tienda vuelven las unidades, el pago queda reembolsado, el
//     cambio queda anotado con quien y por que, el movimiento de stock queda a
//     nombre del admin, y la devolucion llega a ClickHouse a nombre de la
//     compradora con por_la_tienda = 1: el pedido sale de las ventas, y F5
//     (devoluciones seriales) no se la cuenta (2026-11-07);
//   - cuando cancela la compradora todo sigue como antes, con su devolucion y
//     por_la_tienda = 0.
//
// Deja dos pedidos cancelados de compradora.norte, con su stock devuelto. Al
// final borra de ClickHouse las compras y devoluciones de esos dos pedidos,
// con el dueno de la base (el backend no borra, ADR-14), para que no muevan lo
// mas vendido ni las tendencias. Vacia el carrito de la compradora al empezar.

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

// El dueno de ClickHouse, del .env de la PC que tiene las bases (igual que
// pruebas/demo_concurrencia.mjs). Sin el, se lee con el backend y no se borra.
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

const estadoDe = async (id) =>
  (await sql(`SELECT ep.estado_pedido_nombre AS e FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido) WHERE p.id_pedido = $1`, [id]))[0]?.e;
const stockDe = async (idOferta) => Number((await sql('SELECT stock FROM oferta WHERE id_oferta = $1', [idOferta]))[0].stock);
const ultimoCambio = async (id) =>
  (
    await sql(
      `SELECT epa.estado_pedido_nombre AS de, epn.estado_pedido_nombre AS a, pce.id_usuario::text AS quien, pce.por_la_tienda, pce.motivo
         FROM pedido_cambio_estado pce
         JOIN estado_pedido epa ON epa.id_estado_pedido = pce.id_estado_anterior
         JOIN estado_pedido epn ON epn.id_estado_pedido = pce.id_estado_nuevo
        WHERE pce.id_pedido = $1
        ORDER BY pce.fecha DESC, pce.id_pedido_cambio_estado DESC LIMIT 1`,
      [id],
    )
  )[0];

const pedidosDeLaPrueba = [];
const inicio = new Date();
let ofertaDeLaPrueba = null;
let idCompradoraPrueba = null;

try {
  titulo('0. Las cuentas y la oferta');
  const admin = await entrar('admin@mesh.com', 'Admin123');
  const compradora = await entrar('compradora.norte@mesh.com', 'Comprador123');
  const vendedor = await entrar('ventas.norte@mesh.com', 'Vendedor123');
  if (!admin || !compradora || !vendedor) throw new Error(`El backend no responde en ${API} o no deja entrar a las cuentas de la semilla`);
  const [{ id_usuario: idAdmin }] = await sql(`SELECT id_usuario::text FROM usuarios WHERE correo_electronico = 'admin@mesh.com'`);
  const [{ id_usuario: idCompradora }] = await sql(`SELECT id_usuario::text FROM usuarios WHERE correo_electronico = 'compradora.norte@mesh.com'`);
  // La oferta activa mas barata con unidades, sin venta relampago, de un
  // producto activo y que no sea de la compradora.
  const [oferta] = await sql(
    `SELECT o.id_oferta::int AS id
       FROM oferta o
       JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta AND eo.estado_oferta_nombre = 'activa'
       JOIN producto_catalogo pc ON pc.id_producto_mongo = o.id_producto_mongo AND pc.estado = 'activo'
      WHERE o.stock >= 5 AND NOT o.es_inventario_limitado AND o.id_usuario <> $1
      ORDER BY o.precio, o.id_oferta LIMIT 1`,
    [idCompradora],
  );
  revisar(oferta != null, `hay una oferta para comprar (${oferta?.id})`);
  ofertaDeLaPrueba = oferta?.id ?? null;
  idCompradoraPrueba = idCompradora;
  await pedir('/carrito', { metodo: 'DELETE', galleta: compradora });
  const direcciones = (await pedir('/direccion-usuario', { galleta: compradora })).j?.payload;
  const idDireccion = (Array.isArray(direcciones) ? direcciones : direcciones?.direcciones ?? [])[0]?.id_direccion;
  revisar(idDireccion != null, 'la compradora tiene una direccion');

  async function comprar() {
    const agregar = await pedir(`/carrito/lineas/${oferta.id}`, { metodo: 'PUT', galleta: compradora, cuerpo: { cantidad: 1 } });
    const compra = await pedir('/carrito/comprar', { metodo: 'POST', galleta: compradora, cuerpo: { id_direccion: idDireccion, metodo_pago: 'efectivo contra entrega' } });
    const id = compra.j?.payload?.id_pedido;
    if (id) pedidosDeLaPrueba.push(Number(id));
    return { agregar: agregar.codigo, compra: compra.codigo, id: Number(id) };
  }

  titulo('1. Solo el admin gestiona pedidos');
  revisar((await pedir('/admin/pedidos/1/enviado', { metodo: 'POST' })).codigo === 401, 'sin sesion contesta 401');
  revisar((await pedir('/admin/pedidos/1/enviado', { metodo: 'POST', galleta: compradora })).codigo === 403, 'la compradora recibe 403');
  revisar((await pedir('/admin/pedidos/1/cancelar', { metodo: 'POST', galleta: vendedor, cuerpo: {} })).codigo === 403, 'el vendedor recibe 403 al cancelar');

  titulo('2. Comprar, enviar y entregar');
  const stockAntes = await stockDe(oferta.id);
  const uno = await comprar();
  revisar(uno.agregar === 200 && uno.compra === 201 && uno.id > 0, `la compradora compra una unidad, pedido ${uno.id}`, `agregar ${uno.agregar}, comprar ${uno.compra}`);
  revisar((await stockDe(oferta.id)) === stockAntes - 1, 'el stock baja una unidad');
  const enviar = await pedir(`/admin/pedidos/${uno.id}/enviado`, { metodo: 'POST', galleta: admin });
  revisar(enviar.codigo === 201 && (await estadoDe(uno.id)) === 'enviado', 'el admin lo marca enviado', `${enviar.codigo} ${enviar.j?.mensaje}`);
  const cambioEnvio = await ultimoCambio(uno.id);
  revisar(cambioEnvio?.de === 'comprado' && cambioEnvio?.a === 'enviado' && cambioEnvio?.por_la_tienda === true && cambioEnvio?.quien === idAdmin, 'queda anotado de comprado a enviado, por la tienda, con el admin');
  revisar((await pedir(`/admin/pedidos/${uno.id}/enviado`, { metodo: 'POST', galleta: admin })).codigo === 409, 'enviarlo otra vez contesta 409');
  const propia = await pedir(`/comprador/pedidos/${uno.id}/cancelar`, { metodo: 'POST', galleta: compradora, cuerpo: {} });
  revisar(propia.codigo === 409 && (await estadoDe(uno.id)) === 'enviado', 'la compradora ya no puede cancelar lo enviado (409)', `${propia.codigo} ${propia.j?.mensaje}`);
  const entregar = await pedir(`/admin/pedidos/${uno.id}/entregado`, { metodo: 'POST', galleta: admin });
  revisar(entregar.codigo === 201 && (await estadoDe(uno.id)) === 'entregado', 'el admin lo marca entregado');
  revisar((await pedir(`/admin/pedidos/${uno.id}/enviado`, { metodo: 'POST', galleta: admin })).codigo === 409, 'de entregado no se vuelve a enviado (409)');

  titulo('3. La tienda cancela lo entregado');
  const motivo = 'Prueba de pedidos_tienda.mjs';
  const cancelar = await pedir(`/admin/pedidos/${uno.id}/cancelar`, { metodo: 'POST', galleta: admin, cuerpo: { motivo } });
  revisar(cancelar.codigo === 201 && (await estadoDe(uno.id)) === 'cancelado', 'el admin lo cancela', `${cancelar.codigo} ${cancelar.j?.mensaje}`);
  revisar(cancelar.j?.payload?.por_la_tienda === true && cancelar.j?.payload?.estado_previo === 'entregado', 'la respuesta dice que fue la tienda y que estaba entregado');
  revisar((await stockDe(oferta.id)) === stockAntes, 'la unidad vuelve a la oferta');
  const [pago] = await sql(`SELECT ep.estado_pago_nombre AS e FROM pago p JOIN estado_pago ep USING (id_estado_pago) WHERE p.id_pedido = $1`, [uno.id]);
  revisar(pago?.e === 'reembolsado', 'el pago queda reembolsado', pago?.e);
  const cambioCancel = await ultimoCambio(uno.id);
  revisar(cambioCancel?.a === 'cancelado' && cambioCancel?.por_la_tienda === true && cambioCancel?.motivo === motivo && cambioCancel?.quien === idAdmin, 'queda anotado cancelado por la tienda, con el admin y el motivo');
  const [mov] = await sql(
    `SELECT sm.id_usuario_modifico::text AS quien FROM stock_movimiento sm JOIN motivo_movimiento mm USING (id_motivo_movimiento)
      WHERE sm.id_pedido = $1 AND mm.motivo_nombre = 'devolucion'`,
    [uno.id],
  );
  revisar(mov?.quien === idAdmin, 'el movimiento de devolucion queda a nombre del admin, no de la compradora');
  revisar((await pedir(`/admin/pedidos/${uno.id}/cancelar`, { metodo: 'POST', galleta: admin, cuerpo: {} })).codigo === 409, 'cancelarlo otra vez contesta 409');
  const mias = (await pedir('/comprador/pedidos', { galleta: compradora })).j?.payload ?? [];
  revisar(mias.find((p) => Number(p.id_pedido) === uno.id)?.cancelado_por_tienda === true, 'en Mis pedidos la compradora ve que lo cancelo la tienda');
  const registro = (await pedir(`/admin/dashboard/pedidos?texto=${uno.id}&desde=2026-01-01`, { galleta: admin })).j?.payload?.pedidos ?? [];
  const fila = registro.find((p) => p.id_pedido === uno.id);
  revisar(fila?.por_la_tienda === true && fila?.motivo === motivo && fila?.estado === 'cancelado', 'el Registro de pedidos lo trae cancelado por la tienda, con su motivo');

  titulo('4. Lo que no se puede');
  revisar((await pedir('/admin/pedidos/abc/enviado', { metodo: 'POST', galleta: admin })).codigo === 400, 'un id con letras contesta 400');
  revisar((await pedir('/admin/pedidos/999999999/cancelar', { metodo: 'POST', galleta: admin, cuerpo: {} })).codigo === 404, 'un pedido que no existe contesta 404');
  revisar((await pedir(`/admin/pedidos/${uno.id}/cancelar`, { metodo: 'POST', galleta: admin, cuerpo: { motivo: 'x'.repeat(301) } })).codigo === 400, 'un motivo de mas de 300 letras contesta 400');
  await pedir(`/carrito/lineas/${oferta.id}`, { metodo: 'PUT', galleta: compradora, cuerpo: { cantidad: 1 } });
  // La copia del carrito en PostgreSQL se escribe un momento despues.
  let carrito;
  for (let i = 0; i < 20 && !carrito; i++) {
    [carrito] = await sql(
      `SELECT p.id_pedido::int AS id FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido) WHERE p.id_usuario = $1 AND ep.estado_pedido_nombre = 'pendiente'`,
      [idCompradora],
    );
    if (!carrito) await espera(300);
  }
  revisar(
    carrito != null && (await pedir(`/admin/pedidos/${carrito.id}/cancelar`, { metodo: 'POST', galleta: admin, cuerpo: {} })).codigo === 409,
    'el carrito de alguien no se cancela (409)',
  );
  await pedir('/carrito', { metodo: 'DELETE', galleta: compradora });

  titulo('5. La compradora cancela lo suyo como siempre');
  const dos = await comprar();
  revisar(dos.compra === 201, `otra compra, pedido ${dos.id}`);
  const suya = await pedir(`/comprador/pedidos/${dos.id}/cancelar`, { metodo: 'POST', galleta: compradora, cuerpo: {} });
  revisar(suya.codigo === 201 && (await estadoDe(dos.id)) === 'cancelado', 'la compradora cancela lo comprado');
  const cambioSuyo = await ultimoCambio(dos.id);
  revisar(cambioSuyo?.por_la_tienda === false && cambioSuyo?.quien === idCompradora, 'queda anotado como suyo, no de la tienda');
  revisar((await stockDe(oferta.id)) === stockAntes, 'el stock queda como al principio');

  titulo('6. ClickHouse');
  await espera(5000);
  const devueltas = async (id) =>
    (await (await ch.query({
      query: `SELECT count() AS n, groupUniqArray(id_usuario) AS quien, groupUniqArray(por_la_tienda) AS marca FROM devolucion_producto WHERE id_pedido = ${id}`,
      format: 'JSONEachRow',
    })).json())[0];
  const deLaTienda = await devueltas(uno.id);
  revisar(
    Number(deLaTienda.n) > 0 && deLaTienda.marca.join() === '1',
    `la cancelacion de la tienda manda su devolucion con por_la_tienda = 1 (${deLaTienda.n} linea(s)), asi el pedido sale de las ventas`,
  );
  revisar(
    deLaTienda.quien.map(String).join() === String(idCompradora),
    'y a nombre de la compradora, como su compra, no del admin',
  );
  const suyaEnCh = await devueltas(dos.id);
  revisar(Number(suyaEnCh.n) > 0 && suyaEnCh.marca.join() === '0', 'la de la compradora manda su devolucion con por_la_tienda = 0, como antes');
  // F5 (hallazgos-evento-fraude-detector) cuenta solo por_la_tienda = 0: lo
  // mismo que el backend, con la misma condicion, sobre estos dos pedidos.
  const paraF5 = Number((await (await ch.query({
    query: `SELECT count() AS n FROM devolucion_producto FINAL WHERE id_pedido IN (${uno.id}, ${dos.id}) AND por_la_tienda = 0`,
    format: 'JSONEachRow',
  })).json())[0].n);
  revisar(paraF5 === Number(suyaEnCh.n), 'F5 solo ve la devolucion de la compradora, no la de la tienda');
} catch (error) {
  fallas++;
  console.log(`  FALLA  ${error.message}`);
} finally {
  if (pedidosDeLaPrueba.length) {
    const ids = pedidosDeLaPrueba.join(',');
    try {
      if (!dueno) throw new Error('sin el dueno de ClickHouse en el .env');
      for (const tabla of ['compra_producto', 'devolucion_producto']) {
        await ch.command({ query: `ALTER TABLE ${tabla} DELETE WHERE id_pedido IN (${ids}) SETTINGS mutations_sync = 2` });
      }
      if (ofertaDeLaPrueba && idCompradoraPrueba) {
        const desde = inicio.toISOString().slice(0, 19).replace('T', ' ');
        await ch.command({
          query: `ALTER TABLE carrito_producto DELETE WHERE id_oferta = ${ofertaDeLaPrueba} AND id_usuario = ${idCompradoraPrueba}
                    AND fecha >= toDateTime('${desde}', 'UTC') SETTINGS mutations_sync = 2`,
        });
      }
      console.log(`\n  ClickHouse sin las compras ni los carritos de la prueba (pedidos ${ids})`);
    } catch (error) {
      console.log(`\n  No se borraron de ClickHouse las compras de la prueba (${error.message})`);
    }
  }
  await pg.end();
  await ch.close();
}

console.log(`\n${oks} OK, ${fallas} FALLA`);
process.exit(fallas > 0 ? 1 : 0);
