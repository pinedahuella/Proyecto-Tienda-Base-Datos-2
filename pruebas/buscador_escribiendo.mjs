// pruebas/buscador_escribiendo.mjs -- la lista del buscador de la cabecera
// (GET /buscador/productos?escribiendo=1), que busca con cada letra.
//
//   node pruebas/buscador_escribiendo.mjs
//
// Lo que vio Meme el 2026-10-20: escribir "lap" daba ocho veces "El camino de
// las nubes" (la difusa toma "lap" por "las" mal escrito, y las copias de lote
// llenaban la lista) y "lapt" no daba nada. Comprueba:
//   1. Con escribiendo, media palabra encuentra lo que empieza asi, lo mal
//      escrito se sigue encontrando y no se repite un producto con sus copias.
//   2. Sin escribiendo, la ruta da lo mismo que la consulta difusa de siempre
//      hecha aparte contra Elasticsearch (la pagina /buscar no cambia).
//   3. Sin Elasticsearch, la copia en PostgreSQL hace lo mismo con prefijo y
//      sigue igual sin el.
//
// Solo lee. Necesita el backend arriba y el dist compilado (npm run build).

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const requerir = createRequire(join(RAIZ, 'backend', 'package.json'));
// override: los clientes de abajo son los del backend y tienen que entrar con
// sus usuarios. En modo remoto activar.sh exporta las contrasenas del .env de
// la raiz, donde ELASTIC_PASSWORD es la de `elastic`, y sin override quedaba
// mesh_backend con esa contrasena y Elasticsearch contestaba 401.
requerir('dotenv').config({ path: join(RAIZ, 'backend', '.env'), quiet: true, override: true });
const { elasticClient } = requerir('./dist/database/elastic');
const { buscarEnCopia } = requerir('./dist/helpers/buscador-respaldo');
const { pool } = requerir('./dist/database/postgres');

const API = process.env.API ?? 'http://localhost:3000';
const MARCA_DE_LOTE = /(\s+[LM]\d+-\d{4})+$/;
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

async function lista(texto, escribiendo, limite = 8) {
  const r = await fetch(
    `${API}/buscador/productos?nombre=${encodeURIComponent(texto)}&limite=${limite}${escribiendo ? '&escribiendo=1' : ''}`,
  );
  const j = await r.json();
  if (!j.ok) throw new Error(`${texto}: ${j.mensaje}`);
  return j.payload.resultados;
}
const nombres = (rs) => rs.map((r) => r.nombre);
const empiezan = (rs, n, prefijo) => rs.length >= n && rs.slice(0, n).every((r) => r.nombre.toLowerCase().startsWith(prefijo));
const sinCopiasRepetidas = (rs) => new Set(rs.map((r) => r.nombre.replace(MARCA_DE_LOTE, ''))).size === rs.length;
const corto = (rs) => nombres(rs).slice(0, 4).join(' | ');

try {
  titulo('1. Con escribiendo, como en la cabecera');
  const lap = await lista('lap', true);
  revisar(empiezan(lap, 6, 'laptop'), 'lap trae laptops primero', corto(lap));
  const lapt = await lista('lapt', true);
  revisar(empiezan(lapt, 6, 'laptop'), 'lapt trae laptops (antes no daba nada)', corto(lapt));
  const labtop = await lista('labtop', true);
  revisar(empiezan(labtop, 6, 'laptop'), 'labtop, mal escrito, sigue trayendo laptops', corto(labtop));
  const cami = await lista('cami', true);
  // "El camino de las nubes" tambien vale: camino empieza con cami.
  revisar(cami.length >= 6 && cami.slice(0, 6).every((r) => /(^|\s)cami/i.test(r.nombre)), 'cami trae primero lo que tiene una palabra que empieza con cami', corto(cami));
  const silla = await lista('silla com', true);
  revisar(silla[0]?.nombre === 'Silla de comedor Vara', 'silla com trae primero la silla de comedor', corto(silla));
  for (const [texto, rs] of [['lap', lap], ['lapt', lapt], ['labtop', labtop], ['cami', cami], ['silla com', silla]]) {
    revisar(sinCopiasRepetidas(rs), `${texto} no repite un producto con sus copias de lote`, nombres(rs).join(' | '));
  }
  const conOriginal = lap.filter((r) => !MARCA_DE_LOTE.test(r.nombre)).length;
  revisar(conOriginal >= 6, 'con lap salen los originales y no sus copias', `${conOriginal} originales`);
  const todos = await lista('laptop', true, 20);
  revisar(todos.length <= 20 && sinCopiasRepetidas(todos), 'con limite 20 respeta el tope y sigue sin repetir', `${todos.length}`);

  titulo('2. Sin escribiendo, la busqueda de siempre');
  for (const texto of ['lap', 'laptop', 'labtop', 'silla com']) {
    const ruta = await lista(texto, false, 20);
    const directo = await elasticClient.search({
      index: process.env.ELASTIC_INDICE ?? 'mesh_productos',
      size: 20,
      _source: false,
      query: {
        bool: {
          must: [{ multi_match: { query: texto, fields: ['nombre^3', 'descripcion', 'variantes'], fuzziness: 'AUTO' } }],
          filter: [{ term: { estado: 'activo' } }],
        },
      },
    });
    const a = ruta.map((r) => r.id_producto).join(',');
    const b = directo.hits.hits.map((h) => Number(h._id)).join(',');
    revisar(a === b, `${texto} da lo mismo que la difusa contra Elasticsearch`, `${ruta.length} y ${directo.hits.hits.length}`);
  }

  titulo('3. Sin Elasticsearch, la copia en PostgreSQL');
  const copia = async (texto, prefijo) =>
    (await buscarEnCopia({ texto, limite: 8, soloActivos: true, prefijo })).resultados;
  const cLap = await copia('lap', true);
  revisar(empiezan(cLap, 6, 'laptop'), 'lap con prefijo trae laptops', corto(cLap));
  const cLapt = await copia('lapt', true);
  revisar(empiezan(cLapt, 6, 'laptop'), 'lapt con prefijo trae laptops', corto(cLapt));
  const cLabtop = await copia('labtop', true);
  revisar(empiezan(cLabtop, 6, 'laptop'), 'labtop con prefijo sigue trayendo laptops', corto(cLabtop));
  revisar((await copia('lapt', false)).length === 0, 'sin prefijo la copia sigue igual (lapt no es ninguna palabra)');
} catch (error) {
  fallas++;
  console.log(`  FALLA  ${error.message}`);
} finally {
  await pool.end().catch(() => {});
  await elasticClient.close().catch(() => {});
}

console.log(`\n${oks} OK, ${fallas} FALLA`);
process.exit(fallas ? 1 : 0);
