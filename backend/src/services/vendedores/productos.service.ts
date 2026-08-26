import { Injectable, Logger } from '@nestjs/common';
import { Collection } from 'mongodb';
import { mongoDb } from '../../database/mongo';
import { ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
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
  CaracteristicaCatalogoPeticion,
  CaracteristicaPersonalizadaPeticion,
  CrearProductoPeticion,
  VarianteCreacionPeticion,
} from '../../dto/crear-producto';
import { EditarProductoPeticion } from '../../dto/editar-producto';
import { CategoriaDocumento } from '../../models/categoria';
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
const ESTADO_VARIANTE_NUEVA = 'activa';
const REGEX_ID = /^\d+$/;

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

  async crear(idUsuario: string, datos: CrearProductoPeticion): Promise<Producto> {
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
      const caracteristicasPersonalizadas = validarCaracteristicasPersonalizadas(
        datos.caracteristicas_personalizadas,
      );

      await this.exigirTiendaOAdmin(idUsuario);

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
          categoria_padre: categoria.categoria_padre as string,
        },
        // Los cuatro calculados nacen en 0/null: todavia no existe ninguna
        // oferta sobre este producto (eso es de otro servicio, sobre
        // `oferta` en PostgreSQL).
        precio_tienda: null,
        precio_desde: null,
        stock_tienda: 0,
        stock_total: 0,
        total_ofertas: 0,
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
    const usuario = await this.usuarioService.obtenerPorId(idUsuario);
    if (usuario.correo_electronico !== CORREO_TIENDA && usuario.id_rol_usuario !== ID_ROL_ADMIN) {
      throw new ErrorNoEncontrado('No existe un producto con ese id');
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
    const ultimo = await coleccion
      .find()
      .sort({ _id: -1 })
      .limit(1)
      .toArray();
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
        { $group: { _id: null, maximo: { $max: '$variantes.id_producto_variante' } } },
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
      const caracteristicasPersonalizadas = validarCaracteristicasPersonalizadas(
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

      if (variantesExistentes != null && peticionVariante.id_producto_variante != null) {
        existente = variantesExistentes.find(
          (candidata) =>
            candidata.id_producto_variante === peticionVariante.id_producto_variante,
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
      throw new ErrorValidacion('Debes enviar al menos un campo para actualizar');
    }

    const coleccion = mongoDb.collection<Producto>('productos');

    try {
      await this.exigirTiendaOAdmin(idUsuarioToken);

      const productoActual = await coleccion.findOne({ _id: idProducto });
      if (productoActual == null) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }

      const categoriaCambia =
        idCategoriaNueva != null &&
        idCategoriaNueva !== productoActual.categoria.id_categoria;

      let categoriaCompleta: CategoriaDocumento | null = null;
      if (categoriaCambia) {
        categoriaCompleta = await this.obtenerCategoriaValida(idCategoriaNueva!);
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

      const conjuntoSet: Record<string, unknown> = {};
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
          categoria_padre: categoriaCompleta.categoria_padre as string,
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
          conjuntoSet.caracteristicas_personalizadas = caracteristicasPersonalizadas;
        } else {
          conjuntoUnset.caracteristicas_personalizadas = '';
        }
        cambiosEvento.caracteristicas_personalizadas = caracteristicasPersonalizadas;
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
      if (error instanceof ErrorValidacion || error instanceof ErrorNoEncontrado) {
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
      throw new ErrorValidacion('La categoria actual del producto ya no existe');
    }

    return categoria;
  }

  /** El siguiente evento del producto: el ultimo numero que tenga, mas 1. */
  private async crearEventoModificacion(
    idProducto: number,
    cambios: ProductoEventoCambios,
  ): Promise<void> {
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

  /** Un producto del catalogo, tal como esta hoy. Solo la tienda o un admin puede pedirlo por esta ruta. */
  async obtenerPropio(
    idProductoParametro: string,
    idUsuario: string,
  ): Promise<Producto> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    await this.exigirTiendaOAdmin(idUsuario);

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
