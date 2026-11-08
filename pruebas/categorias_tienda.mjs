// pruebas/categorias_tienda.mjs -- la tienda crea categorias, les cambia el
// nombre y les agrega caracteristicas (migracion 054, /admin/categorias).
//
//   node pruebas/categorias_tienda.mjs
//
// Comprueba que:
//   - solo el admin entra (401 sin sesion, 403 a vendedor);
//   - una categoria nueva queda en PostgreSQL y en su copia de MongoDB, y el
//     formulario de publicar ya la ofrece con su paleta;
//   - una caracteristica que ya existe se reutiliza, y con otro tipo se niega;
//   - agregar una caracteristica la suma a la paleta sin tocar productos;
//   - cambiar el nombre de una categoria con productos lo cambia en todos sus
//     productos de MongoDB de una vez, y el buscador los vuelve a indexar.
// Para lo ultimo renombra Fragancias y la deja como estaba. Al final borra la
// categoria de prueba y las caracteristicas que creo, en las dos bases.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const requerir = createRequire(join(RAIZ, 'backend', 'package.json'));
requerir('dotenv').config({ path: join(RAIZ, 'backend', '.env'), quiet: true });
const { Pool } = requerir('pg');
const { MongoClient } = requerir('mongodb');

const API = process.env.API ?? 'http://localhost:3000';
const e = process.env;
const pg = new Pool({ host: e.DB_HOST, port: Number(e.DB_PORT ?? 5432), user: e.DB_USER, password: e.DB_PASSWORD, database: e.DB_NAME, max: 2 });
const sql = async (texto, valores) => (await pg.query(texto, valores)).rows;
const mongo = new MongoClient(
  `mongodb://${encodeURIComponent(e.MONGO_USER)}:${encodeURIComponent(e.MONGO_PASSWORD)}@${e.MONGO_HOST ?? 'localhost'}:${e.MONGO_PORT ?? 27018}/?authSource=admin`,
);

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

const SUFIJO = String(Date.now()).slice(-6);
const NOMBRE = `Prueba categoria ${SUFIJO}`;
const CREADAS = [`Prueba material ${SUFIJO}`, `Prueba tono ${SUFIJO}`, `Prueba peso ${SUFIJO}`];
let admin = '';
let idCategoria = null;
let fraganciasRenombrada = false;
let db;

try {
  await mongo.connect();
  db = mongo.db(e.MONGO_DB);
  titulo('0. Las cuentas');
  admin = await entrar('admin@mesh.com', 'Admin123');
  const vendedor = await entrar('ventas.norte@mesh.com', 'Vendedor123');
  if (!admin || !vendedor) throw new Error(`El backend no responde en ${API} o no deja entrar a las cuentas de la semilla`);
  revisar((await pedir('/admin/categorias')).codigo === 401, 'sin sesion contesta 401');
  revisar((await pedir('/admin/categorias', { galleta: vendedor })).codigo === 403, 'el vendedor recibe 403');
  const lista = (await pedir('/admin/categorias', { galleta: admin })).j?.payload;
  const hogar = lista?.categorias?.find((c) => c.es_raiz && c.nombre === 'Hogar');
  const cocina = lista?.categorias?.find((c) => c.nombre === 'Cocina');
  revisar(hogar != null && cocina?.categoria_padre === 'Hogar' && cocina?.caracteristicas?.length > 0, 'el admin ve las raices, las hijas y su paleta');
  revisar(lista?.tipos_dato?.length === 5, 'y los cinco tipos de dato');

  titulo('1. Crear una categoria');
  const crear = await pedir('/admin/categorias', {
    metodo: 'POST',
    galleta: admin,
    cuerpo: {
      nombre: NOMBRE,
      id_categoria_padre: hogar.id_categoria,
      caracteristicas: [
        { nombre: CREADAS[0], tipo_dato: 'texto' },
        { nombre: 'Marca', tipo_dato: 'texto' },
      ],
      caracteristicas_variante: [{ nombre: CREADAS[1], tipo_dato: 'texto' }],
    },
  });
  idCategoria = crear.j?.payload?.id_categoria ?? null;
  revisar(crear.codigo === 201 && idCategoria != null, `el admin crea ${NOMBRE} (${idCategoria})`, `${crear.codigo} ${crear.j?.mensaje}`);
  const [enPg] = await sql('SELECT nombre, id_categoria_padre::int AS padre FROM categorias WHERE id_categoria = $1', [idCategoria]);
  revisar(enPg?.nombre === NOMBRE && enPg?.padre === hogar.id_categoria, 'queda en PostgreSQL, dentro de Hogar');
  const enMongo = await db.collection('categorias').findOne({ _id: idCategoria });
  revisar(enMongo?.nombre === NOMBRE && enMongo?.categoria_padre === 'Hogar' && enMongo?.caracteristicas?.length === 2 && enMongo?.caracteristicas_variante?.length === 1, 'y en su copia de MongoDB, con la misma paleta');
  const [{ n: marcas }] = await sql(`SELECT count(*)::int AS n FROM caracteristica WHERE nombre = 'Marca'`);
  revisar(marcas === 1, 'Marca se reutilizo, no se creo otra');
  const paraVender = (await pedir('/vendedor/categorias', { galleta: vendedor })).j?.payload ?? [];
  revisar(paraVender.some((c) => c.id_categoria === idCategoria), 'el formulario de proponer ya la ofrece');
  const paleta = (await pedir(`/vendedor/categorias/${idCategoria}`, { galleta: vendedor })).j?.payload;
  revisar(paleta?.caracteristicas?.some((c) => c.nombre === CREADAS[0]) && paleta?.caracteristicas_variante?.some((c) => c.nombre === CREADAS[1]), 'y pregunta lo que se le dijo');

  titulo('2. Lo que no se puede al crear');
  revisar((await pedir('/admin/categorias', { metodo: 'POST', galleta: admin, cuerpo: { nombre: NOMBRE, id_categoria_padre: hogar.id_categoria } })).codigo === 409, 'el mismo nombre otra vez contesta 409');
  revisar((await pedir('/admin/categorias', { metodo: 'POST', galleta: admin, cuerpo: { nombre: `${NOMBRE} b`, id_categoria_padre: cocina.id_categoria } })).codigo === 400, 'dentro de una que no es raiz contesta 400');
  revisar((await pedir('/admin/categorias', { metodo: 'POST', galleta: admin, cuerpo: { nombre: `${NOMBRE} b`, id_categoria_padre: hogar.id_categoria, caracteristicas: [{ nombre: 'x', tipo_dato: 'fecha' }] } })).codigo === 400, 'un tipo que no existe contesta 400');
  revisar((await pedir('/admin/categorias', { metodo: 'POST', galleta: admin, cuerpo: { nombre: `${NOMBRE} b`, id_categoria_padre: hogar.id_categoria, caracteristicas: [{ nombre: 'Potencia', tipo_dato: 'texto' }] } })).codigo === 409, 'Potencia, que es un numero, como texto contesta 409');
  const [{ n: sinB }] = await sql('SELECT count(*)::int AS n FROM categorias WHERE nombre = $1', [`${NOMBRE} b`]);
  revisar(sinB === 0, 'ninguna de esas se creo a medias');

  titulo('3. Agregar una caracteristica');
  const agregar = await pedir(`/admin/categorias/${idCategoria}/caracteristicas`, { metodo: 'POST', galleta: admin, cuerpo: { nombre: CREADAS[2], tipo_dato: 'decimal', unidad: 'kg', para: 'producto' } });
  revisar(agregar.codigo === 201, `el admin le agrega ${CREADAS[2]} en kg`, `${agregar.codigo} ${agregar.j?.mensaje}`);
  const despues = await db.collection('categorias').findOne({ _id: idCategoria });
  revisar(despues?.caracteristicas?.some((c) => c.nombre === CREADAS[2] && c.unidad === 'kg' && c.tipo_dato === 'decimal'), 'la copia de MongoDB ya la pregunta');
  revisar((await pedir(`/admin/categorias/${idCategoria}/caracteristicas`, { metodo: 'POST', galleta: admin, cuerpo: { nombre: CREADAS[2], tipo_dato: 'decimal', para: 'producto' } })).codigo === 409, 'agregarla otra vez contesta 409');
  revisar((await pedir(`/admin/categorias/${hogar.id_categoria}/caracteristicas`, { metodo: 'POST', galleta: admin, cuerpo: { nombre: 'x', tipo_dato: 'texto' } })).codigo === 400, 'a una raiz no se le agregan (400)');

  titulo('4. Cambiar el nombre');
  const renombrar = await pedir(`/admin/categorias/${idCategoria}`, { metodo: 'PATCH', galleta: admin, cuerpo: { nombre: `${NOMBRE} nueva` } });
  revisar(renombrar.codigo === 200 && (await db.collection('categorias').findOne({ _id: idCategoria }))?.nombre === `${NOMBRE} nueva`, 'la de prueba cambia de nombre en las dos bases');
  revisar((await pedir(`/admin/categorias/${idCategoria}`, { metodo: 'PATCH', galleta: admin, cuerpo: { nombre: 'Cocina' } })).codigo === 409, 'con el nombre de otra contesta 409');
  const fragancias = lista.categorias.find((c) => c.nombre === 'Fragancias');
  const [{ n: deFragancias }] = await sql('SELECT count(*)::int AS n FROM producto_catalogo WHERE id_categoria = $1', [fragancias.id_categoria]);
  const cambio = await pedir(`/admin/categorias/${fragancias.id_categoria}`, { metodo: 'PATCH', galleta: admin, cuerpo: { nombre: 'Fragancias de prueba' } });
  fraganciasRenombrada = cambio.codigo === 200;
  revisar(fraganciasRenombrada && cambio.j?.payload?.productos_actualizados > 0, `Fragancias cambia de nombre en ${cambio.j?.payload?.productos_actualizados} productos con un solo updateMany (${deFragancias} en la copia de PostgreSQL)`);
  const conViejo = await db.collection('productos').countDocuments({ 'categoria.id_categoria': fragancias.id_categoria, 'categoria.nombre': 'Fragancias' });
  revisar(conViejo === 0, 'ningun producto de MongoDB se quedo con el nombre viejo');
  const uno = await db.collection('productos').findOne({ 'categoria.id_categoria': fragancias.id_categoria, estado: 'activo' });
  let enBuscador = false;
  for (let i = 0; i < 40 && !enBuscador; i++) {
    const r = await pedir(`/buscador/productos?nombre=${encodeURIComponent(uno.nombre)}`);
    enBuscador = JSON.stringify(r.j?.payload ?? '').includes('Fragancias de prueba');
    if (!enBuscador) await espera(1000);
  }
  revisar(enBuscador, 'el buscador ya lo muestra con el nombre nuevo');
  const regreso = await pedir(`/admin/categorias/${fragancias.id_categoria}`, { metodo: 'PATCH', galleta: admin, cuerpo: { nombre: 'Fragancias' } });
  fraganciasRenombrada = regreso.codigo !== 200;
  revisar(!fraganciasRenombrada, 'y vuelve a llamarse Fragancias');
  // Dos renombres seguidos: el worker del buscador puede estar indexando el
  // primero cuando llega el segundo. Desde el 2026-11-07 baja su bandera de
  // forma atomica y no pierde el segundo; antes 20 productos se quedaban con
  // el nombre de prueba en el buscador.
  let limpio = false;
  for (let i = 0; i < 60 && !limpio; i++) {
    const f = (await pedir('/buscador/productos/facetado?nombre=perfume')).j?.payload?.facetas;
    const nombres = (f?.categorias ?? f?.categoria ?? []).map((c) => c.nombre ?? c.valor);
    limpio = nombres.includes('Fragancias') && !nombres.includes('Fragancias de prueba');
    if (!limpio) await espera(1000);
  }
  revisar(limpio, 'el buscador vuelve a decir solo Fragancias, ningun producto se queda con el nombre de prueba');
} catch (error) {
  fallas++;
  console.log(`  FALLA  ${error.message}`);
} finally {
  if (fraganciasRenombrada && admin) {
    const [f] = await sql(`SELECT id_categoria::int AS id FROM categorias WHERE nombre = 'Fragancias de prueba'`);
    if (f) await pedir(`/admin/categorias/${f.id}`, { metodo: 'PATCH', galleta: admin, cuerpo: { nombre: 'Fragancias' } });
  }
  // La categoria de prueba no tiene productos: se borra en las dos bases, con
  // las caracteristicas que creo (no hay ruta para borrar, a proposito).
  if (idCategoria) {
    try {
      await sql('DELETE FROM categoria_caracteristica WHERE id_categoria = $1', [idCategoria]);
      await sql('DELETE FROM categoria_caracteristica_variante WHERE id_categoria = $1', [idCategoria]);
      await sql('DELETE FROM categorias WHERE id_categoria = $1', [idCategoria]);
      await sql('DELETE FROM caracteristica WHERE nombre = ANY($1)', [CREADAS]);
      await sql('DELETE FROM caracteristica_variante WHERE nombre = ANY($1)', [CREADAS]);
      await db.collection('categorias').deleteOne({ _id: idCategoria });
      console.log(`\n  Borrada la categoria de prueba ${idCategoria} y sus caracteristicas, en las dos bases`);
    } catch (error) {
      console.log(`\n  No se pudo borrar la categoria de prueba ${idCategoria} (${error.message})`);
    }
  }
  await pg.end();
  await mongo.close();
}

console.log(`\n${oks} OK, ${fallas} FALLA`);
process.exit(fallas > 0 ? 1 : 0);
