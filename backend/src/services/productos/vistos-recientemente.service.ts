import { Injectable, Logger } from '@nestjs/common';
import { clickhouse } from '../../database/clickhouse';
import { productosPorIds } from '../../helpers/catalogo-respaldo';
import { manejarErrorClickHouse } from '../../helpers/manejar-error-clickhouse';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import {
  validarDiasVentana,
  validarLimiteEvento,
} from '../../helpers/validaciones-eventos';
import type { ConsultarVistosRecientementeQuery } from '../../dto/consultar-vistos-recientemente';
import type { ProductoVistoRecientemente } from '../../models/producto-visto-recientemente';
import { Producto } from '../../models/producto';

interface FilaVistoRecientemente {
  id_producto: string;
  ultima_vista: string;
  veces: string;
  ya_comprado: 0 | 1;
}

/**
 * `GET /productos/vistos-recientemente` -- R1 de la propuesta del
 * companero (`docs/fraude-entrega3/03-consultas-clickhouse.md`): los
 * ultimos productos distintos que la persona miro, del mas nuevo al mas
 * viejo. Controller y servicio separados (mismo criterio que
 * `MasVendidosController`/`Service`, `OfertasDestacadasController`/`Service`
 * -- cada feature del catalogo publico va aparte, aunque comparta el
 * prefijo `/productos`).
 *
 * "La persona" es su cuenta (si inicio sesion) o su `sesion` (si no) -- las
 * dos a la vez, con OR: quien mira sin cuenta y despues inicia sesion tiene
 * que seguir viendo lo de antes de entrar. `usuario = 0` es el centinela de
 * "no hay cuenta" (ningun id real es 0), igual que en el resto de eventos.
 * Sin cuenta NI `sesion`, no hay nada que mostrar -- se devuelve `[]` sin
 * gastar una consulta a ClickHouse.
 *
 * `ya_comprado` no filtra nada -- el frontend decide si lo esconde o lo
 * marca con una etiqueta.
 */
@Injectable()
export class VistosRecientementeService {
  private readonly logger = new Logger(VistosRecientementeService.name);

  async listar(
    idUsuario: string | null,
    query: ConsultarVistosRecientementeQuery,
  ): Promise<ProductoVistoRecientemente[]> {
    const usuario = idUsuario != null ? Number(idUsuario) : 0;
    const sesion = query.sesion?.trim() ?? '';
    if (usuario === 0 && sesion === '') {
      return [];
    }

    const diasHistorial = validarDiasVentana(query.dias_historial);
    const limite = validarLimiteEvento(query.limite);

    let filas: FilaVistoRecientemente[];
    try {
      const resultado = await clickhouse.query({
        query: `SELECT
                    id_producto,
                    max(fecha)                AS ultima_vista,
                    count()                    AS veces,
                    id_producto IN (
                        SELECT id_producto FROM compra_producto
                         WHERE lote = 'real' AND id_usuario = {usuario:UInt64}
                    )                          AS ya_comprado
                  FROM vista_producto
                 WHERE lote = 'real'
                   AND fecha >= now() - INTERVAL {diasHistorial:UInt32} DAY
                   AND (({usuario:UInt64} != 0 AND id_usuario = {usuario:UInt64})
                        OR sesion = {sesion:String})
                 GROUP BY id_producto
                 ORDER BY ultima_vista DESC
                 LIMIT {limite:UInt32}`,
        query_params: { usuario, sesion, diasHistorial, limite },
        format: 'JSONEachRow',
      });
      filas = await resultado.json<FilaVistoRecientemente>();
    } catch (error) {
      manejarErrorClickHouse(this.logger, error);
    }

    if (filas.length === 0) {
      return [];
    }

    const idsProducto = filas.map((fila) => Number(fila.id_producto));
    let productos: Producto[];
    try {
      // Sin Mongo, de la copia del catalogo en PostgreSQL.
      productos = await productosPorIds(idsProducto, { soloVisibles: false });
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
    const productoPorId = new Map(productos.map((p) => [p._id, p]));

    return filas.map((fila) => ({
      ultima_vista: fila.ultima_vista,
      veces: Number(fila.veces),
      ya_comprado: fila.ya_comprado === 1,
      producto: productoPorId.get(Number(fila.id_producto)) ?? null,
    }));
  }
}
