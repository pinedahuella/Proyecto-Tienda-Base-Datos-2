// pruebas/casos_fraude_granja.cjs
// Comprueba dos arreglos de David en de5de2a (2026-09-26) con sus clases compiladas,
// dentro de UNA transaccion que se deshace al final. No deja nada en la base.
//
//   cd backend; npm run build; cd ..
//   node pruebas/casos_fraude_granja.cjs
//
// C6 (docs/BACKEND-PENDIENTE.md). Una cuenta con mas de 10 contrapartes en resenas es
// "concentradora": no une grupos y nunca es nucleo. Antes contaban tambien las resenas
// del propio fraude, asi que el vendedor de una granja de 11 satelites quedaba fuera
// del nucleo de su caso. Aqui se siembra esa granja: 11 cuentas que califican a un
// vendedor, primero sueltas (tiene que salir concentrador, es el control de que la
// prueba mide algo) y despues como evidencia de un anillo `satelites` (ya no tiene que
// serlo, y el agrupador lo tiene que poner en el nucleo).
//
// Desde el refactor de fraude (7453ffe, migraciones 031 a 033) el anillo se siembra
// como senal: senal_fraude con su tipo `satelites`, sus resenas en senal_fraude_resena
// (que es lo que mira el agrupador para C6) y sus cuentas en senal_fraude_cuenta. Antes
// iba a anillo_fraude, que el backend ya no lee.
//
// La regularidad de B.3 (los "menores"). Neo4j da NaN con media 0, JSON lo guarda como
// null y Number(null) es 0, que sumaba los +5 de "regular". Un null ya no suma y un
// 0,1 de verdad si.
const path = require('path');
const BACK = path.join(__dirname, '..', 'backend');
process.chdir(BACK);
require(path.join(BACK, 'node_modules', 'dotenv')).config({ path: path.join(BACK, '.env'), quiet: true });
const { pool } = require(path.join(BACK, 'dist', 'database', 'postgres'));
const fraude = (nombre) => require(path.join(BACK, 'dist', 'services', 'fraude', nombre));
const { AgrupadorFraudeService } = fraude('agrupador-fraude.service');
const { PuntajeFraudeService } = fraude('puntaje-fraude.service');

const PRODUCTO_FALSO = 999999901; // resena.id_producto_mongo no tiene llave foranea
const SATELITES = 11;

(async () => {
  const cliente = await pool.connect();
  await cliente.query('BEGIN');
  const q = (texto, params) =>
    /^\s*(BEGIN|COMMIT|ROLLBACK)/i.test(texto) ? Promise.resolve({ rows: [], rowCount: 0 }) : cliente.query(texto, params);
  pool.connect = async () => ({ query: q, release() {} });
  pool.query = q;
  const filas = async (sql, p) => (await cliente.query(sql, p)).rows;

  const agrupador = new AgrupadorFraudeService();
  const concentradoras = () => agrupador.obtenerCuentasConcentradoras();
  const fallos = [];
  const ok = [];
  const mira = (bien, texto) => (bien ? ok : fallos).push(texto);

  // Un vendedor que hoy NO es concentrador, y 11 cuentas que nunca lo calificaron.
  const antes = await concentradoras();
  const usuarios = (await filas(`SELECT id_usuario::int AS id FROM usuarios ORDER BY id_usuario`)).map((f) => f.id);
  const vendedor = usuarios.find((u) => !antes.has(u));
  const satelites = usuarios
    .filter((u) => u !== vendedor)
    .slice(0, SATELITES);
  if (vendedor == null || satelites.length < SATELITES) throw new Error(`Hacen falta ${SATELITES + 1} cuentas`);

  const resenas = [];
  for (const s of satelites) {
    const [c] = await filas(`INSERT INTO comentario (id_usuario, comentario) VALUES ($1, 'granja de prueba') RETURNING id_comentario`, [s]);
    const [r] = await filas(
      `INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo, calificacion, id_comentario)
       VALUES ($1, $2, $3, 5, $4) RETURNING id_resena`,
      [s, vendedor, PRODUCTO_FALSO, c.id_comentario],
    );
    resenas.push(r.id_resena);
  }
  console.log(`Granja de prueba: ${SATELITES} cuentas califican al vendedor ${vendedor}`);

  mira((await concentradoras()).has(vendedor), 'control: con las resenas sueltas el vendedor SI es concentrador');

  const cuentas = [vendedor, ...satelites];
  const [anillo] = await filas(
    `INSERT INTO senal_fraude (id_tipo_senal_fraude, clave, id_estado_alerta_fraude)
     VALUES ((SELECT id_tipo_senal_fraude FROM tipo_senal_fraude WHERE tipo_senal_fraude_nombre = 'satelites'),
             $1,
             (SELECT id_estado_alerta_fraude FROM estado_alerta_fraude WHERE estado_alerta_fraude_nombre = 'pendiente'))
     RETURNING id_senal_fraude`,
    [[...cuentas].sort((a, b) => a - b).join('-')],
  );
  for (const r of resenas) {
    await filas(`INSERT INTO senal_fraude_resena (id_senal_fraude, id_resena) VALUES ($1, $2)`, [anillo.id_senal_fraude, r]);
  }
  for (const c of cuentas) {
    await filas(
      `INSERT INTO senal_fraude_cuenta (id_senal_fraude, id_usuario, id_rol_cuenta_senal)
       VALUES ($1, $2, (SELECT id_rol_cuenta_senal FROM rol_cuenta_senal WHERE rol_cuenta_senal_nombre = 'autor'))`,
      [anillo.id_senal_fraude, c],
    );
  }

  mira(!(await concentradoras()).has(vendedor), 'C6: con sus resenas como evidencia de un anillo ya no es concentrador');

  const hallazgo = {
    fuente: 'grafo', idOrigen: Number(anillo.id_senal_fraude), tipo: 'satelites', cuentas,
    clave: [...cuentas].sort((a, b) => a - b).join('-'), metricas: {}, ultimaEvidencia: new Date(),
  };
  const [grupo] = await agrupador.agrupar([hallazgo]);
  mira(grupo != null && grupo.cuentas.get(vendedor) === true, 'C6: el agrupador pone al vendedor en el nucleo de su caso');

  // La regularidad, sin base: solo el calculo de puntos.
  const puntaje = new PuntajeFraudeService();
  const persistente = (regularidad) =>
    puntaje.puntosDeHallazgo({ fuente: 'grafo', tipo: 'persistente', cuentas: [1, 2], metricas: { regularidad } });
  const base = persistente(undefined);
  mira(persistente(null) === base, `regularidad null (el NaN guardado) no suma: ${persistente(null)} contra ${base}`);
  mira(persistente(0.1) === base + 5, `regularidad 0,1 suma los 5: ${persistente(0.1)} contra ${base}`);
  mira(persistente(0.5) === base, `regularidad 0,5 no suma: ${persistente(0.5)}`);

  await cliente.query('ROLLBACK');
  cliente.release();
  await pool.end();
  for (const t of ok) console.log(`OK     ${t}`);
  for (const t of fallos) console.log(`FALLA  ${t}`);
  console.log(`\n${ok.length} OK, ${fallos.length} FALLA`);
  console.log('Deshecho, no quedo nada en la base.');
  process.exit(fallos.length ? 1 : 0);
})().catch((e) => {
  console.error('No se pudo correr la prueba.', e.message);
  process.exit(2);
});
