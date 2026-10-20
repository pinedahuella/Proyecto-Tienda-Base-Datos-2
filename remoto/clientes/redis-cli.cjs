// remoto/clientes/redis-cli.cjs -- un redis-cli para el modo remoto
// (remoto/README.md), contra localhost:6379, que remoto/tunel.cjs lleva a la
// otra PC. Habla RESP2 directo por el socket, como redis-cli: ioredis manda
// HELLO al conectar y, sin contrasena, Redis cierra la conexion antes de que
// se vea el NOAUTH que las pruebas esperan.
//
// Contesta como el redis-cli de verdad cuando la salida NO es una terminal
// (que es como lo usan las pruebas, siempre capturado), medido contra el del
// contenedor: cada respuesta en crudo, una por linea, los arreglos aplanados,
// el nil como linea vacia, el error con su texto tal cual seguido de una
// linea vacia, y la salida con 0 aunque Redis conteste un error. Una
// contrasena mala dice "AUTH failed: ..." por stderr y sigue.
//
// Entiende lo que usan las pruebas:
//   -h host -p puerto -n base -a contrasena --user u --pass p --no-auth-warning
//   --raw / --no-raw (no cambian nada: siempre crudo)
//   -x                      el ultimo argumento sale de stdin
//   --scan [--pattern P] [--count N]
//   sin comando: lee los comandos de stdin, uno por linea, con comillas como
//   las de redis-cli ("a b", 'c', \n)
const net = require('net');

const args = process.argv.slice(2);
const op = { host: '127.0.0.1', port: 6379, db: 0, user: null, pass: null, x: false, scan: false, pattern: '*', count: 100 };
const comando = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (comando.length) { comando.push(a); continue; }
  switch (a) {
    case '-h': op.host = args[++i]; break;
    case '-p': op.port = Number(args[++i]); break;
    case '-n': op.db = Number(args[++i]); break;
    case '-a': case '--pass': op.pass = args[++i]; break;
    case '--user': op.user = args[++i]; break;
    case '--no-auth-warning': case '--raw': case '--no-raw': break;
    case '-x': op.x = true; break;
    case '--scan': op.scan = true; break;
    case '--pattern': op.pattern = args[++i]; break;
    case '--count': op.count = Number(args[++i]); break;
    default:
      if (a.startsWith('-') && !/^-\d/.test(a)) {
        process.stderr.write(`redis-cli (remoto): no entiendo la opcion ${a}\n`);
        process.exit(2);
      }
      comando.push(a);
  }
}
if (op.host === 'localhost') op.host = '127.0.0.1';

function leerStdin() {
  return new Promise((resolve) => {
    const partes = [];
    process.stdin.on('data', (d) => partes.push(d));
    process.stdin.on('end', () => resolve(Buffer.concat(partes).toString('utf8')));
  });
}

// Como sdssplitargs de redis-cli: espacios separan, "..." con escapes, '...'.
function partirLinea(linea) {
  const salida = [];
  let i = 0;
  while (i < linea.length) {
    while (i < linea.length && /\s/.test(linea[i])) i++;
    if (i >= linea.length) break;
    let actual = '';
    if (linea[i] === '"') {
      i++;
      while (i < linea.length && linea[i] !== '"') {
        if (linea[i] === '\\' && i + 1 < linea.length) {
          const s = linea[++i];
          actual += s === 'n' ? '\n' : s === 'r' ? '\r' : s === 't' ? '\t' : s;
        } else actual += linea[i];
        i++;
      }
      i++;
    } else if (linea[i] === "'") {
      i++;
      while (i < linea.length && linea[i] !== "'") actual += linea[i++];
      i++;
    } else {
      while (i < linea.length && !/\s/.test(linea[i])) actual += linea[i++];
    }
    salida.push(actual);
  }
  return salida;
}

// ---------------- RESP2 ----------------
const socket = net.connect(op.port, op.host);
let bufer = Buffer.alloc(0);
const esperando = [];
socket.on('data', (d) => { bufer = Buffer.concat([bufer, d]); despachar(); });

class ErrorRedis { constructor(m) { this.mensaje = m; } }

// Lee una respuesta de bufer desde pos; devuelve [valor, nuevaPos] o null si
// falta llegar algo.
function leer(pos) {
  const fin = bufer.indexOf('\r\n', pos);
  if (fin < 0) return null;
  const tipo = String.fromCharCode(bufer[pos]);
  const linea = bufer.toString('utf8', pos + 1, fin);
  const sig = fin + 2;
  switch (tipo) {
    case '+': return [linea, sig];
    case '-': return [new ErrorRedis(linea), sig];
    case ':': return [linea, sig];
    case '$': {
      const n = Number(linea);
      if (n < 0) return [null, sig];
      if (bufer.length < sig + n + 2) return null;
      return [bufer.toString('utf8', sig, sig + n), sig + n + 2];
    }
    case '*': {
      const n = Number(linea);
      if (n < 0) return [null, sig];
      const lista = [];
      let p = sig;
      for (let k = 0; k < n; k++) {
        const r = leer(p);
        if (!r) return null;
        lista.push(r[0]); p = r[1];
      }
      return [lista, p];
    }
    default: throw new Error(`respuesta de Redis que no entiendo: ${tipo}`);
  }
}
function despachar() {
  while (esperando.length) {
    const r = leer(0);
    if (!r) return;
    bufer = bufer.subarray(r[1]);
    esperando.shift()(r[0]);
  }
}
function enviar(partes) {
  return new Promise((resolve) => {
    esperando.push(resolve);
    const trozos = [Buffer.from(`*${partes.length}\r\n`)];
    for (const p of partes) {
      const b = Buffer.from(String(p), 'utf8');
      trozos.push(Buffer.from(`$${b.length}\r\n`), b, Buffer.from('\r\n'));
    }
    socket.write(Buffer.concat(trozos));
  });
}

function crudo(r) {
  if (r === null || r === undefined) return [''];
  if (r instanceof ErrorRedis) return [r.mensaje, ''];
  if (Array.isArray(r)) return r.flatMap(crudo);
  return [String(r)];
}

socket.on('error', (e) => {
  process.stderr.write(`Could not connect to Redis at ${op.host}:${op.port}: ${e.message}\n`);
  process.exit(1);
});

socket.on('connect', async () => {
  if (op.pass != null) {
    const r = await enviar(op.user ? ['AUTH', op.user, op.pass] : ['AUTH', op.pass]);
    if (r instanceof ErrorRedis) process.stderr.write(`AUTH failed: ${r.mensaje}\n`);
  }
  if (op.db) await enviar(['SELECT', op.db]);

  const correr = async (partes) => {
    for (const l of crudo(await enviar(partes))) process.stdout.write(l + '\n');
  };

  if (op.scan) {
    let cursor = '0';
    do {
      const r = await enviar(['SCAN', cursor, 'MATCH', op.pattern, 'COUNT', op.count]);
      if (r instanceof ErrorRedis) { process.stdout.write(`${r.mensaje}\n\n`); break; }
      cursor = String(r[0]);
      for (const k of r[1]) process.stdout.write(k + '\n');
    } while (cursor !== '0');
  } else if (comando.length) {
    if (op.x) comando.push(await leerStdin());
    await correr(comando);
  } else {
    const texto = await leerStdin();
    for (const linea of texto.split(/\r?\n/)) {
      const partes = partirLinea(linea);
      if (partes.length) await correr(partes);
    }
  }
  socket.end();
  process.exitCode = 0;
});
