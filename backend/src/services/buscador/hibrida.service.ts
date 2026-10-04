import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { ErrorValidacion } from '../../helpers/errores';
import { pedirVectores } from '../../helpers/vectores-ollama';
import { cosenoDePuntaje, redondear } from '../../helpers/similitud-vectores';
import { RespuestaHibrida, ResultadoHibrido } from '../../dto/buscar-hibrida';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';

const LIMITE_DEFECTO = 20;
const LIMITE_MAXIMO = 50;

/** El modelo de vectores ve 512 tokens; el mismo tope que la busqueda por intencion. */
const LONGITUD_MAXIMA_BUSQUEDA = 250;

/** Cuantos candidatos pide cada busqueda antes de combinarlas. */
const CANDIDATOS = 50;

/**
 * Constante de la fusion por rango (RRF, "reciprocal rank fusion"): cada
 * busqueda aporta `1 / (RRF_K + posicion)`. 60 es el valor habitual; un numero
 * mas alto reparte el peso mas parejo entre las primeras posiciones.
 */
const RRF_K = 60;

/** Coseno desde el cual un producto cuenta como parecido en significado. Por
 * debajo es ruido: sin umbral, la busqueda por significado siempre devolveria
 * "algo". El mismo valor que `BuscadorIntencionService` usa para productos,
 * calibrado a mano con pocas frases, no con datos reales. */
const UMBRAL_COSENO = 0.4;

/** Ollama tiene que contestar rapido: es una persona esperando. */
const LIMITE_MS_OLLAMA = 8000;

/** El documento de `mesh_productos`, con lo que se devuelve. */
interface DocumentoIndice {
  nombre: string;
  estado: string;
  categoria_nombre: string | null;
  precio_desde: number | null;
  precio_tienda: number | null;
  hay_descuento: boolean;
  stock_total: number;
  resenas_promedio: number;
  resenas_total: number;
}

const CAMPOS_DEVUELTOS = [
  'nombre',
  'estado',
  'categoria_nombre',
  'precio_desde',
  'precio_tienda',
  'hay_descuento',
  'stock_total',
  'resenas_promedio',
  'resenas_total',
];

/** Un candidato de una de las dos busquedas, en su posicion. */
interface Candidato {
  id: number;
  doc: DocumentoIndice;
  posicion: number;
  /** El puntaje de Elasticsearch: relevancia (texto) o coseno (significado). */
  valor: number;
}

/**
 * La busqueda HIBRIDA (`GET /buscador/productos/hibrida`): junta las dos formas
 * de buscar que ya tiene el proyecto sobre el indice `mesh_productos`.
 *
 * 1. Por PALABRAS: el `multi_match` difuso de `GET /buscador/productos`
 *    (tolera errores de tecleo, sin tildes, `nombre` pesa mas que `descripcion`
 *    y `variantes`), pero mas estricto: con una o dos palabras deben estar todas
 *    y con mas, el 70 % (`minimum_should_match`), para que una frase no se llene
 *    de coincidencias con "para" o "algo". Acierta cuando la persona escribe el
 *    nombre o algo muy cercano a el.
 * 2. Por SIGNIFICADO: la frase se convierte en vector (el mismo modelo de
 *    Ollama que usan los productos) y se buscan los productos cuyo vector esta
 *    mas cerca (kNN). Acierta cuando se describe lo que se quiere sin usar las
 *    palabras del catalogo.
 *
 * Se combinan por POSICION, no por puntaje (RRF): el puntaje de relevancia por
 * palabras y el coseno estan en escalas distintas y no se pueden sumar. Un
 * producto que sale bien en las dos sube; uno que sale en una sola se queda
 * donde la otra lo pone. Se hace en el servicio y no con el `retriever` rrf de
 * Elasticsearch porque ese es de licencia de pago.
 *
 * Solo productos activos, igual que `GET /buscador/productos`: el filtro de
 * estado va fijo en el codigo, no depende de ningun parametro de la peticion.
 *
 * Si Ollama no responde, no falla: contesta solo con la busqueda por palabras y
 * lo dice en `modo`. La busqueda principal no debe caerse porque un servicio de
 * apoyo este apagado (a diferencia de la busqueda por intencion, que sin vector
 * no tiene nada que hacer).
 *
 * Limite conocido: igual que la busqueda por intencion, el umbral de parecido
 * se calibro con pocas frases; con una sola palabra suelta el vector dice poco y
 * manda la busqueda por palabras.
 */
@Injectable()
export class BuscadorHibridoService {
  private readonly logger = new Logger(BuscadorHibridoService.name);

  async buscar(
    q: string | undefined,
    limite: string | undefined,
  ): Promise<RespuestaHibrida> {
    const texto = this.validarTexto(q);
    const tope = this.aLimite(limite);

    // Las dos empiezan a la vez; el vector solo hace falta para la segunda.
    const vectorPromesa = this.vectorDe(texto);

    try {
      const [vector, porTexto] = await Promise.all([
        vectorPromesa,
        this.buscarPorTexto(texto),
      ]);
      const porSignificado =
        vector == null ? [] : await this.buscarPorSignificado(vector);
      return {
        modo: vector == null ? 'solo_texto' : 'hibrida',
        resultados: this.combinar(porTexto, porSignificado, tope),
      };
    } catch (error) {
      manejarErrorConexionElastic(this.logger, error);
    }
  }

  private validarTexto(q: string | undefined): string {
    const texto = (q ?? '').trim();
    if (!texto) {
      throw new ErrorValidacion('Escribe lo que buscas');
    }
    if (texto.length > LONGITUD_MAXIMA_BUSQUEDA) {
      throw new ErrorValidacion(
        `La busqueda no puede tener mas de ${LONGITUD_MAXIMA_BUSQUEDA} caracteres`,
      );
    }
    return texto;
  }

  /** `limite` sin validar puede venir vacio, negativo o gigante: se acota. */
  private aLimite(valor: string | undefined): number {
    const numero = Number(valor);
    if (!Number.isFinite(numero) || numero <= 0) {
      return LIMITE_DEFECTO;
    }
    return Math.min(Math.trunc(numero), LIMITE_MAXIMO);
  }

  /** La frase como vector, o `null` si Ollama no responde (se sigue sin el). */
  private async vectorDe(texto: string): Promise<number[] | null> {
    try {
      const [vector] = await pedirVectores([texto], LIMITE_MS_OLLAMA);
      if (!Array.isArray(vector) || vector.length === 0) {
        throw new Error('Ollama no devolvio un vector');
      }
      return vector;
    } catch (error) {
      this.logger.warn(
        `busqueda hibrida: sin vector, solo texto (${error instanceof Error ? error.message : String(error)})`,
      );
      return null;
    }
  }

  private async buscarPorTexto(texto: string): Promise<Candidato[]> {
    const respuesta = await elasticClient.search<DocumentoIndice>({
      index: INDICE,
      size: CANDIDATOS,
      _source: CAMPOS_DEVUELTOS,
      query: {
        bool: {
          must: [
            {
              multi_match: {
                query: texto,
                fields: ['nombre^3', 'descripcion', 'variantes'],
                fuzziness: 'AUTO',
                // Con una o dos palabras deben estar todas; con mas, el 70 %.
                // Sin esto, una frase ("algo para escuchar musica") trae
                // cualquier producto que tenga "para" o "algo": ruido que le
                // gana a la busqueda por significado.
                minimum_should_match: '2<70%',
              },
            },
          ],
          // Fijo en el codigo: lo publico nunca ve un producto que no este activo.
          filter: [{ term: { estado: 'activo' } }],
        },
      },
    });
    return this.aCandidatos(respuesta.hits.hits, (hit) => hit._score ?? 0);
  }

  private async buscarPorSignificado(vector: number[]): Promise<Candidato[]> {
    const respuesta = await elasticClient.search<DocumentoIndice>({
      index: INDICE,
      size: CANDIDATOS,
      _source: CAMPOS_DEVUELTOS,
      knn: {
        field: 'vector',
        query_vector: vector,
        k: CANDIDATOS,
        num_candidates: CANDIDATOS * 4,
        filter: { term: { estado: 'activo' } },
      },
    });
    const candidatos = this.aCandidatos(respuesta.hits.hits, (hit) =>
      cosenoDePuntaje(hit._score),
    );
    // Llegan del mas cercano al mas lejano: se cortan los que no pasan el umbral.
    return candidatos.filter((c) => c.valor >= UMBRAL_COSENO);
  }

  private aCandidatos(
    hits: { _id?: string; _score?: number | null; _source?: DocumentoIndice }[],
    valorDe: (hit: { _score?: number | null }) => number,
  ): Candidato[] {
    const candidatos: Candidato[] = [];
    hits.forEach((hit) => {
      if (hit._source == null || hit._id == null) {
        return;
      }
      candidatos.push({
        id: Number(hit._id),
        doc: hit._source,
        posicion: candidatos.length + 1,
        valor: valorDe(hit),
      });
    });
    return candidatos;
  }

  /** RRF: cada busqueda aporta `1 / (RRF_K + posicion)`; se suman por producto. */
  private combinar(
    porTexto: Candidato[],
    porSignificado: Candidato[],
    tope: number,
  ): ResultadoHibrido[] {
    const fusionados = new Map<
      number,
      { texto?: Candidato; significado?: Candidato }
    >();
    for (const c of porTexto) {
      fusionados.set(c.id, { texto: c });
    }
    for (const c of porSignificado) {
      fusionados.set(c.id, { ...fusionados.get(c.id), significado: c });
    }

    // El maximo posible (primero en las dos) lleva el puntaje a 0..1.
    const maximo = 2 / (RRF_K + 1);
    const resultados: ResultadoHibrido[] = [];
    for (const [id, { texto, significado }] of fusionados) {
      const doc = (texto ?? significado)!.doc;
      const suma =
        (texto ? 1 / (RRF_K + texto.posicion) : 0) +
        (significado ? 1 / (RRF_K + significado.posicion) : 0);
      const origen: ResultadoHibrido['origen'] = [];
      if (texto) origen.push('texto');
      if (significado) origen.push('significado');

      resultados.push({
        id_producto: id,
        nombre: doc.nombre,
        estado: doc.estado,
        categoria: doc.categoria_nombre ?? null,
        precio_desde: doc.precio_desde ?? null,
        precio_tienda: doc.precio_tienda ?? null,
        hay_descuento: doc.hay_descuento ?? false,
        stock_total: doc.stock_total ?? 0,
        resenas_promedio: doc.resenas_promedio ?? 0,
        resenas_total: doc.resenas_total ?? 0,
        puntaje: redondear(suma / maximo),
        origen,
        posicion_texto: texto?.posicion ?? null,
        posicion_significado: significado?.posicion ?? null,
        puntaje_texto: texto == null ? null : redondear(texto.valor),
        similitud: significado == null ? null : redondear(significado.valor),
      });
    }

    return resultados.sort((a, b) => b.puntaje - a.puntaje).slice(0, tope);
  }
}
