// geo-pais.mjs
// El pais que el BACKEND le asigna a una IP, usando el mismo geoip-lite que usa el (para
// geolocalizar los logins, ver backend/src/services/fraude-login). Lo usan las demos de otro
// pais para escoger una salida de Tor que el backend de verdad ubique en el pais pedido.
//
//   node panel-comandos/geo-pais.mjs 194.15.115.212 46.250.243.29
//   194.15.115.212 SG
//   46.250.243.29 GB
//
// Por que no basta con lo que dice Tor ni con un servicio como ipinfo: las tres bases de datos
// no coinciden. Medido el 2026-09-20: 46.250.243.29 es Singapur para Tor, Australia para ipinfo
// y Reino Unido para geoip-lite. Lo unico que cuenta es lo que decide el backend, porque es lo
// que se guarda en el evento y lo que dispara el viaje imposible.
//
// Sale con "??" si la IP no esta en la base, y con error si no esta instalado geoip-lite
// (backend/node_modules); en ese caso quien lo llama vuelve a preguntarle a ipinfo.

import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const aqui = path.dirname(fileURLToPath(import.meta.url));
const requerir = createRequire(path.resolve(aqui, '..', 'backend', 'package.json'));

let geoip;
try {
  geoip = requerir('geoip-lite');
} catch {
  console.error('No encuentro geoip-lite en backend/node_modules');
  process.exit(2);
}

for (const ip of process.argv.slice(2)) {
  const r = geoip.lookup(ip);
  console.log(`${ip} ${r ? r.country : '??'}`);
}
