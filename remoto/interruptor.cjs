// remoto/interruptor.cjs
//   node remoto/interruptor.cjs [ip de la PC con las bases]     (por omision 100.64.42.11)
//
// Un interruptor por base para simular que se cae, sin tocar la PC que la
// tiene. Reenvia un puerto propio de esta PC a cada base de alla, y cada uno se
// puede apagar y prender en vivo. El backend se arranca apuntando a estos
// puertos (remoto/caidas.ps1 lo hace) y para el la base se cae de verdad: su
// driver ve lo mismo que veria con la base parada.
//
// Tres estados por base:
//   arriba     reenvia normal.
//   apagada    deja de escuchar y corta las conexiones abiertas. Es lo que ve
//              el backend con un `docker stop` en la misma maquina: conexion
//              rechazada al instante.
//   congelada  acepta la conexion pero nunca contesta, y deja colgadas las que
//              ya estaban. Es un `docker pause`, o la red cortada a mitad de
//              camino, que es lo que se vio el 19-10 con la PC de Jose David
//              apagando bases por Tailscale: el backend no recibe un "no",
//              espera hasta que se le acaba el tiempo.
//
// Se controla por HTTP en 127.0.0.1:5198 (INTERRUPTOR_PUERTO):
//   GET  /estado                     {"destino": ..., "bases": {"redis": "arriba", ...}}
//   POST /<base>/<estado>            base: postgres, mongo, redis, neo4j, clickhouse,
//                                    elastic o todas; estado: arriba, apagada, congelada
//   GET  /ambiente                   las variables para arrancar el backend por aqui
//
// Solo escucha en 127.0.0.1. Los puertos de aqui no chocan con los del Docker
// local ni con los de remoto/tunel.cjs: son los de siempre mas 10000 (Mongo,
// que ya esta en el 27018, va al 37018).
const net = require('net');
const http = require('http');

const DESTINO = process.argv[2] || '100.64.42.11';
const CONTROL = Number(process.env.INTERRUPTOR_PUERTO || 5198);
const HOST = '127.0.0.1';

// clave: [nombre, puerto aqui, puerto alla, variables del backend]
const BASES = {
  postgres: ['PostgreSQL', 15432, 5432, ['DB_HOST', 'DB_PORT']],
  mongo: ['MongoDB', 37018, 27018, ['MONGO_HOST', 'MONGO_PORT']],
  redis: ['Redis', 16379, 6379, ['REDIS_HOST', 'REDIS_PORT']],
  neo4j: ['Neo4j', 17687, 7687, ['NEO4J_HOST', 'NEO4J_PORT']],
  clickhouse: ['ClickHouse', 18123, 8123, ['CLICKHOUSE_HOST', 'CLICKHOUSE_PORT']],
  elastic: ['Elasticsearch', 19200, 9200, ['ELASTIC_HOST', 'ELASTIC_PORT']],
};
const ESTADOS = ['arriba', 'apagada', 'congelada'];

const hora = () => new Date().toLocaleTimeString('es-GT', { hour12: false });
const log = (texto) => console.log(`${hora()} ${texto}`);

/** Lo de cada base: su estado, su servidor (null si no escucha) y sus conexiones. */
const estado = {};
for (const clave of Object.keys(BASES)) {
  estado[clave] = { modo: 'arriba', servidor: null, conexiones: new Set() };
}

function cerrarPar(par) {
  par.cliente.destroy();
  if (par.alla) par.alla.destroy();
}

function atender(clave, cliente) {
  const base = estado[clave];
  const [, , puertoAlla] = BASES[clave];
  const par = { cliente, alla: null };
  base.conexiones.add(par);
  cliente.on('close', () => {
    base.conexiones.delete(par);
    if (par.alla) par.alla.destroy();
  });
  cliente.on('error', () => cerrarPar(par));
  cliente.setNoDelay(true);

  if (base.modo === 'congelada') {
    // Se acepta y no se contesta: el cliente espera hasta su propio limite.
    cliente.pause();
    return;
  }

  const alla = net.connect(puertoAlla, DESTINO);
  par.alla = alla;
  alla.setNoDelay(true);
  alla.on('error', () => cerrarPar(par));
  alla.on('close', () => cliente.destroy());
  cliente.pipe(alla);
  alla.pipe(cliente);
}

function escuchar(clave) {
  return new Promise((resolver, rechazar) => {
    const [nombre, puertoAqui] = BASES[clave];
    const servidor = net.createServer((cliente) => atender(clave, cliente));
    servidor.once('error', (e) => {
      rechazar(new Error(`${nombre} en ${puertoAqui}: ${e.code === 'EADDRINUSE' ? 'puerto ocupado' : e.message}`));
    });
    servidor.listen(puertoAqui, HOST, () => {
      estado[clave].servidor = servidor;
      resolver();
    });
  });
}

function dejarDeEscuchar(clave) {
  const base = estado[clave];
  if (base.servidor == null) return Promise.resolve();
  const servidor = base.servidor;
  base.servidor = null;
  return new Promise((resolver) => servidor.close(() => resolver()));
}

/** Congela lo que ya estaba abierto: nada pasa en ninguna direccion. */
function congelarAbiertas(clave) {
  for (const par of estado[clave].conexiones) {
    par.cliente.unpipe();
    par.cliente.pause();
    if (par.alla) {
      par.alla.unpipe();
      par.alla.pause();
    }
  }
}

function cortarAbiertas(clave) {
  for (const par of [...estado[clave].conexiones]) cerrarPar(par);
}

async function cambiar(clave, modo) {
  const base = estado[clave];
  const anterior = base.modo;
  if (anterior === modo) return;

  if (modo === 'apagada') {
    base.modo = modo;
    // Primero se cortan las abiertas: close() espera a que terminen todas, y
    // con una colgada esperaria para siempre.
    const cerrando = dejarDeEscuchar(clave);
    cortarAbiertas(clave);
    await cerrando;
  } else if (modo === 'congelada') {
    base.modo = modo;
    congelarAbiertas(clave);
    if (base.servidor == null) await escuchar(clave);
  } else {
    // De congelada a arriba se cortan las colgadas: el driver vuelve a abrir
    // las suyas, como despues de un corte de red de verdad.
    if (anterior === 'congelada') cortarAbiertas(clave);
    base.modo = modo;
    if (base.servidor == null) await escuchar(clave);
  }
  log(`${BASES[clave][0]}: ${anterior} -> ${modo}`);
}

function ambiente() {
  const variables = {};
  for (const [, puertoAqui, , [varHost, varPuerto]] of Object.values(BASES)) {
    variables[varHost] = HOST;
    variables[varPuerto] = String(puertoAqui);
  }
  return variables;
}

function responder(res, codigo, cuerpo) {
  res.writeHead(codigo, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(cuerpo));
}

function resumen() {
  const bases = {};
  for (const clave of Object.keys(BASES)) bases[clave] = estado[clave].modo;
  return { destino: DESTINO, bases };
}

const control = http.createServer(async (req, res) => {
  const partes = (req.url || '/').split('?')[0].split('/').filter(Boolean);
  try {
    if (req.method === 'GET' && partes[0] === 'estado') return responder(res, 200, resumen());
    if (req.method === 'GET' && partes[0] === 'ambiente') return responder(res, 200, ambiente());
    if (req.method === 'POST' && partes.length === 2) {
      const [clave, modo] = partes;
      if (!ESTADOS.includes(modo)) return responder(res, 400, { error: `estado: ${ESTADOS.join(', ')}` });
      const claves = clave === 'todas' ? Object.keys(BASES) : [clave];
      if (claves.some((c) => !BASES[c])) {
        return responder(res, 400, { error: `base: ${Object.keys(BASES).join(', ')} o todas` });
      }
      for (const c of claves) await cambiar(c, modo);
      return responder(res, 200, resumen());
    }
    return responder(res, 404, { error: 'GET /estado, GET /ambiente o POST /<base>/<estado>' });
  } catch (e) {
    return responder(res, 500, { error: e.message });
  }
});

(async () => {
  try {
    for (const clave of Object.keys(BASES)) await escuchar(clave);
  } catch (e) {
    console.error(`interruptor: ${e.message}`);
    process.exit(1);
  }
  control.on('error', (e) => {
    console.error(`interruptor: control en ${CONTROL}: ${e.code === 'EADDRINUSE' ? 'puerto ocupado (ya hay un interruptor?)' : e.message}`);
    process.exit(1);
  });
  control.listen(CONTROL, HOST, () => {
    log(`interruptor listo hacia ${DESTINO}, control en http://${HOST}:${CONTROL}`);
  });
})();
