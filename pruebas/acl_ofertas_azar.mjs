// pruebas/acl_ofertas_azar.mjs -- el ACL de ofertas contra un modelo, al azar.
//
//   node pruebas/acl_ofertas_azar.mjs
//   VUELTAS=1000 SEMILLA=7 node pruebas/acl_ofertas_azar.mjs
//
// pruebas/acl_ofertas.sh prueba cada regla una vez, en orden. Esta las mezcla:
// en cada vuelta la duena (ventas.norte) da o quita permisos al azar a
// ventas.sur, ventas.oriente o al admin, y alguna de esas cuentas intenta
// algo al azar sobre la oferta (verla, editarla, ponerle descuento, buscarla
// en su lista). Un modelo en memoria dice que deberia contestar el backend
// (negar por defecto, ver con cualquier entrada, editar y descuento con la
// suya) y cada respuesta se compara con el. Despues de cada vuelta, las
// entradas que ve la duena tienen que ser las del modelo.
//
// Todo por HTTP, nada directo a la base. La oferta se elige de las de
// ventas.norte por su propia ruta, y al final queda como estaba: sin permisos,
// con su precio y sin descuento. La semilla hace la corrida repetible.

const API = process.env.API ?? 'http://127.0.0.1:3000';
const VUELTAS = Number(process.env.VUELTAS ?? 400);
let semilla = Number(process.env.SEMILLA ?? Date.now() % 100000);
const SEMILLA_INICIAL = semilla;

// mulberry32: el mismo azar para la misma semilla.
function azar() {
  semilla |= 0;
  semilla = (semilla + 0x6d2b79f5) | 0;
  let t = Math.imul(semilla ^ (semilla >>> 15), 1 | semilla);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const uno = (xs) => xs[Math.floor(azar() * xs.length)];

const PERMISOS = ['ver', 'editar', 'descuento'];

async function entrar(correo, clave) {
  const r = await fetch(`${API}/usuario/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identificador: correo, contrasena: clave }),
  });
  const galleta = (r.headers.get('set-cookie') ?? '').split(';')[0];
  if (!galleta) throw new Error(`no se pudo entrar como ${correo}`);
  return galleta;
}

async function pedir(metodo, ruta, galleta, cuerpo) {
  // Content-Type solo con cuerpo: Fastify contesta 400 a un DELETE que dice
  // traer JSON y no trae nada (igual hace el frontend, ver lib/compartidas.ts).
  const headers = { Cookie: galleta };
  if (cuerpo !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(`${API}${ruta}`, {
    method: metodo,
    headers,
    body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
  });
  let datos = null;
  try {
    datos = await r.json();
  } catch {
    // sin cuerpo
  }
  return { codigo: r.status, datos };
}

let ok = 0;
let mal = 0;
const malos = [];
function revisar(condicion, que) {
  if (condicion) {
    ok++;
  } else {
    mal++;
    if (malos.length < 15) malos.push(que);
  }
}

const norte = await entrar('ventas.norte@mesh.com', 'Vendedor123');
const cuentas = {
  'ventas.sur@mesh.com': await entrar('ventas.sur@mesh.com', 'Vendedor123'),
  'ventas.oriente@mesh.com': await entrar('ventas.oriente@mesh.com', 'Vendedor123'),
  'admin@mesh.com': await entrar('admin@mesh.com', 'Admin123'),
};
const correos = Object.keys(cuentas);

// La oferta: de ventas.norte, activa, sin descuento, sin venta relampago y sin
// nadie mas con permisos.
const propias = await pedir('GET', '/vendedor/ofertas', norte);
// Sin reglas de descuento: con una regla activa el descuento a mano da 409
// (otro mecanismo), y eso es correcto.
const conRegla = new Set();
for (const ruta of ['/vendedor/reglas-descuento', '/vendedor/reglas-descuento-periodos']) {
  const r = await pedir('GET', ruta, norte);
  const lista = Array.isArray(r.datos?.payload) ? r.datos.payload : (r.datos?.payload?.reglas ?? []);
  for (const x of lista) conRegla.add(String(x.id_oferta));
}
let oferta = null;
for (const o of propias.datos?.payload ?? []) {
  if (o.estado !== 'activa' || o.es_inventario_limitado) continue;
  if (conRegla.has(String(o.id_oferta))) continue;
  if (o.porcentaje_descuento != null && Number(o.porcentaje_descuento) > 0) continue;
  const p = await pedir('GET', `/vendedor/ofertas/${o.id_oferta}/permisos`, norte);
  if ((p.datos?.payload?.permisos ?? []).length === 0) {
    oferta = o;
    break;
  }
}
if (!oferta) {
  console.log('No hay una oferta de ventas.norte para probar.');
  process.exit(1);
}
const OF = oferta.id_oferta;
const PRECIO = String(oferta.precio);
console.log(`Oferta ${OF} de ventas.norte, Q${PRECIO}. ${VUELTAS} vueltas, semilla ${SEMILLA_INICIAL}.`);

// El modelo: que permisos tiene cada cuenta sobre la oferta.
const modelo = Object.fromEntries(correos.map((c) => [c, new Set()]));
const cuenta = { otorgar: 0, revocar: 0, ver: 0, editar: 0, descuento: 0, lista: 0, negados: 0 };

async function entradasReales() {
  const r = await pedir('GET', `/vendedor/ofertas/${OF}/permisos`, norte);
  const real = Object.fromEntries(correos.map((c) => [c, new Set()]));
  for (const e of r.datos?.payload?.permisos ?? []) {
    if (e.vigente) real[e.receptor.correo]?.add(e.permiso);
  }
  return { real, entradas: r.datos?.payload?.permisos ?? [] };
}

for (let v = 1; v <= VUELTAS; v++) {
  const correo = uno(correos);
  const galleta = cuentas[correo];
  const tiene = modelo[correo];
  const tirada = azar();

  if (tirada < 0.3) {
    // La duena da un subconjunto al azar (no vacio).
    const dar = PERMISOS.filter(() => azar() < 0.5);
    if (dar.length === 0) dar.push(uno(PERMISOS));
    const r = await pedir('POST', `/vendedor/ofertas/${OF}/permisos`, norte, { correo, permisos: dar });
    revisar(r.codigo === 201, `vuelta ${v}: dar ${dar} a ${correo} dio ${r.codigo}`);
    if (r.codigo === 201) dar.forEach((p) => tiene.add(p));
    cuenta.otorgar++;
  } else if (tirada < 0.45) {
    // La duena quita una entrada al azar de esa cuenta, si tiene.
    const { entradas } = await entradasReales();
    const suyas = entradas.filter((e) => e.receptor.correo === correo);
    if (suyas.length > 0) {
      const e = uno(suyas);
      const r = await pedir('DELETE', `/vendedor/ofertas/${OF}/permisos/${e.id_permiso_oferta}`, norte);
      revisar(r.codigo === 200, `vuelta ${v}: quitar ${e.permiso} a ${correo} dio ${r.codigo}`);
      if (r.codigo === 200) tiene.delete(e.permiso);
      cuenta.revocar++;
    }
  } else {
    // La cuenta intenta algo.
    const accion = uno(['ver', 'editar', 'descuento', 'lista', 'repartir']);
    if (accion === 'ver') {
      const r = await pedir('GET', `/compartidas/ofertas/${OF}`, galleta);
      const debe = tiene.size > 0 ? 200 : 404;
      revisar(r.codigo === debe, `vuelta ${v}: ${correo} ver con [${[...tiene]}] dio ${r.codigo}, debia ${debe}`);
      if (debe === 404) cuenta.negados++;
      cuenta.ver++;
    } else if (accion === 'editar') {
      // El mismo precio: cambia la fila (y el historial) pero no el valor.
      const r = await pedir('PATCH', `/compartidas/ofertas/${OF}`, galleta, { precio: PRECIO });
      const debe = tiene.has('editar') ? 200 : 404;
      revisar(r.codigo === debe, `vuelta ${v}: ${correo} editar con [${[...tiene]}] dio ${r.codigo}, debia ${debe}`);
      if (debe === 404) cuenta.negados++;
      cuenta.editar++;
    } else if (accion === 'descuento') {
      const r = await pedir('POST', `/compartidas/ofertas/${OF}/descuento`, galleta, { porcentaje_descuento: 5 });
      // Un POST que sale bien contesta 201, como todos los de Nest.
      const debe = tiene.has('descuento') ? 201 : 404;
      revisar(r.codigo === debe, `vuelta ${v}: ${correo} descuento con [${[...tiene]}] dio ${r.codigo}, debia ${debe} (${r.datos?.mensaje ?? ''})`);
      if (r.codigo === 201) {
        const q = await pedir('DELETE', `/compartidas/ofertas/${OF}/descuento`, galleta);
        revisar(q.codigo === 200, `vuelta ${v}: ${correo} quitar el descuento dio ${q.codigo}`);
      }
      if (debe === 404) cuenta.negados++;
      cuenta.descuento++;
    } else if (accion === 'lista') {
      const r = await pedir('GET', '/compartidas/ofertas', galleta);
      const esta = (r.datos?.payload ?? []).some((x) => x.id_oferta === String(OF));
      revisar(r.codigo === 200 && esta === tiene.size > 0, `vuelta ${v}: ${correo} lista dice ${esta} con [${[...tiene]}]`);
      cuenta.lista++;
    } else {
      // Repartir: solo la duena (o un admin, que reparte por la tienda y no
      // por ventas.norte). Ninguna de estas cuentas puede, tenga lo que tenga.
      const otro = uno(correos.filter((c) => c !== correo));
      const r = await pedir('POST', `/vendedor/ofertas/${OF}/permisos`, galleta, { correo: otro, permisos: ['ver'] });
      revisar(r.codigo === 404, `vuelta ${v}: ${correo} repartio con [${[...tiene]}] y dio ${r.codigo}`);
    }
  }

  // Despues de cada vuelta, lo que ve la duena es el modelo.
  const { real } = await entradasReales();
  for (const c of correos) {
    const a = [...real[c]].sort().join(',');
    const b = [...modelo[c]].sort().join(',');
    revisar(a === b, `vuelta ${v}: ${c} tiene [${a}] y el modelo dice [${b}]`);
  }
  if (v % 100 === 0) console.log(`  vuelta ${v}: ${ok} bien, ${mal} mal`);
}

// Limpieza por la duena: sin permisos, su precio y sin descuento.
const { entradas } = await entradasReales();
for (const e of entradas) {
  await pedir('DELETE', `/vendedor/ofertas/${OF}/permisos/${e.id_permiso_oferta}`, norte);
}
const fin = (await pedir('GET', '/vendedor/ofertas', norte)).datos?.payload?.find((o) => String(o.id_oferta) === String(OF));
if (fin && fin.porcentaje_descuento != null && Number(fin.porcentaje_descuento) > 0) {
  await pedir('DELETE', `/vendedor/ofertas/${OF}/descuento`, norte);
}
if (fin && String(fin.precio) !== PRECIO) {
  await pedir('PATCH', `/vendedor/ofertas/${OF}`, norte, { precio: PRECIO });
}
const quedan = (await entradasReales()).entradas.length;
revisar(quedan === 0, `al final quedan ${quedan} entradas`);

console.log();
console.log(`Acciones: ${JSON.stringify(cuenta)}`);
for (const m of malos) console.log(`  MAL ${m}`);
console.log(`${ok} OK, ${mal} FALLA (semilla ${SEMILLA_INICIAL})`);
process.exit(mal === 0 ? 0 : 1);
