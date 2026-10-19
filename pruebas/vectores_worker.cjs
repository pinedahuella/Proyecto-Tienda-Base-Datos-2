// pruebas/vectores_worker.cjs
//   cd backend; npm run build; cd ..; node pruebas/vectores_worker.cjs
// Necesita PostgreSQL, Mongo y Ollama arriba, y el producto 1 con vector (lo deja el paso 7d de arrancar).
//
// Prueba el worker de vectores de David (VectoresSyncService) con su codigo compilado:
// marca un producto como editado, corre el worker a mano y compara el vector que
// calcula el backend con el que dejo el ETL. El producto queda igual que antes.
//
// Donde vivio el vector: producto_vector de PostgreSQL hasta el 2026-10-02, el
// documento de mesh_productos de Elasticsearch hasta el 2026-10-16, y desde
// entonces la tabla vector_producto (migracion 040, pgvector). La prueba lee y
// escribe ahi. Lo que comprueba es lo mismo.
const path = require('path');
const BACK = path.join(__dirname, '..', 'backend');
process.chdir(BACK);
require(path.join(BACK, 'node_modules', 'dotenv')).config({ path: path.join(BACK, '.env'), quiet: true });
const mongo = require(path.join(BACK, 'dist', 'database', 'mongo'));
const { pool } = require(path.join(BACK, 'dist', 'database', 'postgres'));
const { OLLAMA_URL, OLLAMA_MODELO } = require(path.join(BACK, 'dist', 'database', 'ollama'));
const { VectoresSyncService } = require(path.join(BACK, 'dist', 'services', 'productos', 'vectores-sync.service'));

const leer = async (id) =>
  (
    await pool.query(
      `SELECT vector::text AS vector, texto_hash, grupo, activo, modelo
         FROM vector_producto WHERE id_producto_mongo = $1`,
      [id],
    )
  ).rows[0];

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
  if (!antes) throw new Error(`El producto ${ID} no tiene vector en vector_producto. Corre .\\etl\\cargar_vectores.ps1`);
  const vAntes = JSON.parse(antes.vector);
  console.log(`Producto ${ID}: hash ${antes.texto_hash}, ${vAntes.length} dimensiones`);

  // 1. Se simula una edicion: bandera en Mongo y un hash viejo en la fila, para
  //    que el worker tenga que pedirle el vector a Ollama y no lo salte.
  await db.collection('productos').updateOne({ _id: ID }, { $set: { pendiente_vector: true } });
  await pool.query(`UPDATE vector_producto SET texto_hash = $2 WHERE id_producto_mongo = $1`, [ID, '0'.repeat(32)]);

  // 2. El worker, a mano (el de verdad corre cada 10 s).
  const t0 = Date.now();
  await new VectoresSyncService().recalcular();
  const ms = Date.now() - t0;

  // 3. Como quedo
  const despues = await leer(ID);
  const vDespues = JSON.parse(despues.vector);
  const doc = await db.collection('productos').findOne({ _id: ID }, { projection: { pendiente_vector: 1 } });
  const distancia = 1 - coseno(vAntes, vDespues);

  const ok = [];
  const mal = [];
  (despues.texto_hash === antes.texto_hash ? ok : mal).push(`el hash vuelve a ser el del ETL (${despues.texto_hash})`);
  (distancia < 1e-4 ? ok : mal).push(`el vector del backend es el mismo del ETL, distancia ${distancia.toExponential(2)}`);
  (vDespues.length === 768 ? ok : mal).push('768 dimensiones');
  (despues.grupo === antes.grupo && despues.modelo === antes.modelo && despues.activo === antes.activo ? ok : mal).push('grupo, modelo y activo iguales');
  (!doc.pendiente_vector ? ok : mal).push('la bandera pendiente_vector se bajo en Mongo');

  console.log(`El worker tardo ${ms} ms`);
  ok.forEach((x) => console.log(`  OK     ${x}`));
  mal.forEach((x) => console.log(`  FALLA  ${x}`));
  console.log(`${ok.length} OK, ${mal.length} FALLA`);
  await pool.end().catch(() => undefined);
  process.exit(mal.length ? 1 : 0);
})().catch(async (e) => { console.error('No se pudo correr.', e); process.exit(2); });
