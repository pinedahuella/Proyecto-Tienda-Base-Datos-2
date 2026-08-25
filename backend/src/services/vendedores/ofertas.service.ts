import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { mongoDb } from '../../database/mongo';
import { ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { OfertaPropia, OfertaPropiaResumen } from '../../models/oferta';
import { Producto } from '../../models/producto';
import {
  ProductoConMisOfertas,
  ProductoVarianteConMiOferta,
} from '../../dto/producto-con-mis-ofertas';

const REGEX_ID = /^\d+$/;

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
}
