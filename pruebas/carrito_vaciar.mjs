// pruebas/carrito_vaciar.mjs -- vaciar el carrito justo despues de tocarlo
// no lo deja revivir.
//
//   node pruebas/carrito_vaciar.mjs [vueltas]
//
// El carrito se escribe primero en Redis y se copia a PostgreSQL por debajo
// (carrito.service.ts, programarReplica). Un DELETE /carrito que llegaba
// mientras esa copia escribia leia la version de antes, la copia dejaba la
// linea en PostgreSQL y el vaciado chocaba contra ella: el siguiente GET la
// traia de vuelta. Se vio el 2026-11-07, 12 de 12 veces, y asi la prueba
// producto_inactivo.mjs dejaba su linea en el carrito de compradora.norte.
//
// Con comprador.sur, por cada vuelta: agrega una unidad de la oferta activa
// mas barata de otro vendedor, vacia en seguida, espera la replica y comprueba
// que el carrito sigue vacio, en Redis (GET /carrito) y en PostgreSQL (ningun
// pedido pendiente con lineas). No compra nada. Al final vacia el carrito y
// borra de ClickHouse sus eventos de carrito, con el dueno de la base.
import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const requerir = createRequire(join(RAIZ, 'backend', 'package.json'));
requerir('dotenv').config({ path: join(RAIZ, 'backend', '.env'), quiet: true });
const { Pool } = requerir('pg');
const { createClient } = requerir('@clickhouse/client');

const API = process.env.API ?? 'http://localhost:3000';
const VUELTAS = Number(process.argv[2] ?? 10);
const e = process.env;
const pg = new Pool({ host: e.DB_HOST, port: Number(e.DB_PORT ?? 5432), user: e.DB_USER, password: e.DB_PASSWORD, database: e.DB_NAME, max: 2 });
const sql = async (texto, valores) => (await pg.query(texto, valores)).rows;

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
const espera = (ms) => new Promise((r) => setTimeout(r, ms));

// Sin Content-Type cuando no hay cuerpo: Fastify contesta 400 a un DELETE con
// application/json y el cuerpo vacio, y el vaciado no llegaria a pasar.
async function pedir(ruta, { metodo = 'GET', galleta = '', cuerpo } = {}) {
  const r = await fetch(`${API}${ruta}`, {
    method: metodo,
    headers: { ...(galleta ? { Cookie: galleta } : {}), ...(cuerpo !== undefined ? { 'Content-Type': 'application/json' } : {}) },
    body: cuerpo !== undefined ? JSON.stringify(cuerpo) : undefined,
  });
  const j = r.headers.get('content-type')?.includes('json') ? await r.json() : null;
  return { codigo: r.status, j };
}

async function entrar(correo, clave) {
  const r = await fetch(`${API}/usuario/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identificador: correo, contrasena: clave }),
  });
  return (r.headers.get('set-cookie') ?? '').split(';')[0];
}

const lineasEnPostgres = async (idUsuario) =>
  Number(
    (
      await sql(
        `SELECT count(pp.*) AS n FROM pedido p
           JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido AND ep.estado_pedido_nombre = 'pendiente'
           LEFT JOIN pedido_producto pp ON pp.id_pedido = p.id_pedido
          WHERE p.id_usuario = $1`,
        [idUsuario],
      )
    )[0].n,
  );

const inicio = new Date();
let galleta = '';
let idUsuario = null;
let idOferta = null;
try {
  galleta = await entrar('comprador.sur@mesh.com', 'Comprador123');
  const yo = (await pedir('/usuario/yo', { galleta })).j?.payload;
  if (!yo) throw new Error(`El backend no responde en ${API} o no deja entrar a comprador.sur`);
  idUsuario = yo.id_usuario;
  [{ id_oferta: idOferta } = {}] = await sql(
    `SELECT o.id_oferta FROM oferta o
       JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta AND eo.estado_oferta_nombre = 'activa'
       JOIN producto_catalogo pc ON pc.id_producto_mongo = o.id_producto_mongo AND pc.estado = 'activo'
      WHERE o.stock > 5 AND NOT o.es_inventario_limitado AND o.id_usuario <> $1
      ORDER BY o.precio, o.id_oferta LIMIT 1`,
    [idUsuario],
  );
  if (!idOferta) throw new Error('No hay una oferta activa con unidades para probar');

  titulo(`Agregar y vaciar en seguida, ${VUELTAS} veces (oferta ${idOferta})`);
  await pedir('/carrito', { metodo: 'DELETE', galleta });
  await espera(1500);
  let revivio = 0;
  let quedoEnPostgres = 0;
  let deleteMal = 0;
  for (let i = 0; i < VUELTAS; i++) {
    await pedir(`/carrito/lineas/${idOferta}`, { metodo: 'PUT', galleta, cuerpo: { cantidad: 1 } });
    const vaciar = await pedir('/carrito', { metodo: 'DELETE', galleta });
    if (vaciar.codigo !== 200) deleteMal++;
    await espera(1500);
    const lineas = (await pedir('/carrito', { galleta })).j?.payload?.lineas?.length ?? -1;
    if (lineas !== 0) revivio++;
    if ((await lineasEnPostgres(idUsuario)) > 0) quedoEnPostgres++;
    if (lineas !== 0) {
      await pedir('/carrito', { metodo: 'DELETE', galleta });
      await espera(1500);
    }
  }
  revisar(deleteMal === 0, `los ${VUELTAS} DELETE /carrito contestan 200`, `${deleteMal} no`);
  revisar(revivio === 0, `en ninguna vuelta la linea revive en GET /carrito`, `revivio ${revivio} de ${VUELTAS}`);
  revisar(quedoEnPostgres === 0, `en ninguna vuelta queda la linea en el pedido pendiente de PostgreSQL`, `quedo ${quedoEnPostgres} de ${VUELTAS}`);
} catch (error) {
  fallas++;
  console.log(`  FALLA  ${error.message}`);
} finally {
  if (galleta) {
    await pedir('/carrito', { metodo: 'DELETE', galleta });
    await espera(1500);
  }
  if (idOferta && idUsuario && dueno) {
    try {
      const desde = inicio.toISOString().slice(0, 19).replace('T', ' ');
      await ch.command({
        query: `ALTER TABLE carrito_producto DELETE WHERE id_oferta = ${idOferta} AND id_usuario = ${idUsuario}
                  AND fecha >= toDateTime('${desde}', 'UTC') SETTINGS mutations_sync = 2`,
      });
    } catch (error) {
      console.log(`  No se borraron de ClickHouse los carritos de la prueba (${error.message})`);
    }
  }
  if (galleta) await pedir('/usuario/logout', { metodo: 'POST', galleta });
  await pg.end();
  await ch.close();
}

console.log(`\n${oks} OK, ${fallas} FALLA`);
process.exit(fallas > 0 ? 1 : 0);
