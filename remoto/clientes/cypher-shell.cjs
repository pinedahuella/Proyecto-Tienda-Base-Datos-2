// remoto/clientes/cypher-shell.cjs -- un cypher-shell para el modo remoto
// (remoto/README.md), con el driver del backend (neo4j-driver), contra
// bolt://localhost:7687, que remoto/tunel.cjs lleva a la otra PC.
//
// Entiende lo que usan las pruebas:
//   -u usuario -p contrasena -a direccion -d base --format plain|verbose|auto
//   --non-interactive, -f archivo, y una consulta como argumento
//   sin consulta: el guion sale de stdin, con varias sentencias separadas por
//   ";", comentarios // y los comandos ":param nombre => valor"
//
// Escribe como el de verdad con --format plain: por cada sentencia que
// devuelve columnas, una linea con los nombres separados por ", " y despues
// una linea por fila. Los textos van entre comillas dobles, los booleanos y el
// null en mayusculas (TRUE, FALSE, NULL), las listas [a, b], los mapas
// {k: v}, los nodos (:Etiqueta {k: v}) y los decimales como Java (1.0).
// Un error sale por stderr y el programa sale con 1, sin seguir con el guion.
const fs = require('fs');
const path = require('path');
const { createRequire } = require('module');
const neo4j = createRequire(path.join(__dirname, '..', '..', 'backend', 'package.json'))('neo4j-driver');

const args = process.argv.slice(2);
const op = { user: 'neo4j', pass: '', address: 'bolt://127.0.0.1:7687', database: undefined, archivo: null };
const sueltos = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  switch (a) {
    case '-u': case '--username': op.user = args[++i]; break;
    case '-p': case '--password': op.pass = args[++i]; break;
    case '-a': case '--address': op.address = args[++i]; break;
    case '-d': case '--database': op.database = args[++i]; break;
    case '--format': i++; break;
    case '-f': case '--file': op.archivo = args[++i]; break;
    case '--non-interactive': case '--fail-fast': break;
    default:
      if (a.startsWith('-')) { process.stderr.write(`cypher-shell (remoto): no entiendo ${a}\n`); process.exit(2); }
      sueltos.push(a);
  }
}
if (!/^[a-z+]+:\/\//.test(op.address)) op.address = `bolt://${op.address}`;
// Dentro del contenedor "localhost" es el mismo Neo4j; aqui es el tunel.
op.address = op.address.replace('//localhost', '//127.0.0.1');

function leerStdin() {
  return new Promise((resolve) => {
    const partes = [];
    process.stdin.on('data', (d) => partes.push(d));
    process.stdin.on('end', () => resolve(Buffer.concat(partes).toString('utf8')));
  });
}

// Parte el guion en sentencias por los ";" de afuera, y separa los comandos
// ":algo" (que terminan en el fin de linea o en ";").
function partir(texto) {
  const salida = [];
  let actual = '';
  let i = 0;
  const empujar = () => { if (actual.trim()) salida.push(actual.trim()); actual = ''; };
  while (i < texto.length) {
    const c = texto[i];
    if (!actual.trim() && c === ':') {
      let j = i;
      while (j < texto.length && texto[j] !== '\n' && texto[j] !== ';') j++;
      salida.push(texto.slice(i, j).trim());
      i = j + 1;
      continue;
    }
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1;
      while (j < texto.length && texto[j] !== c) { if (texto[j] === '\\') j++; j++; }
      actual += texto.slice(i, j + 1); i = j + 1; continue;
    }
    if (c === '/' && texto[i + 1] === '/') {
      const j = texto.indexOf('\n', i);
      i = j < 0 ? texto.length : j; continue;
    }
    if (c === '/' && texto[i + 1] === '*') {
      const j = texto.indexOf('*/', i + 2);
      i = j < 0 ? texto.length : j + 2; continue;
    }
    if (c === ';') { empujar(); i++; continue; }
    actual += c; i++;
  }
  empujar();
  return salida;
}

function decimal(x) {
  if (!Number.isFinite(x)) return Number.isNaN(x) ? 'NaN' : (x > 0 ? 'Infinity' : '-Infinity');
  if (Number.isInteger(x) && Math.abs(x) < 1e7) return x.toFixed(1);
  // Java pasa a notacion cientifica por debajo de 0.001 (0.00001 -> 1.0E-5).
  const s = x !== 0 && Math.abs(x) < 1e-3 ? x.toExponential() : String(x);
  // Java escribe 1.0E-7 y 1.2345678E7 donde JavaScript escribe 1e-7 y 12345678.
  if (/e/.test(s)) {
    const [m, e] = s.split('e');
    return `${m.includes('.') ? m : m + '.0'}E${Number(e)}`;
  }
  if (Math.abs(x) >= 1e7) {
    const e = Math.floor(Math.log10(Math.abs(x)));
    const m = x / Math.pow(10, e);
    const ms = String(m);
    return `${ms.includes('.') ? ms : ms + '.0'}E${e}`;
  }
  return s;
}

function texto(v) {
  if (v === null || v === undefined) return 'NULL';
  if (neo4j.isInt(v)) return v.toString();
  if (typeof v === 'number') return decimal(v);
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  if (typeof v === 'string') return `"${v.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  if (Array.isArray(v)) return `[${v.map(texto).join(', ')}]`;
  if (v instanceof neo4j.types.Node) {
    const props = Object.keys(v.properties).length ? ` ${mapa(v.properties)}` : '';
    return `(${v.labels.map((l) => ':' + l).join('')}${props})`;
  }
  if (v instanceof neo4j.types.Relationship) {
    const props = Object.keys(v.properties).length ? ` ${mapa(v.properties)}` : '';
    return `[:${v.type}${props}]`;
  }
  if (v instanceof neo4j.types.Path) {
    return v.segments.map((s, k) => (k === 0 ? texto(s.start) : '') + `-${texto(s.relationship)}->` + texto(s.end)).join('');
  }
  if (neo4j.isDateTime(v) || neo4j.isLocalDateTime(v) || neo4j.isTime(v) || neo4j.isLocalTime(v)) {
    return horaJava(v.toString());
  }
  if (neo4j.isDate(v) || neo4j.isDuration(v) || neo4j.isPoint(v)) return v.toString();
  if (typeof v === 'object') return mapa(v);
  return String(v);
}

// La hora como la escribe Java (LocalTime.toString): sin los segundos si son
// cero y no hay fraccion (20:45), y la fraccion en grupos de 3 cifras (.946672,
// no .946672000). El driver de JavaScript siempre pone los segundos y las 9.
function horaJava(s) {
  return s.replace(/(\d{2}:\d{2}):(\d{2})(?:\.(\d+))?/, (_, hm, seg, frac) => {
    const f = (frac || '').replace(/0+$/, '');
    if (!f) return seg === '00' ? hm : `${hm}:${seg}`;
    const largo = f.length <= 3 ? 3 : f.length <= 6 ? 6 : 9;
    return `${hm}:${seg}.${f.padEnd(largo, '0')}`;
  });
}

// Los mapas (y las propiedades de un nodo) en el orden en que los recorre un
// HashMap de Java, que es como salen en el cypher-shell de verdad: por la
// cubeta del hash de cada llave y, dentro de una cubeta, en el orden en que
// llegaron. El tamano de la tabla es el de HashMap.newHashMap(n): la potencia
// de 2 que alcanza para n / 0.75. Medido contra el del contenedor.
function hashJava(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
  return h;
}
function ordenJava(llaves) {
  let capacidad = 1;
  while (capacidad < Math.ceil(llaves.length / 0.75)) capacidad *= 2;
  return llaves
    .map((k, i) => { const h = hashJava(k); return [(h ^ (h >>> 16)) & (capacidad - 1), i, k]; })
    .sort((a, b) => a[0] - b[0] || a[1] - b[1])
    .map((x) => x[2]);
}
function mapa(o) {
  return `{${ordenJava(Object.keys(o)).map((k) => `${k}: ${texto(o[k])}`).join(', ')}}`;
}

(async () => {
  let guion;
  if (sueltos.length) guion = sueltos.join(' ');
  else if (op.archivo) guion = fs.readFileSync(op.archivo, 'utf8');
  else guion = await leerStdin();

  const driver = neo4j.driver(op.address, neo4j.auth.basic(op.user, op.pass));
  const sesion = driver.session(op.database ? { database: op.database } : {});
  const parametros = {};
  let codigo = 0;
  try {
    for (const sentencia of partir(guion)) {
      if (sentencia.startsWith(':')) {
        // :param nombre => valor   (tambien la forma vieja ":param nombre: valor")
        const m = /^:params?\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=>|:)\s*([\s\S]+)$/.exec(sentencia);
        if (m) {
          const r = await sesion.run(`RETURN ${m[2]} AS v`, parametros);
          parametros[m[1]] = r.records[0].get('v');
        }
        continue; // :begin, :commit, :use... no hacen falta aqui
      }
      const r = await sesion.run(sentencia, parametros);
      if (r.records.length || (r.records.length === 0 && r.summary.query && /\bRETURN\b/i.test(sentencia))) {
        const claves = r.records.length ? r.records[0].keys : [];
        if (claves.length) process.stdout.write(claves.join(', ') + '\n');
        for (const fila of r.records) process.stdout.write(fila.keys.map((k) => texto(fila.get(k))).join(', ') + '\n');
      }
    }
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    codigo = 1;
  } finally {
    await sesion.close();
    await driver.close();
  }
  process.exit(codigo);
})();
