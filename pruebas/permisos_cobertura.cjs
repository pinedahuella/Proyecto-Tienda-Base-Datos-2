// pruebas/permisos_cobertura.cjs
//   cd backend; npm run build; cd ..; node pruebas/permisos_cobertura.cjs
// Necesita PostgreSQL con la migracion 050. No necesita el backend corriendo.
//
// El ACL de funcionalidades (migracion 050, ADR-26) sin mirar una sola peticion:
// lee del backend COMPILADO cada ruta y su @Permiso (pruebas/permisos_matriz.cjs) y
// de PostgreSQL la tabla rol_permiso, y comprueba:
//
//   1. Que cada ruta con SesionGuard tenga PermisoGuard justo detras y declare un
//      permiso, y que ese permiso exista en la base. Ninguna ruta privada sin ACL.
//   2. Que el catalogo de la base y la lista del codigo (models/permiso.ts) sean
//      el mismo, y que ningun permiso de la base quede sin ruta.
//   3. Que la semilla reproduzca EXACTAMENTE lo de antes: para cada ruta, los roles
//      que hoy tienen su permiso son los mismos que dejaba pasar su @Roles(...) en
//      pruebas/permisos_matriz_antes_050.json (sin @Roles = cualquier rol con
//      sesion). Solo vale con la matriz de la semilla: si un admin ya cambio la
//      tabla, esta parte lo dice y no cuenta como falla (--sin-semilla la salta).
//   4. Que /compartidas/ofertas pase primero por el rol y despues por la oferta.
'use strict';
const path = require('path');
const fs = require('fs');
const BACK = path.join(__dirname, '..', 'backend');
const req = (m) => require(require.resolve(m, { paths: [BACK] }));
req('dotenv').config({ path: path.join(BACK, '.env'), quiet: true });
const { leer } = require('./permisos_matriz.cjs');
const { PERMISOS } = require(path.join(BACK, 'dist', 'models', 'permiso'));

let ok = 0;
let falla = 0;
function revisar(condicion, texto, detalle) {
  if (condicion) {
    ok++;
    console.log(`  OK     ${texto}`);
  } else {
    falla++;
    console.log(`  FALLA  ${texto}${detalle ? `\n         ${detalle}` : ''}`);
  }
}

(async () => {
  const { Client } = req('pg');
  const db = new Client({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME,
  });
  await db.connect();
  const { rows } = await db.query(
    `SELECT m.modulo_permiso_nombre || '.' || p.permiso_nombre AS codigo,
            coalesce(array_agg(rp.id_rol_usuario ORDER BY rp.id_rol_usuario)
                     FILTER (WHERE rp.id_rol_usuario IS NOT NULL), '{}') AS roles
       FROM permiso p
       JOIN modulo_permiso m USING (id_modulo_permiso)
       LEFT JOIN rol_permiso rp USING (id_permiso)
      GROUP BY 1`,
  );
  const { rows: roles } = await db.query('SELECT id_rol_usuario FROM rol_usuario ORDER BY 1');
  await db.end();
  const todos = roles.map((r) => Number(r.id_rol_usuario));
  const enBase = new Map(rows.map((r) => [r.codigo, r.roles.map(Number)]));

  const rutas = leer();
  const privadas = rutas.filter((r) => r.guards.includes('SesionGuard'));
  const publicas = rutas.filter((r) => !r.guards.includes('SesionGuard'));
  console.log(`${rutas.length} rutas: ${privadas.length} con sesion, ${publicas.length} publicas. ${enBase.size} permisos en la base.\n`);

  console.log('1. Cada ruta privada pasa por PermisoGuard y declara un permiso que existe');
  const sinGuard = privadas.filter((r) => r.guards[r.guards.indexOf('SesionGuard') + 1] !== 'PermisoGuard');
  revisar(sinGuard.length === 0, `las ${privadas.length} llevan PermisoGuard justo despues de SesionGuard`,
    sinGuard.map((r) => `${r.metodo} ${r.ruta} [${r.guards}]`).join('\n         '));
  const sinPermiso = privadas.filter((r) => r.permiso == null);
  revisar(sinPermiso.length === 0, 'todas declaran @Permiso', sinPermiso.map((r) => `${r.metodo} ${r.ruta}`).join('\n         '));
  const inexistente = privadas.filter((r) => r.permiso != null && !enBase.has(r.permiso));
  revisar(inexistente.length === 0, 'cada permiso declarado existe en la tabla permiso',
    inexistente.map((r) => `${r.metodo} ${r.ruta}: ${r.permiso}`).join('\n         '));
  const conRoles = rutas.filter((r) => r.roles != null);
  revisar(conRoles.length === 0, 'no queda ningun @Roles', conRoles.map((r) => `${r.metodo} ${r.ruta}`).join('\n         '));
  const publicaConPermiso = publicas.filter((r) => r.permiso != null || r.guards.length > 0);
  revisar(publicaConPermiso.length === 0, 'las publicas no tienen guards ni permiso a medias',
    publicaConPermiso.map((r) => `${r.metodo} ${r.ruta}`).join('\n         '));

  console.log('\n2. El catalogo de la base y el del codigo son el mismo');
  const delCodigo = new Set(PERMISOS);
  const faltanEnBase = [...delCodigo].filter((c) => !enBase.has(c));
  const faltanEnCodigo = [...enBase.keys()].filter((c) => !delCodigo.has(c));
  revisar(faltanEnBase.length === 0, `los ${delCodigo.size} de models/permiso.ts estan en la base`, faltanEnBase.join(', '));
  revisar(faltanEnCodigo.length === 0, `los ${enBase.size} de la base estan en models/permiso.ts`, faltanEnCodigo.join(', '));
  const usados = new Set(privadas.map((r) => r.permiso));
  const sinRuta = [...enBase.keys()].filter((c) => !usados.has(c));
  revisar(sinRuta.length === 0, 'ningun permiso de la base se queda sin ruta', sinRuta.join(', '));

  if (!process.argv.includes('--sin-semilla')) {
    console.log('\n3. La semilla deja pasar exactamente a los mismos roles que antes, ruta por ruta');
    const antes = JSON.parse(fs.readFileSync(path.join(__dirname, 'permisos_matriz_antes_050.json'), 'utf8'));
    const clave = (r) => `${r.metodo} ${r.ruta}`;
    const ahora = new Map(rutas.map((r) => [clave(r), r]));
    const distintas = [];
    let comparadas = 0;
    for (const a of antes) {
      const h = ahora.get(clave(a));
      if (h == null) {
        distintas.push(`${clave(a)}: ya no existe`);
        continue;
      }
      comparadas++;
      const privadaAntes = a.guards.includes('SesionGuard');
      const privadaAhora = h.guards.includes('SesionGuard');
      if (privadaAntes !== privadaAhora) {
        distintas.push(`${clave(a)}: era ${privadaAntes ? 'privada' : 'publica'} y ahora no`);
        continue;
      }
      if (!privadaAntes) continue;
      const rolesAntes = (a.roles ?? todos).map(Number).sort().join(',');
      const rolesAhora = (enBase.get(h.permiso) ?? []).slice().sort().join(',');
      if (rolesAntes !== rolesAhora) distintas.push(`${clave(a)}: antes ${rolesAntes}, ahora ${rolesAhora} (${h.permiso})`);
      if (a.permiso_oferta !== h.permiso_oferta) distintas.push(`${clave(a)}: permiso de oferta ${a.permiso_oferta} -> ${h.permiso_oferta}`);
    }
    revisar(distintas.length === 0, `las ${comparadas} rutas de antes dejan pasar a los mismos roles`,
      distintas.join('\n         ') + '\n         (si un admin ya cambio rol_permiso a proposito, corre con --sin-semilla)');
    const nuevas = rutas.filter((r) => !antes.some((a) => clave(a) === clave(r)));
    revisar(nuevas.every((r) => r.ruta.startsWith('/admin/permisos') && r.guards.includes('PermisoGuard')),
      `las ${nuevas.length} rutas nuevas son las de /admin/permisos y van protegidas`,
      nuevas.map((r) => `${clave(r)} [${r.guards}]`).join('\n         '));
  }

  console.log('\n4. Lo compartido pasa primero por el rol y despues por la oferta');
  const compartidas = rutas.filter((r) => r.ruta.startsWith('/compartidas/'));
  revisar(compartidas.length > 0 && compartidas.every((r) => r.guards.join(',') === 'SesionGuard,PermisoGuard,PermisoOfertaGuard'),
    `las ${compartidas.length} de /compartidas: SesionGuard, PermisoGuard, PermisoOfertaGuard`,
    compartidas.map((r) => `${clave(r)} [${r.guards}]`).join('\n         '));
  revisar(compartidas.every((r) => r.permiso === 'ofertas.usar_compartidas'),
    'todas piden ofertas.usar_compartidas');

  console.log(`\n${ok} OK, ${falla} FALLA`);
  process.exit(falla === 0 ? 0 : 1);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});

function clave(r) {
  return `${r.metodo} ${r.ruta}`;
}
