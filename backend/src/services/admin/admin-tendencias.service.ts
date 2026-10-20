import { Injectable, Logger } from '@nestjs/common';
import { clickhouse } from '../../database/clickhouse';
import { productosPorIds } from '../../helpers/catalogo-respaldo';
import { manejarErrorClickHouse } from '../../helpers/manejar-error-clickhouse';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import {
  validarDiasEvento,
  validarLimiteEvento,
  validarDireccionEvento,
} from '../../helpers/validaciones-eventos';
import type { ConsultarTendenciasQuery } from '../../dto/consultar-tendencias';
import type {
  TendenciaProducto,
  TendenciaTermino,
} from '../../models/tendencia-evento';
import { Producto } from '../../models/producto';

/**
 * `GET /admin/eventos/*` -- el ranking de tendencias de cada tabla de
 * ClickHouse (`elementos Generales/plan pendiente/eventos-clickhouse.md`),
 * en una ventana de dias hacia atras. Reemplaza a la version anterior
 * (filas crudas ordenadas por fecha, sin agrupar): esta SI agrega, por
 * `id_producto` o por `termino` segun la tabla, y ordena por esa metrica --
 * los primeros M (`direccion=positivo`) o los ultimos M
 * (`direccion=negativo`).
 *
 * La metrica NO es la misma en las seis tablas -- decision explicita del
 * usuario (2026-09-18), segun que tan facil es repetir la accion:
 *
 *   - `vista_producto`, `carrito_producto` -- CUANTAS PERSONAS DISTINTAS
 *     (no cuantas veces en total): ver una ficha o agregar al carrito es
 *     una accion de bajo esfuerzo que "casi cualquiera puede hacer" varias
 *     veces, asi que lo que importa es a cuanta gente distinta le
 *     intereso, no el volumen bruto. `vista_producto` tiene columna
 *     `sesion` (puede ser anonima); `carrito_producto` no la tiene (el
 *     carrito siempre exige cuenta), asi que ahi la distincion es por
 *     `id_usuario`.
 *   - `compra_producto`, `devolucion_producto` -- CONTEO NORMAL (`sum(cantidad)`,
 *     igual que `MasVendidosSyncService`): completar una compra no es
 *     trivial ni repetible sin friccion, asi que cada unidad vendida o
 *     devuelta cuenta por lo que es, sin dividir por persona.
 *   - `busqueda_realizada`, `busqueda_clic` -- sesiones distintas, pero
 *     agrupado por `termino`, no por producto: la pregunta es que tan
 *     buscado (o cliqueado) esta un termino, no un producto especifico.
 *
 * Las cuatro que agrupan por `id_producto` hacen una SEGUNDA consulta a
 * MongoDB para traer el detalle real (nombre, precio, etc.) -- igual que
 * `MasVendidosService`, pero SIN filtrar por estado: un admin explorando
 * tendencias necesita ver un producto inactivo o ya borrado tambien, a
 * diferencia del catalogo publico. Las dos que agrupan por `termino` no
 * necesitan ninguna segunda consulta: el termino ya es toda la
 * informacion, no hay un "producto" al que pedirle nombre.
 *
 * Las seis solo cuentan `lote = 'real'` -- nunca mezclan con datos
 * sembrados, sin ningun parametro para pedir lo contrario (ver
 * `consultarRanking`).
 */
@Injectable()
export class AdminTendenciasService {
  private readonly logger = new Logger(AdminTendenciasService.name);

  async rankingVistas(
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaProducto[]> {
    return this.rankingPorProducto(
      'vista_producto',
      'count(DISTINCT sesion)',
      query,
    );
  }

  async rankingCarrito(
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaProducto[]> {
    return this.rankingPorProducto(
      'carrito_producto',
      'count(DISTINCT id_usuario)',
      query,
    );
  }

  async rankingCompras(
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaProducto[]> {
    return this.rankingPorProducto('compra_producto', 'sum(cantidad)', query);
  }

  async rankingDevoluciones(
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaProducto[]> {
    return this.rankingPorProducto(
      'devolucion_producto',
      'sum(cantidad)',
      query,
    );
  }

  async rankingBusquedas(
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaTermino[]> {
    return this.rankingPorTermino('busqueda_realizada', query);
  }

  async rankingClicsBusqueda(
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaTermino[]> {
    return this.rankingPorTermino('busqueda_clic', query);
  }

  /**
   * Las tres facetas del buscador facetado (Entrega final,
   * `elementos Generales/plan pendiente/buscador-facetado-clickhouse.md`)
   * que si tiene sentido rankear -- `disponible` queda fuera, es un si/no,
   * no un "top N". El campo `termino` del resultado, aca, no es un texto
   * buscado: es el id de categoria o la clave del rango elegido -- se
   * reusa `TendenciaTermino` para mantener el mismo shape que las seis
   * rutas hermanas, no porque el dato sea literalmente un termino.
   */
  async rankingCategoriasBuscadas(
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaTermino[]> {
    return this.rankingPorFaceta('categorias', query);
  }

  async rankingPreciosBuscados(
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaTermino[]> {
    return this.rankingPorFaceta('precios', query);
  }

  async rankingCalificacionesBuscadas(
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaTermino[]> {
    return this.rankingPorFaceta('calificaciones', query);
  }

  /**
   * El ranking por producto: agrega en ClickHouse (`tabla`/`metrica` nunca
   * salen del cliente, son las constantes que fija cada metodo publico de
   * arriba, asi que interpolarlas es segura), y completa con el detalle
   * real de MongoDB -- reordenado para que coincida con el ranking, porque
   * `$in` no respeta el orden de la lista de ids. Un id sin documento en
   * Mongo (producto borrado) sale con `producto: null`, nunca se descarta:
   * a diferencia del catalogo publico, aqui la fila en si (el total) sigue
   * siendo un dato valido aunque el producto ya no exista.
   */
  private async rankingPorProducto(
    tabla: string,
    metrica: string,
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaProducto[]> {
    const filas = await this.consultarRanking(
      tabla,
      metrica,
      'id_producto',
      query,
    );
    if (filas.length === 0) {
      return [];
    }

    const idsProducto = filas.map((fila) => Number(fila.clave));
    let productos: Producto[];
    try {
      // Sin Mongo, de la copia del catalogo en PostgreSQL.
      productos = await productosPorIds(idsProducto, { soloVisibles: false });
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }

    const productoPorId = new Map(productos.map((p) => [p._id, p]));
    return filas.map((fila) => ({
      total: Number(fila.total),
      producto: productoPorId.get(Number(fila.clave)) ?? null,
    }));
  }

  /** El ranking por termino: sin segunda consulta, el termino ya es todo el dato. */
  private async rankingPorTermino(
    tabla: string,
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaTermino[]> {
    const filas = await this.consultarRanking(
      tabla,
      'count(DISTINCT sesion)',
      'termino',
      query,
    );
    return filas.map((fila) => ({
      termino: fila.clave,
      total: Number(fila.total),
    }));
  }

  /**
   * El ranking de una faceta elegida en `busqueda_realizada` -- a
   * diferencia de `rankingPorTermino`/`rankingPorProducto`, el valor no es
   * una columna simple: `categorias`/`precios`/`calificaciones` son
   * `Array(...)`, una busqueda puede elegir varios a la vez (`?categoria=7,9`).
   * `ARRAY JOIN` desenrolla el arreglo en una fila por valor antes de
   * agrupar -- una busqueda sin esa faceta elegida tiene el arreglo vacio,
   * y `ARRAY JOIN` sobre un arreglo vacio no produce ninguna fila, asi que
   * queda fuera del conteo solo, sin necesidad de filtrar por `facetada`.
   * `columna` nunca sale del cliente (la fija cada metodo publico de
   * arriba), interpolarla es segura, mismo criterio que `tabla`/`metrica`
   * en `consultarRanking`.
   */
  private async rankingPorFaceta(
    columna: 'categorias' | 'precios' | 'calificaciones',
    query: ConsultarTendenciasQuery,
  ): Promise<TendenciaTermino[]> {
    const dias = validarDiasEvento(query.dias);
    const limite = validarLimiteEvento(query.limite);
    const direccion = validarDireccionEvento(query.direccion);

    try {
      const resultado = await clickhouse.query({
        query: `SELECT toString(valor) AS clave, count(DISTINCT sesion) AS total
                  FROM busqueda_realizada
                  ARRAY JOIN ${columna} AS valor
                 WHERE fecha >= now() - INTERVAL {dias:UInt32} DAY
                   AND lote = 'real'
                 GROUP BY valor
                 ORDER BY total ${direccion}
                 LIMIT {limite:UInt32}`,
        query_params: { dias, limite },
        format: 'JSONEachRow',
      });
      const filas = await resultado.json<{ clave: string; total: string }>();
      return filas.map((fila) => ({
        termino: fila.clave,
        total: Number(fila.total),
      }));
    } catch (error) {
      manejarErrorClickHouse(this.logger, error);
    }
  }

  /**
   * La consulta compartida: agrupa `tabla` por `columnaAgrupar`
   * (`id_producto` o `termino`), calcula `metrica` como `total`, y ordena
   * por esa metrica en la `direccion` pedida. `total` sale como STRING de
   * ClickHouse (`count`/`sum` promueven a `UInt64`, igual que
   * `MasVendidosSyncService`) -- se convierte a `number` en cada metodo
   * publico, no aqui, para que esta funcion se quede generica.
   *
   * Solo cuenta `lote = 'real'` -- sin parametro para pedir lo contrario,
   * mismo criterio que `MasVendidosSyncService`: una tendencia de admin
   * mezclada con datos sembrados por un script no es una tendencia, es un
   * numero inventado.
   */
  private async consultarRanking(
    tabla: string,
    metrica: string,
    columnaAgrupar: 'id_producto' | 'termino',
    query: ConsultarTendenciasQuery,
  ): Promise<{ clave: string; total: string }[]> {
    const dias = validarDiasEvento(query.dias);
    const limite = validarLimiteEvento(query.limite);
    const direccion = validarDireccionEvento(query.direccion);

    try {
      const resultado = await clickhouse.query({
        query: `SELECT ${columnaAgrupar} AS clave, ${metrica} AS total
                  FROM ${tabla}
                 WHERE fecha >= now() - INTERVAL {dias:UInt32} DAY
                   AND lote = 'real'
                 GROUP BY ${columnaAgrupar}
                 ORDER BY total ${direccion}
                 LIMIT {limite:UInt32}`,
        query_params: { dias, limite },
        format: 'JSONEachRow',
      });
      return await resultado.json<{ clave: string; total: string }>();
    } catch (error) {
      manejarErrorClickHouse(this.logger, error);
    }
  }
}
