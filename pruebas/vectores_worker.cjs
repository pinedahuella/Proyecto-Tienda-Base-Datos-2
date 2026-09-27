// pruebas/vectores_worker.cjs
//   cd backend; npm run build; cd ..; node pruebas/vectores_worker.cjs
// Necesita PostgreSQL, Mongo y Ollama arriba, y el producto 1 con vector (lo deja el paso 7d de arrancar).
//
// Prueba el worker de vectores de David (VectoresSyncService) con su codigo compilado:
// marca un producto como editado, corre el worker a mano y compara el vector que
// calcula el backend con el que dejo el ETL. El producto queda igual que antes.
const path = require('path');
const BACK = path.join(__dirname, '..', 'backend');
process.chdir(BACK);
require(path.join(BACK, 'node_modules', 'dotenv')).config({ path: path.join(BACK, '.env'), quiet: true });
const { pool } = require(path.join(BACK, 'dist', 'database', 'postgres'));
const mongo = require(path.join(BACK, 'dist', 'database', 'mongo'));
const { OLLAMA_URL, OLLAMA_MODELO } = require(path.join(BACK, 'dist', 'database', 'ollama'));
const { VectoresSyncService } = require(path.join(BACK, 'dist', 'services', 'productos', 'vectores-sync.service'));

(async () => {
  console.log(`El backend usa Ollama en ${OLLAMA_URL} con ${OLLAMA_MODELO}`);
  // mongo.ts conecta al importarse; se espera a que el cliente conteste.
  if (mongo.conectarMongo) await mongo.conectarMongo();
  const db = mongo.mongoDb;
  for (let i = 0; i < 40; i++) { try { await db.command({ ping: 1 }); break; } catch { await new Promise((r) => setTimeout(r, 500)); } }

  const ID = 1;
  const [antes] = (await pool.query(
    `SELECT texto_hash, grupo, activo, vector::text AS vector, fecha_calculo FROM producto_vector WHERE id_producto = $1`, [ID])).rows;
  console.log(`Producto ${ID}: hash ${antes.texto_hash}, calculado ${antes.fecha_calculo.toISOString()}`);

  // 1. Se simula una edicion: bandera en Mongo y un hash viejo en PostgreSQL, para
  //    que el worker tenga que pedirle el vector a Ollama y no lo salte.
  await db.collection('productos').updateOne({ _id: ID }, { $set: { pendiente_vector: true } });
  await pool.query(`UPDATE producto_vector SET texto_hash = 'hash-viejo-de-prueba' WHERE id_producto = $1`, [ID]);

  // 2. El worker, a mano (el de verdad corre cada 3 horas).
  const t0 = Date.now();
  await new VectoresSyncService().recalcular();
  const ms = Date.now() - t0;

  // 3. Como quedo
  const [despues] = (await pool.query(
    `SELECT texto_hash, grupo, activo, fecha_calculo, (vector <=> $2::vector) AS distancia_al_del_etl
       FROM producto_vector WHERE id_producto = $1`, [ID, antes.vector])).rows;
  const doc = await db.collection('productos').findOne({ _id: ID }, { projection: { pendiente_vector: 1 } });

  const ok = [];
  const mal = [];
  (despues.texto_hash === antes.texto_hash ? ok : mal).push(`el hash vuelve a ser el del ETL (${despues.texto_hash})`);
  (despues.fecha_calculo > antes.fecha_calculo ? ok : mal).push('el vector se recalculo ahora');
  (Number(despues.distancia_al_del_etl) < 1e-4 ? ok : mal).push(`el vector del backend es el mismo del ETL, distancia ${Number(despues.distancia_al_del_etl).toExponential(2)}`);
  (despues.grupo === antes.grupo && despues.activo === antes.activo ? ok : mal).push('grupo y activo iguales');
  (!doc.pendiente_vector ? ok : mal).push('la bandera pendiente_vector se bajo en Mongo');

  console.log(`El worker tardo ${ms} ms`);
  ok.forEach((x) => console.log(`  OK     ${x}`));
  mal.forEach((x) => console.log(`  FALLA  ${x}`));
  console.log(`${ok.length} OK, ${mal.length} FALLA`);
  await pool.end();
  process.exit(mal.length ? 1 : 0);
})().catch(async (e) => { console.error('No se pudo correr.', e); process.exit(2); });
