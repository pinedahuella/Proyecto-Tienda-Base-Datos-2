import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { ResultadoBusquedaProducto } from '../../dto/buscar-productos';
import { documentosDesdeCopia } from '../../helpers/buscador-respaldo';
import { pedirVectores } from '../../helpers/vectores-ollama';
import { aVectorPg, buscarCercanos } from '../../helpers/vectores-pgvector';
import { MasVendidosService } from '../productos/mas-vendidos.service';

/** Cuantos productos se sugieren. */
const CUANTOS = 6;

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
 * Tres fuentes, en orden, y se usa la primera que traiga algo:
 *
 *   1. Por significado: el vector de lo escrito (Ollama) contra los vectores
 *      de los productos (pgvector), SIN el umbral de parecido que usa la
 *      busqueda hibrida. Siempre hay un mas cercano, aunque lo escrito no
 *      tenga sentido; es el "producto relacionado" que se puede dar.
 *   2. Lo mas vendido (Redis, o ClickHouse en el momento si Redis no esta).
 *   3. Los productos con mas resenas de la copia del catalogo en PostgreSQL.
 *
 * Las tarjetas salen de la copia del catalogo (`documentosDesdeCopia`): no
 * dependen de Elasticsearch ni de Mongo.
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

  async sugerir(texto: string): Promise<ResultadoBusquedaProducto[]> {
    const fuentes: [string, () => Promise<number[]>][] = [
      ['por significado', () => this.porSignificado(texto)],
      ['lo mas vendido', () => this.masVendidosIds()],
      ['los mas resenados', () => this.masResenadosIds()],
    ];
    for (const [nombre, fuente] of fuentes) {
      try {
        const ids = await fuente();
        const sugeridos = await this.tarjetas(ids);
        if (sugeridos.length > 0) {
          return sugeridos;
        }
      } catch (error) {
        this.logger.warn(
          `sugeridos para "${texto.slice(0, 60)}": sin ${nombre} (${error instanceof Error ? error.message : String(error)})`,
        );
      }
    }
    return [];
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
      [aVectorPg(vector), CUANTOS],
      CUANTOS * 4,
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

  /** Las tarjetas de `ids`, en ese orden y solo las publicas. */
  private async tarjetas(ids: number[]): Promise<ResultadoBusquedaProducto[]> {
    const docs = await documentosDesdeCopia(ids);
    const tarjetas: ResultadoBusquedaProducto[] = [];
    for (const id of ids) {
      const doc = docs.get(id);
      if (doc == null || doc.estado !== 'activo') {
        continue;
      }
      tarjetas.push({
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
    return tarjetas;
  }
}
