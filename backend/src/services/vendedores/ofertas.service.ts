import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { mongoDb } from '../../database/mongo';
import { ErrorConflicto, ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import {
  validarIdProducto,
  validarIdProductoVariante,
  validarStockInicial,
} from '../../helpers/validaciones-inventario';
import { validarPrecioObligatorio } from '../../helpers/validaciones-crear-producto';
import {
  validarAjusteStock,
  validarEstadoOferta,
} from '../../helpers/validaciones-oferta';
import { OfertaPropia, OfertaPropiaResumen } from '../../models/oferta';
import { Producto } from '../../models/producto';
import { ESTADO_PRODUCTO_VISIBLE } from '../../models/estado-producto';
import { CrearOfertaPeticion } from '../../dto/crear-oferta';
import { EditarOfertaPeticion } from '../../dto/editar-oferta';
import {
  ProductoConMisOfertas,
  ProductoVarianteConMiOferta,
} from '../../dto/producto-con-mis-ofertas';
import { ProductosService } from '../productos/productos.service';

const REGEX_ID = /^\d+$/;
const CODIGO_UNIQUE_VIOLATION = '23505';
const CODIGO_CHECK_VIOLATION = '23514';

/** Fila cruda de `oferta` (mas el nombre de su estado), antes de mezclarla con el catalogo. */
interface FilaOfertaPropia {
  id_oferta: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  precio: string;
  stock: number;
  estado_oferta_nombre: string;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}

/** Solo lo que hace falta de un producto para ponerle nombre a una oferta: nada de caracteristicas ni historial. */
interface ProductoLigero {
  _id: number;
  nombre: string;
  variantes: {
    id_producto_variante: number;
    nombre_variante: string;
    imagenes: string[];
  }[];
}

/** Lo que devuelve el INSERT de una oferta nueva. */
interface FilaOfertaNueva {
  id_oferta: string;
  precio: string;
  stock: number;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}

/**
 * Servicio de GET /vendedor/ofertas y GET /vendedor/ofertas/producto/:id.
 *
 * Las ofertas viven solo en PostgreSQL (tabla `oferta`, ver
 * migrations/005_ofertas.sql): Postgres dice QUE ofertas son mias, a como
 * y con cuanto stock. El nombre del producto y de la variante no estan
 * ahi -- el catalogo vive en Mongo -- asi que las dos rutas cruzan las dos
 * bases: primero Postgres para saber que es mio, despues Mongo para
 * ponerle nombre.
 *
 * Sin restriccion de "solo tienda": a diferencia de crear un producto del
 * catalogo (que decidimos que es solo de tienda@mesh.com, ver
 * cambios-multivendedor.md seccion 9), publicar una OFERTA sobre un
 * producto que ya existe es justo lo que cualquier vendedor puede hacer --
 * es el corazon del modelo multi-vendedor.
 */
@Injectable()
export class OfertasVendedorService {
  private readonly logger = new Logger(OfertasVendedorService.name);

  constructor(private readonly productosService: ProductosService) {}

  /**
   * Publica una oferta sobre una variante que ya existe en el catalogo.
   * Cualquier vendedor, no solo tienda -- esto es justo lo que hace a
   * alguien vendedor en el modelo multi-vendedor. Nace siempre `activa` y
   * con `stock = 0`; si viene `stock_inicial > 0` se repone aparte, con
   * `reponer_stock`, para que el kardex explique tambien esas unidades
   * (nunca se mete stock directo en el INSERT).
   *
   * Solo sobre productos activos: uno oculto (`inactivo`/`borrador`) da el
   * mismo 404 que uno que no existe, igual que en el catalogo publico y en
   * `agregar_linea` -- nadie mas lo ve, no deberia poder recibir una oferta
   * nueva tampoco.
   */
  async crear(
    idUsuario: string,
    datos: CrearOfertaPeticion,
  ): Promise<OfertaPropia> {
    const idProducto = validarIdProducto(datos.id_producto);
    const idProductoVariante = validarIdProductoVariante(
      datos.id_producto_variante,
    );
    const precio = validarPrecioObligatorio(datos.precio);
    const stockInicial =
      datos.stock_inicial != null ? validarStockInicial(datos.stock_inicial) : 0;

    let producto: ProductoLigero;
    try {
      const encontrado = await mongoDb
        .collection<Producto>('productos')
        .findOne<ProductoLigero>(
          { _id: idProducto, estado: ESTADO_PRODUCTO_VISIBLE },
          {
            projection: {
              _id: 1,
              nombre: 1,
              'variantes.id_producto_variante': 1,
              'variantes.nombre_variante': 1,
              'variantes.imagenes': 1,
            },
          },
        );

      if (encontrado == null) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }
      producto = encontrado;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }

    const variante = producto.variantes.find(
      (candidata) => candidata.id_producto_variante === idProductoVariante,
    );
    if (variante == null) {
      throw new ErrorNoEncontrado(
        'No existe una variante con ese id en este producto',
      );
    }

    let filaOferta: FilaOfertaNueva;
    try {
      const resultado = await pool.query<FilaOfertaNueva>(
        `INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario, precio, id_estado_oferta)
         VALUES ($1, $2, $3, $4, (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = 'activa'))
         RETURNING id_oferta, precio, stock, fecha_creacion, fecha_actualizacion`,
        [idProducto, idProductoVariante, idUsuario, precio],
      );
      filaOferta = resultado.rows[0];
    } catch (error) {
      if (this.esOfertaDuplicada(error)) {
        throw new ErrorConflicto(
          'Ya tenes una oferta sobre esta variante -- para cambiarla hay que editar la existente, no crear otra',
        );
      }
      manejarErrorConexion(this.logger, error);
    }

    let stockFinal = filaOferta.stock;
    if (stockInicial > 0) {
      try {
        const resultadoStock = await pool.query<{
          reponer_stock: { stock: number };
        }>('SELECT reponer_stock($1, $2, $3, $4)', [
          filaOferta.id_oferta,
          stockInicial,
          'reposicion',
          idUsuario,
        ]);
        stockFinal = resultadoStock.rows[0].reponer_stock.stock;
      } catch (error) {
        manejarErrorConexion(this.logger, error);
      }
    }

    await this.productosService.recalcularCamposCalculados([idProducto]);

    return {
      id_oferta: filaOferta.id_oferta,
      id_producto: idProducto,
      id_producto_variante: idProductoVariante,
      nombre_producto: producto.nombre,
      nombre_variante: variante.nombre_variante,
      imagen: variante.imagenes[0] ?? null,
      precio: filaOferta.precio,
      stock: stockFinal,
      estado: 'activa',
      fecha_creacion: filaOferta.fecha_creacion,
      fecha_actualizacion: filaOferta.fecha_actualizacion,
    };
  }

  /**
   * Edita una oferta propia: precio, estado, y/o un ajuste manual de
   * stock. Los tres son independientes -- se puede mandar uno solo o los
   * tres juntos -- y cada uno cae en la tabla que le corresponde, no se
   * escribe a mano:
   *
   *   - `precio`: un UPDATE sobre `oferta.precio`. El trigger
   *     `trg_oferta_registrar_precio` (005_ofertas.sql) escribe solo la
   *     fila nueva en `precio_historial`.
   *   - `estado`: un UPDATE sobre `oferta.id_estado_oferta`. Sin
   *     restriccion sobre a cual -- el dueno maneja su oferta como
   *     quiera, incluida "retirada" hacia "activa" de nuevo.
   *   - `ajuste_stock`: un entero con signo, nunca 0. Positivo llama a
   *     `reponer_stock(..., 'reposicion', ...)`, negativo llama con
   *     'ajuste' y la magnitud (`Math.abs`) -- los mismos dos motivos que
   *     ya admite esa funcion fuera del flujo del pedido. Es la misma
   *     correccion manual (sube o baja) que ya existia en el modelo viejo
   *     de inventario, ahora sobre la oferta.
   *
   * Solo el dueno de la oferta -- una ajena da el mismo 404 generico que
   * una que no existe, mismo criterio de siempre.
   */
  async editar(
    idUsuario: string,
    idOfertaParametro: string,
    datos: EditarOfertaPeticion,
  ): Promise<OfertaPropia> {
    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idOferta = Number(idOfertaParametro);

    if (datos.precio == null && datos.estado == null && datos.ajuste_stock == null) {
      throw new ErrorValidacion('Debes enviar al menos un campo para actualizar');
    }

    const precio =
      datos.precio != null ? validarPrecioObligatorio(datos.precio) : null;
    const estado =
      datos.estado != null ? validarEstadoOferta(datos.estado) : null;
    const ajusteStock =
      datos.ajuste_stock != null ? validarAjusteStock(datos.ajuste_stock) : null;

    // Comprueba dueno y de paso trae los ids de Mongo -- se pide antes de
    // tocar nada, para no dejar un cambio a medias si la oferta es ajena.
    await this.obtenerFilaPropia(idOferta, idUsuario);

    if (precio != null || estado != null) {
      const asignaciones: string[] = [];
      const valores: unknown[] = [];
      if (precio != null) {
        asignaciones.push(`precio = $${valores.length + 1}`);
        valores.push(precio);
      }
      if (estado != null) {
        asignaciones.push(
          `id_estado_oferta = (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = $${valores.length + 1})`,
        );
        valores.push(estado);
      }
      valores.push(idOferta);

      try {
        await pool.query(
          `UPDATE oferta SET ${asignaciones.join(', ')} WHERE id_oferta = $${valores.length}`,
          valores,
        );
      } catch (error) {
        manejarErrorConexion(this.logger, error);
      }
    }

    if (ajusteStock != null) {
      const motivo = ajusteStock > 0 ? 'reposicion' : 'ajuste';
      const cantidad = Math.abs(ajusteStock);
      try {
        await pool.query('SELECT reponer_stock($1, $2, $3, $4)', [
          idOferta,
          cantidad,
          motivo,
          idUsuario,
        ]);
      } catch (error) {
        if (this.esErrorDeNegocio(error)) {
          throw new ErrorConflicto((error as Error).message);
        }
        manejarErrorConexion(this.logger, error);
      }
    }

    const filaFinal = await this.obtenerFilaPropia(idOferta, idUsuario);
    const idProducto = Number(filaFinal.id_producto_mongo);
    const idProductoVariante = Number(filaFinal.id_producto_variante_mongo);

    await this.productosService.recalcularCamposCalculados([idProducto]);

    const [producto] = await this.consultarProductosLigeros([idProducto]);
    const variante = producto?.variantes.find(
      (candidata) => candidata.id_producto_variante === idProductoVariante,
    );

    return {
      id_oferta: filaFinal.id_oferta,
      id_producto: idProducto,
      id_producto_variante: idProductoVariante,
      nombre_producto: producto?.nombre ?? '(producto no encontrado)',
      nombre_variante: variante?.nombre_variante ?? '(variante no encontrada)',
      imagen: variante?.imagenes[0] ?? null,
      precio: filaFinal.precio,
      stock: filaFinal.stock,
      estado: filaFinal.estado_oferta_nombre,
      fecha_creacion: filaFinal.fecha_creacion,
      fecha_actualizacion: filaFinal.fecha_actualizacion,
    };
  }

  /**
   * Todas mis ofertas, en cualquier estado (activa, pausada o retirada --
   * es mi panel, tengo que poder ver las tres, a diferencia de la ficha
   * publica que solo ensena las activas). Cada una trae el nombre del
   * producto y de la variante, y su portada, para que el frontend no tenga
   * que pedir cada producto aparte.
   *
   * Dos consultas nada mas, sin importar cuantas ofertas haya: una a
   * Postgres por todas mis filas de `oferta`, y una sola a Mongo por todos
   * los productos distintos que aparecen ahi (con `$in`), nunca una por
   * oferta.
   */
  async listarPropias(idUsuario: string): Promise<OfertaPropia[]> {
    const ofertas = await this.consultarOfertasPropias(idUsuario);
    if (ofertas.length === 0) {
      return [];
    }

    const idsProducto = [
      ...new Set(ofertas.map((fila) => Number(fila.id_producto_mongo))),
    ];
    const productos = await this.consultarProductosLigeros(idsProducto);
    const productoPorId = new Map(productos.map((p) => [p._id, p]));

    return ofertas.map((fila) => {
      const producto = productoPorId.get(Number(fila.id_producto_mongo));
      const variante = producto?.variantes.find(
        (v) => v.id_producto_variante === Number(fila.id_producto_variante_mongo),
      );

      return {
        id_oferta: fila.id_oferta,
        id_producto: Number(fila.id_producto_mongo),
        id_producto_variante: Number(fila.id_producto_variante_mongo),
        // Si el producto no aparecio en Mongo (no deberia pasar nunca: el
        // catalogo no borra productos ni variantes, solo los desactiva),
        // se avisa en el nombre en vez de reventar la lista entera por una
        // sola oferta huerfana.
        nombre_producto: producto?.nombre ?? '(producto no encontrado)',
        nombre_variante: variante?.nombre_variante ?? '(variante no encontrada)',
        imagen: variante?.imagenes[0] ?? null,
        precio: fila.precio,
        stock: fila.stock,
        estado: fila.estado_oferta_nombre,
        fecha_creacion: fila.fecha_creacion,
        fecha_actualizacion: fila.fecha_actualizacion,
      };
    });
  }

  /**
   * Un producto del catalogo completo -- misma forma que GET /productos/:id,
   * pero SIN excluir `inactivo`/`borrador`: un vendedor tiene que poder ver
   * un producto oculto para decidir si le conviene ofertarlo, aunque
   * todavia no este publicado -- con `mi_oferta` embebida en cada
   * variante (null si no oferto sobre ella).
   *
   * Un producto que no existe da 404 igual para cualquiera: no hay nada
   * que ocultar aqui (a diferencia de "no es tuyo"), asi que no hace falta
   * el mismo cuidado de siempre con el mensaje.
   */
  async obtenerConMisOfertas(
    idProductoParametro: string,
    idUsuario: string,
  ): Promise<ProductoConMisOfertas> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    let producto: Producto;
    try {
      const encontrado = await mongoDb
        .collection<Producto>('productos')
        .findOne({ _id: idProducto });

      if (encontrado == null) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }
      producto = encontrado;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }

    const misOfertas = await this.consultarOfertasPropiasDeProducto(
      idUsuario,
      idProducto,
    );
    const ofertaPorVariante = new Map(
      misOfertas.map((fila) => [Number(fila.id_producto_variante_mongo), fila]),
    );

    const variantes: ProductoVarianteConMiOferta[] = producto.variantes.map(
      (variante) => {
        const fila = ofertaPorVariante.get(variante.id_producto_variante);
        const miOferta: OfertaPropiaResumen | null = fila
          ? {
              id_oferta: fila.id_oferta,
              precio: fila.precio,
              stock: fila.stock,
              estado: fila.estado_oferta_nombre,
              fecha_creacion: fila.fecha_creacion,
              fecha_actualizacion: fila.fecha_actualizacion,
            }
          : null;

        return { ...variante, mi_oferta: miOferta };
      },
    );

    return { ...producto, variantes };
  }

  private async consultarOfertasPropias(
    idUsuario: string,
  ): Promise<FilaOfertaPropia[]> {
    try {
      const resultado = await pool.query<FilaOfertaPropia>(
        `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.stock, eo.estado_oferta_nombre,
                o.fecha_creacion, o.fecha_actualizacion
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         WHERE o.id_usuario = $1
         ORDER BY o.fecha_actualizacion DESC`,
        [idUsuario],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async consultarOfertasPropiasDeProducto(
    idUsuario: string,
    idProducto: number,
  ): Promise<FilaOfertaPropia[]> {
    try {
      const resultado = await pool.query<FilaOfertaPropia>(
        `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.stock, eo.estado_oferta_nombre,
                o.fecha_creacion, o.fecha_actualizacion
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         WHERE o.id_usuario = $1 AND o.id_producto_mongo = $2`,
        [idUsuario, idProducto],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async consultarProductosLigeros(
    idsProducto: number[],
  ): Promise<ProductoLigero[]> {
    try {
      return await mongoDb
        .collection<Producto>('productos')
        .find<ProductoLigero>(
          { _id: { $in: idsProducto } },
          {
            projection: {
              _id: 1,
              nombre: 1,
              'variantes.id_producto_variante': 1,
              'variantes.nombre_variante': 1,
              'variantes.imagenes': 1,
            },
          },
        )
        .toArray();
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * 23505 es unique_violation: el UNIQUE (id_usuario, id_producto_mongo,
   * id_producto_variante_mongo) de `oferta` (005_ofertas.sql) rechazando una
   * segunda oferta del mismo vendedor sobre la misma variante.
   */
  private esOfertaDuplicada(error: unknown): boolean {
    const codigo = (error as { code?: string } | undefined)?.code;
    return codigo === CODIGO_UNIQUE_VIOLATION;
  }

  /**
   * Una oferta por id, solo si es del vendedor logueado -- el WHERE exige
   * el id_usuario, asi que una ajena da la misma fila vacia que un id que
   * no existe, y de ahi el mismo 404 generico. La usa editar(), antes y
   * despues de aplicar los cambios.
   */
  private async obtenerFilaPropia(
    idOferta: number,
    idUsuario: string,
  ): Promise<FilaOfertaPropia> {
    try {
      const resultado = await pool.query<FilaOfertaPropia>(
        `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.stock, eo.estado_oferta_nombre,
                o.fecha_creacion, o.fecha_actualizacion
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         WHERE o.id_oferta = $1 AND o.id_usuario = $2`,
        [idOferta, idUsuario],
      );
      const fila = resultado.rows[0];

      if (fila == null) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }
      return fila;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * 23514 es check_violation: lo que levanta reponer_stock() con RAISE
   * EXCEPTION cuando el motivo no existe o el ajuste dejaria el stock en
   * negativo (migrations/007_flujo_pedido.sql). A este punto la oferta y
   * el dueno ya se comprobaron, asi que lo unico que puede seguir
   * fallando con este codigo es el stock disponible.
   */
  private esErrorDeNegocio(error: unknown): boolean {
    const codigo = (error as { code?: string } | undefined)?.code;
    return codigo === CODIGO_CHECK_VIOLATION;
  }
}
