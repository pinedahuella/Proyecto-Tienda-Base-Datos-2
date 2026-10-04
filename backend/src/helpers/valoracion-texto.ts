import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Logger } from '@nestjs/common';
import { OLLAMA_MODELO } from '../database/ollama';
import { DIMENSIONES_VECTOR } from './vectores-ollama';

/**
 * La valoracion del TEXTO de una resena: dice si lo que escribio la persona
 * suena bueno o malo, sin mirar las estrellas. La hace una regresion logistica
 * entrenada aparte (`clasificador-resenas/` en la raiz del repo) y exportada a
 * un JSON de pesos (`backend/modelos/regresion_logistica.json`): aca solo se
 * hace la cuenta `sigmoide(x . w + b)` sobre el vector que ya esta en
 * `mesh_comentarios`, sin llamar otra vez a Ollama.
 *
 * Con la valoracion y las estrellas se detecta una resena CONTRADICTORIA: texto
 * malo con 4 o 5 estrellas, o texto bueno con 1 o 2 (ver
 * `NotasIncoherentesDetectorService`). El 3 nunca cuenta.
 *
 * Los pesos solo sirven para los vectores con los que se entrenaron: si cambia
 * el modelo de vectores, hay que reentrenar y volver a copiar el JSON. Por eso
 * el modelo se carga solo si coincide con `OLLAMA_MODELO` y con
 * `DIMENSIONES_VECTOR`; si no, la valoracion queda apagada y se avisa.
 */

const logger = new Logger('ValoracionTexto');

/** Una resena de menos caracteres que esto no se valora: el modelo se entreno
 * con textos largos y una frase corta no le da contexto. */
export const LARGO_MINIMO_VALORACION = 100;

export type ValoracionTexto = 'mala' | 'buena' | 'dudosa' | 'corta';

/** Lo que se lee del JSON de pesos. */
interface ArchivoModelo {
  generado: string;
  modelo_vectores: string;
  dimensiones: number;
  normalizar_l2: boolean;
  umbral_fraude: number;
  pesos: number[];
  sesgo: number;
}

export interface ModeloValoracion {
  /** Cambia si cambia el modelo, el largo minimo o los umbrales: los
   * documentos valorados con otra version se vuelven a valorar. */
  version: string;
  /** Desde esta probabilidad de "malo", el texto es `mala`. */
  umbralMala: number;
  /** Hasta esta probabilidad de "malo", el texto es `buena`. */
  umbralBuena: number;
  pesos: number[];
  sesgo: number;
}

let cargado: ModeloValoracion | null | undefined;

/**
 * El modelo, o `null` si no se pudo cargar o no es compatible con los vectores
 * de este backend. Se lee una sola vez.
 */
export function modeloValoracion(): ModeloValoracion | null {
  if (cargado !== undefined) {
    return cargado;
  }
  const ruta =
    process.env.CLASIFICADOR_MODELO ??
    join(__dirname, '..', '..', 'modelos', 'regresion_logistica.json');
  try {
    const archivo = JSON.parse(readFileSync(ruta, 'utf8')) as ArchivoModelo;
    if (
      archivo.modelo_vectores !== OLLAMA_MODELO ||
      archivo.dimensiones !== DIMENSIONES_VECTOR ||
      archivo.pesos.length !== DIMENSIONES_VECTOR
    ) {
      throw new Error(
        `se entreno para ${archivo.modelo_vectores} (${archivo.dimensiones} dimensiones) y el backend usa ${OLLAMA_MODELO} (${DIMENSIONES_VECTOR})`,
      );
    }
    cargado = {
      version: `regresion_logistica@${archivo.generado}@u${archivo.umbral_fraude}@min${LARGO_MINIMO_VALORACION}`,
      umbralMala: archivo.umbral_fraude,
      umbralBuena: 1 - archivo.umbral_fraude,
      pesos: archivo.pesos,
      sesgo: archivo.sesgo,
    };
    logger.log(`Modelo de valoracion de resenas listo (${cargado.version})`);
  } catch (error) {
    cargado = null;
    logger.warn(
      `no se pudo cargar el modelo de valoracion (${ruta}): ${error instanceof Error ? error.message : String(error)}. Las resenas no se valoran.`,
    );
  }
  return cargado;
}

/** Probabilidad (0 a 1) de que el texto sea malo. `vector` es el de Ollama. */
export function probabilidadMala(
  modelo: ModeloValoracion,
  vector: number[],
): number {
  // Largo 1, como en el entrenamiento: sin esto las probabilidades no cuadran.
  let cuadrados = 0;
  for (const x of vector) {
    cuadrados += x * x;
  }
  const largo = Math.sqrt(cuadrados);
  const divisor = largo === 0 ? 1 : largo;

  let z = modelo.sesgo;
  for (let i = 0; i < vector.length; i++) {
    z += (vector[i] / divisor) * modelo.pesos[i];
  }
  return z >= 0 ? 1 / (1 + Math.exp(-z)) : Math.exp(z) / (1 + Math.exp(z));
}

/**
 * La valoracion de una resena: `corta` si no llega al largo minimo (no se
 * mira el vector), y si no, `mala`, `buena` o `dudosa` (la franja del medio,
 * donde el modelo no esta seguro).
 */
export function valorarTexto(
  modelo: ModeloValoracion,
  texto: string,
  vector: number[],
): { valoracion: ValoracionTexto; probMala: number | null } {
  if (texto.trim().length < LARGO_MINIMO_VALORACION) {
    return { valoracion: 'corta', probMala: null };
  }
  const probMala = probabilidadMala(modelo, vector);
  const valoracion: ValoracionTexto =
    probMala >= modelo.umbralMala
      ? 'mala'
      : probMala <= modelo.umbralBuena
        ? 'buena'
        : 'dudosa';
  return { valoracion, probMala };
}
