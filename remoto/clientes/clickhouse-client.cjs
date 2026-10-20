// remoto/clientes/clickhouse-client.cjs -- un clickhouse-client para el modo
// remoto (remoto/README.md), por la interfaz HTTP de ClickHouse (el 8123, el
// mismo que usa el backend), contra localhost, que remoto/tunel.cjs lleva a la
// otra PC.
//
// Entiende lo que usan las pruebas y los ETL:
//   --user/-u, --password, --database/-d, --host/-h, --port (HTTP, 8123)
//   --query/-q "..."        una consulta. Si es un INSERT, los datos salen de
//                           stdin (como "INSERT ... FORMAT TabSeparated" < datos)
//   sin --query             las consultas salen de stdin, separadas por ";"
//   --multiquery/-n         (no cambia nada: de stdin siempre van varias)
//   --format/-f F           el formato de salida (default_format)
//   --param_x=v, --param_x v  parametros {x:Tipo}
//   --cualquier_ajuste v    se manda como ajuste de la consulta (mutations_sync...)
// Por HTTP el formato por omision es TabSeparated, el mismo que da el cliente
// cuando la salida no es una terminal. Un error sale por stderr con su texto
// ("Code: 60. DB::Exception: ...") y el programa sale con 1.
const args = process.argv.slice(2);
const op = { user: 'default', password: '', database: null, host: '127.0.0.1', port: 8123, query: null, format: null };
const params = {};
const ajustes = {};

for (let i = 0; i < args.length; i++) {
  let a = args[i];
  let valor = null;
  const igual = a.indexOf('=');
  if (a.startsWith('--') && igual > 0) { valor = a.slice(igual + 1); a = a.slice(0, igual); }
  const tomar = () => (valor !== null ? valor : args[++i]);
  switch (a) {
    case '--user': case '-u': op.user = tomar(); break;
    case '--password': op.password = tomar(); break;
    case '--database': case '-d': op.database = tomar(); break;
    case '--host': case '-h': op.host = tomar(); break;
    case '--port': tomar(); break; // el nativo (9000) no existe aqui: siempre HTTP
    case '--query': case '-q': op.query = tomar(); break;
    case '--format': case '-f': op.format = tomar(); break;
    case '--multiquery': case '-n': case '--multiline': case '-m': break;
    default:
      if (a.startsWith('--param_')) params[a.slice(8)] = tomar();
      else if (a.startsWith('--')) ajustes[a.slice(2)] = tomar();
      else { process.stderr.write(`clickhouse-client (remoto): no entiendo ${a}\n`); process.exit(2); }
  }
}

function leerStdin() {
  return new Promise((resolve) => {
    if (process.stdin.isTTY) return resolve('');
    const partes = [];
    process.stdin.on('data', (d) => partes.push(d));
    process.stdin.on('end', () => resolve(Buffer.concat(partes)));
  });
}

// Parte un guion en consultas por los ";" de afuera: respeta '...', "...",
// `...`, los comentarios -- y /* */.
function partir(sql) {
  const salida = [];
  let actual = '';
  for (let i = 0; i < sql.length; i++) {
    const c = sql[i];
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1;
      while (j < sql.length && sql[j] !== c) { if (sql[j] === '\\') j++; j++; }
      actual += sql.slice(i, j + 1); i = j; continue;
    }
    if (c === '-' && sql[i + 1] === '-') {
      const j = sql.indexOf('\n', i);
      i = j < 0 ? sql.length : j; actual += '\n'; continue;
    }
    if (c === '/' && sql[i + 1] === '*') {
      const j = sql.indexOf('*/', i + 2);
      i = j < 0 ? sql.length : j + 1; continue;
    }
    if (c === ';') { if (actual.trim()) salida.push(actual.trim()); actual = ''; continue; }
    actual += c;
  }
  if (actual.trim()) salida.push(actual.trim());
  return salida;
}

async function correr(consulta, cuerpo) {
  const url = new URL(`http://${op.host}:${op.port}/`);
  if (op.database) url.searchParams.set('database', op.database);
  if (op.format) url.searchParams.set('default_format', op.format);
  for (const [k, v] of Object.entries(ajustes)) url.searchParams.set(k, v);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(`param_${k}`, v);
  let body;
  if (cuerpo != null) { url.searchParams.set('query', consulta); body = cuerpo; }
  else body = consulta;
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'X-ClickHouse-User': op.user, 'X-ClickHouse-Key': op.password },
    body,
  });
  const texto = Buffer.from(await r.arrayBuffer());
  if (!r.ok) {
    // El cliente de verdad sale con el numero del error ("Code: 60." -> 60).
    const mensaje = texto.toString('utf8').trimEnd();
    const codigo = /^Code: (\d+)\./.exec(mensaje);
    process.stderr.write(mensaje + '\n');
    process.exit(codigo ? (Number(codigo[1]) % 256 || 1) : 1);
  }
  process.stdout.write(texto);
}

(async () => {
  try {
    if (op.query != null) {
      const esInsert = /^\s*INSERT\b/i.test(op.query) && !/\bVALUES\b/i.test(op.query) && !/\bSELECT\b/i.test(op.query);
      const datos = esInsert ? await leerStdin() : null;
      await correr(op.query, esInsert ? datos : null);
    } else {
      const guion = (await leerStdin()).toString('utf8');
      for (const consulta of partir(guion)) await correr(consulta, null);
    }
  } catch (e) {
    process.stderr.write(`clickhouse-client (remoto): ${e.message}\n`);
    process.exit(1);
  }
})();
