import { Injectable, Logger } from '@nestjs/common';
import { Collection, Document } from 'mongodb';
import type { PoolClient } from 'pg';
import { mongoDb } from '../../database/mongo';
import { pool } from '../../database/postgres';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { esTextoNoVacio } from '../../helpers/validaciones-perfil';
import {
  validarCaracteristicasCatalogo,
  validarCaracteristicasExistentesContraCategoria,
  validarCaracteristicasPersonalizadas,
  validarDescripcionVariante,
  validarEstadoProducto,
  validarImagenes,
  validarNombreProducto,
  validarNombreVariante,
} from '../../helpers/validaciones-crear-producto';
import {
  construirRegexNombreFlexible,
  validarLimite,
  validarPagina,
} from '../../helpers/validaciones-productos';
import {
  CaracteristicaCatalogoPeticion,
  CaracteristicaPersonalizadaPeticion,
  CrearProductoPeticion,
  VarianteCreacionPeticion,
} from '../../dto/crear-producto';
import { EditarProductoPeticion } from '../../dto/editar-producto';
import {
  PaginarProductosVendedorQuery,
  ProductosVendedorPaginados,
} from '../../dto/paginar-productos-vendedor';
import { PropuestaProducto } from '../../dto/propuesta-producto';
import { RevisarPropuestaPeticion } from '../../dto/revisar-propuesta';
import {
  validarDecisionRevision,
  validarRazonRechazo,
} from '../../helpers/validaciones-oferta';
import { validarComentarioAprobacion } from '../../helpers/validaciones-propuesta';
import { CategoriaDocumento } from '../../models/categoria';
import { ESTADOS_PRODUCTO_SOLO_REVISION } from '../../models/estado-producto';
import { RechazoProducto } from '../../models/rechazo-producto';
import {
  EntradaCaracteristica,
  Producto,
  ProductoCategoria,
  ProductoVariante,
} from '../../models/producto';
import {
  ProductoEventoCambios,
  ProductoEventoCreacion,
  ProductoEventoModificacion,
} from '../../models/producto-evento';
import { UsuarioService } from '../../services/usuario.service';
import { ProductosService } from '../../services/productos/productos.service';
import { CORREO_TIENDA } from '../../helpers/constantes';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';

const ESTADO_PRODUCTO_NUEVO = 'borrador';
/**
 * Estado con el que nace un producto que PROPONE un vendedor convencional
 * (POST /vendedor/productos/propuestas): no circula -- la busqueda, la
 * ficha y crear una oferta filtran por `activo` (lista blanca) -- hasta que
 * un admin o la tienda lo apruebe. Ver
 * `elementos Generales/plan pendiente/propuesta-de-productos.md`.
 */
const ESTADO_PRODUCTO_EN_REVISION = 'en_revision';
const ESTADO_VARIANTE_NUEVA = 'activa';
const REGEX_ID = /^\d+$/;
/** unique_violation: el UNIQUE (id_producto_mongo) de propuesta_producto. */
const CODIGO_UNIQUE_VIOLATION = '23505';

/** Fila cruda de `propuesta_producto`; los campos de `usuarios` van solo en las consultas de tienda/admin. */
interface FilaPropuesta {
  id_propuesta_producto: string;
  id_producto_mongo: string;
  fecha_propuesta: Date;
  fecha_aprobacion: Date | null;
  comentario_aprobacion: string | null;
  id_usuario?: string;
  usuario?: string;
  nombre?: string;
  apellido?: string | null;
}

/**
 * Servicio de POST /vendedor/productos.
 *
 * Todo vive en MongoDB: los productos ya no se registran en PostgreSQL (las
 * migraciones de productos fueron solo para el ETL que cargo los datos de
 * prueba). Por eso el id del producto y el de cada variante no salen de un
 * bigserial: se calculan como "el maximo que ya existe, mas 1", sin
 * transaccion ni coleccion de contadores aparte (mas simple; el riesgo
 * aceptado es que dos creaciones en el mismo instante choquen y una falle,
 * recuperable con solo reintentar).
 *
 * Escribe el producto y despues su primer evento, uno detras del otro, sin
 * transaccion (Mongo no esta configurado como replica set todavia).
 */
@Injectable()
export class ProductosVendedorService {
  private readonly logger = new Logger(ProductosVendedorService.name);

  constructor(
    private readonly usuarioService: UsuarioService,
    private readonly productosService: ProductosService,
  ) {}

  async crear(
    idUsuario: string,
    datos: CrearProductoPeticion,
  ): Promise<Producto> {
    // Primero que cualquier otra cosa, ni siquiera validar el cuerpo: si
    // no sos la tienda ni admin, el 404 disfrazado tiene que ganarle a
    // cualquier 400 de validacion -- si no, alguien sin permiso podria
    // usar los mensajes de validacion (o hasta disparar una consulta a
    // Mongo, ver obtenerCategoriaValida mas abajo) para confirmar que la
    // ruta existe y como se comporta, justo lo que el 404 disfrazado
    // busca evitar (ver exigirTiendaOAdmin).
    await this.exigirTiendaOAdmin(idUsuario);

    const nombre = validarNombreProducto(datos.nombre);
    const descripcion = esTextoNoVacio(datos.descripcion)
      ? datos.descripcion
      : null;

    if (!Array.isArray(datos.variantes) || datos.variantes.length === 0) {
      throw new ErrorValidacion('Debes enviar al menos una variante');
    }
    if (
      typeof datos.id_categoria !== 'number' ||
      !Number.isInteger(datos.id_categoria)
    ) {
      throw new ErrorValidacion('El id de la categoria no es valido');
    }

    const coleccionProductos = mongoDb.collection<Producto>('productos');

    try {
      const categoria = await this.obtenerCategoriaValida(datos.id_categoria);

      const caracteristicasAdicionales = validarCaracteristicasCatalogo(
        datos.caracteristicas_adicionales,
        categoria.caracteristicas,
      );
      const caracteristicasPersonalizadas =
        validarCaracteristicasPersonalizadas(
          datos.caracteristicas_personalizadas,
        );

      const idProducto = await this.siguienteIdProducto(coleccionProductos);
      const fechaCreacion = new Date();
      const variantes = await this.construirVariantes(
        datos.variantes,
        categoria,
        fechaCreacion,
        coleccionProductos,
        null,
      );

      const producto: Producto = {
        _id: idProducto,
        nombre,
        descripcion,
        fecha_creacion: fechaCreacion,
        estado: ESTADO_PRODUCTO_NUEVO,
        categoria: {
          id_categoria: categoria._id,
          nombre: categoria.nombre,
          categoria_padre: categoria.categoria_padre,
        },
        // Los calculados nacen en 0/null: todavia no existe ninguna oferta
        // sobre este producto (eso es de otro servicio, sobre `oferta` en
        // PostgreSQL) ni ninguna resena (nace en `nuevo`, aun no se puede
        // comprar).
        precio_tienda: null,
        precio_desde: null,
        stock_tienda: 0,
        stock_total: 0,
        total_ofertas: 0,
        hay_descuento: false,
        resenas_promedio: 0,
        resenas_total: 0,
        // Nace pendiente de sincronizar con el buscador: el indice de
        // Elasticsearch todavia no sabe que este producto existe.
        pendiente_busqueda: true,
        // Ni tiene vector todavia: nace pendiente tambien para la
        // recomendacion semantica.
        pendiente_vector: true,
        variantes,
        ...(caracteristicasAdicionales.length > 0 && {
          caracteristicas_adicionales: caracteristicasAdicionales,
        }),
        ...(caracteristicasPersonalizadas.length > 0 && {
          caracteristicas_personalizadas: caracteristicasPersonalizadas,
        }),
      };

      await coleccionProductos.insertOne(producto);
      await this.crearEventoCreacion(producto);

      return producto;
    } catch (error) {
      if (error instanceof ErrorValidacion) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Un vendedor convencional PROPONE un producto nuevo
   * (POST /vendedor/productos/propuestas). A diferencia de `crear()` (solo
   * la tienda o un admin, nace `borrador`):
   *
   *   - No hay `exigirTiendaOAdmin`: cualquiera con rol vendedor o admin
   *     puede proponer (el guard de la clase ya filtra a los compradores).
   *   - El producto nace en Mongo con estado **`en_revision`**, que no
   *     circula: la busqueda, la ficha y crear una oferta filtran por
   *     `activo` (lista blanca), asi que queda oculto hasta que un admin o
   *     la tienda lo apruebe.
   *   - Ademas del documento de Mongo (y su evento de creacion, igual que
   *     `crear()`), escribe una fila en **`propuesta_producto`** de
   *     PostgreSQL con `id_usuario` = quien propone e `id_producto_mongo` =
   *     el `_id` recien generado. Esa fila es la que sabe quien propuso y
   *     lleva la aprobacion; las dos escrituras son en bases distintas y
   *     no hay transaccion entre ellas, asi que si la de Postgres falla se
   *     deshace la de Mongo (`deshacerProductoMongo`) para no dejar un
   *     producto `en_revision` sin proponente.
   *
   * El orden es Mongo primero: el `_id` unico de Mongo ya serializa dos
   * propuestas que compitan por el mismo id (la segunda falla al insertar
   * el documento y ni llega a Postgres), igual que el riesgo aceptado de
   * `crear()`.
   */
  async proponer(
    idUsuario: string,
    datos: CrearProductoPeticion,
  ): Promise<Producto> {
    const nombre = validarNombreProducto(datos.nombre);
    const descripcion = esTextoNoVacio(datos.descripcion)
      ? datos.descripcion
      : null;

    if (!Array.isArray(datos.variantes) || datos.variantes.length === 0) {
      throw new ErrorValidacion('Debes enviar al menos una variante');
    }
    if (
      typeof datos.id_categoria !== 'number' ||
      !Number.isInteger(datos.id_categoria)
    ) {
      throw new ErrorValidacion('El id de la categoria no es valido');
    }

    const coleccionProductos = mongoDb.collection<Producto>('productos');
    let producto: Producto;

    try {
      const categoria = await this.obtenerCategoriaValida(datos.id_categoria);

      const caracteristicasAdicionales = validarCaracteristicasCatalogo(
        datos.caracteristicas_adicionales,
        categoria.caracteristicas,
      );
      const caracteristicasPersonalizadas =
        validarCaracteristicasPersonalizadas(
          datos.caracteristicas_personalizadas,
        );

      const idProducto = await this.siguienteIdProducto(coleccionProductos);
      const fechaCreacion = new Date();
      const variantes = await this.construirVariantes(
        datos.variantes,
        categoria,
        fechaCreacion,
        coleccionProductos,
        null,
      );

      producto = {
        _id: idProducto,
        nombre,
        descripcion,
        fecha_creacion: fechaCreacion,
        estado: ESTADO_PRODUCTO_EN_REVISION,
        categoria: {
          id_categoria: categoria._id,
          nombre: categoria.nombre,
          categoria_padre: categoria.categoria_padre,
        },
        precio_tienda: null,
        precio_desde: null,
        stock_tienda: 0,
        stock_total: 0,
        total_ofertas: 0,
        hay_descuento: false,
        resenas_promedio: 0,
        resenas_total: 0,
        // Nace pendiente de sincronizar con el buscador, igual que en
        // crear(): aunque en_revision no circula todavia, el worker es
        // quien decide eso -- esta ruta solo avisa que el documento cambio.
        pendiente_busqueda: true,
        pendiente_vector: true,
        variantes,
        ...(caracteristicasAdicionales.length > 0 && {
          caracteristicas_adicionales: caracteristicasAdicionales,
        }),
        ...(caracteristicasPersonalizadas.length > 0 && {
          caracteristicas_personalizadas: caracteristicasPersonalizadas,
        }),
      };

      await coleccionProductos.insertOne(producto);
      await this.crearEventoCreacion(producto);
    } catch (error) {
      if (error instanceof ErrorValidacion) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }

    // El producto ya esta en Mongo (invisible por la lista blanca). Ahora la
    // propuesta en Postgres; si falla, se deshace la escritura de Mongo.
    try {
      await pool.query(
        'INSERT INTO propuesta_producto (id_usuario, id_producto_mongo) VALUES ($1, $2)',
        [idUsuario, producto._id],
      );
    } catch (error) {
      await this.deshacerProductoMongo(producto._id);
      if (
        (error as { code?: string } | undefined)?.code ===
        CODIGO_UNIQUE_VIOLATION
      ) {
        throw new ErrorConflicto(
          'No se pudo registrar la propuesta. Volve a intentarlo.',
        );
      }
      manejarErrorConexion(this.logger, error);
    }

    return producto;
  }

  /**
   * Borra un producto de Mongo y sus eventos -- la compensacion cuando la
   * propuesta en Postgres falla despues de escribir el producto. Si ni esto
   * funciona, queda un producto `en_revision` sin proponente: invisible por
   * la lista blanca, se registra y sigue el error original.
   */
  private async deshacerProductoMongo(idProducto: number): Promise<void> {
    try {
      await mongoDb
        .collection<Producto>('productos')
        .deleteOne({ _id: idProducto });
      await mongoDb
        .collection<ProductoEventoCreacion>('productos_eventos')
        .deleteMany({ id_producto: idProducto });
    } catch {
      this.logger.error(
        `No se pudo deshacer el producto ${idProducto} de Mongo tras fallar su propuesta`,
      );
    }
  }

  /**
   * Las propuestas del vendedor logueado -- las que EL propuso, mas
   * recientes primero. El WHERE exige `propuesta_producto.id_usuario`, asi
   * que no hay forma de ver las de otro vendedor. Sin `exigirTiendaOAdmin`:
   * cualquier vendedor ve las suyas.
   *
   * Cada propuesta trae el documento del producto (desde Mongo) y su
   * historial de rechazos. Sin `vendedor` embebido: ya se que soy yo.
   */
  async listarPropuestasPropias(
    idUsuario: string,
  ): Promise<PropuestaProducto[]> {
    let filas: FilaPropuesta[];
    try {
      const resultado = await pool.query<FilaPropuesta>(
        `SELECT id_propuesta_producto, id_producto_mongo, fecha_propuesta,
                fecha_aprobacion, comentario_aprobacion
         FROM propuesta_producto
         WHERE id_usuario = $1
         ORDER BY fecha_propuesta DESC`,
        [idUsuario],
      );
      filas = resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    return this.armarPropuestas(filas, false);
  }

  /**
   * Todas las propuestas que NO han sido aprobadas todavia
   * (`fecha_aprobacion IS NULL`) -- las `en_revision` esperando y las
   * `rechazado` que el vendedor no ha vuelto a enviar. De cualquier
   * vendedor, la mas antigua primero (cola de trabajo). Solo la tienda o un
   * admin (`exigirTiendaOAdmin`, 404 disfrazado).
   */
  async listarPropuestasSinAprobar(
    idUsuario: string,
  ): Promise<PropuestaProducto[]> {
    await this.exigirTiendaOAdmin(idUsuario);

    let filas: FilaPropuesta[];
    try {
      const resultado = await pool.query<FilaPropuesta>(
        `SELECT pp.id_propuesta_producto, pp.id_producto_mongo, pp.fecha_propuesta,
                pp.fecha_aprobacion, pp.comentario_aprobacion,
                u.id_usuario, u.usuario, u.nombre, u.apellido
         FROM propuesta_producto pp
         JOIN usuarios u ON u.id_usuario = pp.id_usuario
         WHERE pp.fecha_aprobacion IS NULL
         ORDER BY pp.fecha_propuesta ASC`,
      );
      filas = resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    return this.armarPropuestas(filas, true);
  }

  /**
   * Todas las propuestas, en cualquier estado, mas recientes primero. De
   * cualquier vendedor. Solo la tienda o un admin.
   */
  async listarTodasLasPropuestas(
    idUsuario: string,
  ): Promise<PropuestaProducto[]> {
    await this.exigirTiendaOAdmin(idUsuario);

    let filas: FilaPropuesta[];
    try {
      const resultado = await pool.query<FilaPropuesta>(
        `SELECT pp.id_propuesta_producto, pp.id_producto_mongo, pp.fecha_propuesta,
                pp.fecha_aprobacion, pp.comentario_aprobacion,
                u.id_usuario, u.usuario, u.nombre, u.apellido
         FROM propuesta_producto pp
         JOIN usuarios u ON u.id_usuario = pp.id_usuario
         ORDER BY pp.fecha_propuesta DESC`,
      );
      filas = resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    return this.armarPropuestas(filas, true);
  }

  /**
   * Junta las filas de `propuesta_producto` con el documento del producto
   * (Mongo, un solo `$in`) y con los rechazos (`rechazo_producto`, un solo
   * `= ANY`), sin importar cuantas propuestas haya. `incluirVendedor` es
   * true en las vistas de tienda/admin.
   */
  private async armarPropuestas(
    filas: FilaPropuesta[],
    incluirVendedor: boolean,
  ): Promise<PropuestaProducto[]> {
    if (filas.length === 0) {
      return [];
    }

    const idsProducto = [
      ...new Set(filas.map((fila) => Number(fila.id_producto_mongo))),
    ];
    let productoPorId: Map<number, Producto>;
    try {
      const productos = await mongoDb
        .collection<Producto>('productos')
        .find({ _id: { $in: idsProducto } })
        .toArray();
      productoPorId = new Map(productos.map((p) => [p._id, p]));
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }

    const idsPropuesta = filas.map((fila) => fila.id_propuesta_producto);
    const rechazosPorPropuesta = new Map<string, RechazoProducto[]>();
    try {
      const resultado = await pool.query<
        RechazoProducto & { id_propuesta_producto: string }
      >(
        `SELECT id_rechazo_producto, id_propuesta_producto, razon_rechazo, fecha_rechazo
         FROM rechazo_producto
         WHERE id_propuesta_producto = ANY($1::bigint[])
         ORDER BY fecha_rechazo DESC, id_rechazo_producto DESC`,
        [idsPropuesta],
      );
      for (const fila of resultado.rows) {
        const lista =
          rechazosPorPropuesta.get(fila.id_propuesta_producto) ?? [];
        lista.push({
          id_rechazo_producto: fila.id_rechazo_producto,
          razon_rechazo: fila.razon_rechazo,
          fecha_rechazo: fila.fecha_rechazo,
        });
        rechazosPorPropuesta.set(fila.id_propuesta_producto, lista);
      }
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    return filas.map((fila) => {
      const idProducto = Number(fila.id_producto_mongo);
      const propuesta: PropuestaProducto = {
        id_propuesta_producto: fila.id_propuesta_producto,
        id_producto: idProducto,
        fecha_propuesta: fila.fecha_propuesta,
        fecha_aprobacion: fila.fecha_aprobacion,
        comentario_aprobacion: fila.comentario_aprobacion,
        producto: productoPorId.get(idProducto) ?? null,
        rechazos: rechazosPorPropuesta.get(fila.id_propuesta_producto) ?? [],
      };
      if (incluirVendedor && fila.id_usuario != null) {
        propuesta.vendedor = {
          id_usuario: fila.id_usuario,
          usuario: fila.usuario as string,
          nombre: fila.nombre as string,
          apellido: fila.apellido ?? null,
        };
      }
      return propuesta;
    });
  }

  /**
   * La tienda o un admin APRUEBA una propuesta (pasa a `activo`, y ya
   * circula) o la RECHAZA con un motivo (pasa a `rechazado`; se guarda una
   * fila en `rechazo_producto`). `:id` es el `_id` del producto en Mongo.
   *
   * Solo la tienda o un admin (`exigirTiendaOAdmin`, 404 disfrazado, lo
   * primero). La propuesta tiene que estar en estado `en_revision`;
   * cualquier otro estado -> 409.
   *
   * El estado del producto vive en Mongo, no en Postgres, asi que la
   * sincronizacion es un `SELECT ... FOR UPDATE` sobre la fila de
   * `propuesta_producto`: dos revisiones a la vez sobre la misma propuesta
   * se serializan ahi, y `reenviarPropuesta()` toma el mismo lock. Se
   * escribe primero Mongo (estado + evento de modificacion) y despues
   * Postgres, dentro de la transaccion; si Postgres falla, se hace ROLLBACK
   * y se compensa Mongo (`compensarRevisionMongo`).
   */
  async revisarPropuesta(
    idUsuario: string,
    idProductoParametro: string,
    datos: RevisarPropuestaPeticion,
  ): Promise<Producto> {
    await this.exigirTiendaOAdmin(idUsuario);

    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    const decision = validarDecisionRevision(datos.decision);
    const razon =
      decision === 'rechazar' ? validarRazonRechazo(datos.razon) : null;
    const comentario =
      decision === 'aprobar'
        ? validarComentarioAprobacion(datos.comentario)
        : null;

    const nuevoEstado = decision === 'aprobar' ? 'activo' : 'rechazado';
    const coleccionProductos = mongoDb.collection<Producto>('productos');

    let estadoARevertir: string | null = null;
    let eventoABorrar: string | null = null;

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const bloqueo = await cliente.query<{ id_propuesta_producto: string }>(
        `SELECT id_propuesta_producto
           FROM propuesta_producto
          WHERE id_producto_mongo = $1
          FOR UPDATE`,
        [idProducto],
      );
      const propuesta = bloqueo.rows[0];
      if (propuesta == null) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }

      const doc = await coleccionProductos.findOne(
        { _id: idProducto },
        { projection: { estado: 1 } },
      );
      if (doc?.estado !== 'en_revision') {
        throw new ErrorConflicto(
          `Esta propuesta no esta en revision (esta ${doc?.estado ?? 'sin producto'})`,
        );
      }

      await coleccionProductos.updateOne(
        { _id: idProducto },
        {
          $set: {
            estado: nuevoEstado,
            pendiente_busqueda: true,
            pendiente_vector: true,
          },
        },
      );
      estadoARevertir = 'en_revision';
      eventoABorrar = await this.crearEventoModificacion(idProducto, {
        estado: nuevoEstado,
      });

      if (decision === 'aprobar') {
        await cliente.query(
          `UPDATE propuesta_producto
              SET fecha_aprobacion = now(),
                  id_usuario_aprobo = $1,
                  comentario_aprobacion = $2
            WHERE id_propuesta_producto = $3`,
          [idUsuario, comentario, propuesta.id_propuesta_producto],
        );
      } else {
        await cliente.query(
          'INSERT INTO rechazo_producto (id_propuesta_producto, razon_rechazo) VALUES ($1, $2)',
          [propuesta.id_propuesta_producto, razon],
        );
      }

      await cliente.query('COMMIT');
    } catch (error) {
      await this.intentarRollback(cliente);
      await this.compensarRevisionMongo(
        idProducto,
        estadoARevertir,
        eventoABorrar,
      );
      if (
        error instanceof ErrorConflicto ||
        error instanceof ErrorNoEncontrado ||
        error instanceof ErrorValidacion
      ) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }

    return this.leerProducto(idProducto);
  }

  /**
   * El vendedor RE-ENVIA su propia propuesta rechazada: `rechazado` ->
   * `en_revision`, sin editar nada (por diseño una propuesta no se edita).
   * Solo el dueño de la propuesta (`propuesta_producto.id_usuario`); una
   * ajena o inexistente da el mismo 404 generico. La propuesta tiene que
   * estar `rechazado`; cualquier otro estado -> 409.
   *
   * Mismo lock que `revisarPropuesta()` (`SELECT ... FOR UPDATE` sobre
   * `propuesta_producto`), aunque aqui no haya escritura en Postgres: la
   * transaccion existe para serializar el cambio de estado contra una
   * revision simultanea.
   */
  async reenviarPropuesta(
    idUsuario: string,
    idProductoParametro: string,
  ): Promise<Producto> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);
    const coleccionProductos = mongoDb.collection<Producto>('productos');

    let estadoARevertir: string | null = null;
    let eventoABorrar: string | null = null;

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const bloqueo = await cliente.query<{ id_propuesta_producto: string }>(
        `SELECT id_propuesta_producto
           FROM propuesta_producto
          WHERE id_producto_mongo = $1 AND id_usuario = $2
          FOR UPDATE`,
        [idProducto, idUsuario],
      );
      if (bloqueo.rows[0] == null) {
        throw new ErrorNoEncontrado(
          'No existe una propuesta tuya para ese producto',
        );
      }

      const doc = await coleccionProductos.findOne(
        { _id: idProducto },
        { projection: { estado: 1 } },
      );
      if (doc?.estado !== 'rechazado') {
        throw new ErrorConflicto(
          `Solo se puede reenviar una propuesta rechazada (esta ${doc?.estado ?? 'sin producto'})`,
        );
      }

      await coleccionProductos.updateOne(
        { _id: idProducto },
        {
          $set: {
            estado: 'en_revision',
            pendiente_busqueda: true,
            pendiente_vector: true,
          },
        },
      );
      estadoARevertir = 'rechazado';
      eventoABorrar = await this.crearEventoModificacion(idProducto, {
        estado: 'en_revision',
      });

      await cliente.query('COMMIT');
    } catch (error) {
      await this.intentarRollback(cliente);
      await this.compensarRevisionMongo(
        idProducto,
        estadoARevertir,
        eventoABorrar,
      );
      if (
        error instanceof ErrorConflicto ||
        error instanceof ErrorNoEncontrado ||
        error instanceof ErrorValidacion
      ) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }

    return this.leerProducto(idProducto);
  }

  /** Lee un producto de Mongo por su _id. Lo usan revisar/reenviar al final. */
  private async leerProducto(idProducto: number): Promise<Producto> {
    try {
      const producto = await mongoDb
        .collection<Producto>('productos')
        .findOne({ _id: idProducto });
      if (producto == null) {
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

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo.
    }
  }

  /**
   * Deshace el cambio de estado y el evento que escribio revisar/reenviar
   * en Mongo, cuando la parte de Postgres fallo. Si esto tampoco funciona,
   * queda el producto con el estado nuevo pero sin el registro en Postgres
   * -- se registra y sigue el error original.
   */
  private async compensarRevisionMongo(
    idProducto: number,
    estadoARevertir: string | null,
    eventoABorrar: string | null,
  ): Promise<void> {
    if (estadoARevertir == null && eventoABorrar == null) {
      return;
    }
    try {
      if (eventoABorrar != null) {
        await mongoDb
          .collection<ProductoEventoModificacion>('productos_eventos')
          .deleteOne({ _id: eventoABorrar });
      }
      if (estadoARevertir != null) {
        await mongoDb
          .collection<Producto>('productos')
          .updateOne(
            { _id: idProducto },
            { $set: { estado: estadoARevertir } },
          );
      }
    } catch {
      this.logger.error(
        `No se pudo compensar la revision del producto ${idProducto} en Mongo`,
      );
    }
  }

  /**
   * Solo la cuenta de la tienda, o cualquier cuenta con rol admin, crea/edita/
   * consulta el catalogo por estas rutas (ver la nota de CORREO_TIENDA
   * arriba). El guard de rol (@Roles(ID_ROL_VENDEDOR, ID_ROL_ADMIN) en
   * ProductosVendedorController) ya deja pasar admin junto con vendedor;
   * esta funcion es el segundo filtro, mas fino, que distingue "vendedor
   * cualquiera" (rechazado) de "la tienda o un admin" (aceptado) dentro de
   * ese primer grupo. Un producto creado o editado por un admin no queda
   * marcado de ninguna forma especial: el documento en Mongo no tiene (ni
   * tuvo nunca, desde el giro multi-vendedor) un campo de dueño, asi que
   * sale identico sin importar si lo toco la tienda o un admin.
   *
   * Mismo 404 generico que el resto del proyecto usa para "no es tuyo": no
   * hay que confirmarle a un vendedor cualquiera que la ruta existe.
   */
  private async exigirTiendaOAdmin(idUsuario: string): Promise<void> {
    if (!(await this.esTiendaOAdmin(idUsuario))) {
      throw new ErrorNoEncontrado('No existe un producto con ese id');
    }
  }

  /**
   * Version que NO lanza, para las rutas donde la autorizacion tiene mas de
   * una via -- por ejemplo el historial de rechazos de una propuesta, que
   * puede ver la tienda/un admin (cualquiera) o el vendedor (solo la suya).
   */
  private async esTiendaOAdmin(idUsuario: string): Promise<boolean> {
    const usuario = await this.usuarioService.obtenerPorId(idUsuario);
    return (
      usuario.correo_electronico === CORREO_TIENDA ||
      usuario.id_rol_usuario === ID_ROL_ADMIN
    );
  }

  /**
   * El historial de rechazos de una propuesta. `:id` es el `_id` del
   * producto en Mongo.
   *
   * La ve **la tienda o un admin** (de cualquier propuesta) **o el
   * vendedor** que la propuso (solo la suya). Cualquier otro caso -- o una
   * propuesta que no existe -- da el mismo 404 generico. Una propuesta
   * propia que nunca fue rechazada devuelve `[]`, no 404.
   */
  async listarRechazosPropuesta(
    idUsuario: string,
    idProductoParametro: string,
  ): Promise<RechazoProducto[]> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    let propuesta: { id_propuesta_producto: string; id_usuario: string };
    try {
      const resultado = await pool.query<{
        id_propuesta_producto: string;
        id_usuario: string;
      }>(
        `SELECT id_propuesta_producto, id_usuario
           FROM propuesta_producto
          WHERE id_producto_mongo = $1`,
        [idProducto],
      );
      propuesta = resultado.rows[0];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (propuesta == null) {
      throw new ErrorNoEncontrado('No existe una propuesta para ese producto');
    }

    const esMia = propuesta.id_usuario === idUsuario;
    if (!esMia && !(await this.esTiendaOAdmin(idUsuario))) {
      throw new ErrorNoEncontrado('No existe una propuesta para ese producto');
    }

    try {
      const resultado = await pool.query<RechazoProducto>(
        `SELECT id_rechazo_producto, razon_rechazo, fecha_rechazo
           FROM rechazo_producto
          WHERE id_propuesta_producto = $1
          ORDER BY fecha_rechazo DESC, id_rechazo_producto DESC`,
        [propuesta.id_propuesta_producto],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** La categoria tiene que existir y no ser raiz, igual que en CategoriasService. */
  private async obtenerCategoriaValida(
    idCategoria: number,
  ): Promise<CategoriaDocumento> {
    const categoria = await mongoDb
      .collection<CategoriaDocumento>('categorias')
      .findOne({ _id: idCategoria, categoria_padre: { $ne: null } });

    if (categoria == null) {
      throw new ErrorValidacion(
        'La categoria no existe o no es valida para publicar',
      );
    }

    return categoria;
  }

  /** El siguiente id de producto: el maximo _id que ya existe, mas 1. */
  private async siguienteIdProducto(
    coleccion: Collection<Producto>,
  ): Promise<number> {
    const ultimo = await coleccion.find().sort({ _id: -1 }).limit(1).toArray();
    return (ultimo[0]?._id ?? 0) + 1;
  }

  /**
   * El siguiente id de variante: el maximo id_producto_variante entre TODAS
   * las variantes de TODOS los productos, mas 1 (no reinicia por producto).
   */
  private async siguienteIdVariante(
    coleccion: Collection<Producto>,
  ): Promise<number> {
    const resultado = await coleccion
      .aggregate<{ maximo: number | null }>([
        { $unwind: '$variantes' },
        {
          $group: {
            _id: null,
            maximo: { $max: '$variantes.id_producto_variante' },
          },
        },
      ])
      .toArray();

    return (resultado[0]?.maximo ?? 0) + 1;
  }

  /**
   * variantesExistentes es null en la creacion (nunca hay nada que
   * emparejar todavia) y es productoActual.variantes en la edicion. Cuando
   * viene, cada peticionVariante con id_producto_variante se busca ahi: si
   * hay una variante del producto con ese id, esta CONSERVA ese mismo id
   * (no consume uno de siguienteId) y su stock (la copia de lectura en
   * Mongo no se pierde solo por reenviar la variante en una edicion); si no
   * hay ninguna, se rechaza -- el id que mando el vendedor no es de este
   * producto. Sin id_producto_variante en la peticion, es una variante
   * nueva de verdad: id nuevo, sin stock, como siempre.
   */
  private async construirVariantes(
    peticiones: VarianteCreacionPeticion[],
    categoria: CategoriaDocumento,
    fechaCreacion: Date,
    coleccion: Collection<Producto>,
    variantesExistentes: ProductoVariante[] | null,
  ): Promise<ProductoVariante[]> {
    let siguienteId = await this.siguienteIdVariante(coleccion);

    const variantes = peticiones.map((peticionVariante) => {
      const nombreVariante = validarNombreVariante(
        peticionVariante.nombre_variante,
      );
      const descripcionVariante = validarDescripcionVariante(
        peticionVariante.descripcion,
      );
      const imagenes = validarImagenes(peticionVariante.imagenes);

      const caracteristicasAdicionales = validarCaracteristicasCatalogo(
        peticionVariante.caracteristicas_adicionales,
        categoria.caracteristicas_variante,
      );
      const caracteristicasPersonalizadas =
        validarCaracteristicasPersonalizadas(
          peticionVariante.caracteristicas_personalizadas,
        );

      let idProductoVariante: number;
      // undefined para una variante nueva de verdad: ahi si nace con los
      // valores por defecto de abajo. Si se encuentra, es la MISMA variante
      // de siempre, solo con nombre/descripcion/imagenes/caracteristicas
      // posiblemente editados -- todo lo que esta ruta no pregunta (cuando
      // nacio, su estado real, y los cinco campos calculados que solo
      // conoce ProductosService.recalcularCamposCalculados) tiene que
      // seguir siendo lo que ya era, no lo que esta funcion adivine.
      let existente: ProductoVariante | undefined;

      if (
        variantesExistentes != null &&
        peticionVariante.id_producto_variante != null
      ) {
        existente = variantesExistentes.find(
          (candidata) =>
            candidata.id_producto_variante ===
            peticionVariante.id_producto_variante,
        );
        if (existente == null) {
          throw new ErrorValidacion(
            `La variante ${peticionVariante.id_producto_variante} no pertenece a este producto`,
          );
        }
        idProductoVariante = existente.id_producto_variante;
      } else {
        idProductoVariante = siguienteId++;
      }

      const variante: ProductoVariante = {
        id_producto_variante: idProductoVariante,
        nombre_variante: nombreVariante,
        descripcion: descripcionVariante,
        // Una variante nueva nace hoy y activa. Una conservada mantiene su
        // fecha de nacimiento real y el estado que ya tenia -- ninguno de
        // los dos es un dato que esta ruta pida (VarianteCreacionPeticion
        // no tiene ni "fecha_creacion" ni "estado"), asi que no hay de
        // donde mas sacarlos que de la variante que ya existia.
        fecha_creacion: existente?.fecha_creacion ?? fechaCreacion,
        estado: existente?.estado ?? ESTADO_VARIANTE_NUEVA,
        imagenes,
        // Una variante nueva nace en 0/null: todavia no existe ninguna
        // oferta sobre ella. Una conservada mantiene lo que ya tenia
        // calculado -- estos cinco campos son copias de lo que hay en
        // PostgreSQL (ver ProductosService.recalcularCamposCalculados) y
        // esta ruta no toca ofertas, asi que nunca le corresponde
        // reiniciarlos a mitad de una edicion que no tiene nada que ver.
        precio_tienda: existente?.precio_tienda ?? null,
        precio_desde: existente?.precio_desde ?? null,
        stock_tienda: existente?.stock_tienda ?? 0,
        stock_total: existente?.stock_total ?? 0,
        total_ofertas: existente?.total_ofertas ?? 0,
        hay_descuento: existente?.hay_descuento ?? false,
        ...(caracteristicasAdicionales.length > 0 && {
          caracteristicas_adicionales: caracteristicasAdicionales,
        }),
        ...(caracteristicasPersonalizadas.length > 0 && {
          caracteristicas_personalizadas: caracteristicasPersonalizadas,
        }),
      };

      return variante;
    });

    // Una variante nunca se borra por omision: si `peticiones` no trae una
    // que el producto ya tenia, se conserva tal cual (nunca se elimina del
    // documento).
    if (variantesExistentes != null) {
      const idsEnPeticion = new Set(
        variantes.map((variante) => variante.id_producto_variante),
      );
      const faltantes = variantesExistentes.filter(
        (existente) => !idsEnPeticion.has(existente.id_producto_variante),
      );
      for (const faltante of faltantes) {
        validarCaracteristicasExistentesContraCategoria(
          faltante.caracteristicas_adicionales,
          categoria.caracteristicas_variante,
        );
      }
      variantes.push(...faltantes);
    }

    return variantes;
  }

  /** El primer evento del producto: numero 1, operacion "creacion", la copia completa del producto. */
  private async crearEventoCreacion(producto: Producto): Promise<void> {
    // Se desestructura _id a proposito para excluirlo de "datos" (el
    // evento ya lo guarda aparte, en id_producto).
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const { _id, ...datos } = producto;

    const evento: ProductoEventoCreacion = {
      _id: `${producto._id}-1`,
      id_producto: producto._id,
      numero: 1,
      fecha: producto.fecha_creacion,
      operacion: 'creacion',
      datos,
    };

    await mongoDb
      .collection<ProductoEventoCreacion>('productos_eventos')
      .insertOne(evento);
  }

  /**
   * Edita un producto del catalogo (solo la tienda o un admin): cualquier campo que tenga sentido cambiar
   * (nombre, descripcion, estado, categoria, sus caracteristicas, las
   * personalizadas, y las variantes).
   *
   * NO edita un producto que este en el flujo de propuesta (`en_revision`
   * o `rechazado`): esos dos estados solo se mueven por
   * `PATCH .../:id/revision` o `.../:id/reenviar` -- 409 por esta ruta. Ver
   * `ESTADOS_PRODUCTO_SOLO_REVISION`.
   *
   * Cada campo es independiente: el que venga en null (o no venga) no se
   * toca. Para las dos listas de caracteristicas, un array (aunque sea
   * vacio) reemplaza la lista completa; null es no tocarla. `variantes` es
   * distinto: no admite quedar vacio (siempre tiene que traer al menos una)
   * y NUNCA borra una variante que el producto ya tenia, aunque no venga en
   * el array -- las que el producto ya tenia y no vienen en el array se
   * conservan tal cual, sin tocarlas (una variante nunca desaparece por
   * omision). Si el array manda una variante existente, esa se edita (o se
   * deja igual, si no cambia nada de lo que esta ruta pregunta).
   *
   * Cada variante del array puede traer su id_producto_variante viejo: si
   * coincide con una que el producto ya tenia, esa CONSERVA su mismo id; si
   * no viene, es una variante nueva (id nuevo). Un id que no le pertenece a
   * este producto rechaza toda la edicion.
   *
   * El caso especial: si cambia la categoria, las caracteristicas (las que
   * ya tenia el producto, y las de cada variante que no se este
   * reemplazando en esta misma peticion) tienen que seguir siendo validas
   * para la categoria nueva. Si no vienen caracteristicas (ni variantes)
   * nuevas en la misma peticion, se revalidan las que ya existian contra
   * la categoria nueva, y se rechaza la edicion si alguna ya no encaja —
   * las caracteristicas siempre estan atadas a la categoria, nunca sueltas.
   */
  async editar(
    idProductoParametro: string,
    idUsuarioToken: string,
    cambios: EditarProductoPeticion,
  ): Promise<Producto> {
    // Primero que cualquier otra cosa, ni siquiera el formato del id --
    // mismo motivo que en crear(): el 404 disfrazado tiene que ganarle a
    // cualquier 400 de validacion, para no confirmarle a alguien sin
    // permiso que la ruta existe.
    await this.exigirTiendaOAdmin(idUsuarioToken);

    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    const nombre = cambios.nombre ?? null;
    if (nombre != null) {
      validarNombreProducto(nombre);
    }

    const descripcion = cambios.descripcion ?? null;
    if (descripcion != null && !esTextoNoVacio(descripcion)) {
      throw new ErrorValidacion('La descripcion no puede quedar vacia');
    }

    const estado = cambios.estado ?? null;
    if (estado != null) {
      validarEstadoProducto(estado);
    }

    const idCategoriaNueva = cambios.id_categoria ?? null;
    if (idCategoriaNueva != null && !Number.isInteger(idCategoriaNueva)) {
      throw new ErrorValidacion('El id de la categoria no es valido');
    }

    const vieneCaracteristicasAdicionales =
      cambios.caracteristicas_adicionales != null;
    const vieneCaracteristicasPersonalizadas =
      cambios.caracteristicas_personalizadas != null;

    const vieneVariantes = cambios.variantes != null;
    if (vieneVariantes && cambios.variantes!.length === 0) {
      throw new ErrorValidacion('Debes enviar al menos una variante');
    }

    if (
      nombre == null &&
      descripcion == null &&
      estado == null &&
      idCategoriaNueva == null &&
      !vieneCaracteristicasAdicionales &&
      !vieneCaracteristicasPersonalizadas &&
      !vieneVariantes
    ) {
      throw new ErrorValidacion(
        'Debes enviar al menos un campo para actualizar',
      );
    }

    const coleccion = mongoDb.collection<Producto>('productos');

    try {
      const productoActual = await coleccion.findOne({ _id: idProducto });
      if (productoActual == null) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }

      // Candado del flujo de propuesta: un producto `en_revision` o
      // `rechazado` NO se toca por esta ruta -- ni siquiera para cambiarle
      // el estado. La unica salida de esos dos estados es
      // `PATCH .../:id/revision` (aprobar/rechazar) o `.../:id/reenviar`,
      // que son las que dejan constancia en `propuesta_producto` de quien y
      // cuando. Sin esto, un `PATCH .../:id {estado:'activo'}` publicaba el
      // producto dejando la propuesta con `fecha_aprobacion = NULL` para
      // siempre (atascada en `/propuestas/sin-aprobar`, sin poder
      // reenviarse porque reenviar exige estado `rechazado`).
      if (ESTADOS_PRODUCTO_SOLO_REVISION.includes(productoActual.estado)) {
        throw new ErrorConflicto(
          `Este producto esta en el flujo de propuesta (${productoActual.estado}) y no se edita por aca: usa PATCH /vendedor/productos/:id/revision para aprobarlo o rechazarlo, o /reenviar si es una propuesta rechazada`,
        );
      }

      const categoriaCambia =
        idCategoriaNueva != null &&
        idCategoriaNueva !== productoActual.categoria.id_categoria;

      let categoriaCompleta: CategoriaDocumento | null = null;
      if (categoriaCambia) {
        categoriaCompleta = await this.obtenerCategoriaValida(idCategoriaNueva);
      } else if (vieneCaracteristicasAdicionales || vieneVariantes) {
        categoriaCompleta = await this.obtenerCategoriaPorId(
          productoActual.categoria.id_categoria,
        );
      }

      let caracteristicasAdicionales: EntradaCaracteristica[] | undefined;
      if (vieneCaracteristicasAdicionales) {
        caracteristicasAdicionales = validarCaracteristicasCatalogo(
          cambios.caracteristicas_adicionales as CaracteristicaCatalogoPeticion[],
          categoriaCompleta!.caracteristicas,
        );
      } else if (categoriaCambia) {
        validarCaracteristicasExistentesContraCategoria(
          productoActual.caracteristicas_adicionales,
          categoriaCompleta!.caracteristicas,
        );
      }

      // Las variantes que no se estan reemplazando en esta misma peticion
      // siguen teniendo que encajar con la categoria nueva, si cambio.
      if (categoriaCambia && !vieneVariantes) {
        for (const variante of productoActual.variantes) {
          validarCaracteristicasExistentesContraCategoria(
            variante.caracteristicas_adicionales,
            categoriaCompleta!.caracteristicas_variante,
          );
        }
      }

      let variantes: ProductoVariante[] | undefined;
      if (vieneVariantes) {
        variantes = await this.construirVariantes(
          cambios.variantes as VarianteCreacionPeticion[],
          categoriaCompleta!,
          new Date(),
          coleccion,
          productoActual.variantes,
        );
      }

      let caracteristicasPersonalizadas: EntradaCaracteristica[] | undefined;
      if (vieneCaracteristicasPersonalizadas) {
        caracteristicasPersonalizadas = validarCaracteristicasPersonalizadas(
          cambios.caracteristicas_personalizadas as CaracteristicaPersonalizadaPeticion[],
        );
      }

      // pendiente_busqueda/pendiente_vector van desde el inicio, no
      // condicionados a que campo cambie: cualquier edicion por esta ruta
      // (nombre, categoria, estado, caracteristicas, variantes) puede tocar
      // algo que el buscador indexa o que el vector representa, y decidir
      // cual es tarea de cada worker, no de aca -- VectoresSyncService
      // compara el hash del texto y no llama a Ollama si nombre/categoria/
      // descripcion no cambiaron de verdad (por ejemplo, si solo cambiaron
      // caracteristicas o variantes).
      const conjuntoSet: Record<string, unknown> = {
        pendiente_busqueda: true,
        pendiente_vector: true,
      };
      const conjuntoUnset: Record<string, ''> = {};
      const cambiosEvento: ProductoEventoCambios = {};

      if (nombre != null) {
        conjuntoSet.nombre = nombre;
        cambiosEvento.nombre = nombre;
      }
      if (descripcion != null) {
        conjuntoSet.descripcion = descripcion;
        cambiosEvento.descripcion = descripcion;
      }
      if (estado != null) {
        conjuntoSet.estado = estado;
        cambiosEvento.estado = estado;
      }
      if (categoriaCambia && categoriaCompleta != null) {
        const categoriaEmbebida: ProductoCategoria = {
          id_categoria: categoriaCompleta._id,
          nombre: categoriaCompleta.nombre,
          categoria_padre: categoriaCompleta.categoria_padre,
        };
        conjuntoSet.categoria = categoriaEmbebida;
        cambiosEvento.categoria = categoriaEmbebida;
      }
      if (caracteristicasAdicionales != null) {
        if (caracteristicasAdicionales.length > 0) {
          conjuntoSet.caracteristicas_adicionales = caracteristicasAdicionales;
        } else {
          conjuntoUnset.caracteristicas_adicionales = '';
        }
        cambiosEvento.caracteristicas_adicionales = caracteristicasAdicionales;
      }
      if (caracteristicasPersonalizadas != null) {
        if (caracteristicasPersonalizadas.length > 0) {
          conjuntoSet.caracteristicas_personalizadas =
            caracteristicasPersonalizadas;
        } else {
          conjuntoUnset.caracteristicas_personalizadas = '';
        }
        cambiosEvento.caracteristicas_personalizadas =
          caracteristicasPersonalizadas;
      }
      if (variantes != null) {
        conjuntoSet.variantes = variantes;
        cambiosEvento.variantes = variantes;
      }

      const operacion: Record<string, unknown> = {};
      if (Object.keys(conjuntoSet).length > 0) {
        operacion.$set = conjuntoSet;
      }
      if (Object.keys(conjuntoUnset).length > 0) {
        operacion.$unset = conjuntoUnset;
      }

      await coleccion.updateOne({ _id: idProducto }, operacion);
      await this.crearEventoModificacion(idProducto, cambiosEvento);

      return (await coleccion.findOne({ _id: idProducto })) as Producto;
    } catch (error) {
      if (
        error instanceof ErrorValidacion ||
        error instanceof ErrorNoEncontrado ||
        error instanceof ErrorConflicto
      ) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /** La categoria actual del producto, sin exigir que sea "valida": ya lo era cuando se creo. */
  private async obtenerCategoriaPorId(
    idCategoria: number,
  ): Promise<CategoriaDocumento> {
    const categoria = await mongoDb
      .collection<CategoriaDocumento>('categorias')
      .findOne({ _id: idCategoria });

    if (categoria == null) {
      throw new ErrorValidacion(
        'La categoria actual del producto ya no existe',
      );
    }

    return categoria;
  }

  /**
   * El siguiente evento del producto: el ultimo numero que tenga, mas 1.
   * Devuelve el `_id` del evento creado -- lo usa revisarPropuesta() para
   * poder borrarlo si tiene que compensar.
   */
  private async crearEventoModificacion(
    idProducto: number,
    cambios: ProductoEventoCambios,
  ): Promise<string> {
    const ultimo = await mongoDb
      .collection('productos_eventos')
      .find({ id_producto: idProducto })
      .sort({ numero: -1 })
      .limit(1)
      .toArray();

    const siguienteNumero = ((ultimo[0]?.numero as number) ?? 0) + 1;

    const evento: ProductoEventoModificacion = {
      _id: `${idProducto}-${siguienteNumero}`,
      id_producto: idProducto,
      numero: siguienteNumero,
      fecha: new Date(),
      operacion: 'modificacion',
      cambios,
    };

    await mongoDb
      .collection<ProductoEventoModificacion>('productos_eventos')
      .insertOne(evento);

    return evento._id;
  }

  /**
   * Todo el catalogo, en cualquier estado (incluyendo borrador e inactivo).
   * Antes era "los productos del vendedor logueado"; con el catalogo
   * compartido y solo la tienda (o un admin) creando/editando, "propio"
   * paso a ser "todo el catalogo, si sos la tienda o admin".
   */
  async listarPropios(idUsuario: string): Promise<Producto[]> {
    await this.exigirTiendaOAdmin(idUsuario);

    try {
      return await mongoDb
        .collection<Producto>('productos')
        .find({})
        .sort({ fecha_creacion: -1 })
        .toArray();
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Lo mismo que listarPropios() (todo el catalogo, en cualquier estado,
   * sin ninguna exclusion), pero paginado por numero de pagina -- igual
   * que GET /productos/paginacion, no por cursor -- y con un solo filtro
   * posible: `nombre`, "contiene" insensible a mayusculas y a tildes
   * (construirRegexNombreFlexible). Sin categoria, precio, stock ni
   * caracteristicas: ese filtrado es del catalogo publico, no de este
   * panel.
   *
   * Mismo patron de agregacion que ProductosService.listarPaginado()
   * ($facet: productos + total en una sola consulta), pero ordenado por
   * fecha_creacion descendente -- igual que listarPropios() sin paginar,
   * no por _id como el catalogo publico -- para que un admin vea primero
   * lo mas reciente.
   */
  async listarPropiosPaginado(
    idUsuario: string,
    query: PaginarProductosVendedorQuery,
  ): Promise<ProductosVendedorPaginados> {
    await this.exigirTiendaOAdmin(idUsuario);

    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);

    const filtro: Record<string, unknown> = {};
    if (query.nombre) {
      filtro.nombre = {
        $regex: construirRegexNombreFlexible(query.nombre),
        $options: 'i',
      };
    }

    const saltar = (pagina - 1) * limite;

    try {
      const pipeline: Document[] = [
        { $match: filtro },
        {
          $facet: {
            productos: [
              { $sort: { fecha_creacion: -1 } },
              { $skip: saltar },
              { $limit: limite },
            ],
            total: [{ $count: 'total' }],
          },
        },
      ];

      const [resultado] = await mongoDb
        .collection<Producto>('productos')
        .aggregate<{ productos: Producto[]; total: { total: number }[] }>(
          pipeline,
        )
        .toArray();

      const totalProductos = resultado.total[0]?.total ?? 0;
      const totalPaginas =
        totalProductos === 0 ? 0 : Math.ceil(totalProductos / limite);

      return {
        productos: resultado.productos,
        pagina,
        limite,
        total_productos: totalProductos,
        total_paginas: totalPaginas,
      };
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Un producto del catalogo, tal como esta hoy. Solo la tienda o un
   * admin puede pedirlo por esta ruta -- el chequeo va primero, antes
   * incluso del formato del id, mismo motivo que en crear()/editar().
   */
  async obtenerPropio(
    idProductoParametro: string,
    idUsuario: string,
  ): Promise<Producto> {
    await this.exigirTiendaOAdmin(idUsuario);

    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    try {
      const producto = await mongoDb
        .collection<Producto>('productos')
        .findOne({ _id: idProducto });

      if (producto == null) {
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

  /**
   * Reconstruye un producto del catalogo (solo la tienda o un admin) como
   * estaba en una fecha especifica. La reconstruccion en si (el pipeline
   * de agregacion de Mongo sobre productos_eventos) vive en
   * ProductosService.reconstruirEnFecha() -- ya no es exclusiva de la
   * tienda (ver GET /productos/:id/historial, general), asi que esta
   * funcion solo agrega el chequeo de "tienda o admin" antes de delegar.
   */
  async obtenerHistorialPropio(
    idProductoParametro: string,
    idUsuario: string,
    fecha: string | undefined,
  ): Promise<Producto> {
    await this.exigirTiendaOAdmin(idUsuario);
    return this.productosService.reconstruirEnFecha(idProductoParametro, fecha);
  }
}
