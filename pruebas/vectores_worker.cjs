// pruebas/vectores_worker.cjs
//   cd backend; npm run build; cd ..; node pruebas/vectores_worker.cjs
// Necesita Elasticsearch, Mongo y Ollama arriba, y el producto 1 con vector (lo deja el paso 7d de arrancar).
//
// Prueba el worker de vectores de David (VectoresSyncService) con su codigo compilado:
// marca un producto como editado, corre el worker a mano y compara el vector que
// calcula el backend con el que dejo el ETL. El producto queda igual que antes.
//
// Desde el 2026-10-02 el vector vive en el documento de mesh_productos de
// Elasticsearch y no en producto_vector de PostgreSQL; la prueba lee y escribe
// ahi. Lo que comprueba es lo mismo.
const path = require('path');
const BACK = path.join(__dirname, '..', 'backend');
process.chdir(BACK);
require(path.join(BACK, 'node_modules', 'dotenv')).config({ path: path.join(BACK, '.env'), quiet: true });
const mongo = require(path.join(BACK, 'dist', 'database', 'mongo'));
const { OLLAMA_URL, OLLAMA_MODELO } = require(path.join(BACK, 'dist', 'database', 'ollama'));
const { VectoresSyncService } = require(path.join(BACK, 'dist', 'services', 'productos', 'vectores-sync.service'));

const ES = `http://${process.env.ELASTIC_HOST ?? 'localhost'}:${process.env.ELASTIC_PORT ?? 9200}`;
const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';

async function es(metodo, ruta, cuerpo) {
  const r = await fetch(`${ES}${ruta}`, {
    method: metodo,
    headers: { 'Content-Type': 'application/json' },
    body: cuerpo ? JSON.stringify(cuerpo) : undefined,
  });
  if (!r.ok) throw new Error(`Elasticsearch contesto ${r.status} en ${ruta}: ${await r.text()}`);
  return r.json();
}

const leer = async (id) =>
  (await es('GET', `/${INDICE}/_doc/${id}?_source_includes=vector,vector_hash,vector_grupo,vector_modelo`))._source;

function coseno(a, b) {
  let p = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { p += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return p / Math.sqrt(na * nb);
}

(async () => {
  console.log(`El backend usa Ollama en ${OLLAMA_URL} con ${OLLAMA_MODELO}`);
  // mongo.ts conecta al importarse; se espera a que el cliente conteste.
  if (mongo.conectarMongo) await mongo.conectarMongo();
  const db = mongo.mongoDb;
  for (let i = 0; i < 40; i++) { try { await db.command({ ping: 1 }); break; } catch { await new Promise((r) => setTimeout(r, 500)); } }

  const ID = 1;
  const antes = await leer(ID);
  if (!antes.vector) throw new Error(`El producto ${ID} no tiene vector. Corre .\\etl\\cargar_vectores.ps1`);
  console.log(`Producto ${ID}: hash ${antes.vector_hash}, ${antes.vector.length} dimensiones`);

  // 1. Se simula una edicion: bandera en Mongo y un hash viejo en el documento,
  //    para que el worker tenga que pedirle el vector a Ollama y no lo salte.
  await db.collection('productos').updateOne({ _id: ID }, { $set: { pendiente_vector: true } });
  await es('POST', `/${INDICE}/_update/${ID}?refresh=true`, { doc: { vector_hash: 'hash-viejo-de-prueba' } });

  // 2. El worker, a mano (el de verdad corre cada 3 horas).
  const t0 = Date.now();
  await new VectoresSyncService().recalcular();
  const ms = Date.now() - t0;

  // 3. Como quedo
  await es('POST', `/${INDICE}/_refresh`);
  const despues = await leer(ID);
  const doc = await db.collection('productos').findOne({ _id: ID }, { projection: { pendiente_vector: 1 } });
  const distancia = 1 - coseno(antes.vector, despues.vector);

  const ok = [];
  const mal = [];
  (despues.vector_hash === antes.vector_hash ? ok : mal).push(`el hash vuelve a ser el del ETL (${despues.vector_hash})`);
  (distancia < 1e-4 ? ok : mal).push(`el vector del backend es el mismo del ETL, distancia ${distancia.toExponential(2)}`);
  (despues.vector.length === 768 ? ok : mal).push('768 dimensiones');
  (despues.vector_grupo === antes.vector_grupo && despues.vector_modelo === antes.vector_modelo ? ok : mal).push('grupo y modelo iguales');
  (!doc.pendiente_vector ? ok : mal).push('la bandera pendiente_vector se bajo en Mongo');

  console.log(`El worker tardo ${ms} ms`);
  ok.forEach((x) => console.log(`  OK     ${x}`));
  mal.forEach((x) => console.log(`  FALLA  ${x}`));
  console.log(`${ok.length} OK, ${mal.length} FALLA`);
  process.exit(mal.length ? 1 : 0);
})().catch(async (e) => { console.error('No se pudo correr.', e); process.exit(2); });
