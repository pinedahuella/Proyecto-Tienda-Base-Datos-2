// pruebas/clasificador_en_postgres.mjs
//   node pruebas/clasificador_en_postgres.mjs
// Necesita PostgreSQL arriba con vector_comentario lleno (lo llena el worker
// EventoComentarioSyncService del backend) y las resenas del clasificador
// sembradas (paso "Resenas del clasificador" de arrancar.ps1).
//
// Prueba que el clasificador de resenas (clasificador-resenas/) se puede usar
// en el backend con el vector que YA esta guardado, sin volver a pedirle nada a
// Ollama. Para cada resena sembrada compara la probabilidad que da el modelo con
// el vector guardado contra la que da con el vector con que se entreno: si el
// modelo de vectores o el texto fueran otros, no cuadraria. Ademas compara la
// probabilidad con la que ValoracionComentariosService dejo en prob_mala. Despues
// cuenta aciertos y lista las resenas cuya nota no cuadra con el texto, que es la
// senal que el backend levanta.
//
// Hasta el 2026-10-16 se llamaba clasificador_en_elastic.mjs y leia el indice
// mesh_comentarios. Desde la migracion 040 el vector y la valoracion de cada
// comentario viven en vector_comentario de PostgreSQL (pgvector).
//
// Solo lee. Lee las credenciales del .env de la raiz y entra por localhost;
// PG_HOST y PG_PORT cambian a donde. Sale con 1 si la diferencia pasa de 1e-5 o
// si falta alguna resena.
import { readFileSync, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const AQUI = dirname(fileURLToPath(import.meta.url));
const RAIZ = join(AQUI, '..', 'clasificador-resenas');
const { cargarModelo, normalizar, probabilidadMala, notaNoCuadra } =
  await import(pathToFileURL(join(RAIZ, 'predecir.mjs')).href);
const { Client } = createRequire(join(AQUI, '..', 'backend', 'package.json'))('pg');

const env = {};
for (const linea of readFileSync(join(AQUI, '..', '.env'), 'utf8').split(/\r?\n/)) {
  const m = /^\s*([A-Z_]+)\s*=\s*(.*)$/.exec(linea);
  if (m) env[m[1]] = m[2].trim();
}
const pg = new Client({
  host: process.env.PG_HOST ?? 'localhost',
  port: Number(process.env.PG_PORT ?? env.DB_PORT ?? 5432),
  user: env.DB_USER,
  password: env.DB_PASSWORD,
  database: env.DB_NAME,
});
await pg.connect();

const modelo = cargarModelo(cargarModelo('regresion_logistica').recomendado);
const entrenadas = new Map(
  JSON.parse(readFileSync(join(RAIZ, 'vectores', 'vectores.json'), 'utf8')).items.map((x) => [x.id, x.vector]),
);
const porTexto = new Map();
for (const f of readdirSync(join(RAIZ, 'datos')).filter((x) => x.endsWith('.json'))) {
  for (const r of JSON.parse(readFileSync(join(RAIZ, 'datos', f), 'utf8'))) porTexto.set(r.texto, r);
}

// Solo las raices de una resena: las respuestas no se valoran.
const { rows } = await pg.query(
  `SELECT r.id_resena, r.calificacion, c.comentario, v.vector::text AS vector, v.prob_mala
     FROM resena r
     JOIN comentario c ON c.id_comentario = r.id_comentario
     JOIN vector_comentario v ON v.id_comentario = r.id_comentario`,
);

let leidas = 0;
let peor = 0;
let peorGuardada = 0;
let aciertos = 0;
const marcadas = [];
const vistas = new Set();
for (const fila of rows) {
  const r = porTexto.get(fila.comentario);
  if (!r) continue;
  leidas++;
  vistas.add(r.id);
  const p = probabilidadMala(modelo, normalizar(JSON.parse(fila.vector)));
  if (entrenadas.has(r.id)) {
    peor = Math.max(peor, Math.abs(p - probabilidadMala(modelo, normalizar(entrenadas.get(r.id)))));
  }
  // prob_mala se guarda con 3 decimales: la diferencia esperable es de 5e-4.
  if (fila.prob_mala != null) peorGuardada = Math.max(peorGuardada, Math.abs(p - Number(fila.prob_mala)));
  if ((p >= modelo.umbral) === (r.etiqueta === 'mala')) aciertos++;
  if (notaNoCuadra(modelo, p, fila.calificacion)) {
    marcadas.push({ id: r.id, caso: r.caso ?? '-', estrellas: fila.calificacion, p, resena: fila.id_resena });
  }
}
await pg.end();

const ok = [];
const mal = [];
(vistas.size === porTexto.size ? ok : mal).push(`${vistas.size} de ${porTexto.size} resenas del clasificador estan en vector_comentario con vector`);
(peor < 1e-5 ? ok : mal).push(`con el vector guardado la ${modelo.tipo} da lo mismo que con el del entrenamiento, diferencia maxima ${peor.toExponential(2)}`);
(peorGuardada <= 5.01e-4 ? ok : mal).push(`y lo mismo que dejo el backend en prob_mala, diferencia maxima ${peorGuardada.toExponential(2)} (3 decimales)`);
ok.push(`aciertos ${aciertos} de ${leidas} (incluye las que se usaron para entrenar, no mide el modelo)`);

console.log(`Modelo ${modelo.tipo}, umbral de fraude ${modelo.umbral_fraude}`);
ok.forEach((x) => console.log(`  OK     ${x}`));
mal.forEach((x) => console.log(`  FALLA  ${x}`));
console.log(`\nNota que no cuadra con el texto, ${marcadas.length}:`);
for (const m of marcadas.sort((a, b) => (a.id < b.id ? -1 : 1))) {
  console.log(`  ${m.id.padEnd(5)} ${m.caso.padEnd(22)} ${m.estrellas} estrellas, probabilidad de mala ${m.p.toFixed(2)}, resena ${m.resena}`);
}
console.log(`\n${ok.length} OK, ${mal.length} FALLA`);
process.exit(mal.length ? 1 : 0);
