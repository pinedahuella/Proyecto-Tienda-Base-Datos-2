import { Injectable, Logger } from '@nestjs/common';
import { elasticClient, OPCIONES_BUSQUEDA } from '../../database/elastic';
import { pool } from '../../database/postgres';
import {
  FuenteSugeridos,
  ResultadoBusquedaProducto,
} from '../../dto/buscar-productos';
import {
  DocumentoCopia,
  documentosDesdeCopia,
} from '../../helpers/buscador-respaldo';
import { pedirVectores } from '../../helpers/vectores-ollama';
import { aVectorPg, buscarCercanos } from '../../helpers/vectores-pgvector';
import { MasVendidosService } from '../productos/mas-vendidos.service';

/** Cuantos productos se sugieren. */
const CUANTOS = 6;

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';

export interface Sugeridos {
  productos: ResultadoBusquedaProducto[];
  /** `null` si ninguna fuente trajo nada. */
  desde: FuenteSugeridos | null;
}

/** Los ids de una fuente, en orden, y sus documentos si la fuente ya los trae. */
interface Candidatos {
  ids: number[];
  docs?: Map<number, DocumentoCopia>;
}

/**
 * Cuanto se espera el vector de Ollama antes de pasar a la siguiente fuente.
 * Corto a proposito: con el modelo frio (Ollama lo descarga a los 5 minutos sin
 * uso) el primer vector tarda unos 8 s, medido el 2026-10-20, y nadie tiene que
 * esperar eso por un extra. Lo mas vendido contesta al instante.
 */
const LIMITE_MS_OLLAMA = 3000;

/**
 * Lo que se ensena cuando una busqueda no encuentra nada, para que nunca salga
 * vacia: "No encontramos asdffff, pero te pueden interesar estos". Lo pidio el
 * profesor (2026-10-19): buscar una locura tiene que traer al menos un producto
 * relacionado.
 *
 * Cuatro fuentes, en orden, y se usa la primera que traiga algo:
 *
 *   1. Elasticsearch, con una consulta mas floja que la de la busqueda
 *      (`consultaSugeridos`): lo que se parece a lo escrito, aunque sea de
 *      lejos, va primero, y si nada se parece, el mismo motor ordena el
 *      catalogo por resenas y existencias. Siempre trae algo mientras haya un
 *      producto activo. El profesor lo pidio para el buscador (2026-10-19, "si
 *      estan usando Elasticsearch ... tiene que salir por lo menos un
 *      producto"), asi que lo hace Elasticsearch y no el backend por fuera.
 *   2. Sin Elasticsearch, por significado: el vector de lo escrito (Ollama)
 *      contra los vectores de los productos (pgvector), SIN el umbral de
 *      parecido que usa la busqueda hibrida. Siempre hay un mas cercano.
 *   3. Lo mas vendido (Redis, o ClickHouse en el momento si Redis no esta).
 *   4. Los productos con mas resenas de la copia del catalogo en PostgreSQL.
 *
 * Las tarjetas de la 1 salen del propio indice. Las de las otras tres, de la
 * copia del catalogo (`documentosDesdeCopia`), que no depende de
 * Elasticsearch ni de Mongo.
 *
 * Los sugeridos van APARTE de los resultados, a proposito. La busqueda sigue
 * contando 0 resultados, y asi se guarda en ClickHouse: el reporte de
 * "busquedas sin resultados" del admin (y su prueba) sigue viendo lo que la
 * gente busca y la tienda no tiene. Si los sugeridos se contaran como
 * resultados, esas busquedas desaparecerian del reporte sin avisar.
 *
 * Nunca lanza: si las tres fuentes fallan (por ejemplo PostgreSQL caido),
 * devuelve una lista vacia y la pagina ensena el aviso de siempre.
 */
@Injectable()
export class SugeridosBusquedaService {
  private readonly logger = new Logger(SugeridosBusquedaService.name);

  constructor(private readonly masVendidos: MasVendidosService) {}

  async sugerir(texto: string): Promise<Sugeridos> {
    const soloIds =
      (fuente: () => Promise<number[]>) => async (): Promise<Candidatos> => ({
        ids: await fuente(),
      });
    const fuentes: [FuenteSugeridos, () => Promise<Candidatos>][] = [
      ['elasticsearch', () => this.desdeElastic(texto)],
      ['significado', soloIds(() => this.porSignificado(texto))],
      ['mas vendido', soloIds(() => this.masVendidosIds())],
      ['mas resenados', soloIds(() => this.masResenadosIds())],
    ];
    for (const [nombre, fuente] of fuentes) {
      try {
        const { ids, docs } = await fuente();
        const productos = this.tarjetas(
          ids,
          docs ?? (await documentosDesdeCopia(ids)),
        );
        if (productos.length > 0) {
          return { productos, desde: nombre };
        }
      } catch (error) {
        this.logger.warn(
          `sugeridos para "${texto.slice(0, 60)}": sin ${nombre} (${error instanceof Error ? error.message : String(error)})`,
        );
      }
    }
    return { productos: [], desde: null };
  }

  /**
   * La fuente de Elasticsearch: los documentos del indice, en el orden de
   * `consultaSugeridos`. Con Elasticsearch caido o en la pausa de su
   * cortacircuitos falla al momento y se pasa a la siguiente fuente.
   */
  private async desdeElastic(texto: string): Promise<Candidatos> {
    const respuesta = await elasticClient.search<DocumentoCopia>(
      {
        index: INDICE,
        // Muchos mas que los que se ensenan, por las copias de lote (`tarjetas`).
        size: CUANTOS * 20,
        _source: [
          'nombre',
          'descripcion',
          'estado',
          'categoria_nombre',
          'precio_desde',
          'precio_tienda',
          'hay_descuento',
          'stock_total',
          'resenas_promedio',
          'resenas_total',
        ],
        query: consultaSugeridos(texto),
      },
      OPCIONES_BUSQUEDA,
    );
    const ids: number[] = [];
    const docs = new Map<number, DocumentoCopia>();
    for (const hit of respuesta.hits.hits) {
      if (hit._id != null && hit._source != null) {
        ids.push(Number(hit._id));
        docs.set(Number(hit._id), hit._source);
      }
    }
    return { ids, docs };
  }

  /** Los productos publicos mas cercanos por significado, sin umbral. */
  private async porSignificado(texto: string): Promise<number[]> {
    if (texto.trim() === '') {
      return [];
    }
    const [vector] = await pedirVectores([texto], LIMITE_MS_OLLAMA);
    if (!Array.isArray(vector) || vector.length === 0) {
      return [];
    }
    const filas = await buscarCercanos<{ id_producto_mongo: string }>(
      `SELECT id_producto_mongo
         FROM vector_producto
        WHERE activo
        ORDER BY vector <=> $1::vector
        LIMIT $2`,
      // Muchos mas que los que se ensenan: las copias de un lote generado
      // tienen la misma descripcion y el mismo vector, y salen todas juntas
      // (`tarjetas` deja una por producto). Con 1000 productos de 102
      // originales hay unas 10 copias por original, y 36 vecinos daban solo
      // 4 sugeridos para asdffff (2026-10-20); con 240 salen los 6.
      [aVectorPg(vector), CUANTOS * 40],
      CUANTOS * 80,
    );
    return filas.map((fila) => Number(fila.id_producto_mongo));
  }

  private async masVendidosIds(): Promise<number[]> {
    return (await this.masVendidos.obtener())
      .slice(0, CUANTOS)
      .map((t) => t._id);
  }

  private async masResenadosIds(): Promise<number[]> {
    const { rows } = await pool.query<{ id: string }>(
      `SELECT pc.id_producto_mongo AS id
         FROM producto_catalogo pc
         LEFT JOIN resena r ON r.id_producto_mongo = pc.id_producto_mongo
        WHERE pc.estado = 'activo'
        GROUP BY pc.id_producto_mongo
        ORDER BY count(r.*) DESC, pc.id_producto_mongo
        LIMIT $1`,
      [CUANTOS],
    );
    return rows.map((fila) => Number(fila.id));
  }

  /**
   * Las tarjetas de `ids`, en ese orden, solo las publicas y una por producto,
   * hasta `CUANTOS`. Los productos que genera un lote (`arrancar.ps1
   * -Productos`) son copias de los curados con la marca del lote al final del
   * nombre ("Espinilleras Muralla L1-0880"): sin juntarlas, buscar asdffff
   * sugeria tres veces las mismas espinilleras (visto en la pagina el
   * 2026-10-20). De cada grupo queda el lugar del primero que aparece, con el
   * original si tambien esta.
   */
  private tarjetas(
    ids: number[],
    docs: Map<number, DocumentoCopia>,
  ): ResultadoBusquedaProducto[] {
    const porNombre = new Map<string, ResultadoBusquedaProducto>();
    for (const id of ids) {
      const doc = docs.get(id);
      if (doc == null || doc.estado !== 'activo') {
        continue;
      }
      const base = doc.nombre.replace(MARCA_DE_LOTE, '');
      const previa = porNombre.get(base);
      if (previa != null && !(previa.nombre !== base && doc.nombre === base)) {
        continue;
      }
      if (previa == null && porNombre.size === CUANTOS) {
        continue;
      }
      porNombre.set(base, {
        id_producto: id,
        nombre: doc.nombre,
        estado: doc.estado,
        categoria: doc.categoria_nombre,
        precio_desde: doc.precio_desde,
        precio_tienda: doc.precio_tienda,
        hay_descuento: doc.hay_descuento,
        stock_total: doc.stock_total,
        resenas_promedio: doc.resenas_promedio,
        resenas_total: doc.resenas_total,
      });
    }
    return [...porNombre.values()];
  }
}

/**
 * Las marcas que ponen los dos generadores de lotes al final del nombre: " L1-0880"
 * (migrations/lote, nace en PostgreSQL) y " M7-0002" (mongo/lote, solo en Mongo).
 * Un clon de un clon lleva las dos: "... L1-0493 M77-0002".
 */
const MARCA_DE_LOTE = /(\s+[LM]\d+-\d{4})+$/;

/**
 * La consulta de los sugeridos en Elasticsearch, sobre los productos activos.
 * El texto va en un `should` y no en un `must`, asi que todos los activos
 * entran y el texto solo ordena.
 *
 *   - El texto, con `fuzziness: 2` para cualquier largo (la busqueda usa AUTO,
 *     que en una palabra de 3 a 5 letras deja 1) y tambien contra el nombre de
 *     la categoria. Pesa 10, asi que un parecido de lejos (zpatos, audifonoz)
 *     queda siempre arriba de cualquier producto que no se parezca.
 *   - Lo que el motor sabe de cada producto, sumado al puntaje: cuantas
 *     resenas tiene (log1p, para que 47 no aplaste a 12), su nota y si tiene
 *     existencias. Con un texto que no se parece a nada (asdffff, qwerty) es
 *     lo unico que ordena, y salen los mejor valorados que se pueden comprar.
 *
 * Medido el 2026-10-20 con los 1000 productos de la PC de Jose David: 7 a
 * 23 ms.
 */
export function consultaSugeridos(texto: string) {
  return {
    function_score: {
      query: {
        bool: {
          filter: [{ term: { estado: 'activo' } }],
          should: [
            {
              multi_match: {
                query: texto,
                fields: [
                  'nombre^3',
                  'descripcion',
                  'variantes',
                  'categoria_nombre',
                ],
                fuzziness: 2,
                prefix_length: 0,
                boost: 10,
              },
            },
          ],
        },
      },
      functions: [
        {
          field_value_factor: {
            field: 'resenas_total',
            modifier: 'log1p' as const,
            missing: 0,
          },
        },
        {
          field_value_factor: {
            field: 'resenas_promedio',
            factor: 0.2,
            missing: 0,
          },
        },
        { filter: { range: { stock_total: { gt: 0 } } }, weight: 1 },
      ],
      score_mode: 'sum' as const,
      boost_mode: 'sum' as const,
    },
  };
}
