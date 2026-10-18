import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { ErrorConexion, ErrorValidacion } from '../../helpers/errores';
import { pedirVectores } from '../../helpers/vectores-ollama';
import { aVectorPg, buscarCercanos } from '../../helpers/vectores-pgvector';
import { redondear } from '../../helpers/similitud-vectores';
import {
  MotivoIntencion,
  ResultadoIntencion,
} from '../../dto/buscar-intencion';

const INDICE_PRODUCTOS = process.env.ELASTIC_INDICE ?? 'mesh_productos';

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

/** Cuantas resenas y cuantos productos se piden antes de juntarlos por
 * producto. */
const CANDIDATOS_RESENAS = 100;
const CANDIDATOS_PRODUCTOS = 50;

/** Ollama tiene que contestar rapido: es una peticion de una persona esperando. */
const LIMITE_MS_OLLAMA = 8000;

/** Una resena cercana a lo pedido. */
interface FilaResena {
  id_producto_mongo: string;
  id_resena: string;
  comentario: string;
  calificacion: number;
  similitud: number;
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
 * Funciona sobre los vectores que ya viven en PostgreSQL (pgvector): el de cada
 * resena (`vector_comentario`, `EventoComentarioSyncService`) y el de cada
 * producto (`vector_producto`, `VectoresSyncService`). La frase se convierte en
 * vector con el mismo modelo de Ollama, y se hacen dos busquedas de vecinos:
 *
 * 1. Sobre las resenas (solo las raiz, de buena calificacion): la gente cuenta
 *    para que le sirvio, y esa es la forma en que se busca. Es la fuente
 *    principal, y la que dice POR QUE sale un producto (`motivo`).
 * 2. Sobre los productos activos: su nombre, categoria y descripcion.
 *
 * Se juntan por producto (el puntaje es el mejor de los dos parecidos) y lo que
 * se muestra de cada uno (nombre, precio, estrellas) sale de su documento en
 * `mesh_productos`, como en `GET /buscador/productos`. Solo salen productos
 * activos: el filtro de estado va fijo en el codigo, no depende de ningun
 * parametro de la peticion.
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
    const [resenas, productos] = await this.buscarCercanos(vector, minimo);

    try {
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

  /** Las dos busquedas de vecinos, a la vez. Si PostgreSQL falla es un 503. */
  private async buscarCercanos(
    vector: number[],
    calificacionMinima: number,
  ): Promise<[Map<number, CoincidenciaResenas>, Map<number, number>]> {
    try {
      const parametro = aVectorPg(vector);
      return await Promise.all([
        this.buscarResenas(parametro, calificacionMinima),
        this.buscarProductos(parametro),
      ]);
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** Las resenas mas cercanas, agrupadas por producto: la mejor y cuantas. */
  private async buscarResenas(
    vector: string,
    calificacionMinima: number,
  ): Promise<Map<number, CoincidenciaResenas>> {
    // Solo las raiz: la resena es la que lleva la calificacion.
    const filas = await buscarCercanos<FilaResena>(
      `SELECT r.id_producto_mongo, r.id_resena, c.comentario, r.calificacion,
              1 - (v.vector <=> $1::vector) AS similitud
         FROM vector_comentario v
         JOIN resena r ON r.id_comentario = v.id_comentario
         JOIN comentario c ON c.id_comentario = v.id_comentario
        WHERE r.calificacion >= $2
        ORDER BY v.vector <=> $1::vector
        LIMIT $3`,
      [vector, calificacionMinima, CANDIDATOS_RESENAS],
      CANDIDATOS_RESENAS * 3,
    );

    const porProducto = new Map<number, CoincidenciaResenas>();
    // Llegan del mas cercano al mas lejano: la primera de cada producto es la mejor.
    for (const fila of filas) {
      if (fila.similitud < UMBRAL_COSENO_RESENAS) {
        continue;
      }
      const idProducto = Number(fila.id_producto_mongo);
      const previo = porProducto.get(idProducto);
      if (previo) {
        previo.total++;
        continue;
      }
      porProducto.set(idProducto, {
        total: 1,
        mejor: {
          id_resena: Number(fila.id_resena),
          calificacion: fila.calificacion,
          comentario: fila.comentario,
          similitud: redondear(fila.similitud),
        },
      });
    }
    return porProducto;
  }

  /** Los productos activos mas cercanos: id y parecido, del mas cercano al
   * mas lejano. */
  private async buscarProductos(vector: string): Promise<Map<number, number>> {
    // `activo` fijo en el codigo, como en `BuscadorProductosService`: lo
    // publico nunca ve un producto que no este activo.
    const filas = await buscarCercanos<{
      id_producto_mongo: string;
      similitud: number;
    }>(
      `SELECT id_producto_mongo, 1 - (vector <=> $1::vector) AS similitud
         FROM vector_producto
        WHERE activo
        ORDER BY vector <=> $1::vector
        LIMIT $2`,
      [vector, CANDIDATOS_PRODUCTOS],
      CANDIDATOS_PRODUCTOS * 4,
    );

    const productos = new Map<number, number>();
    for (const fila of filas) {
      if (fila.similitud >= UMBRAL_COSENO_PRODUCTOS) {
        productos.set(Number(fila.id_producto_mongo), fila.similitud);
      }
    }
    return productos;
  }

  /** Une los dos origenes por producto, deja solo los activos y ordena. */
  private async juntar(
    resenas: Map<number, CoincidenciaResenas>,
    productos: Map<number, number>,
    tope: number,
  ): Promise<ResultadoIntencion[]> {
    // Primero los que salieron por su descripcion, luego los que solo
    // salieron por una resena. Lo que se muestra sale de su documento, que de
    // paso confirma que sigan activos.
    const ids = [
      ...productos.keys(),
      ...[...resenas.keys()].filter((id) => !productos.has(id)),
    ];
    if (ids.length === 0) {
      return [];
    }
    const respuesta = await elasticClient.mget<DocumentoProducto>({
      index: INDICE_PRODUCTOS,
      ids: ids.map(String),
    });
    const docs = new Map<number, DocumentoProducto>();
    for (const doc of respuesta.docs) {
      if ('found' in doc && doc.found && doc._source?.estado === 'activo') {
        docs.set(Number(doc._id), doc._source);
      }
    }

    const resultados: ResultadoIntencion[] = [];
    for (const [id, doc] of docs) {
      const deResenas = resenas.get(id);
      const deProducto = productos.get(id);
      const similitudResenas = deResenas?.mejor.similitud ?? null;
      const similitudProducto =
        deProducto == null ? null : redondear(deProducto);
      const origen: ResultadoIntencion['origen'] = [];
      if (deResenas) origen.push('resenas');
      if (deProducto != null) origen.push('producto');

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
