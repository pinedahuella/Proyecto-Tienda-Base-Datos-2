// pruebas/ofertas_tienda.mjs -- la tienda gestiona la oferta de cualquier
// vendedor (migracion 053, GET /admin/ofertas y PATCH /admin/ofertas/:id).
//
//   node pruebas/ofertas_tienda.mjs
//
// Toma una oferta activa de un vendedor que no es la tienda y comprueba que:
//   - solo el admin entra (401 sin sesion, 403 a compradora y vendedor);
//   - el admin ve todas las ofertas del producto, tambien las no activas;
//   - la pausa y deja de salir en la ficha, y la vuelve a activar;
//   - le suma y le resta unidades, y el kardex lo anota a nombre del admin;
//   - no la deja en negativo, no le cambia el precio y no acepta estados raros;
//   - la retira y la puede volver a activar.
// Al final la oferta queda como estaba: mismo estado y mismas unidades.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const requerir = createRequire(join(RAIZ, 'backend', 'package.json'));
requerir('dotenv').config({ path: join(RAIZ, 'backend', '.env'), quiet: true });
const { Pool } = requerir('pg');

const API = process.env.API ?? 'http://localhost:3000';
const e = process.env;
const pg = new Pool({ host: e.DB_HOST, port: Number(e.DB_PORT ?? 5432), user: e.DB_USER, password: e.DB_PASSWORD, database: e.DB_NAME, max: 2 });
const sql = async (texto, valores) => (await pg.query(texto, valores)).rows;

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
const filaOferta = async (id) =>
  (
    await sql(
      `SELECT o.stock, o.precio::text AS precio, eo.estado_oferta_nombre AS estado
         FROM oferta o JOIN estado_oferta eo USING (id_estado_oferta) WHERE o.id_oferta = $1`,
      [id],
    )
  )[0];

let admin = '';
let oferta = null;
let original = null;

try {
  titulo('0. Una oferta activa de un vendedor');
  admin = await entrar('admin@mesh.com', 'Admin123');
  const compradora = await entrar('compradora.norte@mesh.com', 'Comprador123');
  const vendedor = await entrar('ventas.norte@mesh.com', 'Vendedor123');
  if (!admin || !compradora || !vendedor) throw new Error(`El backend no responde en ${API} o no deja entrar a las cuentas de la semilla`);
  const [{ id_usuario: idAdmin }] = await sql(`SELECT id_usuario::text FROM usuarios WHERE correo_electronico = 'admin@mesh.com'`);
  [oferta] = await sql(
    `SELECT o.id_oferta::int AS id, o.id_producto_mongo::int AS producto, u.correo_electronico AS dueno
       FROM oferta o
       JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta AND eo.estado_oferta_nombre = 'activa'
       JOIN usuarios u ON u.id_usuario = o.id_usuario
       JOIN producto_catalogo pc ON pc.id_producto_mongo = o.id_producto_mongo AND pc.estado = 'activo'
      WHERE u.correo_electronico = 'ventas.sur@mesh.com' AND o.stock >= 3 AND NOT o.es_inventario_limitado
        AND o.porcentaje_descuento IS NULL
      ORDER BY o.id_oferta LIMIT 1`,
  );
  revisar(oferta != null, `oferta ${oferta?.id} de ${oferta?.dueno}, producto ${oferta?.producto}`);
  original = await filaOferta(oferta.id);

  titulo('1. Solo la tienda');
  revisar((await pedir(`/admin/ofertas?producto=${oferta.producto}`)).codigo === 401, 'sin sesion contesta 401');
  revisar((await pedir(`/admin/ofertas?producto=${oferta.producto}`, { galleta: compradora })).codigo === 403, 'la compradora recibe 403');
  revisar((await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: vendedor, cuerpo: { estado: 'pausada' } })).codigo === 403, 'otro vendedor recibe 403');
  revisar((await pedir(`/vendedor/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: vendedor, cuerpo: { estado: 'pausada' } })).codigo === 404, 'y por su ruta de vendedor la oferta ajena no existe (404, como siempre)');

  titulo('2. Ver todas las ofertas del producto');
  const lista = await pedir(`/admin/ofertas?producto=${oferta.producto}`, { galleta: admin });
  const enLista = lista.j?.payload?.find((o) => Number(o.id_oferta) === oferta.id);
  revisar(lista.codigo === 200 && enLista?.estado === 'activa', `el admin ve la oferta en la lista del producto (${lista.j?.payload?.length} ofertas)`);
  const [{ n: todas }] = await sql('SELECT count(*)::int AS n FROM oferta WHERE id_producto_mongo = $1', [oferta.producto]);
  revisar(lista.j?.payload?.length === todas, `trae todas, de todos los estados (${todas})`);
  revisar((await pedir('/admin/ofertas?producto=abc', { galleta: admin })).codigo === 400, 'un producto con letras contesta 400');

  titulo('3. Pausar y activar');
  const pausar = await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'pausada' } });
  revisar(pausar.codigo === 200 && (await filaOferta(oferta.id)).estado === 'pausada', 'el admin la pausa', `${pausar.codigo} ${pausar.j?.mensaje}`);
  const ficha = (await pedir(`/productos/${oferta.producto}`)).j?.payload;
  revisar(!JSON.stringify(ficha?.ofertas ?? []).includes(`"id_oferta":${oferta.id}`) && !JSON.stringify(ficha?.ofertas ?? []).includes(`"id_oferta":"${oferta.id}"`), 'pausada ya no sale en la ficha');
  const activar = await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'activa' } });
  revisar(activar.codigo === 200 && (await filaOferta(oferta.id)).estado === 'activa', 'y la vuelve a activar');

  titulo('4. Ajustar unidades');
  const sumar = await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { ajuste_stock: 2 } });
  revisar(sumar.codigo === 200 && (await filaOferta(oferta.id)).stock === original.stock + 2, 'le suma 2 unidades');
  const [kardex] = await sql(
    `SELECT sm.id_usuario_modifico::text AS quien, mm.motivo_nombre AS motivo, sm.cantidad
       FROM stock_movimiento sm JOIN motivo_movimiento mm USING (id_motivo_movimiento)
      WHERE sm.id_oferta = $1 ORDER BY sm.id_stock_movimiento DESC LIMIT 1`,
    [oferta.id],
  );
  revisar(kardex?.quien === idAdmin && kardex?.motivo === 'reposicion' && Number(kardex?.cantidad) === 2, 'el kardex lo anota como reposicion del admin');
  const restar = await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { ajuste_stock: -2 } });
  revisar(restar.codigo === 200 && (await filaOferta(oferta.id)).stock === original.stock, 'le resta 2 y vuelve a las de antes');
  revisar((await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { ajuste_stock: -(original.stock + 100) } })).codigo === 409, 'no la deja en negativo (409)');
  revisar((await filaOferta(oferta.id)).stock === original.stock, 'y no toco nada');

  titulo('5. Lo que no se puede');
  revisar((await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { precio: '1.00' } })).codigo === 400, 'el precio no se cambia desde aqui (400)');
  revisar((await filaOferta(oferta.id)).precio === original.precio, 'el precio sigue igual');
  revisar((await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'pendiente' } })).codigo === 400, 'un estado que no es activa, pausada o retirada contesta 400');
  revisar((await pedir('/admin/ofertas/999999999', { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'pausada' } })).codigo === 404, 'una oferta que no existe contesta 404');

  titulo('6. Retirar y volver');
  const retirar = await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'retirada' } });
  revisar(retirar.codigo === 200 && (await filaOferta(oferta.id)).estado === 'retirada', 'el admin la retira');
  const volver = await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'activa' } });
  revisar(volver.codigo === 200 && (await filaOferta(oferta.id)).estado === 'activa', 'y la puede volver a activar, porque ya estaba aprobada');
} catch (error) {
  fallas++;
  console.log(`  FALLA  ${error.message}`);
} finally {
  // La oferta queda como estaba.
  if (admin && oferta && original) {
    const ahora = await filaOferta(oferta.id);
    if (ahora.estado !== original.estado) {
      await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: original.estado } });
    }
    if (ahora.stock !== original.stock) {
      await pedir(`/admin/ofertas/${oferta.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { ajuste_stock: original.stock - ahora.stock } });
    }
    const fin = await filaOferta(oferta.id);
    revisar(fin.estado === original.estado && fin.stock === original.stock && fin.precio === original.precio, 'la oferta queda como estaba');
  }
  await pg.end();
}

console.log(`\n${oks} OK, ${fallas} FALLA`);
process.exit(fallas > 0 ? 1 : 0);
