// pruebas/clasificador_en_elastic.mjs
//   node pruebas/clasificador_en_elastic.mjs
// Necesita Elasticsearch arriba con mesh_comentarios lleno (lo llena el worker
// EventoComentarioSyncService del backend) y las resenas del clasificador
// sembradas (paso "Resenas del clasificador" de arrancar.ps1).
//
// Prueba que el clasificador de resenas (clasificador-resenas/) se puede usar
// en el backend con el vector que YA esta en mesh_comentarios, sin volver a
// pedirle nada a Ollama. Para cada resena sembrada compara la probabilidad
// que da la red con el vector de Elasticsearch contra la que da con el vector
// con que se entreno: si el modelo de vectores o el texto fueran otros, no
// cuadraria. Despues cuenta aciertos y lista las resenas cuya nota no cuadra
// con el texto, que es la senal que el backend levantaria.
//
// Solo lee. Sale con 1 si la diferencia pasa de 1e-5 o si falta alguna resena.
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..', 'clasificador-resenas');
const { cargarModelo, normalizar, probabilidadMala, notaNoCuadra } =
  await import(pathToFileURL(join(RAIZ, 'predecir.mjs')).href);

const ES = process.env.ES ?? 'http://localhost:9200';
const INDICE = 'mesh_comentarios';

async function es(ruta, cuerpo) {
  const r = await fetch(`${ES}${ruta}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(cuerpo),
  });
  if (!r.ok) throw new Error(`Elasticsearch contesto ${r.status} en ${ruta}: ${await r.text()}`);
  return r.json();
}

const modelo = cargarModelo(cargarModelo('regresion_logistica').recomendado);
const entrenadas = new Map(
  JSON.parse(readFileSync(join(RAIZ, 'vectores', 'vectores.json'), 'utf8')).items.map((x) => [x.id, x.vector]),
);
const porTexto = new Map();
for (const f of readdirSync(join(RAIZ, 'datos')).filter((x) => x.endsWith('.json'))) {
  for (const r of JSON.parse(readFileSync(join(RAIZ, 'datos', f), 'utf8'))) porTexto.set(r.texto, r);
}

let leidas = 0;
let peor = 0;
let aciertos = 0;
const marcadas = [];
const vistas = new Set();
let pagina = await es(`/${INDICE}/_search?scroll=1m`, {
  size: 200,
  query: { bool: { filter: [{ term: { es_respuesta: false } }] } },
  _source: ['comentario', 'vector', 'calificacion', 'id_resena'],
});
while (pagina.hits.hits.length) {
  for (const h of pagina.hits.hits) {
    const r = porTexto.get(h._source.comentario);
    if (!r || !h._source.vector) continue;
    leidas++;
    vistas.add(r.id);
    const p = probabilidadMala(modelo, normalizar(h._source.vector));
    if (entrenadas.has(r.id)) {
      peor = Math.max(peor, Math.abs(p - probabilidadMala(modelo, normalizar(entrenadas.get(r.id)))));
    }
    if ((p >= modelo.umbral) === (r.etiqueta === 'mala')) aciertos++;
    if (notaNoCuadra(modelo, p, h._source.calificacion)) {
      marcadas.push({ id: r.id, caso: r.caso ?? '-', estrellas: h._source.calificacion, p, resena: h._source.id_resena });
    }
  }
  pagina = await es('/_search/scroll', { scroll: '1m', scroll_id: pagina._scroll_id });
}

const ok = [];
const mal = [];
(vistas.size === porTexto.size ? ok : mal).push(`${vistas.size} de ${porTexto.size} resenas del clasificador estan en ${INDICE} con vector`);
(peor < 1e-5 ? ok : mal).push(`con el vector de Elasticsearch la ${modelo.tipo} da lo mismo que con el del entrenamiento, diferencia maxima ${peor.toExponential(2)}`);
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
