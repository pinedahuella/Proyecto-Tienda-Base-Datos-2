// pruebas/correr_detectores_resenas.cjs
//   node pruebas/correr_detectores_resenas.cjs
// Corre una vez, con el codigo compilado del backend (backend/dist), los
// detectores de fraude de resenas que no salen del grafo: los cuatro que leen
// el vector de cada resena en vector_comentario de PostgreSQL (resenas
// repetidas, anillo de texto, notas incoherentes y resenas parecidas; hasta el
// 2026-10-16, en mesh_comentarios de Elasticsearch) y el de resenas con la
// compra cancelada.
// En el backend corren solos cada 15 minutos, y desde 1f1f480 tambien al
// escribir la resena o al cancelar el pedido; esto es la red de seguridad de
// una demo o de una prueba. Guardan en senal_fraude igual que cuando los corre
// el backend. Necesita `npm run build` del backend.
const path = require('path');
const BACK = path.join(__dirname, '..', 'backend');
process.chdir(BACK);
// override: los servicios de abajo son los del backend y tienen que entrar con
// sus usuarios. En modo remoto activar.sh exporta las contrasenas de la otra PC,
// donde ELASTIC_PASSWORD es la de `elastic`, y sin override quedaba mesh_backend
// con esa contrasena: Elasticsearch contestaba 401 y el detector de login lento
// se interrumpia (2026-11-07, igual que en buscador_escribiendo.mjs).
require(path.join(BACK, 'node_modules', 'dotenv')).config({ path: path.join(BACK, '.env'), quiet: true, override: true });
const { pool } = require(path.join(BACK, 'dist', 'database', 'postgres'));

const DETECTORES = [
  ['resenas-repetidas-detector.service', 'ResenasRepetidasDetectorService'],
  ['anillo-de-texto-detector.service', 'AnilloDeTextoDetectorService'],
  ['notas-incoherentes-detector.service', 'NotasIncoherentesDetectorService'],
  ['resenas-parecidas-detector.service', 'ResenasParecidasDetectorService'],
  ['resenas-canceladas-detector.service', 'ResenasCanceladasDetectorService'],
];

(async () => {
  let fallos = 0;
  for (const [archivo, clase] of DETECTORES) {
    const Clase = require(path.join(BACK, 'dist', 'services', 'fraude', archivo))[clase];
    try {
      await new Clase().detectar();
      console.log(`  OK     ${clase}`);
    } catch (e) {
      fallos++;
      console.log(`  FALLA  ${clase}: ${e.message}`);
    }
  }
  await pool.end();
  process.exit(fallos ? 1 : 0);
})().catch((e) => { console.error('No se pudo correr.', e.message); process.exit(2); });
