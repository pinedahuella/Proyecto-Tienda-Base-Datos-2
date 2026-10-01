// pruebas/casos_fraude_fusion.cjs
// Reproduce C1, C2 y C3 de docs/BACKEND-PENDIENTE.md (seccion del 2026-09-26 en la
// noche) con las clases compiladas del agrupador de casos de fraude, dentro de UNA
// transaccion que se deshace al final. No deja nada en la base.
//
//   cd backend; npm run build; cd ..
//   node pruebas/casos_fraude_fusion.cjs
//
// Necesita PostgreSQL arriba con la 033, dos senales de anillo sin cuentas en comun
// y una senal multi_cuenta_ip.
//
// Desde el refactor de fraude (7453ffe, migraciones 031 a 033) todo hallazgo es una
// senal: su idOrigen es senal_fraude.id_senal_fraude y la evidencia del caso tiene
// una sola llave, id_senal_fraude. Antes esta prueba tomaba los ids de anillo_fraude
// y alerta_fraude, que el backend ya no lee.
//
// C2 y C3 son FALLA: el caso confirmado tiene que seguir confirmado y ninguna cuenta
// se pierde. Los arreglo David en 14e5084 (2026-09-26) y esta prueba da 0 FALLA.
// C1 sale como DECISION y no cuenta como falla: si una IP compartida debe unir dos
// anillos en un caso es algo que tienen que decidir. Mientras se una, el puntaje del
// caso sale solo del ultimo grupo guardado, y la prueba lo dice.
const path = require('path');
const BACK = path.join(__dirname, '..', 'backend');
process.chdir(BACK);
require(path.join(BACK, 'node_modules', 'dotenv')).config({ path: path.join(BACK, '.env'), quiet: true });
const { pool } = require(path.join(BACK, 'dist', 'database', 'postgres'));
const fraude = (nombre) => require(path.join(BACK, 'dist', 'services', 'fraude', nombre));
const { AgrupadorFraudeService } = fraude('agrupador-fraude.service');
const { PuntajeFraudeService } = fraude('puntaje-fraude.service');
const { ReglasCasiConfirmadoService } = fraude('reglas-casi-confirmado.service');
const { PersistenciaCasoFraudeService } = fraude('persistencia-caso-fraude.service');

(async () => {
  const cliente = await pool.connect();
  await cliente.query('BEGIN');
  // Todo lo que pidan los servicios pasa por este mismo cliente, y sus propios
  // BEGIN, COMMIT y ROLLBACK se ignoran: manda la transaccion de afuera.
  const q = (texto, params) =>
    /^\s*(BEGIN|COMMIT|ROLLBACK)/i.test(texto) ? Promise.resolve({ rows: [], rowCount: 0 }) : cliente.query(texto, params);
  pool.connect = async () => ({ query: q, release() {} });
  pool.query = q;

  const filas = async (sql, p) => (await cliente.query(sql, p)).rows;
  const agrupador = new AgrupadorFraudeService();
  const persistencia = new PersistenciaCasoFraudeService(new PuntajeFraudeService(), new ReglasCasiConfirmadoService());

  // Dos senales de anillo reales sin cuentas en comun, y una senal real de login.
  // La clave de un anillo son sus cuentas ordenadas y unidas con guion.
  const ANILLOS = `SELECT s.id_senal_fraude, s.clave FROM senal_fraude s
                     JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude)
                     JOIN familia_senal_fraude f USING (id_familia_senal_fraude)
                    WHERE f.familia_senal_fraude_nombre IN ('anillo_resenas', 'patron_resenas')
                      AND s.clave ~ '^[0-9]+(-[0-9]+)+$'`;
  const [a1] = await filas(`${ANILLOS} ORDER BY s.id_senal_fraude LIMIT 1`);
  const [a2] = a1
    ? await filas(
        `${ANILLOS} AND NOT (string_to_array(s.clave, '-') && string_to_array($1, '-'))
          ORDER BY s.id_senal_fraude LIMIT 1`,
        [a1.clave],
      )
    : [];
  const [al] = await filas(
    `SELECT s.id_senal_fraude FROM senal_fraude s JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude)
      WHERE t.tipo_senal_fraude_nombre = 'multi_cuenta_ip' LIMIT 1`,
  );
  if (!a1 || !a2 || !al) throw new Error('Hacen falta dos senales de anillo sin cuentas en comun y una senal multi_cuenta_ip');

  const c1 = a1.clave.split('-').map(Number);
  const c2 = a2.clave.split('-').map(Number);
  const ahora = new Date();
  const h = (fuente, id, tipo, cuentas) => ({
    fuente, idOrigen: Number(id), tipo, cuentas,
    clave: [...cuentas].sort((x, y) => x - y).join('-'), metricas: {}, ultimaEvidencia: ahora,
  });
  const anillo1 = h('grafo', a1.id_senal_fraude, 'mutuo', c1);
  const anillo2 = h('grafo', a2.id_senal_fraude, 'mutuo', c2);
  const login = h('login', al.id_senal_fraude, 'multi_cuenta_ip', [c1[0], c2[0]]);
  const senales = [a1.id_senal_fraude, a2.id_senal_fraude, al.id_senal_fraude];

  const casos = async () =>
    filas(
      `SELECT c.id_caso_fraude, e.estado_alerta_fraude_nombre AS estado, c.puntaje::float,
              (SELECT count(*) FROM evidencia_caso_fraude v WHERE v.id_caso_fraude = c.id_caso_fraude)::int AS evidencias,
              (SELECT string_agg(DISTINCT x.id_usuario::text, ',')
                 FROM evidencia_caso_fraude v JOIN evidencia_caso_fraude_cuenta x USING (id_evidencia_caso_fraude)
                WHERE v.id_caso_fraude = c.id_caso_fraude) AS cuentas
         FROM caso_fraude c JOIN estado_alerta_fraude e USING (id_estado_alerta_fraude)
        WHERE c.id_caso_fraude IN (SELECT id_caso_fraude FROM evidencia_caso_fraude
                                    WHERE id_senal_fraude IN ($1, $2, $3))
        ORDER BY 1`,
      senales,
    );

  // Se sacan las tres fuentes de sus casos, para empezar de cero dentro de la transaccion.
  await filas(`DELETE FROM evidencia_caso_fraude WHERE id_senal_fraude IN ($1, $2, $3)`, senales);

  console.log(`Anillos ${a1.clave} y ${a2.clave}, y una alerta de login que toca a ${c1[0]} y a ${c2[0]}`);
  for (const g of await agrupador.agrupar([anillo1, anillo2])) await persistencia.persistir(g);
  const antes = await casos();
  console.log('1. Sin la alerta:', JSON.stringify(antes));

  const confirmado = antes[antes.length - 1].id_caso_fraude;
  await filas(
    `UPDATE caso_fraude SET id_estado_alerta_fraude = (SELECT id_estado_alerta_fraude FROM estado_alerta_fraude
                                                        WHERE estado_alerta_fraude_nombre = 'confirmada')
      WHERE id_caso_fraude = $1`,
    [confirmado],
  );
  console.log(`   el admin confirma el caso ${confirmado}`);

  const grupos = await agrupador.agrupar([anillo1, anillo2, login]);
  console.log(`2. Con la alerta, el agrupador arma ${grupos.length} grupos y la alerta esta en ${grupos.filter((g) => g.hallazgos.includes(login)).length}`);
  for (const g of grupos) await persistencia.persistir(g);
  const despues = await casos();
  console.log('   casos al guardar:', JSON.stringify(despues));

  const fallos = [];
  const decisiones = [];
  if (despues.length < antes.length) {
    decisiones.push('C1, la alerta de login unio dos casos que el agrupador dejo separados');
    const completo = new PuntajeFraudeService().calcular({ cuentas: new Map(), hallazgos: [anillo1, anillo2, login] });
    const guardado = despues[0].puntaje;
    if (Math.abs(completo - guardado) > 0.01) {
      decisiones.push(`   y el puntaje guardado (${guardado}) sale del ultimo grupo; con toda su evidencia daria ${Math.round(completo * 10) / 10}`);
    }
  }
  if (!despues.some((c) => c.estado === 'confirmada')) fallos.push(`C2, el caso ${confirmado} confirmado ya no existe o volvio a pendiente`);
  const todas = new Set([...c1, ...c2].map(String));
  const quedan = new Set(despues.flatMap((c) => (c.cuentas ?? '').split(',')));
  const perdidas = [...todas].filter((x) => !quedan.has(x));
  if (perdidas.length) fallos.push(`C3, se perdieron las cuentas ${perdidas.join(', ')}`);

  await cliente.query('ROLLBACK');
  cliente.release();
  await pool.end();
  if (decisiones.length) console.log(`\nDECISION PENDIENTE\n  ${decisiones.join('\n  ')}`);
  console.log(fallos.length ? `\n${fallos.length} FALLA\n  ${fallos.join('\n  ')}` : '\n0 FALLA');
  console.log('Deshecho, no quedo nada en la base.');
  process.exit(fallos.length ? 1 : 0);
})().catch((e) => {
  console.error('No se pudo correr la prueba.', e.message);
  process.exit(2);
});
