// pruebas/caidas.mjs -- apaga cada base, una por una, y comprueba que la tienda
// siga respondiendo con las que quedan, como pidio el profesor. Despues la
// prende y comprueba que todo vuelve solo, sin reiniciar nada.
//
//   .\remoto\caidas.ps1 -Accion levantar      (una vez: el backend por el interruptor)
//   node pruebas/caidas.mjs                   las seis, apagadas
//   node pruebas/caidas.mjs --congeladas      las seis, congeladas (la red cortada)
//   node pruebas/caidas.mjs redis mongo       solo esas
//
// Necesita remoto/interruptor.cjs arriba y el backend arrancado a traves de el
// (remoto/caidas.ps1 lo hace). Sin eso dice SIN MEDIR y sale con 0: apagar
// una base de verdad no es cosa de una prueba. Sirve igual con las bases en
// otra PC (modo remoto) que con el Docker de aqui.
//
// Lo que espera de cada base es lo de docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md. Solo
// lee: inicia sesion con dos cuentas de prueba y pide cosas; no compra (la
// compra que se intenta con PostgreSQL caido no puede escribir nada) ni manda
// `sesion` al buscador, asi que no deja eventos en ClickHouse.
//
// Tarda unos 3 minutos: despues de prender cada base espera la pausa de 15 s
// de su cortacircuitos.
const API = process.env.API || 'http://localhost:3000';
const CONTROL = process.env.INTERRUPTOR || 'http://127.0.0.1:5198';
const MODO = process.argv.includes('--congeladas') ? 'congelada' : 'apagada';
const PEDIDAS = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const PRODUCTO = 66; // Guantes de portero Zarpa 300: con ventas, vistas y ofertas
const PAUSA_MS = 16_000; // la pausa del cortacircuitos, y un segundo de margen

let oks = 0;
let fallas = 0;
const ok = (texto) => { oks++; console.log(`  OK     ${texto}`); };
const falla = (texto) => { fallas++; console.log(`  FALLA  ${texto}`); };
const revisar = (cond, texto, detalle = '') => (cond ? ok(texto) : falla(detalle ? `${texto}  (${detalle})` : texto));
const esperar = (ms) => new Promise((r) => setTimeout(r, ms));

async function pedir(ruta, { galleta, metodo = 'GET', cuerpo } = {}) {
  const ini = Date.now();
  try {
    const r = await fetch(API + ruta, {
      method: metodo,
      headers: { 'Content-Type': 'application/json', ...(galleta ? { Cookie: galleta } : {}) },
      body: cuerpo ? JSON.stringify(cuerpo) : undefined,
      signal: AbortSignal.timeout(60_000),
    });
    let j = null;
    try { j = await r.json(); } catch { /* sin cuerpo JSON */ }
    return { codigo: r.status, ms: Date.now() - ini, j, p: j?.payload, galleta: (r.headers.get('set-cookie') || '').split(';')[0] };
  } catch (e) {
    return { codigo: 0, ms: Date.now() - ini, j: null, p: null, error: String(e?.name || e) };
  }
}

const largo = (p) => (Array.isArray(p) ? p.length : Array.isArray(p?.resultados) ? p.resultados.length : -1);
const resumen = (r) => `${r.codigo}, ${r.ms} ms${r.j && !r.j.ok ? `, "${r.j.mensaje}"` : ''}`;

async function interruptor(base, estado) {
  const r = await fetch(`${CONTROL}/${base}/${estado}`, { method: 'POST', signal: AbortSignal.timeout(10_000) });
  if (!r.ok) throw new Error(`el interruptor no cambio ${base} a ${estado}`);
}

async function entrar(identificador, contrasena) {
  const r = await pedir('/usuario/login', { metodo: 'POST', cuerpo: { identificador, contrasena } });
  return r.codigo === 200 ? r.galleta : null;
}

// ------------------------------------------------------------- lo esperado
// Cada base: lo que tiene que seguir saliendo, lo que tiene que avisar (503) y
// como se ve que volvio.
const CASOS = {
  mongo: {
    nombre: 'MongoDB',
    async caida(g) {
      const ficha = await pedir(`/productos/${PRODUCTO}`);
      revisar(ficha.codigo === 200 && ficha.p?.desde_respaldo === true, 'la ficha sale de la copia en PostgreSQL', resumen(ficha));
      const pagina = await pedir('/productos/paginacion?pagina=1&limite=12');
      revisar(pagina.codigo === 200 && pagina.p?.productos?.length > 0, 'el catalogo sale con productos', resumen(pagina));
      const cats = await pedir('/categorias');
      revisar(cats.codigo === 200 && largo(cats.p) > 0, 'las categorias salen', resumen(cats));
      const ram = await pedir('/productos/paginacion?pagina=1&limite=20&ram=16');
      revisar(ram.codigo === 503, 'filtrar por caracteristica avisa (503): solo vive en Mongo', resumen(ram));
      const paraTi = await pedir('/productos/para-ti', { galleta: g.comprador });
      revisar(paraTi.codigo === 200 && largo(paraTi.p) > 0, 'para ti sale con productos', resumen(paraTi));
      const busca = await pedir('/buscador/productos/facetado?nombre=laptop');
      revisar(busca.codigo === 200 && busca.p?.total > 0, 'el buscador sigue', resumen(busca));
      const carrito = await pedir('/carrito', { galleta: g.comprador });
      revisar(carrito.codigo === 200, 'el carrito sigue', resumen(carrito));
    },
    async volvio() {
      const ficha = await pedir(`/productos/${PRODUCTO}`);
      return ficha.codigo === 200 && !ficha.p?.desde_respaldo;
    },
  },
  redis: {
    nombre: 'Redis',
    async caida(g) {
      for (const [ruta, que] of [
        ['/productos/mas-vendidos', 'lo mas vendido'],
        ['/productos/mas-vistos', 'lo mas visto'],
        ['/productos/combos', 'se compran juntos'],
        ['/productos/ofertas/descuento', 'las ofertas con descuento'],
      ]) {
        const r = await pedir(ruta);
        revisar(r.codigo === 200 && largo(r.p) > 0, `${que} sale igual (ClickHouse o PostgreSQL en el momento)`, resumen(r));
      }
      const vieron = await pedir(`/productos/${PRODUCTO}/tambien-vieron`);
      revisar(vieron.codigo === 200, 'tambien vieron contesta', resumen(vieron));
      const carrito = await pedir('/carrito', { galleta: g.comprador });
      revisar(carrito.codigo === 200 && carrito.p?.fuente === 'postgres', 'el carrito sale de PostgreSQL', resumen(carrito));
      const ficha = await pedir(`/productos/${PRODUCTO}`);
      revisar(ficha.codigo === 200 && largo(ficha.p?.ofertas) > 0, 'la ficha con sus ofertas sigue', resumen(ficha));
    },
    async volvio(g) {
      const carrito = await pedir('/carrito', { galleta: g.comprador });
      return carrito.codigo === 200 && carrito.p?.fuente !== 'postgres';
    },
  },
  elastic: {
    nombre: 'Elasticsearch',
    async caida() {
      const facetas = await pedir('/buscador/productos/facetado?nombre=laptop');
      revisar(facetas.codigo === 200 && facetas.p?.total > 0 && facetas.p?.facetas?.categoria?.length > 0,
        'el buscador con filtros sale de la copia del catalogo, con sus facetas', resumen(facetas));
      const conCat = await pedir('/buscador/productos/facetado?nombre=laptop&categoria=7');
      revisar(conCat.codigo === 200 && conCat.p?.facetas?.categoria?.length === 1, 'el filtro de categoria va en la busqueda', resumen(conCat));
      const typo = await pedir('/buscador/productos?nombre=labtop');
      revisar(typo.codigo === 200 && largo(typo.p) > 0, '"labtop" encuentra laptops sin Elasticsearch', resumen(typo));
      const locura = await pedir('/buscador/productos/facetado?nombre=asdffff');
      revisar(locura.codigo === 200 && locura.p?.total === 0 && locura.p?.sugeridos?.length > 0,
        '"asdffff" no encuentra nada pero trae sugeridos', resumen(locura));
      // Con Elasticsearch arriba los elige el; sin el, el backend por fuera.
      revisar(locura.p?.sugeridos_desde != null && locura.p.sugeridos_desde !== 'elasticsearch',
        `y sin Elasticsearch salen de otra fuente (${locura.p?.sugeridos_desde})`, resumen(locura));
      const hibrida = await pedir('/buscador/productos/hibrida?q=laptop');
      revisar(hibrida.codigo === 200 && largo(hibrida.p) > 0, 'la busqueda hibrida sigue', resumen(hibrida));
      const sugerencias = await pedir('/buscador/productos/sugerencias?prefijo=lap');
      revisar(sugerencias.codigo === 200 && largo(sugerencias.p) > 0, 'las sugerencias al escribir siguen', resumen(sugerencias));
    },
    async volvio() {
      const r = await pedir('/buscador/productos?nombre=labtop');
      return r.codigo === 200 && r.p?.quisiste_decir != null; // solo Elasticsearch corrige
    },
  },
  neo4j: {
    nombre: 'Neo4j',
    async caida(g) {
      const paraTi = await pedir('/productos/para-ti', { galleta: g.comprador });
      revisar(paraTi.codigo === 200 && largo(paraTi.p) > 0, 'para ti sale de los pedidos en PostgreSQL', resumen(paraTi));
      const compraron = await pedir(`/productos/${PRODUCTO}/tambien-compraron`);
      revisar(compraron.codigo === 200 && largo(compraron.p) > 0, 'quienes lo compraron tambien llevaron sigue', resumen(compraron));
      const conciliacion = await pedir('/admin/grafo/conciliacion', { galleta: g.admin });
      revisar(conciliacion.codigo === 503, 'la conciliacion del grafo (admin) avisa (503): compara contra Neo4j', resumen(conciliacion));
    },
    async volvio(g) {
      const r = await pedir('/admin/grafo/conciliacion', { galleta: g.admin });
      return r.codigo === 200;
    },
  },
  clickhouse: {
    nombre: 'ClickHouse',
    async caida(g) {
      const vistos = await pedir('/productos/vistos-recientemente', { galleta: g.comprador });
      revisar(vistos.codigo === 503, 'viste hace poco avisa (503): las vistas solo viven en ClickHouse', resumen(vistos));
      const tendencias = await pedir('/admin/eventos/vista', { galleta: g.admin });
      revisar(tendencias.codigo === 503, 'las tendencias del admin avisan (503)', resumen(tendencias));
      const masVendidos = await pedir('/productos/mas-vendidos');
      revisar(masVendidos.codigo === 200 && largo(masVendidos.p) > 0, 'lo mas vendido sigue (guardado en Redis)', resumen(masVendidos));
      const pagina = await pedir('/productos/paginacion?pagina=1&limite=12');
      revisar(pagina.codigo === 200, 'el catalogo sigue', resumen(pagina));
    },
    async volvio(g) {
      const r = await pedir('/admin/eventos/vista', { galleta: g.admin });
      return r.codigo === 200;
    },
  },
  postgres: {
    nombre: 'PostgreSQL',
    async caida(g) {
      const yo = await pedir('/usuario/yo', { galleta: g.comprador });
      revisar(yo.codigo === 200 && yo.p?.correo_electronico, 'la sesion abierta sigue (perfil copiado en Redis)', resumen(yo));
      const carrito = await pedir('/carrito', { galleta: g.comprador });
      revisar(carrito.codigo === 200, 'el carrito se ve (copia en Redis)', resumen(carrito));
      const ficha = await pedir(`/productos/${PRODUCTO}`);
      revisar(ficha.codigo === 200 && ficha.p?.ofertas_no_disponibles === true,
        'la ficha se ve sin vendedores y avisa que no se puede comprar', resumen(ficha));
      const pagina = await pedir('/productos/paginacion?pagina=1&limite=12');
      revisar(pagina.codigo === 200 && pagina.p?.productos?.length > 0, 'el catalogo sigue (MongoDB)', resumen(pagina));
      const comprar = await pedir('/carrito/comprar', { galleta: g.comprador, metodo: 'POST', cuerpo: { id_direccion: 1, metodo_pago: 'tarjeta' } });
      revisar(comprar.codigo === 503, 'pagar no se puede (503) y no escribe nada', resumen(comprar));
      const entrar = await pedir('/usuario/login', { metodo: 'POST', cuerpo: { identificador: 'admin@mesh.com', contrasena: 'Admin123' } });
      revisar(entrar.codigo === 503, 'iniciar sesion nueva no se puede (503)', resumen(entrar));
    },
    async volvio(g) {
      const r = await pedir(`/productos/${PRODUCTO}`);
      return r.codigo === 200 && !r.p?.ofertas_no_disponibles && g != null;
    },
  },
};

// ------------------------------------------------------------- la corrida
const estado = await fetch(`${CONTROL}/estado`, { signal: AbortSignal.timeout(3000) }).then((r) => r.json()).catch(() => null);
// GET /db/cortacircuitos es solo del admin: dice que base ve caida y por que.
const admin = estado == null ? null : await entrar('admin@mesh.com', 'Admin123');
const cortacircuitos = await pedir('/db/cortacircuitos', { galleta: admin });
if (estado == null || cortacircuitos.codigo !== 200) {
  console.log('SIN MEDIR: hace falta el interruptor y el backend arrancado por el (.\\remoto\\caidas.ps1 -Accion levantar).');
  process.exit(0);
}
if (Object.values(estado.bases).some((e) => e !== 'arriba')) {
  console.log(`Hay bases que no estan arriba en el interruptor: ${JSON.stringify(estado.bases)}. Prendelas antes.`);
  process.exit(1);
}

const orden = PEDIDAS.length > 0 ? PEDIDAS : ['mongo', 'redis', 'elastic', 'neo4j', 'clickhouse', 'postgres'];
console.log(`Caidas ${MODO === 'congelada' ? 'CONGELADAS (la red cortada)' : 'APAGADAS (docker stop)'} contra ${estado.destino}: ${orden.join(', ')}`);

for (const clave of orden) {
  const caso = CASOS[clave];
  if (!caso) { falla(`no conozco la base ${clave}`); continue; }
  console.log(`\n=== ${caso.nombre} ${MODO} ===`);
  // Las sesiones se abren con todo arriba: es la persona que ya estaba dentro.
  const g = { comprador: await entrar('compradora.norte@mesh.com', 'Comprador123'), admin: await entrar('admin@mesh.com', 'Admin123') };
  if (!g.comprador || !g.admin) { falla('no se pudo iniciar sesion con todo arriba'); continue; }
  await interruptor(clave, MODO);
  try {
    await caso.caida(g);
    const cc = await pedir('/db/cortacircuitos', { galleta: g.admin });
    const visto = cc.p?.find((c) => c.base === caso.nombre);
    revisar(visto?.responde === false, `el backend la da por caida (GET /db/cortacircuitos)`);
  } finally {
    await interruptor(clave, 'arriba');
  }
  // Vuelve sola: se espera la pausa del cortacircuitos y se mira el camino normal.
  await esperar(PAUSA_MS);
  let volvio = false;
  for (let i = 0; i < 6 && !volvio; i++) {
    volvio = await caso.volvio(g);
    if (!volvio) await esperar(5000);
  }
  revisar(volvio, `al prenderla, la tienda vuelve a ${caso.nombre} sola, sin reiniciar nada`);
}

const final = await pedir('/db/cortacircuitos', { galleta: admin });
revisar(final.p?.every((c) => c.responde), 'al final el backend ve las seis bases arriba', JSON.stringify(final.p?.filter((c) => !c.responde)));
console.log(`\n${oks} OK, ${fallas} FALLA`);
process.exit(fallas > 0 ? 1 : 0);
