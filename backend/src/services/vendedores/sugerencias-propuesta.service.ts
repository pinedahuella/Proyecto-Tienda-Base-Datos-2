import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { ErrorConexion, ErrorValidacion } from '../../helpers/errores';
import { pedirVectores } from '../../helpers/vectores-ollama';
import { aVectorPg, buscarCercanos } from '../../helpers/vectores-pgvector';
import { redondear } from '../../helpers/similitud-vectores';
import { esTextoNoVacio } from '../../helpers/validaciones-perfil';
import { validarNombreProducto } from '../../helpers/validaciones-crear-producto';
import {
  CategoriaSugerida,
  ProductoParecido,
  SugerenciasPropuesta,
  SugerenciasPropuestaPeticion,
} from '../../dto/sugerencias-propuesta';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';

const MAX_CATEGORIAS = 3;
const MAX_PRODUCTOS = 5;

/** Cuantos vecinos se piden antes de repartirlos entre categorias y productos. */
const CANDIDATOS = 30;

/** La descripcion puede ser larga; el modelo de vectores ve 512 tokens. Solo se
 * usan los primeros caracteres, que es donde esta lo que dice que es el producto. */
const LONGITUD_MAXIMA_DESCRIPCION_VECTOR = 1000;

/** Coseno desde el cual un producto del catalogo cuenta como parecido. Por
 * debajo es ruido: sin umbral siempre se sugeriria "algo". Calibrado a mano con
 * productos del catalogo local (ver la nota del cambio), no con datos reales. */
const UMBRAL_COSENO = 0.5;

/** Coseno desde el cual el producto es, casi seguro, el mismo que se esta
 * proponiendo. Mismo caso: calibrado a mano. */
const UMBRAL_DUPLICADO = 0.85;

/** Una categoria con menos de esta parte del parecido total de los vecinos es
 * ruido (un vecino suelto de otra categoria). La primera siempre se devuelve. */
const PUNTAJE_MINIMO_CATEGORIA = 0.25;

/** Ollama tiene que contestar rapido: es una persona esperando. */
const LIMITE_MS_OLLAMA = 8000;

/** El nombre sin mayusculas, tildes ni espacios de mas, para compararlo. */
function normalizarNombre(nombre: string): string {
  return nombre
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

/** Lo que se muestra de un producto, de su documento en `mesh_productos`. */
interface DocumentoIndice {
  nombre: string;
  estado: string;
  categoria_nombre: string | null;
  id_categoria: number | null;
  precio_tienda: number | null;
}

/** Un producto activo cercano al texto, de `vector_producto`. */
interface FilaCercana {
  id_producto_mongo: string;
  grupo: string;
  similitud: number;
}

/** Un producto del catalogo que paso el umbral de parecido. */
interface Vecino {
  id: number;
  doc: DocumentoIndice;
  grupo: string;
  similitud: number;
}

/**
 * Las sugerencias al PROPONER un producto
 * (`POST /vendedor/productos/sugerencias`): antes de enviar la propuesta, el
 * vendedor escribe el nombre (y la descripcion si ya la tiene) y se le dice:
 *
 * - en que CATEGORIA suele ir algo asi, y
 * - que productos PARECIDOS ya hay en el catalogo (para que vea si el suyo ya
 *   existe, y no proponga un duplicado).
 *
 * Usa los vectores de `vector_producto` (PostgreSQL, pgvector): el texto
 * escrito se convierte en vector con el mismo modelo de Ollama, y los productos
 * activos mas cercanos se reparten dos veces. Las categorias de esos vecinos
 * "votan", ponderadas por su parecido: la categoria que junta mas parecido es
 * la primera. Y los vecinos mismos son los productos similares, uno por grupo
 * de copias (`grupo`, igual que `SimilaresService`), con la bandera
 * `posible_duplicado` cuando el parecido es muy alto. El nombre, la categoria y
 * el precio de cada uno salen de su documento en `mesh_productos`.
 *
 * El vector del catalogo se hizo con `"nombre. Categoria X. descripcion"`; aca
 * la categoria no se conoce (es justo lo que se sugiere), asi que el texto es
 * `"nombre. descripcion"`.
 *
 * Solo mira productos activos (lo que circula). No evita que se proponga: es
 * una ayuda, la decision es de quien propone. Cualquier vendedor o admin puede
 * pedirlo, igual que `POST /vendedor/productos/propuestas`.
 *
 * Si Ollama no responde es un 503: sin vector no hay nada que sugerir, y no
 * hay un sustituto razonable (a diferencia de la busqueda hibrida).
 */
@Injectable()
export class SugerenciasPropuestaService {
  private readonly logger = new Logger(SugerenciasPropuestaService.name);

  async sugerir(
    datos: SugerenciasPropuestaPeticion,
  ): Promise<SugerenciasPropuesta> {
    const nombre = validarNombreProducto(datos?.nombre).trim();
    const nombreNormalizado = normalizarNombre(nombre);
    const descripcion = this.validarDescripcion(datos?.descripcion);

    const texto = descripcion ? `${nombre}. ${descripcion}` : nombre;
    const vector = await this.vectorDe(texto);

    // Llegan del mas cercano al mas lejano: se cortan los que no pasan el umbral.
    const cercanos = (await this.buscarCercanos(vector)).filter(
      (fila) => fila.similitud >= UMBRAL_COSENO,
    );
    const docs = await this.documentos(
      cercanos.map((fila) => Number(fila.id_producto_mongo)),
    );
    const vecinos: Vecino[] = [];
    for (const fila of cercanos) {
      const id = Number(fila.id_producto_mongo);
      const doc = docs.get(id);
      if (doc != null) {
        vecinos.push({ id, doc, grupo: fila.grupo, similitud: fila.similitud });
      }
    }

    return {
      categorias: this.categoriasDe(vecinos),
      productos_similares: this.productosDe(vecinos, nombreNormalizado),
    };
  }

  /** Los productos activos mas cercanos al texto. Si PostgreSQL falla es un 503. */
  private async buscarCercanos(vector: number[]): Promise<FilaCercana[]> {
    try {
      // `activo` fijo en el codigo: solo lo que circula.
      return await buscarCercanos<FilaCercana>(
        `SELECT id_producto_mongo, grupo, 1 - (vector <=> $1::vector) AS similitud
           FROM vector_producto
          WHERE activo
          ORDER BY vector <=> $1::vector
          LIMIT $2`,
        [aVectorPg(vector), CANDIDATOS],
        CANDIDATOS * 4,
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** Los documentos de `mesh_productos` de esos productos, solo si siguen
   * activos. Si Elasticsearch falla es un 503. */
  private async documentos(
    ids: number[],
  ): Promise<Map<number, DocumentoIndice>> {
    const docs = new Map<number, DocumentoIndice>();
    if (ids.length === 0) {
      return docs;
    }
    try {
      const respuesta = await elasticClient.mget<DocumentoIndice>({
        index: INDICE,
        ids: ids.map(String),
        _source: [
          'nombre',
          'estado',
          'categoria_nombre',
          'id_categoria',
          'precio_tienda',
        ],
      });
      for (const doc of respuesta.docs) {
        if ('found' in doc && doc.found && doc._source?.estado === 'activo') {
          docs.set(Number(doc._id), doc._source);
        }
      }
      return docs;
    } catch (error) {
      manejarErrorConexionElastic(this.logger, error);
    }
  }

  /** La descripcion es opcional: vacia es `null`. Solo se usa el principio. */
  private validarDescripcion(valor: unknown): string | null {
    if (valor == null || valor === '') {
      return null;
    }
    if (!esTextoNoVacio(valor)) {
      throw new ErrorValidacion('La descripcion debe ser un texto');
    }
    return valor.trim().slice(0, LONGITUD_MAXIMA_DESCRIPCION_VECTOR);
  }

  /** El texto como vector. Si Ollama no responde es un 503. */
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

  /** Cada vecino vota por su categoria con su parecido; gana la que mas junta. */
  private categoriasDe(vecinos: Vecino[]): CategoriaSugerida[] {
    const porCategoria = new Map<
      number,
      { nombre: string; suma: number; cuenta: number; mejor: number }
    >();
    let total = 0;
    for (const { doc, similitud } of vecinos) {
      if (doc.id_categoria == null) {
        continue;
      }
      total += similitud;
      const previo = porCategoria.get(doc.id_categoria) ?? {
        nombre: doc.categoria_nombre ?? '',
        suma: 0,
        cuenta: 0,
        mejor: 0,
      };
      previo.suma += similitud;
      previo.cuenta++;
      previo.mejor = Math.max(previo.mejor, similitud);
      porCategoria.set(doc.id_categoria, previo);
    }

    return [...porCategoria.entries()]
      .map(([id, c]) => ({
        id_categoria: id,
        nombre: c.nombre,
        puntaje: redondear(c.suma / total),
        productos_parecidos: c.cuenta,
        mejor_similitud: redondear(c.mejor),
      }))
      .sort((a, b) => b.puntaje - a.puntaje)
      .filter((c, i) => i === 0 || c.puntaje >= PUNTAJE_MINIMO_CATEGORIA)
      .slice(0, MAX_CATEGORIAS);
  }

  /** Los vecinos mas cercanos, uno por grupo de copias. */
  private productosDe(
    vecinos: Vecino[],
    nombreNormalizado: string,
  ): ProductoParecido[] {
    const vistos = new Set<string>();
    const productos: ProductoParecido[] = [];
    for (const { id, doc, grupo, similitud } of vecinos) {
      if (vistos.has(grupo)) {
        continue;
      }
      vistos.add(grupo);
      productos.push({
        id_producto: id,
        nombre: doc.nombre,
        id_categoria: doc.id_categoria ?? null,
        categoria: doc.categoria_nombre ?? null,
        precio_tienda: doc.precio_tienda ?? null,
        similitud: redondear(similitud),
        // Mismo nombre (sin mayusculas ni tildes) o casi el mismo texto. El
        // nombre solo da ~0.80 de coseno contra el producto idéntico, porque el
        // vector del catalogo lleva tambien categoria y descripcion: por eso el
        // nombre igual cuenta aparte.
        posible_duplicado:
          similitud >= UMBRAL_DUPLICADO ||
          normalizarNombre(doc.nombre) === nombreNormalizado,
      });
      if (productos.length === MAX_PRODUCTOS) {
        break;
      }
    }
    return productos;
  }
}
