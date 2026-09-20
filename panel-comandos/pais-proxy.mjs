// pais-proxy.mjs
// El link de Mesh "visto desde otro pais". Todo lo que llega a mesh-<pais>.ledkid.com se
// reenvia a https://mesh.ledkid.com SALIENDO POR TOR de ese pais. Para el backend, quien
// abre ese link (desde tu navegador de siempre, o desde un celular) esta en Singapur,
// Alemania, etc.: su IP es la de la salida de Tor, y la alerta de viaje imposible salta
// con un login normal. Lo lanza demo-entrar-otro-pais.ps1 (via pais-enlace.ps1).
//
//   node pais-proxy.mjs        con PAIS_HOST, PAIS_NOMBRE y TOR_SOCKS_PUERTO en el entorno
//
// Que lo hace seguro de dejar corriendo:
//   1. Solo hay UN destino, mesh.ledkid.com. No es un proxy abierto: no reenvia a otro sitio.
//   2. Solo contesta al Host de su pais (PAIS_HOST). Cualquier otro Host recibe un aviso.
//   3. Escucha solo en 127.0.0.1; a el llega cloudflared, que ya esta en esta maquina.
//   4. NO reenvia quien es el visitante (X-Forwarded-For, CF-*, Forwarded...): si lo pasara,
//      el backend veria la IP real de quien abre el link y no la de Tor, y no serviria.
//      Tampoco pasa CDN-Loop: Cloudflare lo tomaria por un bucle.
//
// Va mas lento que la tienda normal: cada conexion nueva pasa por Tor. Se reusan las
// conexiones (keep-alive) para no pagar el saludo de Tor en cada archivo.

import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';

const PUERTO = Number(process.env.PAIS_PROXY_PUERTO || 5299);
const HOST_PAIS = (process.env.PAIS_HOST || '').toLowerCase();
const NOMBRE = process.env.PAIS_NOMBRE || 'otro pais';
const SOCKS = { host: '127.0.0.1', port: Number(process.env.TOR_SOCKS_PUERTO || 9051) };
const DESTINO = 'mesh.ledkid.com';

if (!HOST_PAIS) { console.error('Falta PAIS_HOST'); process.exit(1); }

// --- SOCKS5 sin dependencias: CONNECT por nombre, sin autenticacion. Tor resuelve el DNS. ---
function conectarPorSocks(host, puerto) {
  return new Promise((resolver, rechazar) => {
    const s = net.connect(SOCKS.port, SOCKS.host);
    s.setTimeout(45000);
    const falla = (e) => { s.destroy(); rechazar(e); };
    s.once('error', falla);
    s.once('timeout', () => falla(new Error('Tor no contesto a tiempo')));
    s.once('connect', () => s.write(Buffer.from([5, 1, 0])));
    s.once('data', (d) => {
      if (d[0] !== 5 || d[1] !== 0) return falla(new Error('Tor rechazo el saludo SOCKS'));
      const h = Buffer.from(host);
      s.write(Buffer.concat([Buffer.from([5, 1, 0, 3, h.length]), h, Buffer.from([puerto >> 8, puerto & 255])]));
      s.once('data', (r) => {
        if (r[1] !== 0) return falla(new Error(`Tor no pudo llegar a ${host} (codigo ${r[1]})`));
        s.setTimeout(0);
        s.removeListener('error', falla);
        resolver(s);
      });
    });
  });
}

// Un agente por destino: las conexiones se abren por Tor y se reusan.
const agentes = new Map();
function agenteHacia(destino) {
  if (agentes.has(destino)) return agentes.get(destino);
  const agente = new https.Agent({ keepAlive: true, maxSockets: 8, keepAliveMsecs: 30000 });
  agente.createConnection = (_opciones, cb) => {
    conectarPorSocks(destino, 443)
      .then((sock) => {
        const t = tls.connect({ socket: sock, servername: destino, ALPNProtocols: ['http/1.1'] });
        t.once('secureConnect', () => cb(null, t));
        t.once('error', (e) => cb(e));
      })
      .catch((e) => cb(e));
  };
  agentes.set(destino, agente);
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

  // Comprobaciones de este mismo programa. Solo por loopback o por el host de este pais.
  if (req.url === '/__pais/estado' && (esLocal || host === HOST_PAIS)) {
    return json(res, { pais: NOMBRE, host: HOST_PAIS, destino: DESTINO, socks: SOCKS.port });
  }
  if (req.url === '/__pais/ip' && (esLocal || host === HOST_PAIS)) {
    // La IP con la que Tor sale a internet, para comprobar que el link si es de ese pais
    https.get({ agent: agenteHacia('api.ipify.org'), host: 'api.ipify.org', path: '/', headers: { host: 'api.ipify.org' } }, (r) => {
      let t = ''; r.on('data', (d) => (t += d)); r.on('end', () => json(res, { ip: t.trim(), pais: NOMBRE }));
    }).on('error', (e) => pagina(res, 502, 'Sin salida por Tor', e.message));
    return;
  }

  if (host !== HOST_PAIS) {
    return pagina(res, 503, 'Esta direccion no esta abierta',
      `Mesh visto desde ${NOMBRE} vive en <b>${HOST_PAIS}</b>. Esta otra direccion no esta activa ahora.`);
  }

  const cab = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (NO_REENVIAR.has(k) || k.startsWith('cf-')) continue;
    cab[k] = v;
  }
  cab.host = DESTINO;
  // El origen de la peticion tiene que ser el destino real, o Mesh la toma por ajena
  if (cab.origin) cab.origin = `https://${DESTINO}`;
  if (cab.referer) cab.referer = cab.referer.replace(`https://${HOST_PAIS}`, `https://${DESTINO}`);

  const salida = https.request(
    { agent: agenteHacia(DESTINO), host: DESTINO, port: 443, method: req.method, path: req.url, headers: cab },
    (r) => {
      const h = { ...r.headers };
      // Las redirecciones y las cookies tienen que quedarse en ESTE host, no saltar a mesh.ledkid.com
      if (h.location) h.location = h.location.replace(`https://${DESTINO}`, `https://${HOST_PAIS}`);
      if (h['set-cookie']) h['set-cookie'] = h['set-cookie'].map((c) => c.replace(/;\s*domain=[^;]*/i, ''));
      delete h['strict-transport-security'];
      res.writeHead(r.statusCode, h);
      r.pipe(res);
    },
  );
  salida.setTimeout(90000, () => salida.destroy(new Error('Mesh no contesto por Tor a tiempo')));
  salida.on('error', (e) => {
    if (!res.headersSent) pagina(res, 502, 'No llego a Mesh', `La salida por Tor de ${NOMBRE} fallo (${e.message}). Intenta de nuevo en unos segundos.`);
    else res.destroy();
  });
  req.pipe(salida);
});

servidor.requestTimeout = 0;
servidor.on('error', (e) => { console.error(e.code === 'EADDRINUSE' ? `El puerto ${PUERTO} ya esta ocupado.` : e.message); process.exit(1); });
servidor.listen(PUERTO, '127.0.0.1', () => console.log(`Mesh desde ${NOMBRE}: ${HOST_PAIS} -> ${DESTINO} por Tor (socks ${SOCKS.port}), escuchando en 127.0.0.1:${PUERTO}`));
