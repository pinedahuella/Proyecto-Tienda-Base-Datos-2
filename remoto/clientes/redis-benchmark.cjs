// remoto/clientes/redis-benchmark.cjs -- un redis-benchmark para el modo
// remoto (remoto/README.md), contra localhost:6379, que remoto/tunel.cjs lleva
// a la otra PC. Lo usa redis/prueba_concurrencia.sh para lanzar la carga.
//
// Hace lo mismo que el de verdad en lo que esa prueba mira:
//   - abre -c conexiones a la vez, cada una con su AUTH, y las sostiene toda la
//     corrida (la prueba cuenta los sockets con total_connections_received);
//   - reparte -n comandos entre ellas, con una peticion en el aire por
//     conexion (el -P 1 de siempre): cada una manda la siguiente al recibir la
//     respuesta de la anterior;
//   - cambia cada __rand_int__ del comando por un numero al azar menor que -r,
//     con 12 cifras y ceros a la izquierda, distinto en cada peticion;
//   - termina con la linea "<COMANDO>: N requests per second, p50=X msec".
//
// Entiende: -h host -p puerto -a contrasena --user u --pass p -q -n -c -r, y
// despues el comando con sus argumentos.
const net = require('net');

const args = process.argv.slice(2);
const op = { host: '127.0.0.1', port: 6379, user: null, pass: null, n: 100000, c: 50, r: 0 };
const comando = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (comando.length) { comando.push(a); continue; }
  switch (a) {
    case '-h': op.host = args[++i]; break;
    case '-p': op.port = Number(args[++i]); break;
    case '-a': case '--pass': op.pass = args[++i]; break;
    case '--user': op.user = args[++i]; break;
    case '-n': op.n = Number(args[++i]); break;
    case '-c': op.c = Number(args[++i]); break;
    case '-r': op.r = Number(args[++i]); break;
    case '-q': case '--no-auth-warning': break;
    default:
      if (a.startsWith('-')) {
        process.stderr.write(`redis-benchmark (remoto): no entiendo la opcion ${a}\n`);
        process.exit(2);
      }
      comando.push(a);
  }
}
if (op.host === 'localhost') op.host = '127.0.0.1';
if (!comando.length) {
  process.stderr.write('redis-benchmark (remoto): solo sabe correr un comando dado (los -t de siempre no)\n');
  process.exit(2);
}

const RAND = '__rand_int__';
function azar() {
  return String(op.r > 0 ? Math.floor(Math.random() * op.r) : 0).padStart(12, '0');
}
function codificar(partes) {
  const trozos = [Buffer.from(`*${partes.length}\r\n`)];
  for (const p of partes) {
    const texto = String(p).split(RAND).reduce((acc, trozo, k) => (k ? acc + azar() + trozo : trozo));
    const b = Buffer.from(texto, 'utf8');
    trozos.push(Buffer.from(`$${b.length}\r\n`), b, Buffer.from('\r\n'));
  }
  return Buffer.concat(trozos);
}

// Cuantas respuestas RESP2 completas hay en b desde pos; devuelve el fin de la
// primera, o -1 si todavia falta llegar algo. El error de la primera queda en
// el objeto que se le pasa.
function finDeRespuesta(b, pos, info) {
  const fin = b.indexOf('\r\n', pos);
  if (fin < 0) return -1;
  const tipo = String.fromCharCode(b[pos]);
  const linea = b.toString('utf8', pos + 1, fin);
  const sig = fin + 2;
  switch (tipo) {
    case '+': case ':': return sig;
    case '-': if (info) info.error = linea; return sig;
    case '$': {
      const n = Number(linea);
      if (n < 0) return sig;
      return b.length < sig + n + 2 ? -1 : sig + n + 2;
    }
    case '*': {
      const n = Number(linea);
      let p = sig;
      for (let k = 0; k < n; k++) {
        p = finDeRespuesta(b, p, null);
        if (p < 0) return -1;
      }
      return p;
    }
    default: throw new Error(`respuesta de Redis que no entiendo: ${tipo}`);
  }
}

let enviadas = 0;
let contestadas = 0;
let inicio = 0;
const tiempos = [];
let primerError = null;

function conectar() {
  return new Promise((resolve, reject) => {
    const s = net.connect(op.port, op.host);
    s.setNoDelay(true);
    const cx = { s, bufer: Buffer.alloc(0), alLlegar: null, mandada: 0 };
    s.on('data', (d) => {
      cx.bufer = Buffer.concat([cx.bufer, d]);
      for (;;) {
        const info = {};
        const fin = finDeRespuesta(cx.bufer, 0, info);
        if (fin < 0) return;
        cx.bufer = cx.bufer.subarray(fin);
        if (cx.alLlegar) cx.alLlegar(info.error || null);
      }
    });
    s.on('error', reject);
    s.on('connect', () => resolve(cx));
  });
}
function pedir(cx, partes) {
  return new Promise((resolve) => {
    cx.alLlegar = resolve;
    cx.s.write(codificar(partes));
  });
}

async function trabajar(cx) {
  while (enviadas < op.n) {
    enviadas++;
    const t = process.hrtime.bigint();
    const error = await pedir(cx, comando);
    tiempos.push(Number(process.hrtime.bigint() - t) / 1e6);
    if (error && !primerError) primerError = error;
    contestadas++;
  }
}

(async () => {
  const auth = op.pass == null ? null : op.user ? ['AUTH', op.user, op.pass] : ['AUTH', op.pass];

  // Como el de verdad: antes de la carga abre una conexion aparte para leer la
  // configuracion del servidor (CONFIG GET save y appendonly) y la cierra. La
  // prueba cuenta esa conexion junto con las -c.
  try {
    const cfg = await conectar();
    if (auth) await pedir(cfg, auth);
    await pedir(cfg, ['CONFIG', 'GET', 'save']);
    await pedir(cfg, ['CONFIG', 'GET', 'appendonly']);
    cfg.s.end();
  } catch (e) {
    process.stderr.write('WARNING: Could not fetch server CONFIG\n');
  }

  let conexiones;
  try {
    conexiones = await Promise.all(Array.from({ length: op.c }, conectar));
  } catch (e) {
    process.stderr.write(`Could not connect to Redis at ${op.host}:${op.port}: ${e.message}\n`);
    process.exit(1);
  }
  if (auth) {
    const errores = await Promise.all(conexiones.map((cx) => pedir(cx, auth)));
    if (errores.some(Boolean)) {
      process.stderr.write(`AUTH failed: ${errores.find(Boolean)}\n`);
      process.exit(1);
    }
  }
  inicio = Date.now();
  await Promise.all(conexiones.map(trabajar));
  const segundos = Math.max((Date.now() - inicio) / 1000, 0.001);
  for (const cx of conexiones) cx.s.end();

  if (primerError) process.stderr.write(`Error from server: ${primerError}\n`);
  tiempos.sort((a, b) => a - b);
  const p50 = tiempos.length ? tiempos[Math.floor(tiempos.length / 2)] : 0;
  const nombre = String(comando[0]).toUpperCase();
  process.stdout.write(`${nombre}: ${(contestadas / segundos).toFixed(2)} requests per second, p50=${p50.toFixed(3)} msec\n`);
})();
