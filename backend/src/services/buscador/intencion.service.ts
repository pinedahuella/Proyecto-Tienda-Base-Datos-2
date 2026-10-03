import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { ErrorConexion, ErrorValidacion } from '../../helpers/errores';
import { pedirVectores } from '../../helpers/vectores-ollama';
import { redondear } from '../../helpers/similitud-vectores';
import {
  MotivoIntencion,
  ResultadoIntencion,
} from '../../dto/buscar-intencion';

const INDICE_PRODUCTOS = process.env.ELASTIC_INDICE ?? 'mesh_productos';
const INDICE_COMENTARIOS =
  process.env.ELASTIC_INDICE_COMENTARIOS ?? 'mesh_comentarios';

const LIMITE_DEFECTO = 10;
const LIMITE_MAXIMO = 30;

/** Igual que el tope de una resena: el modelo de embeddings ve 512 tokens. */
const LONGITUD_MAXIMA_BUSQUEDA = 250;

const CALIFICACION_MINIMA_DEFECTO = 4;

/** Coseno desde el cual algo cuenta como parecido a lo pedido. Por debajo, el
 * resultado es ruido: sin umbral, la busqueda siempre devolveria "algo".
 * Calibrados a mano con unas pocas frases (ver `buscador-intencion` en
 * `endpoints-buscador.md`), no con datos reales. El de los productos es mas
 * bajo porque el vector de una descripcion comercial da parecidos mas bajos
 * que el de una resena escrita por una persona. */
const UMBRAL_COSENO_RESENAS = 0.45;
const UMBRAL_COSENO_PRODUCTOS = 0.4;

/** Cuantas resenas y cuantos productos se piden a Elasticsearch antes de
 * juntarlos por producto. */
const CANDIDATOS_RESENAS = 100;
const CANDIDATOS_PRODUCTOS = 50;

/** Ollama tiene que contestar rapido: es una peticion de una persona esperando. */
const LIMITE_MS_OLLAMA = 8000;

interface DocumentoResena {
  id_producto: number;
  id_resena: number;
  comentario: string;
  calificacion: number;
}

interface DocumentoProducto {
  nombre: string;
  descripcion: string | null;
  estado: string;
  categoria_nombre: string | null;
  precio_desde: number | null;
  precio_tienda: number | null;
  hay_descuento: boolean;
  stock_total: number;
  resenas_promedio: number;
  resenas_total: number;
}

/** Lo que se sabe de un producto despues de mirar las resenas. */
interface CoincidenciaResenas {
  mejor: MotivoIntencion;
  total: number;
}

/**
 * La busqueda por intencion (`GET /buscador/productos/intencion`): la persona
 * dice lo que quiere lograr, con sus palabras ("mi ventana esta muy
 * solitaria"), y se le muestran productos cuyas resenas o descripcion se
 * parecen en SIGNIFICADO, aunque no compartan ninguna palabra ("decora muy
 * bien la ventana" en la resena de una maceta).
 *
 * Funciona sobre los vectores que ya viven en Elasticsearch: el de cada resena
 * (`mesh_comentarios`, `EventoComentarioSyncService`) y el de cada producto
 * (`mesh_productos`, `VectoresSyncService`). La frase se convierte en vector
 * con el mismo modelo de Ollama, y se hacen dos busquedas kNN:
 *
 * 1. Sobre las resenas (solo las raiz, de buena calificacion): la gente cuenta
 *    para que le sirvio, y esa es la forma en que se busca. Es la fuente
 *    principal, y la que dice POR QUE sale un producto (`motivo`).
 * 2. Sobre los productos activos: su nombre, categoria y descripcion.
 *
 * Se juntan por producto (el puntaje es el mejor de los dos parecidos) y solo
 * salen productos activos, igual que `GET /buscador/productos`: el filtro de
 * estado va fijo en el codigo, no depende de ningun parametro de la peticion.
 *
 * Limite conocido: el modelo (`paraphrase-multilingual`) compara frases
 * parecidas, no esta hecho para "pregunta contra documento", y los umbrales de
 * parecido (`UMBRAL_COSENO_RESENAS` y `UMBRAL_COSENO_PRODUCTOS`) se calibraron
 * con pocas frases. Va a funcionar mejor con resenas reales y variadas que con
 * datos de generador.
 */
@Injectable()
export class BuscadorIntencionService {
  private readonly logger = new Logger(BuscadorIntencionService.name);

  async buscar(
    q: string | undefined,
    limite: string | undefined,
    calificacionMinima: string | undefined,
  ): Promise<ResultadoIntencion[]> {
    const texto = this.validarTexto(q);
    const tope = this.aLimite(limite);
    const minimo = this.aCalificacionMinima(calificacionMinima);

    const vector = await this.vectorDe(texto);

    try {
      const [resenas, productos] = await Promise.all([
        this.buscarResenas(vector, minimo),
        this.buscarProductos(vector),
      ]);
      return await this.juntar(resenas, productos, tope);
    } catch (error) {
      manejarErrorConexionElastic(this.logger, error);
    }
  }

  private validarTexto(q: string | undefined): string {
    const texto = (q ?? '').trim();
    if (!texto) {
      throw new ErrorValidacion('Escribe lo que quieres lograr o buscar');
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

  private aCalificacionMinima(valor: string | undefined): number {
    if (valor == null || valor === '') {
      return CALIFICACION_MINIMA_DEFECTO;
    }
    const numero = Number(valor);
    if (!Number.isInteger(numero) || numero < 1 || numero > 5) {
      throw new ErrorValidacion(
        'La calificacion minima debe ser un numero entero de 1 a 5',
      );
    }
    return numero;
  }

  /** La frase como vector. Si Ollama no responde, es un 503: sin el vector no
   * hay busqueda posible. */
  private async vectorDe(texto: string): Promise<number[]> {
    try {
      const [vector] = await pedirVectores([texto], LIMITE_MS_OLLAMA);
      if (!Array.isArray(vector) || vector.length === 0) {
        throw new Error('Ollama no devolvio un vector');
      }
      return vector;
    } catch (error) {
      this.logger.error(error instanceof Error ? error.message : String(error));
      throw new ErrorConexion('No se pudo conectar con Ollama');
    }
  }

  /** Las resenas mas cercanas, agrupadas por producto: la mejor y cuantas. */
  private async buscarResenas(
    vector: number[],
    calificacionMinima: number,
  ): Promise<Map<number, CoincidenciaResenas>> {
    const respuesta = await elasticClient.search<DocumentoResena>({
      index: INDICE_COMENTARIOS,
      size: CANDIDATOS_RESENAS,
      _source: ['id_producto', 'id_resena', 'comentario', 'calificacion'],
      knn: {
        field: 'vector',
        query_vector: vector,
        k: CANDIDATOS_RESENAS,
        num_candidates: CANDIDATOS_RESENAS * 3,
        filter: {
          bool: {
            filter: [
              { term: { es_respuesta: false } },
              { range: { calificacion: { gte: calificacionMinima } } },
            ],
          },
        },
      },
    });

    const porProducto = new Map<number, CoincidenciaResenas>();
    // Llegan del mas cercano al mas lejano: la primera de cada producto es la mejor.
    for (const hit of respuesta.hits.hits) {
      const fuente = hit._source;
      const similitud = aCoseno(hit._score);
      if (fuente == null || similitud < UMBRAL_COSENO_RESENAS) {
        continue;
      }
      const previo = porProducto.get(fuente.id_producto);
      if (previo) {
        previo.total++;
        continue;
      }
      porProducto.set(fuente.id_producto, {
        total: 1,
        mejor: {
          id_resena: fuente.id_resena,
          calificacion: fuente.calificacion,
          comentario: fuente.comentario,
          similitud: redondear(similitud),
        },
      });
    }
    return porProducto;
  }

  /** Los productos activos mas cercanos: id, documento y parecido. */
  private async buscarProductos(
    vector: number[],
  ): Promise<Map<number, { doc: DocumentoProducto; similitud: number }>> {
    const respuesta = await elasticClient.search<DocumentoProducto>({
      index: INDICE_PRODUCTOS,
      size: CANDIDATOS_PRODUCTOS,
      knn: {
        field: 'vector',
        query_vector: vector,
        k: CANDIDATOS_PRODUCTOS,
        num_candidates: CANDIDATOS_PRODUCTOS * 4,
        // Fijo en el codigo, como en `BuscadorProductosService`: lo publico
        // nunca ve un producto que no este activo.
        filter: { term: { estado: 'activo' } },
      },
    });

    const productos = new Map<
      number,
      { doc: DocumentoProducto; similitud: number }
    >();
    for (const hit of respuesta.hits.hits) {
      const similitud = aCoseno(hit._score);
      if (hit._source == null || similitud < UMBRAL_COSENO_PRODUCTOS) {
        continue;
      }
      productos.set(Number(hit._id), { doc: hit._source, similitud });
    }
    return productos;
  }

  /** Une los dos origenes por producto, deja solo los activos y ordena. */
  private async juntar(
    resenas: Map<number, CoincidenciaResenas>,
    productos: Map<number, { doc: DocumentoProducto; similitud: number }>,
    tope: number,
  ): Promise<ResultadoIntencion[]> {
    const docs = new Map<number, DocumentoProducto>();
    for (const [id, p] of productos) {
      docs.set(id, p.doc);
    }

    // Los productos que solo salieron por una resena: su documento hay que
    // traerlo, y de paso comprobar que sigan activos.
    const faltantes = [...resenas.keys()].filter((id) => !docs.has(id));
    if (faltantes.length > 0) {
      const respuesta = await elasticClient.mget<DocumentoProducto>({
        index: INDICE_PRODUCTOS,
        ids: faltantes.map(String),
      });
      for (const doc of respuesta.docs) {
        if ('found' in doc && doc.found && doc._source?.estado === 'activo') {
          docs.set(Number(doc._id), doc._source);
        }
      }
    }

    const resultados: ResultadoIntencion[] = [];
    for (const [id, doc] of docs) {
      const deResenas = resenas.get(id);
      const deProducto = productos.get(id);
      const similitudResenas = deResenas?.mejor.similitud ?? null;
      const similitudProducto =
        deProducto == null ? null : redondear(deProducto.similitud);
      const origen: ResultadoIntencion['origen'] = [];
      if (deResenas) origen.push('resenas');
      if (deProducto) origen.push('producto');

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
        puntaje: Math.max(similitudResenas ?? 0, similitudProducto ?? 0),
        origen,
        motivo: deResenas?.mejor ?? null,
        resenas_coincidentes: deResenas?.total ?? 0,
        similitud_resenas: similitudResenas,
        similitud_producto: similitudProducto,
      });
    }

    return resultados.sort((a, b) => b.puntaje - a.puntaje).slice(0, tope);
  }
}

/** En coseno, Elasticsearch puntua `(1 + coseno) / 2`: se devuelve al coseno. */
function aCoseno(puntaje: number | null | undefined): number {
  return 2 * (puntaje ?? 0) - 1;
}
