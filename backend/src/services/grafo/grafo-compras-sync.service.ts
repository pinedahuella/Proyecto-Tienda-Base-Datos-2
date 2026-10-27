import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import type { PoolClient } from 'pg';
import neo4j from 'neo4j-driver';
import { pool } from '../../database/postgres';
import { ejecutarGrafo } from '../../database/neo4j';
import { esFalloDeConexionGrafo } from '../../helpers/manejar-error-grafo';
import { idCategoriaParaGrafo } from './grafo-categorias-sync.service';

/** Los estados de pedido que cuentan como compra. `pendiente` todavia no lo
 * es y `cancelado` ya no. Lo usan tambien la conciliacion y la siembra. */
export const ESTADOS_DE_COMPRA = ['comprado', 'enviado', 'entregado'];

/** La cuenta, con lo que el grafo guarda de un `:Usuario`. */
interface FilaCuenta {
  usuario: string;
  correo: string;
  nombre: string;
  apellido: string | null;
  /** ISO 8601 UTC con microsegundos (de `to_char`), para `datetime()`. */
  alta: string;
}

/** Una linea de pedido comprada: una variante, a un vendedor. */
interface FilaCompra {
  id_compra: string;
  id_pedido: string;
  producto_id: string;
  producto_nombre: string;
  /** `producto_catalogo.id_categoria`; null si el producto no esta en la copia. */
  producto_id_categoria: string | null;
  producto_categoria: string | null;
  vendedor_id: string;
  variante_id: string;
  variante_nombre: string;
  cantidad: number;
  precio: string;
  /** ISO 8601 UTC con microsegundos, para `datetime()`. */
  fecha: string;
}

/**
 * Lleva las COMPRAS de PostgreSQL al grafo de Neo4j, con la misma forma que
 * las resenas:
 *
 *   (:Usuario)-[:HIZO]->(:Compra)-[:A_VENDEDOR]->(:Usuario)
 *                       (:Compra)-[:DE]->(:Producto)
 *
 * Un nodo `:Compra` por linea de pedido (`pedido_producto`): una variante,
 * comprada a la oferta de un vendedor. La variante, la cantidad, el precio y
 * la fecha van como propiedades; el centro es el `:Producto`, el mismo de las
 * resenas (`GrafoSyncService`). Con esto el grafo responde "quienes compraron
 * lo mismo que tu, que mas compraron" (`ParaTiService`) y une compra y resena
 * de una cuenta con un vendedor. Ver
 * `elementos Generales/plan pendiente/grafo-compras.md`.
 *
 * Mismo outbox que las resenas, con la misma directiva del profesor: el
 * pedido commitea en PostgreSQL sin esperar a Neo4j, los triggers de `pedido`
 * y `pedido_producto` encolan la CUENTA en `evento_grafo_compra`, y este
 * worker la proyecta segundos despues. Por cada cuenta relee TODAS sus
 * compras y deja sus `:Compra` iguales a eso: agrega o actualiza las que hay
 * y borra las que ya no (un pedido cancelado). Todo idempotente.
 *
 * Mismo molde que `GrafoSyncService.vaciarCola()`: un evento por transaccion
 * corta con `FOR UPDATE SKIP LOCKED`; un dato torcido suma un intento y a los
 * `MAX_INTENTOS` queda apartado; un fallo de conexion corta la corrida sin
 * gastar intentos. La conciliacion (`GrafoSyncService.conciliar()`) compara
 * las relaciones de las dos bases.
 */
@Injectable()
export class GrafoComprasSyncService {
  private readonly logger = new Logger(GrafoComprasSyncService.name);

  private static readonly INTERVALO_MS = 10000;

  /** Tope de eventos por corrida: si hay mas, siguen en la proxima. */
  private static readonly MAX_POR_CORRIDA = 500;

  /** Reintentos antes de apartar un evento envenenado (dato torcido). */
  static readonly MAX_INTENTOS = 5;

  /** Cada cuantas corridas se poda lo ya procesado (~1 h con 10 s de intervalo). */
  private static readonly PODA_CADA = 360;

  /** Se descarta lo procesado con mas de estos dias. */
  private static readonly RETENCION_DIAS = 7;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  /** Cuenta corridas para decidir cuando podar. */
  private corridas = 0;

  /** Para no repetir el aviso de "la tabla no existe" en cada corrida. */
  private avisoTablaAusente = false;

  @Interval('grafo-compras', GrafoComprasSyncService.INTERVALO_MS)
  async vaciarCola(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    let cliente: PoolClient | null = null;
    try {
      cliente = await pool.connect();

      let aplicados = 0;
      for (let i = 0; i < GrafoComprasSyncService.MAX_POR_CORRIDA; i++) {
        if (!(await this.procesarUnEvento(cliente))) {
          break;
        }
        aplicados++;
      }
      if (aplicados > 0) {
        this.logger.log(
          `worker de compras del grafo: ${aplicados} cuenta(s) proyectadas`,
        );
      }

      if (this.corridas++ % GrafoComprasSyncService.PODA_CADA === 0) {
        await this.podar(cliente);
      }
    } catch (error) {
      if ((error as { code?: string })?.code === '42P01') {
        // Falta la migracion de `evento_grafo_compra`: se avisa una vez.
        if (!this.avisoTablaAusente) {
          this.logger.warn(
            'worker de compras del grafo: la tabla evento_grafo_compra no existe todavia. El worker queda inactivo hasta que exista.',
          );
          this.avisoTablaAusente = true;
        }
        return;
      }
      // Neo4j o PostgreSQL caidos: lo pendiente se reintenta en la proxima.
      this.logger.warn(
        `worker de compras del grafo: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      cliente?.release();
      this.procesando = false;
    }
  }

  /** Procesa el evento pendiente mas viejo. `false` si la cola esta vacia. */
  private async procesarUnEvento(cliente: PoolClient): Promise<boolean> {
    await cliente.query('BEGIN');
    try {
      const { rows } = await cliente.query<{
        id_evento: string;
        id_usuario: string;
      }>(
        `SELECT id_evento, id_usuario
           FROM evento_grafo_compra
          WHERE procesado_en IS NULL AND intentos < $1
          ORDER BY id_evento
          LIMIT 1
          FOR UPDATE SKIP LOCKED`,
        [GrafoComprasSyncService.MAX_INTENTOS],
      );
      if (rows.length === 0) {
        await cliente.query('ROLLBACK');
        return false;
      }

      const { id_evento, id_usuario } = rows[0];
      try {
        await this.proyectarCompras(cliente, id_usuario);
        await cliente.query(
          `UPDATE evento_grafo_compra SET procesado_en = now() WHERE id_evento = $1`,
          [id_evento],
        );
        await cliente.query('COMMIT');
        return true;
      } catch (error) {
        await cliente.query('ROLLBACK');
        if (esFalloDeConexionGrafo(error)) {
          throw error;
        }
        // Dato torcido: culpa del evento. Suma un intento y se sigue.
        await cliente.query(
          `UPDATE evento_grafo_compra
              SET intentos = intentos + 1, ultimo_error = $2
            WHERE id_evento = $1`,
          [id_evento, mensajeCorto(error)],
        );
        this.logger.warn(
          `evento ${id_evento} (compras de la cuenta ${id_usuario}): ${mensajeCorto(error)}`,
        );
        return true;
      }
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      throw error;
    }
  }

  /**
   * Deja las `:Compra` de la cuenta iguales a sus compras en PostgreSQL. Sin
   * compras (todo cancelado, o la cuenta ya no existe) se le borran todas, sin
   * crear el nodo de la cuenta si no estaba.
   */
  private async proyectarCompras(
    cliente: PoolClient,
    idUsuario: string,
  ): Promise<void> {
    const { rows: cuentas } = await cliente.query<FilaCuenta>(SQL_CUENTA, [
      idUsuario,
    ]);
    const { rows: compras } = await cliente.query<FilaCompra>(SQL_COMPRAS, [
      idUsuario,
      ESTADOS_DE_COMPRA,
    ]);
    const id = neo4j.int(idUsuario);

    if (cuentas.length === 0 || compras.length === 0) {
      await ejecutarGrafo(
        'MATCH (:Usuario {id: $id})-[:HIZO]->(c:Compra) DETACH DELETE c',
        { id },
      );
      return;
    }

    const cuenta = cuentas[0];
    await ejecutarGrafo(CYPHER_PROYECTAR_COMPRAS, {
      id,
      usuario: cuenta.usuario,
      correo: cuenta.correo,
      nombre: cuenta.nombre,
      apellido: cuenta.apellido,
      alta: cuenta.alta,
      ids_compra: compras.map((c) => neo4j.int(c.id_compra)),
      compras: compras.map((c) => ({
        id: neo4j.int(c.id_compra),
        id_pedido: neo4j.int(c.id_pedido),
        producto_id: neo4j.int(c.producto_id),
        producto_nombre: c.producto_nombre,
        producto_id_categoria: idCategoriaParaGrafo(c.producto_id_categoria),
        producto_categoria: c.producto_categoria,
        vendedor_id: neo4j.int(c.vendedor_id),
        variante_id: neo4j.int(c.variante_id),
        variante_nombre: c.variante_nombre,
        cantidad: neo4j.int(c.cantidad),
        precio: Number(c.precio),
        fecha: c.fecha,
      })),
    });
  }

  /** Borra lo ya procesado hace mas de `RETENCION_DIAS` dias. */
  private async podar(cliente: PoolClient): Promise<void> {
    try {
      const { rowCount } = await cliente.query(
        `DELETE FROM evento_grafo_compra
          WHERE procesado_en IS NOT NULL
            AND procesado_en < now() - make_interval(days => $1)`,
        [GrafoComprasSyncService.RETENCION_DIAS],
      );
      if (rowCount && rowCount > 0) {
        this.logger.log(
          `worker de compras del grafo: podados ${rowCount} evento(s) viejos`,
        );
      }
    } catch (error) {
      this.logger.warn(
        `worker de compras del grafo: no se pudo podar la cola -- ${mensajeCorto(error)}`,
      );
    }
  }
}

/** Un mensaje de error corto para `ultimo_error` y el log. */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 500 ? `${texto.slice(0, 497)}...` : texto;
}

/** Las mismas propiedades de `:Usuario` que proyectan las resenas. */
const SQL_CUENTA = `
  SELECT usuario, correo_electronico AS correo, nombre, apellido,
         to_char(fecha_creacion AT TIME ZONE 'UTC',
                 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS alta
    FROM usuarios
   WHERE id_usuario = $1
`;

/**
 * Las compras de una cuenta, una fila por linea de pedido. El vendedor sale de
 * la oferta del precio cobrado. El nombre del producto con el mismo relleno
 * que las resenas (`SQL_RESENA` de `GrafoSyncService`), para que el mismo
 * `:Producto` no cambie de nombre segun quien lo proyecte.
 */
const SQL_COMPRAS = `
  SELECT pp.id_pedido_producto::text                       AS id_compra,
         pe.id_pedido::text                                AS id_pedido,
         pp.id_producto_mongo::text                        AS producto_id,
         COALESCE(p.nombre,
                  'Producto ' || pp.id_producto_mongo || ' (solo en MongoDB)')
                                                           AS producto_nombre,
         pc.id_categoria::text                             AS producto_id_categoria,
         cat.nombre                                        AS producto_categoria,
         o.id_usuario::text                                AS vendedor_id,
         pp.id_producto_variante_mongo::text               AS variante_id,
         pp.nombre_variante                                AS variante_nombre,
         pp.cantidad,
         ph.precio::text                                   AS precio,
         to_char(pe.fecha_creacion AT TIME ZONE 'UTC',
                 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')          AS fecha
    FROM pedido pe
    JOIN estado_pedido e ON e.id_estado_pedido = pe.id_estado_pedido
    JOIN pedido_producto pp ON pp.id_pedido = pe.id_pedido
    JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
    JOIN oferta o ON o.id_oferta = ph.id_oferta
    LEFT JOIN productos p ON p.id_producto = pp.id_producto_mongo
    LEFT JOIN producto_catalogo pc ON pc.id_producto_mongo = pp.id_producto_mongo
    LEFT JOIN categorias cat ON cat.id_categoria = pc.id_categoria
   WHERE pe.id_usuario = $1
     AND e.estado_pedido_nombre = ANY($2::text[])
`;

/**
 * Proyecta las compras de una cuenta en una sola sentencia: borra sus
 * `:Compra` que ya no estan (un pedido cancelado) y hace `MERGE` de las que
 * si, con su producto y su vendedor. El `WITH DISTINCT u` despues del borrado
 * vuelve a una fila por cuenta, haya borrado algo o no. Un vendedor que todavia
 * no esta en el grafo nace solo con su id; sus datos los pone la proyeccion de
 * una resena, o la de sus propias compras.
 */
const CYPHER_PROYECTAR_COMPRAS = `
MERGE (u:Usuario {id: $id})
  SET u.usuario = $usuario, u.correo = $correo, u.nombre = $nombre,
      u.apellido = $apellido, u.fecha_alta = datetime($alta)
WITH u
OPTIONAL MATCH (u)-[:HIZO]->(sobra:Compra)
  WHERE NOT sobra.id IN $ids_compra
DETACH DELETE sobra
WITH DISTINCT u
UNWIND $compras AS c
  MERGE (p:Producto {id: c.producto_id})
    SET p.nombre = c.producto_nombre,
        p.id_categoria = c.producto_id_categoria,
        p.categoria = c.producto_categoria
  MERGE (v:Usuario {id: c.vendedor_id})
  MERGE (k:Compra {id: c.id})
    SET k.id_pedido = c.id_pedido, k.id_variante = c.variante_id,
        k.variante = c.variante_nombre, k.cantidad = c.cantidad,
        k.precio = c.precio, k.fecha = datetime(c.fecha)
  MERGE (u)-[:HIZO]->(k)
  MERGE (k)-[:DE]->(p)
  MERGE (k)-[:A_VENDEDOR]->(v)
`;
