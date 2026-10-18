import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import type { estypes } from '@elastic/elasticsearch';
import { pool } from '../../database/postgres';
import { elasticClient } from '../../database/elastic';
import { obtenerIdTienda } from '../../helpers/cuenta-tienda';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';
import {
  validarIdProducto,
  validarIdProductoVariante,
} from '../../helpers/validaciones-inventario';
import {
  exigirAusente,
  validarFiltroEstadoSeguimiento,
  validarFiltroNoLeidos,
  validarIdSeguimiento,
  validarLeido,
  validarPrecioSeguimiento,
  validarSoloTienda,
  validarTextoSeguimiento,
  validarTipoSeguimiento,
} from '../../helpers/validaciones-seguimiento';
import type {
  AvisoSeguimientoOferta,
  AvisosSeguimiento,
  CrearSeguimientoPeticion,
  ListarAvisosQuery,
  ListarSeguimientosQuery,
  SeguimientoOferta,
} from '../../dto/seguimientos-oferta';

export const INDICE_SEGUIMIENTOS =
  process.env.ELASTIC_INDICE_SEGUIMIENTOS ?? 'mesh_seguimientos';

/** Cuantos seguimientos vivos (sin cumplir) puede tener un comprador a la vez. */
const MAXIMO_SEGUIMIENTOS_VIVOS = 20;

/** Cuantos avisos devuelve la lista (los mas nuevos). */
const MAXIMO_AVISOS = 50;

/** Lo que hace falta para guardar un seguimiento, ya validado. */
interface NuevoSeguimiento {
  tipo: string;
  texto: string | null;
  precioMaximo: string | null;
  idProducto: number | null;
  idProductoVariante: number | null;
  precioReferencia: string | null;
  soloTienda: boolean;
}

/** Una fila de `seguimiento_oferta` con los nombres del catalogo. */
interface FilaSeguimiento {
  id_seguimiento: string;
  tipo: string;
  texto: string | null;
  precio_maximo: string | null;
  id_producto_mongo: string | null;
  id_producto_variante_mongo: string | null;
  nombre_producto: string | null;
  nombre_variante: string | null;
  precio_referencia: string | null;
  solo_tienda: boolean;
  fecha_creacion: Date;
  fecha_cumplido: Date | null;
  id_aviso: string | null;
}

interface FilaAviso {
  id_aviso: string;
  fecha_aviso: Date;
  fecha_leida: Date | null;
  precio_final_aviso: string;
  id_seguimiento: string;
  tipo: string;
  texto: string | null;
  precio_maximo: string | null;
  precio_referencia: string | null;
  solo_tienda: boolean;
  id_oferta: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  nombre_producto: string | null;
  nombre_variante: string | null;
  vendedor_usuario: string;
  precio_final: string;
  stock: number;
  estado: string;
}

/**
 * Los seguimientos del comprador (/comprador/seguimientos): "avisame cuando
 * llegue" (`busqueda`, con o sin precio maximo) y "avisame cuando baje"
 * (`baja_precio`, de la tienda o de cualquier vendedor). Ver
 * `elementos Generales/plan pendiente/seguimiento-ofertas.md`.
 *
 * Cada seguimiento vive en PostgreSQL (`seguimiento_oferta`, la fuente de
 * verdad) y, mientras no se cumple, como una consulta guardada en el
 * percolator `mesh_seguimientos`. Quien lo cumple es
 * `PercolarSeguimientosService`, desde el worker de ofertas: este servicio
 * solo crea, lista, borra y marca avisos.
 *
 * Crear y borrar tocan las dos bases: PostgreSQL primero (sin COMMIT),
 * despues Elasticsearch, despues COMMIT -- el mismo orden que
 * `escribirConCatalogoPostgres`. Si Elasticsearch falla, se hace ROLLBACK y
 * no queda nada a medias; si el COMMIT falla al crear, se borra la consulta
 * de Elasticsearch (compensacion).
 */
@Injectable()
export class SeguimientosOfertaService {
  private readonly logger = new Logger(SeguimientosOfertaService.name);

  async crear(
    idUsuario: string,
    cuerpo: CrearSeguimientoPeticion,
  ): Promise<SeguimientoOferta> {
    const nuevo = this.validarNuevo(cuerpo ?? {});

    let idTienda: string | null = null;
    if (nuevo.tipo === 'baja_precio' && nuevo.soloTienda) {
      idTienda = await obtenerIdTienda(this.logger);
    }
    if (nuevo.tipo === 'baja_precio') {
      await this.exigirVariante(nuevo.idProducto!, nuevo.idProductoVariante!);
      nuevo.precioReferencia ??= await this.precioMasBajo(nuevo, idTienda);
    }

    const cliente = await this.conectar();
    let idSeguimiento: string;
    try {
      try {
        await cliente.query('BEGIN');
        await this.exigirCupo(cliente, idUsuario);
        idSeguimiento = await this.insertar(cliente, idUsuario, nuevo);
      } catch (error) {
        await cliente.query('ROLLBACK').catch(() => undefined);
        this.lanzarDuplicado(error, nuevo.tipo);
        manejarErrorConexion(this.logger, error);
      }

      try {
        await elasticClient.index({
          index: INDICE_SEGUIMIENTOS,
          id: idSeguimiento,
          document: {
            id_seguimiento: Number(idSeguimiento),
            id_usuario: Number(idUsuario),
            tipo_seguimiento: nuevo.tipo,
            consulta: consultaDelSeguimiento(nuevo, idTienda),
          },
        });
      } catch (error) {
        await cliente.query('ROLLBACK').catch(() => undefined);
        manejarErrorConexionElastic(this.logger, error);
      }

      try {
        await cliente.query('COMMIT');
      } catch (error) {
        await this.quitarDelPercolator(idSeguimiento).catch((e: unknown) =>
          this.logger.error(
            `No se pudo compensar el seguimiento ${idSeguimiento} en Elasticsearch: ${e instanceof Error ? e.message : String(e)}`,
          ),
        );
        manejarErrorConexion(this.logger, error);
      }
    } finally {
      cliente.release();
    }

    const [seguimiento] = await this.consultar(idUsuario, null, idSeguimiento);
    return seguimiento;
  }

  async listar(
    idUsuario: string,
    query: ListarSeguimientosQuery,
  ): Promise<SeguimientoOferta[]> {
    const estado = validarFiltroEstadoSeguimiento(query.estado);
    return this.consultar(idUsuario, estado, null);
  }

  /**
   * Borra un seguimiento propio, vivo o cumplido (el aviso se va con el, por
   * el CASCADE). Uno vivo sale tambien del percolator; uno cumplido ya no
   * estaba ahi.
   */
  async borrar(idUsuario: string, id: string): Promise<void> {
    const idSeguimiento = validarIdSeguimiento(id);
    const cliente = await this.conectar();
    try {
      let vivo: boolean;
      try {
        await cliente.query('BEGIN');
        const { rows } = await cliente.query<{ vivo: boolean }>(
          `DELETE FROM seguimiento_oferta
            WHERE id_seguimiento = $1 AND id_usuario = $2
        RETURNING fecha_cumplido IS NULL AS vivo`,
          [idSeguimiento, idUsuario],
        );
        if (rows.length === 0) {
          throw new ErrorNoEncontrado('No existe un seguimiento con ese id');
        }
        vivo = rows[0].vivo;
      } catch (error) {
        await cliente.query('ROLLBACK').catch(() => undefined);
        manejarErrorConexion(this.logger, error);
      }

      if (vivo) {
        try {
          await this.quitarDelPercolator(idSeguimiento);
        } catch (error) {
          await cliente.query('ROLLBACK').catch(() => undefined);
          manejarErrorConexionElastic(this.logger, error);
        }
      }

      try {
        await cliente.query('COMMIT');
      } catch (error) {
        // La consulta ya salio del percolator y la fila sigue: el
        // seguimiento queda mudo (no avisara), y se puede volver a borrar.
        manejarErrorConexion(this.logger, error);
      }
    } finally {
      cliente.release();
    }
  }

  async listarAvisos(
    idUsuario: string,
    query: ListarAvisosQuery,
  ): Promise<AvisosSeguimiento> {
    const soloNoLeidos = validarFiltroNoLeidos(query.no_leidos);
    try {
      const { rows } = await pool.query<FilaAviso>(
        `SELECT a.id_aviso, a.fecha_aviso, a.fecha_leida,
                a.precio_final::text AS precio_final_aviso,
                s.id_seguimiento, t.tipo_seguimiento_oferta_nombre AS tipo,
                s.texto, s.precio_maximo, s.precio_referencia, s.solo_tienda,
                o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                pc.nombre AS nombre_producto, vc.nombre_variante,
                u.usuario AS vendedor_usuario,
                ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, eo.estado_oferta_nombre AS estado
           FROM aviso_seguimiento_oferta a
           JOIN seguimiento_oferta s ON s.id_seguimiento = a.id_seguimiento
           JOIN tipo_seguimiento_oferta t
             ON t.id_tipo_seguimiento_oferta = s.id_tipo_seguimiento_oferta
           JOIN oferta o ON o.id_oferta = a.id_oferta
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
           JOIN usuarios u ON u.id_usuario = o.id_usuario
           LEFT JOIN producto_catalogo pc
                  ON pc.id_producto_mongo = o.id_producto_mongo
           LEFT JOIN variante_catalogo vc
                  ON vc.id_producto_mongo = o.id_producto_mongo
                 AND vc.id_producto_variante_mongo = o.id_producto_variante_mongo
          WHERE s.id_usuario = $1
            AND (NOT $2 OR a.fecha_leida IS NULL)
          ORDER BY a.fecha_aviso DESC, a.id_aviso DESC
          LIMIT $3`,
        [idUsuario, soloNoLeidos, MAXIMO_AVISOS],
      );
      const conteo = await pool.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM aviso_seguimiento_oferta a
           JOIN seguimiento_oferta s ON s.id_seguimiento = a.id_seguimiento
          WHERE s.id_usuario = $1 AND a.fecha_leida IS NULL`,
        [idUsuario],
      );
      return {
        avisos: rows.map(aAviso),
        total_no_leidos: Number(conteo.rows[0].total),
      };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** Leido pone la fecha de ahora; no leido la vuelve a dejar en NULL. */
  async marcarAviso(
    idUsuario: string,
    id: string,
    cuerpo: { leido?: unknown },
  ): Promise<{ id_aviso: string; leido: boolean }> {
    const idAviso = validarIdSeguimiento(id);
    const leido = validarLeido(cuerpo?.leido);
    try {
      const { rowCount } = await pool.query(
        `UPDATE aviso_seguimiento_oferta a
            SET fecha_leida = CASE WHEN $3 THEN COALESCE(a.fecha_leida, now()) END
           FROM seguimiento_oferta s
          WHERE a.id_aviso = $1
            AND s.id_seguimiento = a.id_seguimiento
            AND s.id_usuario = $2`,
        [idAviso, idUsuario, leido],
      );
      if (rowCount === 0) {
        throw new ErrorNoEncontrado('No existe un aviso con ese id');
      }
      return { id_aviso: idAviso, leido };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private validarNuevo(cuerpo: CrearSeguimientoPeticion): NuevoSeguimiento {
    const tipo = validarTipoSeguimiento(cuerpo.tipo);
    if (tipo === 'busqueda') {
      exigirAusente(cuerpo.id_producto, 'id_producto', tipo);
      exigirAusente(cuerpo.id_producto_variante, 'id_producto_variante', tipo);
      exigirAusente(cuerpo.solo_tienda, 'solo_tienda', tipo);
      exigirAusente(cuerpo.precio_referencia, 'precio_referencia', tipo);
      return {
        tipo,
        texto: validarTextoSeguimiento(cuerpo.texto),
        precioMaximo: validarPrecioSeguimiento(
          cuerpo.precio_maximo,
          'precio_maximo',
        ),
        idProducto: null,
        idProductoVariante: null,
        precioReferencia: null,
        soloTienda: false,
      };
    }
    exigirAusente(cuerpo.texto, 'texto', tipo);
    exigirAusente(cuerpo.precio_maximo, 'precio_maximo', tipo);
    return {
      tipo,
      texto: null,
      precioMaximo: null,
      idProducto: validarIdProducto(cuerpo.id_producto),
      idProductoVariante: validarIdProductoVariante(
        cuerpo.id_producto_variante,
      ),
      precioReferencia: validarPrecioSeguimiento(
        cuerpo.precio_referencia,
        'precio_referencia',
      ),
      soloTienda: validarSoloTienda(cuerpo.solo_tienda),
    };
  }

  private async conectar(): Promise<PoolClient> {
    try {
      return await pool.connect();
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async exigirVariante(
    idProducto: number,
    idProductoVariante: number,
  ): Promise<void> {
    try {
      const { rowCount } = await pool.query(
        `SELECT 1 FROM variante_catalogo
          WHERE id_producto_mongo = $1 AND id_producto_variante_mongo = $2`,
        [idProducto, idProductoVariante],
      );
      if (rowCount === 0) {
        throw new ErrorNoEncontrado('No existe esa variante del producto');
      }
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * El precio final mas bajo de la variante ahora mismo, entre las ofertas
   * que se pueden comprar (activas y con stock), de la tienda si
   * `solo_tienda`. Es el `precio_referencia` cuando el comprador no pone uno.
   */
  private async precioMasBajo(
    nuevo: NuevoSeguimiento,
    idTienda: string | null,
  ): Promise<string> {
    let minimo: string | null;
    try {
      const { rows } = await pool.query<{ minimo: string | null }>(
        `SELECT min(${expresionPrecioFinal('o')})::text AS minimo
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
          WHERE o.id_producto_mongo = $1
            AND o.id_producto_variante_mongo = $2
            AND eo.estado_oferta_nombre = 'activa'
            AND o.stock > 0
            AND ($3::bigint IS NULL OR o.id_usuario = $3)`,
        [nuevo.idProducto, nuevo.idProductoVariante, idTienda],
      );
      minimo = rows[0]?.minimo ?? null;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    if (minimo == null || Number(minimo) <= 0) {
      throw new ErrorValidacion(
        nuevo.soloTienda
          ? 'La tienda no tiene una oferta activa de esa variante: indica precio_referencia'
          : 'No hay ofertas activas de esa variante: indica precio_referencia',
      );
    }
    return minimo;
  }

  private async exigirCupo(cliente: PoolClient, idUsuario: string) {
    const { rows } = await cliente.query<{ vivos: string }>(
      `SELECT count(*) AS vivos FROM seguimiento_oferta
        WHERE id_usuario = $1 AND fecha_cumplido IS NULL`,
      [idUsuario],
    );
    if (Number(rows[0].vivos) >= MAXIMO_SEGUIMIENTOS_VIVOS) {
      throw new ErrorConflicto(
        `Ya tienes ${MAXIMO_SEGUIMIENTOS_VIVOS} seguimientos activos: borra alguno para crear otro`,
      );
    }
  }

  private async insertar(
    cliente: PoolClient,
    idUsuario: string,
    nuevo: NuevoSeguimiento,
  ): Promise<string> {
    const { rows } = await cliente.query<{ id_seguimiento: string }>(
      `INSERT INTO seguimiento_oferta
              (id_usuario, id_tipo_seguimiento_oferta, texto, precio_maximo,
               id_producto_mongo, id_producto_variante_mongo,
               precio_referencia, solo_tienda)
       SELECT $1, t.id_tipo_seguimiento_oferta, $3, $4, $5, $6, $7, $8
         FROM tipo_seguimiento_oferta t
        WHERE t.tipo_seguimiento_oferta_nombre = $2
    RETURNING id_seguimiento`,
      [
        idUsuario,
        nuevo.tipo,
        nuevo.texto,
        nuevo.precioMaximo,
        nuevo.idProducto,
        nuevo.idProductoVariante,
        nuevo.precioReferencia,
        nuevo.soloTienda,
      ],
    );
    if (rows.length === 0) {
      throw new Error(`No existe el tipo de seguimiento ${nuevo.tipo}`);
    }
    return rows[0].id_seguimiento;
  }

  /** 23505 en uno de los dos indices unicos de seguimientos vivos: ya lo sigue. */
  private lanzarDuplicado(error: unknown, tipo: string): void {
    if ((error as { code?: string } | null)?.code === '23505') {
      throw new ErrorConflicto(
        tipo === 'busqueda'
          ? 'Ya sigues esa busqueda'
          : 'Ya sigues el precio de esa variante',
      );
    }
  }

  private async quitarDelPercolator(idSeguimiento: string): Promise<void> {
    await elasticClient.delete(
      { index: INDICE_SEGUIMIENTOS, id: idSeguimiento },
      { ignore: [404] },
    );
  }

  private async consultar(
    idUsuario: string,
    estado: string | null,
    idSeguimiento: string | null,
  ): Promise<SeguimientoOferta[]> {
    try {
      const { rows } = await pool.query<FilaSeguimiento>(
        `SELECT s.id_seguimiento, t.tipo_seguimiento_oferta_nombre AS tipo,
                s.texto, s.precio_maximo, s.id_producto_mongo,
                s.id_producto_variante_mongo, pc.nombre AS nombre_producto,
                vc.nombre_variante, s.precio_referencia, s.solo_tienda,
                s.fecha_creacion, s.fecha_cumplido, a.id_aviso
           FROM seguimiento_oferta s
           JOIN tipo_seguimiento_oferta t
             ON t.id_tipo_seguimiento_oferta = s.id_tipo_seguimiento_oferta
           LEFT JOIN producto_catalogo pc
                  ON pc.id_producto_mongo = s.id_producto_mongo
           LEFT JOIN variante_catalogo vc
                  ON vc.id_producto_mongo = s.id_producto_mongo
                 AND vc.id_producto_variante_mongo = s.id_producto_variante_mongo
           LEFT JOIN aviso_seguimiento_oferta a
                  ON a.id_seguimiento = s.id_seguimiento
          WHERE s.id_usuario = $1
            AND ($2::text IS NULL
                 OR ($2 = 'activos' AND s.fecha_cumplido IS NULL)
                 OR ($2 = 'cumplidos' AND s.fecha_cumplido IS NOT NULL))
            AND ($3::bigint IS NULL OR s.id_seguimiento = $3)
          ORDER BY s.fecha_creacion DESC, s.id_seguimiento DESC`,
        [idUsuario, estado, idSeguimiento],
      );
      return rows.map((fila) => ({
        id_seguimiento: fila.id_seguimiento,
        tipo: fila.tipo,
        texto: fila.texto,
        precio_maximo: fila.precio_maximo,
        id_producto: fila.id_producto_mongo,
        id_producto_variante: fila.id_producto_variante_mongo,
        nombre_producto: fila.nombre_producto,
        nombre_variante: fila.nombre_variante,
        precio_referencia: fila.precio_referencia,
        solo_tienda: fila.solo_tienda,
        fecha_creacion: fila.fecha_creacion,
        fecha_cumplido: fila.fecha_cumplido,
        id_aviso: fila.id_aviso,
      }));
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}

/**
 * La consulta que se guarda en el percolator. Corre contra el documento de
 * cada oferta que indexa el worker (los campos de `mesh_ofertas`). Las dos
 * piden lo mismo para que la oferta se pueda comprar: activa, con stock, y
 * con la variante y el vendedor activos.
 *
 *   - `busqueda`: TODAS las palabras del texto (`operator: and`, si no
 *     "laptop gamer" avisaria con cualquier laptop), difusa, sobre
 *     `nombre_completo` (producto + variante juntos, ver
 *     `plan pendiente/seguimientos-indice.json`). Con precio maximo, que el
 *     precio final no lo pase.
 *   - `baja_precio`: esa variante, con precio final ESTRICTAMENTE menor que
 *     la referencia. Con `solo_tienda`, solo la oferta de la tienda.
 */
function consultaDelSeguimiento(
  nuevo: NuevoSeguimiento,
  idTienda: string | null,
): estypes.QueryDslQueryContainer {
  const filtros: estypes.QueryDslQueryContainer[] = [
    { term: { estado: 'activa' } },
    { range: { stock: { gt: 0 } } },
    { term: { estado_variante: 'activa' } },
    { term: { estado_vendedor: 'activo' } },
  ];

  if (nuevo.tipo === 'busqueda') {
    if (nuevo.precioMaximo != null) {
      filtros.push({
        range: { precio_final: { lte: Number(nuevo.precioMaximo) } },
      });
    }
    return {
      bool: {
        must: [
          {
            match: {
              nombre_completo: {
                query: nuevo.texto!,
                operator: 'and',
                fuzziness: 'AUTO',
              },
            },
          },
        ],
        filter: filtros,
      },
    };
  }

  filtros.push(
    { term: { id_producto: nuevo.idProducto! } },
    { term: { id_producto_variante: nuevo.idProductoVariante! } },
    { range: { precio_final: { lt: Number(nuevo.precioReferencia) } } },
  );
  if (idTienda != null) {
    filtros.push({ term: { id_vendedor: Number(idTienda) } });
  }
  return { bool: { filter: filtros } };
}

function aAviso(fila: FilaAviso): AvisoSeguimientoOferta {
  return {
    id_aviso: fila.id_aviso,
    leido: fila.fecha_leida != null,
    fecha_aviso: fila.fecha_aviso,
    fecha_leida: fila.fecha_leida,
    precio_final_aviso: fila.precio_final_aviso,
    seguimiento: {
      id_seguimiento: fila.id_seguimiento,
      tipo: fila.tipo,
      texto: fila.texto,
      precio_maximo: fila.precio_maximo,
      precio_referencia: fila.precio_referencia,
      solo_tienda: fila.solo_tienda,
    },
    oferta: {
      id_oferta: fila.id_oferta,
      id_producto: fila.id_producto_mongo,
      id_producto_variante: fila.id_producto_variante_mongo,
      nombre_producto: fila.nombre_producto,
      nombre_variante: fila.nombre_variante,
      vendedor_usuario: fila.vendedor_usuario,
      precio_final: fila.precio_final,
      stock: fila.stock,
      estado: fila.estado,
    },
  };
}
