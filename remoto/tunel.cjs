// remoto/tunel.cjs
//   node remoto/tunel.cjs 100.64.42.11
// Reenvia los puertos de las bases desde localhost a la PC que las tiene (la
// de Jose David, por Tailscale), para que las pruebas y las demos que hablan
// con "localhost" lleguen alla sin tocarlas. Lo arranca remoto/activar.sh.
//
// Dos juegos de puertos:
//   - los de la maquina (los del docker-compose): 5432, 27018, 6379, 7687,
//     8123, 9200. Los usan las pruebas que van directo (curl a 9200, python a
//     8123) y los clientes que el docker falso corre aqui (psql a 5432).
//   - los de DENTRO de un contenedor, cuando no son los mismos: 27017 es el
//     de Mongo adentro de mesh-mongo. Un "docker exec mesh-mongo mongosh"
//     conecta a localhost:27017; aqui ese puerto lleva al 27018 de alla.
// Escucha en 127.0.0.1 y en ::1, porque "localhost" puede ser cualquiera de
// los dos. Necesita esos puertos libres: con el Docker local arriba estan
// tomados y el tunel no arranca (lo dice y sale con 1).
const net = require('net');

const DESTINO = process.argv[2];
if (!DESTINO) {
  console.error('Uso: node remoto/tunel.cjs <ip de la PC con las bases>');
  process.exit(2);
}

// [puerto aqui, puerto alla, que es]
const PUERTOS = [
  [5432, 5432, 'PostgreSQL'],
  [27018, 27018, 'MongoDB'],
  [27017, 27018, 'MongoDB, el de dentro del contenedor'],
  [6379, 6379, 'Redis'],
  [7687, 7687, 'Neo4j'],
  [8123, 8123, 'ClickHouse'],
  [9200, 9200, 'Elasticsearch'],
];
const DIRECCIONES = ['127.0.0.1', '::1'];

const total = PUERTOS.length * DIRECCIONES.length;
let listos = 0;
let fallos = 0;
function terminado() {
  if (listos + fallos < total) return;
  if (fallos) process.exit(1);
  console.log(`tunel listo: ${PUERTOS.length} puertos de localhost a ${DESTINO}`);
}

for (const [local, remoto, nombre] of PUERTOS) {
  for (const direccion of DIRECCIONES) {
    const servidor = net.createServer((cliente) => {
      const alla = net.connect(remoto, DESTINO);
      cliente.setNoDelay(true);
      alla.setNoDelay(true);
      cliente.pipe(alla);
      alla.pipe(cliente);
      const cerrar = () => { cliente.destroy(); alla.destroy(); };
      cliente.on('error', cerrar);
      alla.on('error', cerrar);
      cliente.on('close', cerrar);
      alla.on('close', cerrar);
    });
    servidor.on('error', (e) => {
      fallos++;
      console.error(`  ${direccion} ${local} (${nombre}): ${e.code === 'EADDRINUSE' ? 'ocupado; apaga el Docker local' : e.message}`);
      terminado();
    });
    servidor.listen(local, direccion, () => { listos++; terminado(); });
  }
}
