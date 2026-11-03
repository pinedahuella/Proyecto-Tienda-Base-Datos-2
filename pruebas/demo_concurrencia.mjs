// pruebas/demo_concurrencia.mjs -- la demo de concurrencia, para mostrar en vivo:
// muchos compradores usando la tienda a la vez, y una venta relampago con mas
// gente que unidades que no se sobrevende.
//
//   node pruebas/demo_concurrencia.mjs                   40 compradores, 10 unidades
//   node pruebas/demo_concurrencia.mjs --usuarios 80 --stock 15
//   node pruebas/demo_concurrencia.mjs --caida redis     y con Redis apagado a mitad
//   .\demo-concurrencia.ps1 -Usuarios 80 -Stock 15 -Caida redis   lo mismo desde PowerShell
//
// QUE HACE, TODO POR LA API Y CON CUENTAS DE VERDAD
//   1. Deja listos al vendedor de la demo (vendconcurrencia@mesh.com, solo para
//      esto: etl/extraer_compras.sql no copia sus ventas a ClickHouse) y a los
//      compradores (carga01..cargaNN, los de pruebas/oferta_limitada.sh), y una
//      oferta con STOCK unidades, con descuento y venta relampago abierta.
//   2. Todos navegan a la vez (catalogo, buscar laptop, la ficha) y se miden los
//      tiempos. Nadie espera a nadie: cada comprador es una peticion en el aire.
//   3. Todos piden 1 unidad de la venta relampago en el mismo instante. Tienen
//      que ganar exactamente STOCK. Decide el script atomico de Redis
//      (redis/inventario_limitado.lua), o PostgreSQL con FOR UPDATE si Redis no
//      esta. Sin candados en la aplicacion.
//   4. Los que ganaron pagan todos a la vez. El stock de la oferta en
//      PostgreSQL tiene que quedar en 0, nunca negativo, con un pedido pagado y
//      un movimiento de stock por cada uno.
//   5. Con --caida, la base elegida se apaga antes del paso 2 y se prende al
//      final, con el interruptor (.\remoto\caidas.ps1 -Accion levantar). Se ve
//      que la tienda sigue.
//   6. Limpia. Cancela los pedidos de la demo (el stock vuelve), cierra la
//      venta, quita el descuento, retira la oferta y borra de ClickHouse las
//      compras, devoluciones y agregados al carrito de la demo, para que no
//      muevan lo mas vendido ni las tendencias. Con --sin-limpiar deja los
//      pedidos para mostrarlos en la pagina.
//
// Lee las bases solo para mirar, con el backend/.env (el mismo destino que el
// backend). La primera corrida registra las cuentas desde una sola IP, asi que
// el panel de fraude puede marcar multi cuenta por IP. Es lo esperado.

import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const requerir = createRequire(join(RAIZ, 'backend', 'package.json'));
requerir('dotenv').config({ path: join(RAIZ, 'backend', '.env'), quiet: true });
const { Pool } = requerir('pg');
const { createClient } = requerir('@clickhouse/client');

const opcion = (nombre, porDefecto) => {
  const i = process.argv.indexOf(`--${nombre}`);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : porDefecto;
};
const API = process.env.API ?? 'http://localhost:3000';
const CONTROL = 'http://127.0.0.1:5198';
const N = Number(opcion('usuarios', 40));
const STOCK = Number(opcion('stock', 10));
const CAIDA = opcion('caida', '');
const LIMPIAR = !process.argv.includes('--sin-limpiar');
const PRODUCTO = 83;
const VARIANTE = 166;
const CLAVE = process.env.CLAVE_CARGA ?? 'Desarrollo123!';
const BASES = ['mongo', 'redis', 'elastic', 'neo4j', 'clickhouse'];

if (!(N > STOCK && STOCK > 0)) {
  console.error('Tiene que haber mas compradores que unidades (--usuarios mayor que --stock).');
  process.exit(1);
}
if (CAIDA && !BASES.includes(CAIDA)) {
  console.error(`--caida acepta ${BASES.join(', ')}. Sin PostgreSQL no se compra, a proposito.`);
  process.exit(1);
}

const e = process.env;
const pg = new Pool({ host: e.DB_HOST, port: Number(e.DB_PORT ?? 5432), user: e.DB_USER, password: e.DB_PASSWORD, database: e.DB_NAME, max: 2 });
const sql = async (texto, valores) => (await pg.query(texto, valores)).rows;
// ClickHouse solo se usa para BORRAR lo de la demo, y eso lo puede el dueno de
// la base y no mesh_backend: desde el 2026-10-23 (ADR-14) el backend lee y
// agrega eventos pero no borra, y la limpieza fallaba con "Not enough
// privileges" dejando las compras de la demo en lo mas vendido y en las
// tendencias (2026-11-02). El dueno sale del .env de la PC que tiene las
// bases: el de la raiz si son las de esta PC, remoto/.env.remoto si son las de
// la otra. Si no esta, se intenta con el del backend y se avisa al limpiar.
function duenoClickHouse() {
  const local = ['localhost', '127.0.0.1'].includes(e.CLICKHOUSE_HOST ?? 'localhost');
  const archivo = local ? join(RAIZ, '.env') : join(RAIZ, 'remoto', '.env.remoto');
  if (!existsSync(archivo)) return null;
  const v = requerir('dotenv').parse(readFileSync(archivo));
  return v.CLICKHOUSE_USER && v.CLICKHOUSE_PASSWORD ? { username: v.CLICKHOUSE_USER, password: v.CLICKHOUSE_PASSWORD } : null;
}
const dueno = duenoClickHouse();
const ch = createClient({
  url: `http://${e.CLICKHOUSE_HOST ?? 'localhost'}:${e.CLICKHOUSE_PORT ?? 8123}`,
  username: dueno?.username ?? e.CLICKHOUSE_USER,
  password: dueno?.password ?? e.CLICKHOUSE_PASSWORD,
  database: e.CLICKHOUSE_DB,
});

const titulo = (t) => console.log(`\n=== ${t}`);
const linea = (t) => console.log(`    ${t}`);

async function pedir(ruta, { metodo = 'GET', galleta, cuerpo } = {}) {
  const inicio = performance.now();
  try {
    const r = await fetch(API + ruta, {
      method: metodo,
      // Sin cuerpo, sin Content-Type: el backend rechaza con 400 un DELETE que
      // dice traer JSON y no trae nada.
      headers: { ...(cuerpo === undefined ? {} : { 'Content-Type': 'application/json' }), ...(galleta ? { Cookie: galleta } : {}) },
      body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
      signal: AbortSignal.timeout(30_000),
    });
    let j = null;
    try { j = await r.json(); } catch { /* sin cuerpo */ }
    return { codigo: r.status, ms: performance.now() - inicio, j, galleta: (r.headers.get('set-cookie') ?? '').split(';')[0] };
  } catch {
    return { codigo: 0, ms: performance.now() - inicio, j: null, galleta: '' };
  }
}

async function entrar(correo) {
  return (await pedir('/usuario/login', { metodo: 'POST', cuerpo: { identificador: correo, contrasena: CLAVE } })).galleta;
}
async function entrarOCrear(correo, usuario, nombre) {
  let g = await entrar(correo);
  if (!g) {
    await pedir('/usuario/registro', { metodo: 'POST', cuerpo: { correo_electronico: correo, usuario, nombre, apellido: 'Carga', contrasena: CLAVE } });
    g = await entrar(correo);
  }
  return g;
}

/** De a `tanda` a la vez, para preparar cuentas sin ahogar al backend. */
async function enTandas(lista, tanda, fn) {
  const salida = [];
  for (let i = 0; i < lista.length; i += tanda) {
    salida.push(...(await Promise.all(lista.slice(i, i + tanda).map(fn))));
  }
  return salida;
}

function tiempos(lista) {
  const ms = lista.map((r) => r.ms).sort((a, b) => a - b);
  const p = (q) => ms[Math.min(ms.length - 1, Math.floor(q * ms.length))];
  return `mediana ${Math.round(p(0.5))} ms, 95 de cada 100 en menos de ${Math.round(p(0.95))} ms, la mas lenta ${Math.round(ms.at(-1))} ms`;
}

const interruptor = async (base, estado) => {
  try {
    const r = await fetch(`${CONTROL}/${base}/${estado}`, { method: 'POST', signal: AbortSignal.timeout(3000) });
    return r.ok;
  } catch {
    return false;
  }
};

let oferta = null;
let vendedor = '';
let ventaAbierta = false;
let caidaPuesta = false;
const pedidos = [];
const compradores = [];
const inicioDemo = new Date();

async function limpiar() {
  if (caidaPuesta) {
    await interruptor(CAIDA, 'arriba');
    caidaPuesta = false;
    linea(`${CAIDA} prendida otra vez`);
  }
  if (oferta == null) return;
  if (LIMPIAR) {
    let canceladas = 0;
    for (const { galleta, id } of pedidos) {
      const r = await pedir(`/comprador/pedidos/${id}/cancelar`, { metodo: 'POST', galleta, cuerpo: {} });
      if (r.codigo >= 200 && r.codigo < 300) canceladas++;
    }
    if (pedidos.length) linea(`${canceladas} de ${pedidos.length} pedidos de la demo cancelados, el stock vuelve`);
  }
  await Promise.all(compradores.map((g) => pedir('/carrito', { metodo: 'DELETE', galleta: g })));
  const bien = (r) => r.codigo >= 200 && r.codigo < 300;
  // Primero la venta y despues el descuento: con la venta abierta el backend no
  // deja quitarlo.
  const venta = await pedir(`/vendedor/ofertas/${oferta}/venta-limitada`, { metodo: 'DELETE', galleta: vendedor });
  const descuento = await pedir(`/vendedor/ofertas/${oferta}/descuento`, { metodo: 'DELETE', galleta: vendedor });
  const retirada = await pedir(`/vendedor/ofertas/${oferta}`, { metodo: 'PATCH', galleta: vendedor, cuerpo: { estado: 'retirada' } });
  linea(bien(venta) || !ventaAbierta ? 'venta relampago cerrada' : `NO se cerro la venta relampago (${venta.j?.mensaje ?? venta.codigo})`);
  linea(bien(descuento) ? 'descuento quitado' : `el descuento no se quito (${descuento.j?.mensaje ?? descuento.codigo})`);
  linea(bien(retirada) ? 'oferta retirada, no queda en el catalogo' : `la oferta no quedo retirada (${retirada.j?.mensaje ?? retirada.codigo})`);
  if (LIMPIAR && pedidos.length) {
    // Las compras y las devoluciones llegan a ClickHouse sin esperar; se les
    // da un momento antes de borrarlas.
    await new Promise((r) => setTimeout(r, 5000));
    const ids = pedidos.map((p) => Number(p.id)).join(',');
    try {
      for (const tabla of ['compra_producto', 'devolucion_producto']) {
        await ch.command({ query: `ALTER TABLE ${tabla} DELETE WHERE id_pedido IN (${ids}) SETTINGS mutations_sync = 2` });
      }
      const usuarios = (await sql(`SELECT string_agg(id_usuario::text, ',') AS ids FROM usuarios WHERE correo_electronico LIKE 'carga%@mesh.com'`))[0].ids;
      if (usuarios) {
        await ch.command({
          query: `ALTER TABLE carrito_producto DELETE WHERE id_producto = ${PRODUCTO} AND id_usuario IN (${usuarios})
                    AND fecha >= toDateTime('${inicioDemo.toISOString().slice(0, 19).replace('T', ' ')}') SETTINGS mutations_sync = 2`,
        });
      }
      linea('ClickHouse sin las compras de la demo, lo mas vendido y las tendencias no cambian');
    } catch (error) {
      linea(`no se pudo limpiar ClickHouse (${error.message}), las compras de la demo quedan en las tendencias`);
    }
  }
}

async function principal() {
  titulo('PREPARANDO');
  const adminG = (await pedir('/usuario/login', { metodo: 'POST', cuerpo: { identificador: 'admin@mesh.com', contrasena: 'Admin123' } })).galleta;
  if (!adminG) throw new Error(`El backend no responde en ${API} o no deja entrar al admin`);

  vendedor = await entrarOCrear('vendconcurrencia@mesh.com', 'vendconcurrencia', 'Vendedor de la demo');
  const [{ id_usuario: idVendedor, id_rol_usuario: rol }] = await sql(`SELECT id_usuario, id_rol_usuario FROM usuarios WHERE correo_electronico = 'vendconcurrencia@mesh.com'`);
  if (rol !== 2) {
    await pedir(`/admin/usuarios/${idVendedor}`, { metodo: 'PATCH', galleta: adminG, cuerpo: { id_rol_usuario: 2 } });
    vendedor = await entrar('vendconcurrencia@mesh.com');
  }
  const existente = await sql('SELECT id_oferta FROM oferta WHERE id_usuario = $1 AND id_producto_mongo = $2 AND id_producto_variante_mongo = $3 LIMIT 1', [idVendedor, PRODUCTO, VARIANTE]);
  if (existente.length) {
    oferta = existente[0].id_oferta;
  } else {
    const r = await pedir('/vendedor/ofertas', { metodo: 'POST', galleta: vendedor, cuerpo: { id_producto: PRODUCTO, id_producto_variante: VARIANTE, precio: '15.00', stock_inicial: STOCK } });
    oferta = r.j?.payload?.id_oferta;
    if (oferta == null) throw new Error(`No se pudo crear la oferta (${r.j?.mensaje ?? r.codigo})`);
  }
  await pedir(`/vendedor/ofertas/${oferta}/revision`, { metodo: 'PATCH', galleta: adminG, cuerpo: { decision: 'aprobar' } });
  await pedir(`/vendedor/ofertas/${oferta}`, { metodo: 'PATCH', galleta: vendedor, cuerpo: { estado: 'activa' } });
  const [{ stock: antes }] = await sql('SELECT stock FROM oferta WHERE id_oferta = $1', [oferta]);
  if (antes !== STOCK) {
    await pedir(`/vendedor/ofertas/${oferta}`, { metodo: 'PATCH', galleta: vendedor, cuerpo: { ajuste_stock: STOCK - antes } });
  }
  // Si una corrida anterior murio a medias, la venta puede seguir abierta y el
  // descuento puesto (un segundo POST daria 409, y se reusa).
  await pedir(`/vendedor/ofertas/${oferta}/venta-limitada`, { metodo: 'DELETE', galleta: vendedor });
  const [{ porcentaje_descuento: yaTiene }] = await sql('SELECT porcentaje_descuento FROM oferta WHERE id_oferta = $1', [oferta]);
  if (yaTiene == null) {
    await pedir(`/vendedor/ofertas/${oferta}/descuento`, { metodo: 'POST', galleta: vendedor, cuerpo: { porcentaje_descuento: 20 } });
  }
  const venta = await pedir(`/vendedor/ofertas/${oferta}/venta-limitada`, { metodo: 'POST', galleta: vendedor, cuerpo: {} });
  if (!venta.j?.ok) throw new Error(`No abrio la venta relampago (${venta.j?.mensaje ?? venta.codigo})`);
  ventaAbierta = true;
  const [{ stock: stockInicial }] = await sql('SELECT stock FROM oferta WHERE id_oferta = $1', [oferta]);
  linea(`oferta ${oferta} con ${stockInicial} unidades, 20 % de descuento y venta relampago abierta`);

  const numeros = Array.from({ length: N }, (_, i) => String(i + 1).padStart(2, '0'));
  const listos = await enTandas(numeros, 10, async (n) => {
    const g = await entrarOCrear(`carga${n}@mesh.com`, `carga${n}`, `Comprador ${n}`);
    if (!g) return null;
    let dirs = (await pedir('/direccion-usuario', { galleta: g })).j?.payload ?? [];
    if (!dirs.length) {
      await pedir('/direccion-usuario', { metodo: 'POST', galleta: g, cuerpo: { pais: 'Guatemala', departamento: 'Guatemala', ciudad: 'Guatemala', direccion_exacta: 'Demo de concurrencia' } });
      dirs = (await pedir('/direccion-usuario', { galleta: g })).j?.payload ?? [];
    }
    await pedir('/carrito', { metodo: 'DELETE', galleta: g });
    return dirs.length ? { g, direccion: dirs[0].id_direccion } : null;
  });
  const gente = listos.filter(Boolean);
  compradores.push(...gente.map((c) => c.g));
  linea(`${gente.length} compradores con sesion y direccion de entrega`);
  if (gente.length <= STOCK) throw new Error('No hay suficientes compradores con sesion para que haya competencia');

  if (CAIDA) {
    if (!(await interruptor(CAIDA, 'apagada'))) throw new Error('El interruptor no responde. Corre antes .\\remoto\\caidas.ps1 -Accion levantar');
    caidaPuesta = true;
    titulo(`${CAIDA.toUpperCase()} APAGADA, la tienda sigue con las demas bases`);
  }

  titulo(`${gente.length} COMPRADORES NAVEGANDO A LA VEZ`);
  const rutas = ['/productos/paginacion?pagina=1&limite=12', '/buscador/productos/facetado?nombre=laptop', `/productos/${PRODUCTO}`];
  const navegacion = await Promise.all(gente.flatMap((c) => rutas.map((ruta) => pedir(ruta, { galleta: c.g }))));
  const bien = navegacion.filter((r) => r.codigo === 200).length;
  linea(`${navegacion.length} paginas pedidas, ${bien} contestaron bien`);
  linea(tiempos(navegacion));

  titulo(`VENTA RELAMPAGO, ${gente.length} PIDEN 1 UNIDAD EN EL MISMO INSTANTE Y HAY ${stockInicial}`);
  const intentos = await Promise.all(gente.map((c) => pedir(`/carrito/lineas/${oferta}`, { metodo: 'PUT', galleta: c.g, cuerpo: { cantidad: 1 } })));
  const ganadores = gente.filter((_, i) => intentos[i].codigo === 200);
  const sinStock = intentos.filter((r) => r.codigo === 409).length;
  const otros = intentos.length - ganadores.length - sinStock;
  linea(`${ganadores.length} se la llevaron, ${sinStock} recibieron que ya no hay${otros ? `, ${otros} con otro codigo` : ''}`);
  linea(tiempos(intentos));
  linea(ganadores.length === stockInicial ? 'ganaron exactamente las unidades que habia' : `ganaron ${ganadores.length} y habia ${stockInicial}, eso NO deberia pasar`);

  titulo(`LOS ${ganadores.length} QUE GANARON PAGAN TODOS A LA VEZ`);
  const [{ stock: stockAntes }] = await sql('SELECT stock FROM oferta WHERE id_oferta = $1', [oferta]);
  const pagos = await Promise.all(ganadores.map((c) => pedir('/carrito/comprar', { metodo: 'POST', galleta: c.g, cuerpo: { id_direccion: c.direccion, metodo_pago: 'transferencia' } })));
  pagos.forEach((r, i) => { if (r.j?.payload?.comprado) pedidos.push({ galleta: ganadores[i].g, id: r.j.payload.id_pedido }); });
  const porCodigo = {};
  for (const r of pagos) porCodigo[r.codigo] = (porCodigo[r.codigo] ?? 0) + 1;
  linea(`${pedidos.length} compras hechas (${Object.entries(porCodigo).map(([c, n]) => `${n} con ${c}`).join(', ')})`);
  linea(tiempos(pagos));
  const [{ stock: stockDespues }] = await sql('SELECT stock FROM oferta WHERE id_oferta = $1', [oferta]);
  const ids = pedidos.map((p) => Number(p.id));
  const [{ pagados, movimientos }] = ids.length
    ? await sql(`SELECT (SELECT count(*) FROM pedido p JOIN estado_pedido e USING (id_estado_pedido) WHERE p.id_pedido = ANY($1) AND e.estado_pedido_nombre <> 'pendiente')::int AS pagados,
                        (SELECT count(*) FROM stock_movimiento s JOIN motivo_movimiento m USING (id_motivo_movimiento)
                          WHERE s.id_pedido = ANY($1) AND s.id_oferta = $2 AND m.motivo_nombre = 'venta')::int AS movimientos`, [ids, oferta])
    : [{ pagados: 0, movimientos: 0 }];
  linea(`stock en PostgreSQL ${stockAntes} antes de pagar y ${stockDespues} despues`);
  linea(`${pagados} pedidos pagados y ${movimientos} movimientos de stock en PostgreSQL`);

  titulo('RESULTADO');
  const correcto = ganadores.length === stockInicial && pedidos.length === ganadores.length && stockDespues === 0 &&
    pagados === pedidos.length && movimientos === pedidos.length;
  linea(correcto
    ? `Bien. ${gente.length} compradores a la vez, ${stockInicial} unidades, ${pedidos.length} ventas, stock en 0 y nunca negativo.`
    : 'Algo no cuadra, mira los numeros de arriba.');
  return correcto;
}

let correcto = false;
try {
  correcto = await principal();
} catch (error) {
  console.error(`\n    No se pudo terminar. ${error.message}`);
} finally {
  titulo(LIMPIAR ? 'LIMPIANDO' : 'SIN LIMPIAR, los pedidos quedan para verlos en la pagina');
  await limpiar().catch((error) => linea(`la limpieza fallo (${error.message})`));
  await pg.end();
  await ch.close();
}
process.exit(correcto ? 0 : 1);
