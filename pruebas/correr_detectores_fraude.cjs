// pruebas/correr_detectores_fraude.cjs
//   node pruebas/correr_detectores_fraude.cjs                  todas las familias
//   node pruebas/correr_detectores_fraude.cjs compras casos    solo esas
// Corre una vez, con el codigo compilado del backend (backend/dist), los
// detectores de fraude que en el backend van por reloj, y al final el
// agrupador de casos. Es lo que hay que correr en una demo para no esperar al
// reloj: el de compras y navegacion (F1, F2, F3 y F5 en ClickHouse) corre una
// vez al DIA y Nest no lo dispara al arrancar; los demas cada 15 minutos.
// Guardan en senal_fraude y caso_fraude igual que cuando los corre el backend.
// Necesita `npm run build` del backend y las bases arriba (las del .env del
// backend). Sale con 1 si algun detector fallo.
//
// Familias:
//   anillos     ciclo, mutuo, reiterado                      (Neo4j)
//   patrones    satelites, persistente, coordinados,
//               reputacion_expres                            (Neo4j)
//   texto       resenas_repetidas, anillo_de_texto,
//               notas_incoherentes_*, resenas_parecidas_*    (vector_comentario)
//   canceladas  resena_positiva_cancelada,
//               resenas_negativas_canceladas_vendedor        (PostgreSQL)
//   login       fuerza_bruta_cuenta_lenta, multi_cuenta_ip_lenta,
//               ip_rotacion_cuenta_lenta, granja_de_registros (Elasticsearch)
//   compras     vistas_infladas, compras_en_rafaga,
//               ip_multicuenta_compras, devoluciones_seriales (ClickHouse)
//   casos       el agrupador: junta las senales en casos y los puntua
// Las senales de login inmediatas (fuerza_bruta_cuenta, fuerza_bruta_ip,
// multi_cuenta_ip, ip_rotacion_cuenta, toma_cuenta, viaje_imposible) no tienen
// reloj: salen en el momento del login (ver demo-evento-fraude.ps1).
const path = require('path');
const BACK = path.join(__dirname, '..', 'backend');
process.chdir(BACK);
// override: los servicios de abajo son los del backend y tienen que entrar con
// sus usuarios. En modo remoto activar.sh exporta las contrasenas de la otra PC,
// donde ELASTIC_PASSWORD es la de `elastic`, y sin override quedaba mesh_backend
// con esa contrasena: Elasticsearch contestaba 401 y el detector de login lento
// se interrumpia (2026-11-07, igual que en buscador_escribiendo.mjs).
require(path.join(BACK, 'node_modules', 'dotenv')).config({ path: path.join(BACK, '.env'), quiet: true, override: true });
const dist = (archivo) => require(path.join(BACK, 'dist', 'services', archivo));

const FAMILIAS = {
  anillos: [['fraude/anillos-detector.service', 'AnillosDetectorService', 'detectar']],
  patrones: [['fraude/patrones-fraude-detector.service', 'PatronesFraudeDetectorService', 'detectar']],
  texto: [
    ['fraude/resenas-repetidas-detector.service', 'ResenasRepetidasDetectorService', 'detectar'],
    ['fraude/anillo-de-texto-detector.service', 'AnilloDeTextoDetectorService', 'detectar'],
    ['fraude/notas-incoherentes-detector.service', 'NotasIncoherentesDetectorService', 'detectar'],
    ['fraude/resenas-parecidas-detector.service', 'ResenasParecidasDetectorService', 'detectar'],
  ],
  canceladas: [['fraude/resenas-canceladas-detector.service', 'ResenasCanceladasDetectorService', 'detectar']],
  login: [['fraude-login/fraude-login-retrospectivo.service', 'FraudeLoginRetrospectivoService', 'evaluar']],
  compras: [['fraude/hallazgos-evento-fraude-detector.service', 'HallazgosEventoFraudeDetectorService', 'detectar']],
  casos: [['fraude/agrupador-fraude-worker.service', 'AgrupadorFraudeWorkerService', 'ejecutar']],
};

// El agrupador es el unico con dependencias: se las pasamos a mano, las
// mismas que le inyecta Nest.
function crear(archivo, clase) {
  const Clase = dist(archivo)[clase];
  if (clase !== 'AgrupadorFraudeWorkerService') return new Clase();
  const { HallazgoFraudeAdaptadorService } = dist('fraude/hallazgo-fraude-adaptador.service');
  const { AgrupadorFraudeService } = dist('fraude/agrupador-fraude.service');
  const { PersistenciaCasoFraudeService } = dist('fraude/persistencia-caso-fraude.service');
  const { PuntajeFraudeService } = dist('fraude/puntaje-fraude.service');
  const { ReglasCasiConfirmadoService } = dist('fraude/reglas-casi-confirmado.service');
  return new Clase(
    new HallazgoFraudeAdaptadorService(),
    new AgrupadorFraudeService(),
    new PersistenciaCasoFraudeService(new PuntajeFraudeService(), new ReglasCasiConfirmadoService()),
  );
}

// Los de texto leen el vector y la valoracion de cada resena. El vector lo
// calcula el backend con Ollama (evento_comentario); la valoracion, un reloj
// de 30 s que va DESPUES del vector. Una resena recien sembrada puede tener
// vector y no valoracion todavia, y entonces no cuenta: se valora aqui lo
// pendiente antes de buscar.
async function antesDelTexto() {
  const { pool } = require(path.join(BACK, 'dist', 'database', 'postgres'));
  const { rows } = await pool.query(
    'SELECT count(*)::int AS n FROM evento_comentario WHERE procesado_en IS NULL',
  );
  if (rows[0].n > 0) {
    console.log(`  AVISO  ${rows[0].n} comentario(s) todavia sin vector: los calcula el backend; esos no cuentan en esta corrida`);
  }
  const { ValoracionComentariosService } = dist('resenas/valoracion-comentarios.service');
  await new ValoracionComentariosService().valorarAhora();
}

(async () => {
  const pedidas = process.argv.slice(2);
  for (const f of pedidas) {
    if (!FAMILIAS[f]) {
      console.error(`No conozco la familia "${f}". Son: ${Object.keys(FAMILIAS).join(', ')}`);
      process.exit(2);
    }
  }
  const familias = pedidas.length ? pedidas : Object.keys(FAMILIAS);
  let fallos = 0;
  for (const familia of familias) {
    if (familia === 'texto') await antesDelTexto();
    for (const [archivo, clase, metodo] of FAMILIAS[familia]) {
      try {
        await crear(archivo, clase)[metodo]();
        console.log(`  OK     ${familia.padEnd(10)} ${clase}`);
      } catch (e) {
        fallos++;
        console.log(`  FALLA  ${familia.padEnd(10)} ${clase}: ${e.message}`);
      }
    }
  }
  // Los detectores atrapan sus propios errores y los dejan en el log como
  // WARN: un OK aqui dice que corrio, no que encontro algo. Lo que encontro
  // se ve en senal_fraude o en el panel.
  process.exit(fallos ? 1 : 0);
})().catch((e) => { console.error('No se pudo correr.', e.message); process.exit(2); });
