// pais-proxy.mjs
// Los links de Mesh "vistos desde otro pais". Todo lo que llega a mesh-<pais>.ledkid.com se
// reenvia a https://mesh.ledkid.com SALIENDO POR EL TOR de ESE pais. Para el backend, quien
// abre el link (desde el navegador que sea, o un celular) esta en Singapur, Alemania, etc.: su
// IP es la de la salida de Tor de ese pais, y la alerta de viaje imposible salta con un login
// normal. Lo lanza pais-enlace.ps1.
//
//   node pais-proxy.mjs        con PAIS_TABLA (y opcionalmente PAIS_PROXY_PUERTO) en el entorno
//
// UN solo programa atiende a TODOS los paises abiertos. Que paises hay se lee de un archivo
// (PAIS_TABLA, paises-activos.json) EN CADA PETICION: abrir o cerrar un pais es escribir ese
// archivo, sin reiniciar nada ni tocar el tunel. Cada pais lleva el puerto SOCKS de su Tor.
//
// Que lo hace seguro de dejar corriendo:
//   1. Solo hay UN destino, mesh.ledkid.com. No es un proxy abierto: no reenvia a otro sitio.
//   2. Solo contesta a los Host que estan en la tabla. Cualquier otro recibe un aviso.
//   3. Escucha solo en 127.0.0.1; a el llega cloudflared, que ya esta en esta maquina.
//   4. NO reenvia quien es el visitante (X-Forwarded-For, CF-*, Forwarded...): si lo pasara,
//      el backend veria la IP real de quien abre el link y no la de Tor, y no serviria.
//      Tampoco pasa CDN-Loop: Cloudflare lo tomaria por un bucle.
//
// Va mas lento que la tienda normal: cada conexion nueva pasa por Tor. Se reusan las
// conexiones (keep-alive) para no pagar el saludo de Tor en cada archivo.

import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';

const PUERTO = Number(process.env.PAIS_PROXY_PUERTO || 5299);
const TABLA = process.env.PAIS_TABLA || '';
const DESTINO = 'mesh.ledkid.com';

if (!TABLA) { console.error('Falta PAIS_TABLA'); process.exit(1); }

// --- La tabla de paises abiertos, releida cuando cambia el archivo ---
let cache = { mtime: 0, porHost: new Map(), porCodigo: new Map() };
function tabla() {
  try {
    const st = fs.statSync(TABLA);
    if (st.mtimeMs === cache.mtime) return cache;
    const j = JSON.parse(fs.readFileSync(TABLA, 'utf8').replace(/^﻿/, ''));
    const porHost = new Map();
    const porCodigo = new Map();
    for (const [codigo, e] of Object.entries(j.paises || {})) {
      const entrada = { codigo, nombre: e.nombre, host: String(e.host).toLowerCase(), socks: Number(e.socks), usuario: e.usuario ? String(e.usuario) : '' };
      porHost.set(entrada.host, entrada);
      porCodigo.set(codigo, entrada);
    }
    cache = { mtime: st.mtimeMs, porHost, porCodigo };
  } catch {
    // Sin archivo o a medio escribir: se sigue con lo que habia
    if (!fs.existsSync(TABLA)) cache = { mtime: 0, porHost: new Map(), porCodigo: new Map() };
  }
  return cache;
}

// --- SOCKS5 sin dependencias: CONNECT por nombre, sin autenticacion. Tor resuelve el DNS. ---
function conectarPorSocks(socksPuerto, host, puerto, usuario = '') {
  return new Promise((resolver, rechazar) => {
    const s = net.connect(socksPuerto, '127.0.0.1');
    s.setTimeout(45000);
    const falla = (e) => { s.destroy(); rechazar(e); };
    s.once('error', falla);
    s.once('timeout', () => falla(new Error('Tor no contesto a tiempo')));
    // Con `usuario` (la etiqueta de un circuito, c3) se pide autenticacion usuario/clave: Tor da un
    // circuito distinto por cada usuario, asi que todas las conexiones de este pais usan el MISMO
    // circuito, el que se verifico con el backend, y no uno cualquiera de los que arma Tor.
    const conAuth = Boolean(usuario);
    const pedirDestino = () => {
      const h = Buffer.from(host);
      s.write(Buffer.concat([Buffer.from([5, 1, 0, 3, h.length]), h, Buffer.from([puerto >> 8, puerto & 255])]));
      s.once('data', (r) => {
        if (r[1] !== 0) return falla(new Error(`Tor no pudo llegar a ${host} (codigo ${r[1]})`));
        s.setTimeout(0);
        s.removeListener('error', falla);
        resolver(s);
      });
    };
    s.once('connect', () => s.write(Buffer.from(conAuth ? [5, 1, 2] : [5, 1, 0])));
    s.once('data', (d) => {
      if (d[0] !== 5 || d[1] !== (conAuth ? 2 : 0)) return falla(new Error('Tor rechazo el saludo SOCKS'));
      if (!conAuth) return pedirDestino();
      const u = Buffer.from(usuario);
      const clave = Buffer.from('x');
      s.write(Buffer.concat([Buffer.from([1, u.length]), u, Buffer.from([clave.length]), clave]));
      s.once('data', (a) => {
        if (a[1] !== 0) return falla(new Error('Tor rechazo el usuario del circuito'));
        pedirDestino();
      });
    });
  });
}

// Un agente por (destino, Tor de un pais): las conexiones se abren por ESE Tor y se reusan.
const agentes = new Map();
function agenteHacia(destino, socksPuerto, usuario = '') {
  const clave = `${destino}@${socksPuerto}#${usuario}`;
  if (agentes.has(clave)) return agentes.get(clave);
  const agente = new https.Agent({ keepAlive: true, maxSockets: 8, keepAliveMsecs: 30000 });
  agente.createConnection = (_opciones, cb) => {
    conectarPorSocks(socksPuerto, destino, 443, usuario)
      .then((sock) => {
        const t = tls.connect({ socket: sock, servername: destino, ALPNProtocols: ['http/1.1'] });
        t.once('secureConnect', () => cb(null, t));
        t.once('error', (e) => cb(e));
      })
      .catch((e) => cb(e));
  };
  agentes.set(clave, agente);
  return agente;
}

const NO_REENVIAR = new Set([
  'host', 'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer',
  'transfer-encoding', 'upgrade', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto',
  'x-forwarded-port', 'x-real-ip', 'forwarded', 'cdn-loop', 'true-client-ip', 'via',
]);

function pagina(res, estado, titulo, texto) {
  res.writeHead(estado, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(`<!doctype html><meta charset="utf-8"><title>${titulo}</title><body style="font:16px system-ui;max-width:34rem;margin:15vh auto;padding:0 1rem;color:#333"><h1 style="font-weight:400">${titulo}</h1><p>${texto}</p>`);
}

function json(res, cuerpo) {
  res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(cuerpo));
}

const servidor = http.createServer((req, res) => {
  const host = (req.headers.host || '').toLowerCase().split(':')[0];
  const esLocal = host === '127.0.0.1' || host === 'localhost';
  const t = tabla();
  const entrada = t.porHost.get(host);
  const url = new URL(req.url, 'http://x');

  // Comprobaciones de este mismo programa: solo por loopback, o por el host de un pais abierto.
  if (url.pathname === '/__pais/estado' && (esLocal || entrada)) {
    return json(res, { destino: DESTINO, paises: [...t.porCodigo.values()].map((e) => ({ codigo: e.codigo, nombre: e.nombre, host: e.host, socks: e.socks })) });
  }
  if (url.pathname === '/__pais/ip' && (esLocal || entrada)) {
    // La IP con la que sale el Tor de ese pais: ?pais=sg por loopback, o el pais del propio host
    const e = entrada || t.porCodigo.get(url.searchParams.get('pais') || '');
    if (!e) return pagina(res, 404, 'Pais no abierto', 'Ese pais no esta abierto.');
    https.get({ agent: agenteHacia('api.ipify.org', e.socks, e.usuario), host: 'api.ipify.org', path: '/', headers: { host: 'api.ipify.org' } }, (r) => {
      let txt = ''; r.on('data', (d) => (txt += d)); r.on('end', () => json(res, { ip: txt.trim(), pais: e.nombre, codigo: e.codigo }));
    }).on('error', (err) => pagina(res, 502, 'Sin salida por Tor', err.message));
    return;
  }

  if (!entrada) {
    const abiertos = [...t.porHost.keys()];
    return pagina(res, 503, 'Esta direccion no esta abierta',
      abiertos.length
        ? `Ahora estan abiertos: <b>${abiertos.join('</b>, <b>')}</b>.`
        : 'No hay ningun pais abierto ahora. Se abren desde el panel de comandos de Mesh.');
  }

  const cab = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (NO_REENVIAR.has(k) || k.startsWith('cf-')) continue;
    cab[k] = v;
  }
  cab.host = DESTINO;
  // El origen de la peticion tiene que ser el destino real, o Mesh la toma por ajena
  if (cab.origin) cab.origin = `https://${DESTINO}`;
  if (cab.referer) cab.referer = cab.referer.replace(`https://${entrada.host}`, `https://${DESTINO}`);

  const salida = https.request(
    { agent: agenteHacia(DESTINO, entrada.socks, entrada.usuario), host: DESTINO, port: 443, method: req.method, path: req.url, headers: cab },
    (r) => {
      const h = { ...r.headers };
      // Las redirecciones y las cookies tienen que quedarse en ESTE host, no saltar a mesh.ledkid.com
      if (h.location) h.location = h.location.replace(`https://${DESTINO}`, `https://${entrada.host}`);
      if (h['set-cookie']) h['set-cookie'] = h['set-cookie'].map((c) => c.replace(/;\s*domain=[^;]*/i, ''));
      delete h['strict-transport-security'];
      res.writeHead(r.statusCode, h);
      r.pipe(res);
    },
  );
  salida.setTimeout(90000, () => salida.destroy(new Error('Mesh no contesto por Tor a tiempo')));
  salida.on('error', (e) => {
    if (!res.headersSent) pagina(res, 502, 'No llego a Mesh', `La salida por Tor de ${entrada.nombre} fallo (${e.message}). Intenta de nuevo en unos segundos.`);
    else res.destroy();
  });
  req.pipe(salida);
});

servidor.requestTimeout = 0;
servidor.on('error', (e) => { console.error(e.code === 'EADDRINUSE' ? `El puerto ${PUERTO} ya esta ocupado.` : e.message); process.exit(1); });
servidor.listen(PUERTO, '127.0.0.1', () => console.log(`Links por pais -> ${DESTINO} por Tor, tabla ${TABLA}, escuchando en 127.0.0.1:${PUERTO}`));
