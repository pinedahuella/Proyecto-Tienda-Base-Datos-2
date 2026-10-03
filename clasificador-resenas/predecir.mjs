// Paso 3. Usa el modelo desde JavaScript, igual que lo haria el backend.
//
//   node predecir.mjs "llego roto y nadie contesta"
//   node predecir.mjs "llego roto y nadie contesta" --estrellas 5
//   node predecir.mjs "..." --modelo regresion_logistica
//   node predecir.mjs --verificar
//
// No usa ninguna libreria: el modelo es un JSON con numeros y predecir es
// multiplicar y sumar. Estas mismas funciones se pasan tal cual a TypeScript.
// --verificar comprueba que dan lo mismo que Python con los vectores guardados.

import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = dirname(fileURLToPath(import.meta.url));

function leerEnvBackend() {
  const archivo = join(RAIZ, '..', 'backend', '.env');
  const valores = {};
  if (!existsSync(archivo)) return valores;
  for (const linea of readFileSync(archivo, 'utf8').split(/\r?\n/)) {
    const i = linea.indexOf('=');
    if (i > 0 && !linea.trimStart().startsWith('#')) {
      valores[linea.slice(0, i).trim()] = linea.slice(i + 1).trim().replace(/^["']|["']$/g, '');
    }
  }
  return valores;
}

const env = leerEnvBackend();
const OLLAMA_URL = process.env.OLLAMA_URL || env.OLLAMA_URL || 'http://localhost:11434';

export function cargarModelo(nombre) {
  return JSON.parse(readFileSync(join(RAIZ, 'modelo', `${nombre}.json`), 'utf8'));
}

/** Largo 1, como en el entrenamiento. Sin esto las probabilidades no cuadran. */
export function normalizar(v) {
  const largo = Math.sqrt(v.reduce((s, x) => s + x * x, 0));
  return largo ? v.map((x) => x / largo) : v;
}

const sigmoide = (z) => (z >= 0 ? 1 / (1 + Math.exp(-z)) : Math.exp(z) / (1 + Math.exp(z)));

/** p = sigmoide(x . w + b) */
function regresion(modelo, x) {
  let z = modelo.sesgo;
  for (let i = 0; i < x.length; i++) z += x[i] * modelo.pesos[i];
  return sigmoide(z);
}

/** oculta = relu(x W1 + b1), p = sigmoide(oculta W2 + b2) */
function red(modelo, x) {
  let entrada = x;
  for (const capa of modelo.capas) {
    const salida = capa.sesgos.slice();
    for (let i = 0; i < capa.entradas; i++) {
      const xi = entrada[i];
      if (xi === 0) continue;
      const fila = capa.pesos[i];
      for (let j = 0; j < capa.salidas; j++) salida[j] += xi * fila[j];
    }
    entrada = salida.map((z) => (capa.activacion === 'relu' ? Math.max(z, 0) : sigmoide(z)));
  }
  return entrada[0];
}

/** Probabilidad de que el texto sea malo, de 0 a 1. `vector` es el de Ollama, ya normalizado. */
export function probabilidadMala(modelo, vector) {
  if (vector.length !== modelo.dimensiones) {
    throw new Error(`El vector trae ${vector.length} numeros y el modelo espera ${modelo.dimensiones}`);
  }
  return modelo.tipo === 'red_neuronal' ? red(modelo, vector) : regresion(modelo, vector);
}

/** La senal de fraude: el texto dice una cosa y las estrellas otra. */
export function notaNoCuadra(modelo, prob, estrellas) {
  const u = modelo.umbral_fraude;
  return (prob >= u && estrellas >= 4) || (prob <= 1 - u && estrellas <= 2);
}

async function vectorDe(texto, modelo) {
  const r = await fetch(`${OLLAMA_URL}/api/embed`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: modelo.modelo_vectores, input: [texto] }),
  });
  if (!r.ok) throw new Error(`Ollama respondio ${r.status} en ${OLLAMA_URL}`);
  return normalizar((await r.json()).embeddings[0]);
}

function verificar() {
  const muestras = JSON.parse(readFileSync(join(RAIZ, 'modelo', 'verificacion.json'), 'utf8'));
  let peor = 0;
  for (const nombre of ['regresion_logistica', 'red_neuronal']) {
    const modelo = cargarModelo(nombre);
    let peorModelo = 0;
    for (const m of muestras) {
      peorModelo = Math.max(peorModelo, Math.abs(probabilidadMala(modelo, m.vector) - m[nombre]));
    }
    console.log(`${nombre}: ${muestras.length} muestras, diferencia maxima con Python ${peorModelo.toExponential(2)}`);
    peor = Math.max(peor, peorModelo);
  }
  if (peor > 1e-9) {
    console.log('NO CUADRA: JavaScript y Python no calculan lo mismo');
    process.exit(1);
  }
  console.log('Cuadra: JavaScript da las mismas probabilidades que Python');
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--verificar')) return verificar();
  const opcion = (n) => (args.includes(n) ? args[args.indexOf(n) + 1] : undefined);
  const texto = args.find((a, i) => !a.startsWith('--') && !['--modelo', '--estrellas'].includes(args[i - 1]));
  if (!texto) {
    console.log('Uso: node predecir.mjs "texto de la resena" [--estrellas 1-5] [--modelo red_neuronal|regresion_logistica]');
    process.exit(1);
  }
  const base = cargarModelo('regresion_logistica');
  const modelo = cargarModelo(opcion('--modelo') ?? base.recomendado);
  const prob = probabilidadMala(modelo, await vectorDe(texto, modelo));
  console.log(`Modelo ${modelo.tipo}`);
  console.log(`Probabilidad de que el texto sea malo ${(prob * 100).toFixed(1)} %, se lee como ${prob >= modelo.umbral ? 'MALA' : 'BUENA'}`);
  const estrellas = opcion('--estrellas');
  if (estrellas) {
    console.log(notaNoCuadra(modelo, prob, Number(estrellas))
      ? `SENAL: ${estrellas} estrellas no cuadran con lo que dice el texto`
      : `${estrellas} estrellas cuadran con el texto`);
  }
}

main().catch((e) => { console.error(e.message); process.exit(1); });
