// Lee del backend COMPILADO (backend/dist) cada ruta, sus guards, sus roles y su
// permiso, sin levantar el servidor. Es la fuente de verdad de lo que protege cada
// ruta, porque sale de los mismos decoradores que usa Nest.
//
//   node pruebas/permisos_matriz.cjs                 la matriz en JSON por la salida
//   node pruebas/permisos_matriz.cjs --tabla         una linea por ruta, para leer
//   node pruebas/permisos_matriz.cjs --guardar F     la escribe en el archivo F
//
// Antes hay que compilar: cd backend; npm run build.
// La usan pruebas/permisos_rol.sh (para comparar con la matriz de antes de la 050)
// y pruebas/permisos_cobertura.cjs.
'use strict';
const fs = require('fs');
const path = require('path');

const raiz = path.join(__dirname, '..', 'backend');
const req = (m) => require(require.resolve(m, { paths: [raiz] }));
req('reflect-metadata');
// Los modulos de las bases piden sus variables al cargarse, aunque aqui no se use ninguna.
req('dotenv').config({ path: path.join(raiz, '.env'), quiet: true });

const METODOS = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'ALL', 'OPTIONS', 'HEAD', 'SEARCH'];

function archivos(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) return archivos(p);
    return e.name.endsWith('.controller.js') ? [p] : [];
  });
}

function unir(a, b) {
  const s = ['', a, b].filter((x) => x != null && x !== '' && x !== '/').join('/');
  return ('/' + s).replace(/\/+/g, '/').replace(/\/$/, '') || '/';
}

function nombres(guards) {
  return (guards || []).map((g) => (typeof g === 'function' ? g.name : g?.constructor?.name ?? '?'));
}

function leer() {
  const dist = path.join(raiz, 'dist', 'controllers');
  if (!fs.existsSync(dist)) {
    throw new Error('No hay backend/dist: corre npm run build en backend');
  }
  const rutas = [];
  for (const f of archivos(dist).sort()) {
    const modulo = require(f);
    for (const clase of Object.values(modulo)) {
      if (typeof clase !== 'function') continue;
      const base = Reflect.getMetadata('path', clase);
      if (base === undefined) continue;
      const proto = clase.prototype;
      for (const nombre of Object.getOwnPropertyNames(proto)) {
        if (nombre === 'constructor') continue;
        const fn = proto[nombre];
        if (typeof fn !== 'function') continue;
        const sub = Reflect.getMetadata('path', fn);
        const metodo = Reflect.getMetadata('method', fn);
        if (sub === undefined || metodo === undefined) continue;
        const guards = [...nombres(Reflect.getMetadata('__guards__', clase)), ...nombres(Reflect.getMetadata('__guards__', fn))];
        const de = (clave) => {
          const m = Reflect.getMetadata(clave, fn);
          return m !== undefined ? m : Reflect.getMetadata(clave, clase);
        };
        for (const b of [].concat(base)) {
          for (const s of [].concat(sub)) {
            rutas.push({
              metodo: METODOS[metodo] ?? String(metodo),
              ruta: unir(b, s),
              controlador: clase.name,
              funcion: nombre,
              archivo: path.relative(path.join(raiz, 'dist'), f).replace(/\\/g, '/'),
              guards,
              roles: de('roles') ?? null,
              permiso: de('permiso_funcion') ?? null,
              permiso_oferta: de('permiso_oferta') ?? null,
            });
          }
        }
      }
    }
  }
  rutas.sort((x, y) => (x.ruta + ' ' + x.metodo).localeCompare(y.ruta + ' ' + y.metodo));
  return rutas;
}

module.exports = { leer };

if (require.main === module) {
  let salida = 0;
  try {
    const rutas = leer();
    const i = process.argv.indexOf('--guardar');
    if (i > 0) {
      fs.writeFileSync(process.argv[i + 1], JSON.stringify(rutas, null, 2) + '\n');
      console.log(`${rutas.length} rutas guardadas en ${process.argv[i + 1]}`);
    } else if (process.argv.includes('--tabla')) {
      for (const r of rutas) {
        const quien = r.permiso ?? (r.roles ? 'roles ' + r.roles.join(',') : r.guards.length ? 'cualquier sesion' : 'publica');
        console.log(`${r.metodo.padEnd(6)} ${r.ruta.padEnd(58)} ${quien}${r.permiso_oferta ? ' + oferta:' + r.permiso_oferta : ''}`);
      }
    } else {
      process.stdout.write(JSON.stringify(rutas, null, 2) + '\n');
    }
  } catch (e) {
    console.error(e.message);
    salida = 1;
  }
  // Algunos modulos abren conexiones al cargarse; no hay que esperarlas.
  process.exit(salida);
}
