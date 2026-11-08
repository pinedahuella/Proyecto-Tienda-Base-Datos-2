// pruebas/resenas_moderar.mjs -- la tienda oculta una resena sin borrarla
// (migracion 052, PATCH /admin/resenas/:id).
//
//   node pruebas/resenas_moderar.mjs
//
// Toma una resena publicada que este en una senal de fraude de resenas, la
// oculta como admin y comprueba que:
//   - solo el admin puede (401 sin sesion, 403 a la compradora);
//   - sale de la ficha y del resumen, y el promedio del producto en MongoDB se
//     recalcula sin ella;
//   - nadie le puede responder;
//   - sigue en el detalle del anillo, marcada oculta, y sigue en la base;
//   - su autor no puede volver a resenar ese producto de ese vendedor (el
//     UNIQUE de resena, probado en una transaccion que se deshace);
//   - queda anotado quien la oculto y por que.
// Al final la vuelve a publicar y todo queda como estaba, salvo las dos filas
// de resena_moderacion, que son la historia de la prueba.

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
// El promedio de MongoDB lo recalcula el worker de evento_producto.
async function esperarTotal(idProducto, total) {
  for (let i = 0; i < 60; i++) {
    const p = (await pedir(`/productos/${idProducto}`)).j?.payload;
    if (p?.resenas_total === total) return p;
    await espera(500);
  }
  return null;
}

let admin = '';
let resena = null;

try {
  titulo('0. Una resena publicada que esta en una senal de fraude');
  admin = await entrar('admin@mesh.com', 'Admin123');
  const compradora = await entrar('compradora.norte@mesh.com', 'Comprador123');
  if (!admin || !compradora) throw new Error(`El backend no responde en ${API} o no deja entrar a las cuentas de la semilla`);
  [resena] = await sql(
    `SELECT r.id_resena::int AS id, r.id_producto_mongo::int AS producto, r.id_usuario::text AS autor,
            r.id_usuario_vendedor::text AS vendedor, sr.id_senal_fraude::text AS senal
       FROM resena r
       JOIN senal_fraude_resena sr ON sr.id_resena = r.id_resena
       JOIN tipo_senal_fraude t ON t.id_tipo_senal_fraude = (SELECT id_tipo_senal_fraude FROM senal_fraude WHERE id_senal_fraude = sr.id_senal_fraude)
      WHERE r.id_estado_resena = 1
        AND t.tipo_senal_fraude_nombre IN ('satelites', 'reputacion_expres', 'coordinados', 'mutuo', 'ciclo')
        AND (SELECT count(*) FROM resena r2 WHERE r2.id_producto_mongo = r.id_producto_mongo AND r2.id_estado_resena = 1) >= 2
      ORDER BY r.id_resena LIMIT 1`,
  );
  revisar(resena != null, `resena ${resena?.id} del producto ${resena?.producto}, en la senal ${resena?.senal}`);
  const antes = (await pedir(`/productos/${resena.producto}/resenas`)).j?.payload;
  const ficha = (await pedir(`/productos/${resena.producto}`)).j?.payload;
  const totalAntes = antes?.resumen?.total;
  revisar(antes?.resenas?.some((r) => r.id_resena === resena.id), 'antes sale en la ficha');
  revisar(ficha?.resenas_total === totalAntes, `el total de MongoDB coincide con la ficha (${totalAntes})`, `${ficha?.resenas_total}`);

  titulo('1. Solo la tienda modera');
  revisar((await pedir(`/admin/resenas/${resena.id}`, { metodo: 'PATCH', cuerpo: { estado: 'oculta' } })).codigo === 401, 'sin sesion contesta 401');
  revisar((await pedir(`/admin/resenas/${resena.id}`, { metodo: 'PATCH', galleta: compradora, cuerpo: { estado: 'oculta' } })).codigo === 403, 'la compradora recibe 403');
  revisar((await pedir(`/admin/resenas/${resena.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'borrada' } })).codigo === 400, 'un estado que no existe contesta 400');
  revisar((await pedir('/admin/resenas/999999999', { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'oculta' } })).codigo === 404, 'una resena que no existe contesta 404');

  titulo('2. Ocultarla');
  const motivo = 'Prueba de resenas_moderar.mjs';
  const ocultar = await pedir(`/admin/resenas/${resena.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'oculta', motivo } });
  revisar(ocultar.codigo === 200 && ocultar.j?.payload?.estado === 'oculta', 'el admin la oculta', `${ocultar.codigo} ${ocultar.j?.mensaje}`);
  revisar((await pedir(`/admin/resenas/${resena.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'oculta' } })).codigo === 409, 'ocultarla otra vez contesta 409');
  const despues = (await pedir(`/productos/${resena.producto}/resenas`)).j?.payload;
  revisar(!despues?.resenas?.some((r) => r.id_resena === resena.id), 'ya no sale en la ficha');
  revisar(despues?.resumen?.total === totalAntes - 1, `el resumen baja a ${totalAntes - 1}`, `${despues?.resumen?.total}`);
  revisar((await esperarTotal(resena.producto, totalAntes - 1)) != null, 'el worker recalcula el total en MongoDB sin ella');
  revisar((await pedir(`/resenas/${resena.id}/respuestas`, { metodo: 'POST', galleta: compradora, cuerpo: { comentario: 'No deberia quedar' } })).codigo === 404, 'nadie le puede responder (404)');
  const [fila] = await sql('SELECT id_estado_resena FROM resena WHERE id_resena = $1', [resena.id]);
  revisar(fila?.id_estado_resena === 2, 'sigue en la base, oculta');
  const detalle = (await pedir(`/admin/fraude/alertas-resenas/${resena.senal}/detalle-grafo`, { galleta: admin })).j?.payload;
  revisar(detalle?.resenas?.find((r) => r.id_resena === resena.id)?.estado_en_tienda === 'oculta', 'sigue en el detalle del anillo, marcada oculta');
  const [historia] = await sql(
    `SELECT u.correo_electronico AS quien, rm.motivo, ea.estado_resena_nombre AS de, en.estado_resena_nombre AS a
       FROM resena_moderacion rm
       JOIN usuarios u ON u.id_usuario = rm.id_usuario
       JOIN estado_resena ea ON ea.id_estado_resena = rm.id_estado_anterior
       JOIN estado_resena en ON en.id_estado_resena = rm.id_estado_nuevo
      WHERE rm.id_resena = $1 ORDER BY rm.fecha DESC LIMIT 1`,
    [resena.id],
  );
  revisar(historia?.quien === 'admin@mesh.com' && historia?.motivo === motivo && historia?.de === 'publicada' && historia?.a === 'oculta', 'queda anotado quien, por que y de que a que');
  // El autor no puede volver a resenar lo mismo: el UNIQUE de la 011 lo frena
  // aunque la resena este oculta. En una transaccion que se deshace.
  const cliente = await pg.connect();
  let codigoUnique = null;
  try {
    await cliente.query('BEGIN');
    const { rows } = await cliente.query(`INSERT INTO comentario (id_usuario, comentario) VALUES ($1, 'Otra vez') RETURNING id_comentario`, [resena.autor]);
    await cliente.query(
      `INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo, calificacion, id_comentario) VALUES ($1, $2, $3, 5, $4)`,
      [resena.autor, resena.vendedor, resena.producto, rows[0].id_comentario],
    );
  } catch (error) {
    codigoUnique = error.code;
  } finally {
    await cliente.query('ROLLBACK');
    cliente.release();
  }
  revisar(codigoUnique === '23505', 'su autor no puede volver a resenar ese producto de ese vendedor (UNIQUE)', codigoUnique ?? 'entro');

  titulo('3. Volverla a publicar');
  const publicar = await pedir(`/admin/resenas/${resena.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'publicada' } });
  revisar(publicar.codigo === 200 && publicar.j?.payload?.estado === 'publicada', 'el admin la vuelve a publicar');
  resena.restaurada = true;
  const otraVez = (await pedir(`/productos/${resena.producto}/resenas`)).j?.payload;
  revisar(otraVez?.resenas?.some((r) => r.id_resena === resena.id) && otraVez?.resumen?.total === totalAntes, 'sale otra vez en la ficha, con el total de antes');
  revisar((await esperarTotal(resena.producto, totalAntes)) != null, 'MongoDB vuelve al total de antes');
} catch (error) {
  fallas++;
  console.log(`  FALLA  ${error.message}`);
} finally {
  // Si algo corto la prueba con la resena oculta, se vuelve a publicar.
  if (admin && resena && !resena.restaurada) {
    await pedir(`/admin/resenas/${resena.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { estado: 'publicada' } });
  }
  await pg.end();
}

console.log(`\n${oks} OK, ${fallas} FALLA`);
process.exit(fallas > 0 ? 1 : 0);
