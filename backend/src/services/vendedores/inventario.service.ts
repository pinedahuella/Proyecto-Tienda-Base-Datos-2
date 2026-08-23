import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { mongoDb } from '../../database/mongo';
import { pool } from '../../database/postgres';
import { ErrorConflicto, ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import {
  validarCantidadMovimiento,
  validarIdProductoVariante,
  validarStockInicial,
} from '../../helpers/validaciones-inventario';
import { AjustarInventarioPeticion } from '../../dto/ajustar-inventario-vendedor';
import { CrearInventarioPeticion, InventarioVariante } from '../../dto/inventario-vendedor';
import { MotivoMovimiento } from '../../models/motivo-movimiento';
import { Producto } from '../../models/producto';

/** El motivo de movimiento con el que nace un inventario reconstruido: entra mercaderia, no se vende. */
const MOTIVO_REPOSICION = 'reposicion';

/** Los unicos dos motivos que PATCH /vendedor/productos/:id/inventario admite. */
const NOMBRES_MOTIVO_AJUSTE = ['ajuste positivo', 'ajuste negativo'];

const REGEX_ID = /^\d+$/;

/**
 * Solo lo necesario de un producto para resolver su inventario: no hace
 * falta precio, imagenes ni caracteristicas para esto.
 */
interface ProductoLigero {
  _id: number;
  nombre: string;
  variantes: { id_producto_variante: number; nombre_variante: string }[];
}

/** ProductoLigero, mas el dueno: solo para el chequeo de propiedad de obtenerPropio. */
interface ProductoLigeroConDueno extends ProductoLigero {
  vendedor: { id_usuario: number };
}

interface FilaInventario {
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  stock: number;
}

/**
 * Servicio de GET /vendedor/productos/inventario,
 * GET /vendedor/productos/:id/inventario,
 * GET /vendedor/productos/inventario/motivos-ajuste,
 * POST /vendedor/productos/:id/inventario y
 * PATCH /vendedor/productos/:id/inventario.
 *
 * El stock real vive en PostgreSQL (tabla inventario), pero solo Mongo sabe
 * que productos y que variantes son del vendedor logueado. Por eso cada
 * consulta pasa por las dos bases: primero Mongo (dueno y lista de
 * variantes), despues PostgreSQL (el stock de esas variantes).
 *
 * Si una variante propia todavia no tiene fila en inventario (pendiente:
 * publicar/agregar variante hoy no la crea, ver cambios-etl-productos.md),
 * los GET no se rellenan con 0 en silencio: lanzan ErrorConflicto para que
 * el vendedor sepa que ese producto necesita que le arreglen el inventario.
 * El POST es justamente esa reconstruccion: crea la fila que falta, de una
 * variante a la vez. El PATCH es distinto: ajusta (sube o baja) el stock de
 * una variante que YA tiene inventario -- para correcciones manuales, solo
 * sobre productos propios.
 */
@Injectable()
export class InventarioVendedorService {
  private readonly logger = new Logger(InventarioVendedorService.name);

  /** El inventario real de TODOS los productos del vendedor logueado. */
  async listarPropio(idUsuario: string): Promise<InventarioVariante[]> {
    const productos = await this.obtenerTodosLosPropios(idUsuario);
    if (productos.length === 0) {
      return [];
    }

    const stockPorPar = await this.consultarInventario(
      productos.map((producto) => producto._id),
    );
    return this.combinarConInventario(productos, stockPorPar);
  }

  /** El inventario real de un solo producto propio. */
  async obtenerPropio(
    idProductoParametro: string,
    idUsuario: string,
  ): Promise<InventarioVariante[]> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    const producto = await this.obtenerUnPropio(idProducto, idUsuario);
    const stockPorPar = await this.consultarInventario([producto._id]);
    return this.combinarConInventario([producto], stockPorPar);
  }

  /**
   * Los dos motivos que PATCH /vendedor/productos/:id/inventario admite,
   * con sus ids reales de PostgreSQL, para que el frontend arme el select
   * sin tenerlos escritos a mano. No trae los otros cuatro del catalogo
   * (venta, devolucion, reposicion, merma): esos nacen de otros flujos, no
   * de un ajuste manual.
   */
  async listarMotivosAjuste(): Promise<
    Pick<MotivoMovimiento, 'id_motivo_movimiento' | 'motivo_nombre'>[]
  > {
    try {
      const resultado = await pool.query<
        Pick<MotivoMovimiento, 'id_motivo_movimiento' | 'motivo_nombre'>
      >(
        `SELECT id_motivo_movimiento, motivo_nombre
         FROM motivo_movimiento
         WHERE motivo_nombre = ANY($1)
         ORDER BY id_motivo_movimiento`,
        [NOMBRES_MOTIVO_AJUSTE],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Crea la fila de inventario de UNA variante propia, de a una (no admite
   * lote): es la reconstruccion del primer inventario para el caso que
   * los GET de arriba rechazan con ErrorConflicto.
   *
   * Si stock_inicial es mayor a 0, tambien deja su primer movimiento en
   * stock_movimiento (motivo "reposicion"), para que el libro mayor nazca
   * cuadrado con inventario.stock desde el primer dia — si fuera 0 no hay
   * nada que mover (stock_movimiento.cantidad no admite 0), asi que se
   * queda solo con la fila de inventario.
   *
   * Si la variante ya tenia inventario, se rechaza con ErrorConflicto: esta
   * ruta es solo para crearlo la primera vez, no para ajustarlo despues.
   *
   * Al terminar, tambien deja variantes[].stock al dia en el documento de
   * Mongo: es uno de los tres momentos documentados en
   * cambios-etl-productos.md en que la copia de lectura se actualiza ("al
   * publicar un producto o agregar una variante"), y este POST es
   * justamente ese momento para una variante que no lo tenia.
   */
  async crearInicial(
    idProductoParametro: string,
    idUsuario: string,
    datos: CrearInventarioPeticion,
  ): Promise<InventarioVariante> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    const idProductoVariante = validarIdProductoVariante(datos.id_producto_variante);
    const stockInicial = validarStockInicial(datos.stock_inicial);

    const producto = await this.obtenerUnPropio(idProducto, idUsuario);
    const variante = producto.variantes.find(
      (candidata) => candidata.id_producto_variante === idProductoVariante,
    );
    if (variante == null) {
      throw new ErrorValidacion(
        `La variante ${idProductoVariante} no existe en el producto "${producto.nombre}" (id ${producto._id})`,
      );
    }

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const resultadoInventario = await cliente.query<{ id_inventario: number }>(
        `INSERT INTO inventario (id_producto_mongo, id_producto_variante_mongo, stock)
         VALUES ($1, $2, $3)
         RETURNING id_inventario`,
        [idProducto, idProductoVariante, stockInicial],
      );
      const idInventario = resultadoInventario.rows[0].id_inventario;

      if (stockInicial > 0) {
        await cliente.query(
          `INSERT INTO stock_movimiento
             (id_inventario, id_motivo_movimiento, id_usuario, cantidad, stock_resultante)
           VALUES (
             $1,
             (SELECT id_motivo_movimiento FROM motivo_movimiento WHERE motivo_nombre = $2),
             $3, $4, $4
           )`,
          [idInventario, MOTIVO_REPOSICION, idUsuario, stockInicial],
        );
      }

      await cliente.query('COMMIT');
    } catch (error) {
      await this.intentarRollback(cliente);
      if (this.tieneCodigoUnico(error)) {
        throw new ErrorConflicto(
          `Ya existe inventario para el producto "${producto.nombre}" (id ${producto._id}), ` +
            `variante "${variante.nombre_variante}" (id ${idProductoVariante})`,
        );
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }

    await this.actualizarStockEnMongo(idProducto, idProductoVariante, stockInicial);

    return {
      id_producto: idProducto,
      id_producto_variante: idProductoVariante,
      stock: stockInicial,
    };
  }

  /**
   * Ajusta (sube o baja) el stock de una variante propia que YA tiene
   * inventario -- para correcciones manuales (un conteo fisico que no
   * cuadraba, mercaderia daniada que no entra en "merma" todavia, etc.).
   * No crea inventario que no existia (para eso esta crearInicial) y nunca
   * deja el stock en negativo. Bloquea la fila de inventario (FOR UPDATE)
   * mientras decide, igual que comprar_pedido, para que dos ajustes
   * simultaneos no se pisen el calculo.
   */
  async ajustar(
    idProductoParametro: string,
    idUsuario: string,
    datos: AjustarInventarioPeticion,
  ): Promise<InventarioVariante> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    const idProductoVariante = validarIdProductoVariante(datos.id_producto_variante);
    const cantidad = validarCantidadMovimiento(datos.cantidad);
    if (
      typeof datos.id_motivo_movimiento !== 'number' ||
      !Number.isInteger(datos.id_motivo_movimiento) ||
      datos.id_motivo_movimiento <= 0
    ) {
      throw new ErrorValidacion(
        'El id_motivo_movimiento es obligatorio y debe ser un numero entero mayor a 0',
      );
    }

    const producto = await this.obtenerUnPropio(idProducto, idUsuario);
    const variante = producto.variantes.find(
      (candidata) => candidata.id_producto_variante === idProductoVariante,
    );
    if (variante == null) {
      throw new ErrorValidacion(
        `La variante ${idProductoVariante} no existe en el producto "${producto.nombre}" (id ${producto._id})`,
      );
    }

    const cliente = await pool.connect();
    let nuevoStock: number;
    try {
      await cliente.query('BEGIN');

      const resultadoMotivo = await cliente.query<MotivoMovimiento>(
        `SELECT id_motivo_movimiento, motivo_nombre, valor
         FROM motivo_movimiento
         WHERE id_motivo_movimiento = $1`,
        [datos.id_motivo_movimiento],
      );
      const motivo = resultadoMotivo.rows[0];
      if (motivo == null || !NOMBRES_MOTIVO_AJUSTE.includes(motivo.motivo_nombre)) {
        throw new ErrorValidacion(
          'El id_motivo_movimiento debe ser el de "ajuste positivo" o "ajuste negativo"',
        );
      }

      const resultadoInventario = await cliente.query<{
        id_inventario: number;
        stock: number;
      }>(
        `SELECT id_inventario, stock
         FROM inventario
         WHERE id_producto_mongo = $1 AND id_producto_variante_mongo = $2
         FOR UPDATE`,
        [idProducto, idProductoVariante],
      );
      const inventario = resultadoInventario.rows[0];
      if (inventario == null) {
        throw new ErrorConflicto(
          `El producto "${producto.nombre}" (id ${producto._id}), variante "${variante.nombre_variante}" ` +
            `(id ${idProductoVariante}), todavia no tiene inventario creado`,
        );
      }

      nuevoStock = inventario.stock + cantidad * motivo.valor;
      if (nuevoStock < 0) {
        throw new ErrorConflicto(
          `No hay suficiente stock: quedan ${inventario.stock} y se quiere quitar ${cantidad}`,
        );
      }

      await cliente.query(
        `UPDATE inventario SET stock = $1, fecha_actualizacion = now() WHERE id_inventario = $2`,
        [nuevoStock, inventario.id_inventario],
      );
      await cliente.query(
        `INSERT INTO stock_movimiento
           (id_inventario, id_motivo_movimiento, id_usuario, cantidad, stock_resultante)
         VALUES ($1, $2, $3, $4, $5)`,
        [
          inventario.id_inventario,
          datos.id_motivo_movimiento,
          idUsuario,
          cantidad,
          nuevoStock,
        ],
      );

      await cliente.query('COMMIT');
    } catch (error) {
      await this.intentarRollback(cliente);
      if (error instanceof ErrorValidacion || error instanceof ErrorConflicto) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }

    await this.actualizarStockEnMongo(idProducto, idProductoVariante, nuevoStock!);

    return {
      id_producto: idProducto,
      id_producto_variante: idProductoVariante,
      stock: nuevoStock!,
    };
  }

  /**
   * variantes[].stock es una copia de lectura, nunca la verdad (ver
   * cambios-etl-productos.md); esto la pone al dia despues de crear el
   * inventario real en PostgreSQL.
   */
  private async actualizarStockEnMongo(
    idProducto: number,
    idProductoVariante: number,
    stock: number,
  ): Promise<void> {
    try {
      await mongoDb.collection<Producto>('productos').updateOne(
        { _id: idProducto, 'variantes.id_producto_variante': idProductoVariante },
        { $set: { 'variantes.$.stock': stock } },
      );
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Todos los productos del vendedor, con solo _id, nombre y las variantes
   * (id y nombre). El filtro de dueno va en la consulta: no hace falta
   * revisarlo despues.
   */
  private async obtenerTodosLosPropios(
    idUsuario: string,
  ): Promise<ProductoLigero[]> {
    try {
      return await mongoDb
        .collection<Producto>('productos')
        .find<ProductoLigero>(
          { 'vendedor.id_usuario': Number(idUsuario) },
          {
            projection: {
              _id: 1,
              nombre: 1,
              'variantes.id_producto_variante': 1,
              'variantes.nombre_variante': 1,
            },
            sort: { _id: 1 },
          },
        )
        .toArray();
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Un producto por id, ligero, solo si es del vendedor logueado. Mismo
   * mensaje y mismo codigo que ProductosVendedorService.obtenerPropio para
   * el que no es suyo o no existe: no hay que confirmar por esta ruta que
   * un producto ajeno existe.
   */
  private async obtenerUnPropio(
    idProducto: number,
    idUsuario: string,
  ): Promise<ProductoLigero> {
    try {
      const producto = await mongoDb
        .collection<Producto>('productos')
        .findOne<ProductoLigeroConDueno>(
          { _id: idProducto },
          {
            projection: {
              _id: 1,
              nombre: 1,
              'vendedor.id_usuario': 1,
              'variantes.id_producto_variante': 1,
              'variantes.nombre_variante': 1,
            },
          },
        );

      if (
        producto == null ||
        Number(producto.vendedor.id_usuario) !== Number(idUsuario)
      ) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }

      return producto;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /** El stock real de cada variante de estos productos, indexado por "id_producto:id_producto_variante". */
  private async consultarInventario(
    idsProducto: number[],
  ): Promise<Map<string, number>> {
    try {
      const resultado = await pool.query<FilaInventario>(
        `SELECT id_producto_mongo, id_producto_variante_mongo, stock
         FROM inventario
         WHERE id_producto_mongo = ANY($1::bigint[])`,
        [idsProducto],
      );

      const stockPorPar = new Map<string, number>();
      for (const fila of resultado.rows) {
        stockPorPar.set(
          `${fila.id_producto_mongo}:${fila.id_producto_variante_mongo}`,
          fila.stock,
        );
      }
      return stockPorPar;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Empareja cada variante de Mongo con su stock de PostgreSQL. Una
   * variante sin fila en inventario no se omite ni se rellena con 0: es un
   * hueco de datos (el publicar/agregar variante todavia no crea esa fila),
   * y se avisa con ErrorConflicto en vez de esconderlo.
   */
  private combinarConInventario(
    productos: ProductoLigero[],
    stockPorPar: Map<string, number>,
  ): InventarioVariante[] {
    const inventario: InventarioVariante[] = [];

    for (const producto of productos) {
      for (const variante of producto.variantes) {
        const stock = stockPorPar.get(
          `${producto._id}:${variante.id_producto_variante}`,
        );
        if (stock == null) {
          throw new ErrorConflicto(
            `El producto "${producto.nombre}" (id ${producto._id}), variante "${variante.nombre_variante}" ` +
              `(id ${variante.id_producto_variante}), todavia no tiene inventario creado`,
          );
        }
        inventario.push({
          id_producto: producto._id,
          id_producto_variante: variante.id_producto_variante,
          stock,
        });
      }
    }

    return inventario;
  }

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo.
      // No hay nada mas que hacer; sigue el error original de quien llamo.
    }
  }

  /** 23505: viola la restriccion UNIQUE (id_producto_mongo, id_producto_variante_mongo) de inventario. */
  private tieneCodigoUnico(error: unknown): boolean {
    return (
      typeof error === 'object' &&
      error !== null &&
      (error as { code?: string }).code === '23505'
    );
  }
}
