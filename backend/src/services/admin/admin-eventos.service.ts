import { Injectable, Logger } from '@nestjs/common';
import { clickhouse } from '../../database/clickhouse';
import { manejarErrorClickHouse } from '../../helpers/manejar-error-clickhouse';
import type { ConsultarEventosQuery } from '../../dto/consultar-eventos';
import {
  validarDiasEvento,
  validarLimiteEvento,
  validarOrdenEvento,
} from '../../helpers/validaciones-eventos';
import type {
  FilaVistaProducto,
  FilaCarritoProducto,
  FilaCompraODevolucionProducto,
  FilaBusquedaRealizada,
  FilaBusquedaClic,
} from '../../models/evento-clickhouse';

/**
 * `GET /admin/eventos/*` -- filas CRUDAS de las seis tablas de ClickHouse
 * (`elementos Generales/plan pendiente/eventos-clickhouse.md`), en una
 * ventana de dias hacia atras. Ninguna agrega ni calcula tendencias --
 * son exploracion directa, mismo espiritu que
 * `AdminFraudeLoginController.eventosLogin` sobre Elasticsearch.
 *
 * Todas comparten la misma forma de consulta: `WHERE fecha >= now() -
 * INTERVAL {dias} DAY ORDER BY fecha {orden} LIMIT {limite}`. `dias` y
 * `limite` van por `query_params` (bind seguro de ClickHouse); `orden`
 * (`ASC`/`DESC`) se interpola directo porque ya viene fijado por
 * `validarOrdenEvento` a uno de esos dos literales -- nunca texto libre
 * del cliente.
 */
@Injectable()
export class AdminEventosService {
  private readonly logger = new Logger(AdminEventosService.name);

  async listarVistas(
    query: ConsultarEventosQuery,
  ): Promise<FilaVistaProducto[]> {
    return this.consultarTabla<FilaVistaProducto>('vista_producto', query);
  }

  async listarCarrito(
    query: ConsultarEventosQuery,
  ): Promise<FilaCarritoProducto[]> {
    return this.consultarTabla<FilaCarritoProducto>('carrito_producto', query);
  }

  async listarCompras(
    query: ConsultarEventosQuery,
  ): Promise<FilaCompraODevolucionProducto[]> {
    return this.consultarTabla<FilaCompraODevolucionProducto>(
      'compra_producto',
      query,
    );
  }

  async listarDevoluciones(
    query: ConsultarEventosQuery,
  ): Promise<FilaCompraODevolucionProducto[]> {
    return this.consultarTabla<FilaCompraODevolucionProducto>(
      'devolucion_producto',
      query,
    );
  }

  async listarBusquedas(
    query: ConsultarEventosQuery,
  ): Promise<FilaBusquedaRealizada[]> {
    return this.consultarTabla<FilaBusquedaRealizada>(
      'busqueda_realizada',
      query,
    );
  }

  async listarClicsBusqueda(
    query: ConsultarEventosQuery,
  ): Promise<FilaBusquedaClic[]> {
    return this.consultarTabla<FilaBusquedaClic>('busqueda_clic', query);
  }

  /**
   * `tabla` nunca sale del cliente -- cada metodo publico de arriba la fija
   * a un nombre literal, asi que interpolarla en el `FROM` es seguro (no es
   * un dato de la peticion, es una de seis constantes de este archivo).
   */
  private async consultarTabla<T>(
    tabla: string,
    query: ConsultarEventosQuery,
  ): Promise<T[]> {
    const dias = validarDiasEvento(query.dias);
    const limite = validarLimiteEvento(query.limite);
    const orden = validarOrdenEvento(query.orden);

    try {
      const resultado = await clickhouse.query({
        query: `SELECT * FROM ${tabla}
                 WHERE fecha >= now() - INTERVAL {dias:UInt32} DAY
                 ORDER BY fecha ${orden}
                 LIMIT {limite:UInt32}`,
        query_params: { dias, limite },
        format: 'JSONEachRow',
      });
      return await resultado.json<T>();
    } catch (error) {
      manejarErrorClickHouse(this.logger, error);
    }
  }
}
