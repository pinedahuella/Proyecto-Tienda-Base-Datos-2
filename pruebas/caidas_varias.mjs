// pruebas/caidas_varias.mjs -- que hace la tienda con SOLO 1, 2 o 3 bases prendidas, varias caidas a
// la vez. pruebas/caidas.mjs apaga una base por vez; esta apaga todas menos las del escenario.
//
//   .\remoto\caidas.ps1 -Accion levantar           (una vez: el backend por el interruptor)
//   node pruebas/caidas_varias.mjs                  los seis escenarios, apagadas
//   node pruebas/caidas_varias.mjs --congeladas     lo mismo con la red cortada
//
// Por cada paso dice SI (contesta con datos), AVISA (503 a proposito: esa parte no tiene otra fuente),
// VACIO o ERROR. Es una tabla para leer, no un examen: lo que se espera de cada base esta en
// docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md. Si sale ERROR o NO CONTESTA, eso si es un fallo.
// Compra de verdad una unidad por escenario con compradora.norte y al final cancela esos pedidos por la
// API, como lo haria ella (el stock vuelve). Las devoluciones de esas cancelaciones quedan en ClickHouse:
// el final dice los id_pedido, para borrarlas si se corre en la base de la presentacion.
const API = process.env.API || 'http://localhost:3000';
const CONTROL = process.env.INTERRUPTOR || 'http://127.0.0.1:5198';
const MODO = process.argv.includes('--congeladas') ? 'congelada' : 'apagada';
const PRODUCTO = 66; // Guantes de portero Zarpa 300: con ventas, vistas, ofertas y parecidos
const TODAS = ['postgres', 'mongo', 'redis', 'elastic', 'neo4j', 'clickhouse'];
const NOMBRE = { postgres: 'PostgreSQL', mongo: 'MongoDB', redis: 'Redis', elastic: 'Elasticsearch', neo4j: 'Neo4j', clickhouse: 'ClickHouse' };
const ESCENARIOS = [
  { titulo: 'Solo PostgreSQL (1 base)', prendidas: ['postgres'] },
  { titulo: 'PostgreSQL y Redis (2 bases)', prendidas: ['postgres', 'redis'] },
  { titulo: 'PostgreSQL y MongoDB (2 bases)', prendidas: ['postgres', 'mongo'] },
  { titulo: 'PostgreSQL, MongoDB y Redis (3 bases)', prendidas: ['postgres', 'mongo', 'redis'] },
  { titulo: 'PostgreSQL, MongoDB y Elasticsearch (3 bases)', prendidas: ['postgres', 'mongo', 'elastic'] },
  { titulo: 'Todas menos PostgreSQL (5 bases)', prendidas: ['mongo', 'redis', 'elastic', 'neo4j', 'clickhouse'] },
];
const esperar = (ms) => new Promise((r) => setTimeout(r, ms));

async function pedir(ruta, { galleta, metodo = 'GET', cuerpo } = {}) {
  const ini = Date.now();
  try {
    const r = await fetch(API + ruta, {
      method: metodo,
      headers: { 'Content-Type': 'application/json', ...(galleta ? { Cookie: galleta } : {}) },
      body: cuerpo ? JSON.stringify(cuerpo) : undefined,
      signal: AbortSignal.timeout(30_000),
    });
    let j = null;
    try { j = await r.json(); } catch { /* sin cuerpo */ }
    return { codigo: r.status, ms: Date.now() - ini, j, p: j?.payload, galleta: (r.headers.get('set-cookie') || '').split(';')[0] };
  } catch (e) {
    return { codigo: 0, ms: Date.now() - ini, j: null, p: null, error: String(e?.name || e) };
  }
}
const largo = (p) => (Array.isArray(p) ? p.length : Array.isArray(p?.resultados) ? p.resultados.length
  : Array.isArray(p?.productos) ? p.productos.length : Array.isArray(p?.lineas) ? p.lineas.length : p && typeof p === 'object' ? 1 : 0);
async function interruptor(base, estado) {
  const r = await fetch(`${CONTROL}/${base}/${estado}`, { method: 'POST', signal: AbortSignal.timeout(10_000) });
  if (!r.ok) throw new Error(`el interruptor no cambio ${base} a ${estado}`);
}
async function entrar(identificador, contrasena) {
  const r = await pedir('/usuario/login', { metodo: 'POST', cuerpo: { identificador, contrasena } });
  return r.codigo === 200 ? r.galleta : null;
}

// Lo que hace una persona en la tienda, en el orden en que lo haria
const PASOS = [
  ['Catalogo de la portada', () => pedir('/productos/paginacion?pagina=1&limite=12')],
  ['Categorias', () => pedir('/categorias')],
  ['Ficha de un producto', () => pedir(`/productos/${PRODUCTO}`)],
  ['Buscar laptop con filtros', () => pedir('/buscador/productos/facetado?nombre=laptop')],
  ['Buscar labtop mal escrito', () => pedir('/buscador/productos?nombre=labtop')],
  ['Lo mas vendido', () => pedir('/productos/mas-vendidos')],
  ['Lo mas visto', () => pedir('/productos/mas-vistos')],
  ['Ofertas con descuento', () => pedir('/productos/ofertas/descuento')],
  ['Se compran juntos', () => pedir('/productos/combos')],
  ['Parecidos a este (vectores)', () => pedir(`/productos/${PRODUCTO}/similares`)],
  ['Tambien llevaron', () => pedir(`/productos/${PRODUCTO}/tambien-compraron`)],
  ['Para ti (con sesion)', (g) => pedir('/productos/para-ti', { galleta: g.comprador })],
  ['Iniciar sesion de nuevo', async () => {
    const r = await pedir('/usuario/login', { metodo: 'POST', cuerpo: { identificador: 'compradora.norte@mesh.com', contrasena: 'Comprador123' } });
    return { ...r, p: r.codigo === 200 ? { ok: 1 } : null };
  }],
  ['Mi perfil (sesion abierta)', (g) => pedir('/usuario/yo', { galleta: g.comprador })],
  ['Ver el carrito', (g) => pedir('/carrito', { galleta: g.comprador })],
  ['Panel admin, reportes', (g) => pedir('/admin/reportes/ventas', { galleta: g.admin })],
  ['Panel admin, tendencias', (g) => pedir('/admin/eventos/vista', { galleta: g.admin })],
];

function marca(r) {
  if (r.codigo === 200 || r.codigo === 201) return largo(r.p) > 0 ? 'SI' : 'VACIO';
  if (r.codigo === 503) return 'AVISA';
  if (r.codigo === 0) return 'NO CONTESTA';
  return `ERROR ${r.codigo}`;
}

const pedidos = [];
async function comprar(g, oferta, direccion) {
  await pedir('/carrito', { galleta: g.comprador, metodo: 'DELETE' });
  await pedir(`/carrito/lineas/${oferta}`, { galleta: g.comprador, metodo: 'PUT', cuerpo: { cantidad: 1 } });
  const r = await pedir('/carrito/comprar', { galleta: g.comprador, metodo: 'POST', cuerpo: { id_direccion: String(direccion), metodo_pago: 'transferencia' } });
  const id = r.p?.id_pedido ?? r.p?.pedido?.id_pedido;
  if (id) pedidos.push(id);
  return { r, id };
}

// ---------------------------------------------------------------------------
const estado = await fetch(`${CONTROL}/estado`, { signal: AbortSignal.timeout(5000) }).then((r) => r.json()).catch(() => null);
if (!estado) { console.log('SIN MEDIR: el interruptor no esta arriba (.\\remoto\\caidas.ps1 -Accion levantar)'); process.exit(0); }
console.log(`Varias bases caidas a la vez, ${MODO}s, contra ${estado.destino}\n`);

const g0 = { comprador: await entrar('compradora.norte@mesh.com', 'Comprador123'), admin: await entrar('admin@mesh.com', 'Admin123') };
const dirs = await pedir('/direccion-usuario', { galleta: g0.comprador });
const direccion = (Array.isArray(dirs.p) ? dirs.p : dirs.p?.direcciones ?? [])[0]?.id_direccion;
const ficha = await pedir(`/productos/${PRODUCTO}`);
const oferta = (ficha.p?.ofertas ?? []).find((o) => Number(o.stock ?? o.stock_disponible ?? 0) > 3)?.id_oferta;
if (!direccion || !oferta) { console.log('No pude preparar la compra', { direccion, oferta }); process.exit(1); }

let errores = 0;
for (const esc of ESCENARIOS) {
  const apagar = TODAS.filter((b) => !esc.prendidas.includes(b));
  console.log(`=== ${esc.titulo}: prendidas ${esc.prendidas.map((b) => NOMBRE[b]).join(', ')}`);
  const g = { comprador: await entrar('compradora.norte@mesh.com', 'Comprador123'), admin: await entrar('admin@mesh.com', 'Admin123') };
  for (const b of apagar) await interruptor(b, MODO);
  await esperar(1500);
  try {
    for (const [nombre, f] of PASOS) {
      const r = await f(g);
      const m = marca(r);
      if (m.startsWith('ERROR') || m === 'NO CONTESTA') errores++;
      console.log(`  ${nombre.padEnd(32)} ${m.padEnd(12)} ${r.codigo} ${r.ms} ms${r.j && r.j.ok === false ? '  ' + String(r.j.mensaje).slice(0, 80) : ''}`);
    }
    const c = await comprar(g, oferta, direccion);
    const m = c.id ? 'SI' : c.r.codigo === 503 ? 'AVISA' : `NO (${c.r.codigo})`;
    if (m.startsWith('NO')) errores++;
    console.log(`  ${'Comprar 1 unidad'.padEnd(32)} ${m.padEnd(12)} ${c.r.codigo} ${c.r.ms} ms ${c.id ? 'pedido ' + c.id : String(c.r.j?.mensaje ?? c.r.error ?? '').slice(0, 90)}`);
  } finally {
    for (const b of apagar) await interruptor(b, 'arriba');
  }
  await esperar(17_000);
  // Un cortacircuitos se cierra con la siguiente consulta que llega a su base: se le pide algo a cada una
  const tocarTodas = () => Promise.all([
    pedir(`/productos/${PRODUCTO}`), pedir('/carrito', { galleta: g.comprador }), pedir('/buscador/productos?nombre=labtop'),
    pedir('/admin/grafo/conciliacion', { galleta: g0.admin }), pedir('/admin/eventos/vista', { galleta: g0.admin }),
  ]);
  let todas = false;
  for (let i = 0; i < 8 && !todas; i++) {
    await tocarTodas();
    const cc = await pedir('/db/cortacircuitos', { galleta: g0.admin });
    todas = Array.isArray(cc.p) && cc.p.every((x) => x.responde);
    if (!todas) await esperar(5000);
  }
  if (!todas) errores++;
  console.log(`  al prenderlas, el backend vuelve a las seis solo, sin reiniciar nada: ${todas ? 'si' : 'NO'}\n`);
}

// Limpieza: los pedidos de la prueba se cancelan por la API, como lo haria la compradora
const g = { comprador: await entrar('compradora.norte@mesh.com', 'Comprador123') };
for (const id of pedidos) {
  const r = await pedir(`/comprador/pedidos/${id}/cancelar`, { galleta: g.comprador, metodo: 'POST', cuerpo: {} });
  if (r.codigo !== 200 && r.codigo !== 201) errores++;
  console.log(`pedido ${id} cancelado: ${r.codigo}${r.j?.ok === false ? ' ' + r.j.mensaje : ''}`);
}
await pedir('/carrito', { galleta: g.comprador, metodo: 'DELETE' });
console.log(`\npedidos de la prueba, ya cancelados: ${pedidos.join(', ')}`);
console.log(errores === 0 ? 'Todo bien: ningun paso dio error ni se quedo sin contestar.' : `${errores} FALLA`);
process.exit(errores === 0 ? 0 : 1);
