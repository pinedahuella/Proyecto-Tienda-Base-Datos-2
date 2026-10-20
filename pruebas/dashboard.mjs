// pruebas/dashboard.mjs -- el dashboard general del admin (GET /admin/dashboard/*)
// cuenta lo mismo en todas sus secciones, lo mismo que Reportes y lo mismo que
// PostgreSQL contado aparte, y sus archivos (Excel, PDF) traen esos numeros.
//
//   node pruebas/dashboard.mjs
//
// Solo lee: no manda ningun correo (de la ruta del correo prueba solo que
// rechaza lo que tiene que rechazar). Necesita el backend arriba y las cuentas
// de la semilla (admin@mesh.com y compradora.norte@mesh.com).

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const requerir = createRequire(join(RAIZ, 'backend', 'package.json'));
requerir('dotenv').config({ path: join(RAIZ, 'backend', '.env'), quiet: true });
const { Pool } = requerir('pg');
const ExcelJS = requerir('exceljs');

const API = process.env.API ?? 'http://localhost:3000';
let oks = 0;
let fallas = 0;
const revisar = (cond, texto, detalle = '') => {
  if (cond) {
    oks++;
    console.log(`  OK     ${texto}`);
  } else {
    fallas++;
    console.log(`  FALLA  ${texto}${detalle ? `  (${detalle})` : ''}`);
  }
};
const titulo = (t) => console.log(`\n=== ${t}`);

async function entrar(correo, clave) {
  const r = await fetch(`${API}/usuario/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identificador: correo, contrasena: clave }),
  });
  return (r.headers.get('set-cookie') ?? '').split(';')[0];
}
const e = process.env;
const pg = new Pool({ host: e.DB_HOST, port: Number(e.DB_PORT ?? 5432), user: e.DB_USER, password: e.DB_PASSWORD, database: e.DB_NAME, max: 2 });

const suma = (lista, f) => lista.reduce((s, x) => s + Number(f(x)), 0);
const igual = (a, b) => Math.abs(Number(a) - Number(b)) < 0.005;

try {
  titulo('0. Solo el admin entra');
  const admin = await entrar('admin@mesh.com', 'Admin123');
  const comprador = await entrar('compradora.norte@mesh.com', 'Comprador123');
  if (!admin) throw new Error(`El backend no responde en ${API} o no deja entrar al admin`);
  const pedir = async (ruta, galleta = admin) => {
    const r = await fetch(`${API}/admin/dashboard/${ruta}`, { headers: galleta ? { Cookie: galleta } : {} });
    return { codigo: r.status, j: r.headers.get('content-type')?.includes('json') ? await r.json() : null, r };
  };
  revisar((await pedir('resumen', '')).codigo === 401, 'sin sesion contesta 401');
  if (comprador) revisar((await pedir('resumen', comprador)).codigo === 403, 'un comprador recibe 403');
  revisar((await pedir('resumen?desde=2026-13-01')).codigo === 400, 'una fecha que no existe contesta 400');
  revisar((await pedir('resumen?desde=2026-10-20&hasta=2026-10-01')).codigo === 400, 'desde despues de hasta contesta 400');

  const hoy = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Guatemala' }).format(new Date());
  const periodos = [
    ['el anio', `${hoy.slice(0, 4)}-01-01`, hoy],
    ['los ultimos 7 dias', new Date(Date.parse(`${hoy}T12:00:00Z`) - 6 * 86_400_000).toISOString().slice(0, 10), hoy],
  ];
  for (const [nombre, desde, hasta] of periodos) {
    titulo(`1. Todas las secciones cuentan lo mismo, ${nombre} (${desde} a ${hasta})`);
    const q = `?desde=${desde}&hasta=${hasta}`;
    const [res, ven, cat, pag, mapa, dep, emb, canc, ped] = await Promise.all(
      ['resumen', 'ventas', 'categorias', 'pagos', 'mapa', 'departamentos', 'embudo', 'cancelaciones', 'pedidos'].map(
        async (r) => (await pedir(r + q)).j?.payload,
      ),
    );
    const cobrado = res.actual.ingresos;
    revisar(igual(suma(ven.serie, (p) => p.ingresos), cobrado), `la serie suma lo cobrado (${cobrado})`, suma(ven.serie, (p) => p.ingresos).toFixed(2));
    revisar(igual(suma(cat, (c) => c.ingresos), cobrado), 'las categorias suman lo cobrado', suma(cat, (c) => c.ingresos).toFixed(2));
    revisar(igual(suma(pag, (p) => p.ingresos), cobrado), 'los pagos por mes suman lo cobrado', suma(pag, (p) => p.ingresos).toFixed(2));
    revisar(igual(suma(dep, (d) => d.ingresos), cobrado), 'los departamentos suman lo cobrado', suma(dep, (d) => d.ingresos).toFixed(2));
    revisar(igual(suma(mapa, (c) => c.ingresos), cobrado), 'el mapa de calor suma lo cobrado', suma(mapa, (c) => c.ingresos).toFixed(2));
    revisar(suma(ven.serie, (p) => p.pedidos) === res.actual.pedidos && suma(mapa, (c) => c.pedidos) === res.actual.pedidos,
      `la serie y el mapa cuentan los mismos ${res.actual.pedidos} pedidos`);
    revisar(suma(ven.serie, (p) => p.unidades) === res.actual.unidades, `la serie cuenta las mismas ${res.actual.unidades} unidades`);
    revisar(emb.compraron === res.actual.compradores && emb.cancelaron === res.actual.cancelados,
      'el embudo trae los mismos compradores y cancelados');
    revisar(suma(canc.por_tiempo, (t) => t.pedidos) === res.actual.cancelados, 'los tramos de cancelacion suman los cancelados');
    revisar(ped.total === res.actual.pedidos + res.actual.cancelados, `el registro trae vendidos mas cancelados (${ped.total})`);

    // PostgreSQL contado aparte, con otra consulta.
    const { rows } = await pg.query(
      `SELECT count(DISTINCT p.id_pedido) FILTER (WHERE ep.estado_pedido_nombre IN ('comprado','enviado','entregado'))::int AS vendidos,
              count(DISTINCT p.id_pedido) FILTER (WHERE ep.estado_pedido_nombre = 'cancelado')::int AS cancelados,
              COALESCE(sum(pg.monto) FILTER (WHERE epa.estado_pago_nombre = 'pagado'), 0)::numeric(14,2)::text AS cobrado
         FROM pedido p
         JOIN estado_pedido ep USING (id_estado_pedido)
         LEFT JOIN pago pg ON pg.id_pedido = p.id_pedido
         LEFT JOIN estado_pago epa ON epa.id_estado_pago = pg.id_estado_pago
        WHERE (p.fecha_creacion AT TIME ZONE 'America/Guatemala')::date BETWEEN $1 AND $2`,
      [desde, hasta],
    );
    revisar(rows[0].vendidos === res.actual.pedidos && rows[0].cancelados === res.actual.cancelados && igual(rows[0].cobrado, cobrado),
      'PostgreSQL contado aparte da lo mismo', JSON.stringify(rows[0]));
  }

  titulo('2. Contra Reportes');
  const reporte = await (await fetch(`${API}/admin/reportes/ventas`, { headers: { Cookie: admin } })).json();
  const tres = new Date(Date.parse(`${hoy}T12:00:00Z`) - 3 * 365 * 86_400_000).toISOString().slice(0, 10);
  const todo = (await pedir(`resumen?desde=${tres}&hasta=${hoy}`)).j.payload;
  const { rows: antes } = await pg.query(`SELECT count(*)::int AS n FROM pedido WHERE fecha_creacion < $1::date`, [tres]);
  if (antes[0].n === 0) {
    revisar(igual(reporte.payload.totales.ingresos, todo.actual.ingresos), `lo cobrado de los tres anios es el Cobrado de Reportes (${reporte.payload.totales.ingresos})`, todo.actual.ingresos);
  } else {
    console.log('  SIN MEDIR hay pedidos de hace mas de tres anios, Reportes cuenta todo');
  }

  titulo('3. Los archivos traen los mismos numeros');
  const q = `?desde=${hoy.slice(0, 4)}-01-01&hasta=${hoy}`;
  const res = (await pedir(`resumen${q}`)).j.payload;
  const xlsx = await pedir(`exportar/excel${q}`);
  revisar(xlsx.codigo === 200 && xlsx.r.headers.get('content-type')?.includes('spreadsheetml'), 'el Excel sale como .xlsx');
  const libro = new ExcelJS.Workbook();
  await libro.xlsx.load(Buffer.from(await xlsx.r.arrayBuffer()));
  const hoja = libro.getWorksheet('Resumen');
  revisar(hoja && igual(hoja.getCell('B2').value, res.actual.ingresos), 'la hoja Resumen tiene lo cobrado', String(hoja?.getCell('B2').value));
  revisar(libro.getWorksheet('Pedidos')?.rowCount - 1 === res.actual.pedidos + res.actual.cancelados, 'la hoja Pedidos tiene todos los pedidos');
  const pdf = await pedir(`exportar/pdf${q}&secciones=resumen,ventas,mapa`);
  const bytes = Buffer.from(await pdf.r.arrayBuffer());
  revisar(pdf.codigo === 200 && bytes.subarray(0, 5).toString() === '%PDF-' && bytes.length > 2000, `el PDF es un PDF (${bytes.length} bytes)`);
  revisar((await pedir(`exportar/pdf${q}&secciones=nada`)).codigo === 400, 'una seccion que no existe contesta 400');

  titulo('4. El correo rechaza lo que tiene que rechazar (sin mandar nada)');
  const correo = async (cuerpo) =>
    (await fetch(`${API}/admin/dashboard/exportar/correo`, { method: 'POST', headers: { Cookie: admin, 'Content-Type': 'application/json' }, body: JSON.stringify(cuerpo) })).status;
  revisar((await correo({ correos: [], formato: 'pdf' })) === 400, 'sin correos, 400');
  revisar((await correo({ correos: ['no-es-correo'], formato: 'pdf' })) === 400, 'un correo mal escrito, 400');
  revisar((await correo({ correos: ['a@b.com'], formato: 'word' })) === 400, 'un formato que no existe, 400');
} catch (error) {
  fallas++;
  console.log(`  FALLA  ${error.message}`);
} finally {
  await pg.end();
}

console.log(`\n${oks} OK, ${fallas} FALLA`);
process.exit(fallas > 0 ? 1 : 0);
