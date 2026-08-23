import { Injectable, Logger } from '@nestjs/common';
import { Collection, Decimal128 } from 'mongodb';
import { mongoDb } from '../../database/mongo';
import { ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { esTextoNoVacio } from '../../helpers/validaciones-perfil';
// Reusada tal cual: la fecha de un historial se valida igual aqui que en
// GET /direccion-usuario/historial (formato AAAA-MM-DD, fecha real).
import { validarFechaHistorial } from '../../helpers/validaciones-direccion';
import {
  validarCaracteristicasCatalogo,
  validarCaracteristicasExistentesContraCategoria,
  validarCaracteristicasPersonalizadas,
  validarDescripcionVariante,
  validarEstadoProducto,
  validarImagenes,
  validarNombreProducto,
  validarNombreVariante,
  validarPrecioObligatorio,
} from '../../helpers/validaciones-crear-producto';
import { validarStockInicial } from '../../helpers/validaciones-inventario';
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
import { InventarioVendedorService } from '../../services/vendedores/inventario.service';

const ESTADO_PRODUCTO_NUEVO = 'borrador';
const ESTADO_VARIANTE_NUEVA = 'activa';
const REGEX_ID = /^\d+$/;

/**
 * Sin variantes[].stock: estas rutas son las "rapidas" del panel del
 * vendedor (listar y ver el propio, tal como esta hoy). El stock/inventario
 * va a tener sus propios GET aparte, todavia no hechos.
 */
const PROYECCION_SIN_STOCK = { 'variantes.stock': 0 };

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
    private readonly inventarioVendedorService: InventarioVendedorService,
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
    // Se valida antes de crear nada: un stock_inicial invalido rechaza toda
    // la creacion, en vez de crear el producto y fallar despues creando su
    // inventario a medias.
    for (const peticionVariante of datos.variantes) {
      if (peticionVariante?.stock_inicial != null) {
        validarStockInicial(peticionVariante.stock_inicial);
      }
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

      const vendedor = await this.usuarioService.obtenerPorId(idUsuario);

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
        vendedor: {
          id_usuario: Number(vendedor.id_usuario),
          usuario: vendedor.usuario,
          nombre: vendedor.nombre,
          apellido: vendedor.apellido ?? '',
        },
        categoria: {
          id_categoria: categoria._id,
          nombre: categoria.nombre,
          categoria_padre: categoria.categoria_padre as string,
          porcentaje_comision: categoria.porcentaje_comision,
        },
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

      await this.crearInventariosIniciales(idProducto, idUsuario, datos.variantes, variantes);

      return producto;
    } catch (error) {
      if (error instanceof ErrorValidacion) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Por cada variante que trajo stock_inicial, crea su inventario real en
   * PostgreSQL reutilizando InventarioVendedorService.crearInicial() tal
   * cual (mismo mecanismo que POST /vendedor/productos/:id/inventario), una
   * variante a la vez.
   *
   * El producto ya esta creado y confirmado en Mongo en este punto: si
   * crear el inventario de alguna variante fallara (por ejemplo, PostgreSQL
   * no responde), el producto se queda creado igual — esa variante nace en
   * el mismo estado de hoy (sin inventario, arreglable despues con
   * POST /vendedor/productos/:id/inventario). Por eso el error solo se
   * loguea, nunca se relanza.
   */
  private async crearInventariosIniciales(
    idProducto: number,
    idUsuario: string,
    peticionesVariantes: VarianteCreacionPeticion[],
    variantesCreadas: ProductoVariante[],
  ): Promise<void> {
    for (let i = 0; i < variantesCreadas.length; i++) {
      const stockInicial = peticionesVariantes[i]?.stock_inicial;
      if (stockInicial == null) {
        continue;
      }
      try {
        await this.inventarioVendedorService.crearInicial(
          String(idProducto),
          idUsuario,
          {
            id_producto_variante: variantesCreadas[i].id_producto_variante,
            stock_inicial: stockInicial,
          },
        );
      } catch (error) {
        this.logger.warn(
          `No se pudo crear el inventario inicial de la variante ${variantesCreadas[i].id_producto_variante} ` +
            `del producto ${idProducto}: ${error instanceof Error ? error.message : error}`,
        );
      }
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

    return peticiones.map((peticionVariante) => {
      const nombreVariante = validarNombreVariante(
        peticionVariante.nombre_variante,
      );
      const precio = validarPrecioObligatorio(peticionVariante.precio);
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
      let stockExistente: number | undefined;

      if (variantesExistentes != null && peticionVariante.id_producto_variante != null) {
        const existente = variantesExistentes.find(
          (candidata) =>
            candidata.id_producto_variante === peticionVariante.id_producto_variante,
        );
        if (existente == null) {
          throw new ErrorValidacion(
            `La variante ${peticionVariante.id_producto_variante} no pertenece a este producto`,
          );
        }
        idProductoVariante = existente.id_producto_variante;
        stockExistente = existente.stock;
      } else {
        idProductoVariante = siguienteId++;
      }

      const variante: ProductoVariante = {
        id_producto_variante: idProductoVariante,
        nombre_variante: nombreVariante,
        precio: Decimal128.fromString(precio),
        descripcion: descripcionVariante,
        fecha_creacion: fechaCreacion,
        estado: ESTADO_VARIANTE_NUEVA,
        imagenes,
        ...(stockExistente != null && { stock: stockExistente }),
        ...(caracteristicasAdicionales.length > 0 && {
          caracteristicas_adicionales: caracteristicasAdicionales,
        }),
        ...(caracteristicasPersonalizadas.length > 0 && {
          caracteristicas_personalizadas: caracteristicasPersonalizadas,
        }),
      };

      return variante;
    });
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
   * Edita un producto propio: cualquier campo que tenga sentido cambiar
   * (nombre, descripcion, estado, categoria, sus caracteristicas, las
   * personalizadas, y las variantes).
   *
   * Cada campo es independiente: el que venga en null (o no venga) no se
   * toca. Para las dos listas de caracteristicas, un array (aunque sea
   * vacio) reemplaza la lista completa; null es no tocarla. `variantes`
   * funciona igual salvo que no admite quedar vacio: si se manda, se
   * reemplaza completo (mismas reglas que al crear), pero siempre tiene que
   * traer al menos una.
   *
   * Cada variante del array puede traer su id_producto_variante viejo: si
   * coincide con una que el producto ya tenia, esa CONSERVA su mismo id y
   * su stock (nunca se pierde solo por reenviarla en una edicion); si no
   * viene, es una variante nueva (id nuevo, sin stock). Un id que no le
   * pertenece a este producto rechaza toda la edicion.
   *
   * Tambien puede traer stock_inicial (igual que al crear un producto): si
   * la variante (nueva, o conservada pero sin inventario todavia) no tiene
   * fila en inventario, se le crea de una vez, reutilizando el mismo
   * mecanismo de POST /vendedor/productos/:id/inventario. Si ya la tenia,
   * no pasa nada (se ignora, no se sobreescribe).
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
    // Igual que en crear(): se valida antes de escribir nada, para que un
    // stock_inicial invalido rechace toda la edicion en vez de dejarla a
    // medias.
    if (vieneVariantes) {
      for (const peticionVariante of cambios.variantes!) {
        if (peticionVariante?.stock_inicial != null) {
          validarStockInicial(peticionVariante.stock_inicial);
        }
      }
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
      const productoActual = await coleccion.findOne({ _id: idProducto });
      if (
        productoActual == null ||
        Number(productoActual.vendedor.id_usuario) !== Number(idUsuarioToken)
      ) {
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
          porcentaje_comision: categoriaCompleta.porcentaje_comision,
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

      if (variantes != null) {
        await this.crearInventariosIniciales(
          idProducto,
          idUsuarioToken,
          cambios.variantes as VarianteCreacionPeticion[],
          variantes,
        );
      }

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

  /** Todos los productos del vendedor logueado, en cualquier estado (incluyendo borrador e inactivo). */
  async listarPropios(idUsuario: string): Promise<Producto[]> {
    try {
      return await mongoDb
        .collection<Producto>('productos')
        .find(
          { 'vendedor.id_usuario': Number(idUsuario) },
          { projection: PROYECCION_SIN_STOCK },
        )
        .sort({ fecha_creacion: -1 })
        .toArray();
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /** Un producto propio, tal como esta hoy. Solo si es del vendedor logueado. */
  async obtenerPropio(
    idProductoParametro: string,
    idUsuario: string,
  ): Promise<Producto> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    try {
      const producto = await mongoDb
        .collection<Producto>('productos')
        .findOne({ _id: idProducto }, { projection: PROYECCION_SIN_STOCK });

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

  /**
   * Reconstruye un producto propio como estaba en una fecha especifica:
   * toma el evento de creacion y todos los de modificacion anteriores a
   * esa fecha (o de ese mismo dia), en orden, y los va fusionando uno
   * encima del otro con el framework de agregacion de Mongo ($match,
   * $sort, $group, $reduce, $mergeObjects) — sin traer los eventos a
   * Node.js para combinarlos ahi.
   *
   * Cada evento aporta "datos" (solo la creacion) o "cambios" (solo las
   * modificaciones); como cada uno es el estado completo de lo que cambio
   * (nunca un campo suelto), fusionarlos en orden con $mergeObjects
   * reconstruye el documento tal como estaba ese dia. Igual que ya se
   * explica en ejemplos_bson_productos.md, pero aplicado por la propia
   * base de datos en vez de en el codigo.
   */
  async obtenerHistorialPropio(
    idProductoParametro: string,
    idUsuario: string,
    fecha: string | undefined,
  ): Promise<Producto> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    validarFechaHistorial(fecha);
    const idProducto = Number(idProductoParametro);

    try {
      const productoActual = await mongoDb
        .collection<Producto>('productos')
        .findOne({ _id: idProducto });

      if (
        productoActual == null ||
        Number(productoActual.vendedor.id_usuario) !== Number(idUsuario)
      ) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }

      // "hasta ese dia completo": el limite es la medianoche del dia
      // siguiente, igual que en GET /direccion-usuario/historial.
      //
      // El dia se cuenta en la zona de Guatemala (-06:00), no en UTC. Con UTC
      // el corte caia seis horas antes: un producto creado a las 21:45 del 22
      // se guarda como 03:45Z del 23, asi que preguntar por el 22 contestaba
      // "el producto no existia en esa fecha" el mismo dia en que se publico.
      // Cualquier cosa hecha despues de las 6 de la tarde caia en el dia
      // siguiente. Guatemala no cambia de hora, asi que -06:00 vale todo el
      // ano y no hace falta una libreria de zonas.
      const fechaLimite = new Date(`${fecha}T00:00:00.000-06:00`);
      fechaLimite.setUTCDate(fechaLimite.getUTCDate() + 1);

      const resultado = await mongoDb
        .collection('productos_eventos')
        .aggregate([
          { $match: { id_producto: idProducto, fecha: { $lt: fechaLimite } } },
          { $sort: { numero: 1 } },
          {
            $group: {
              _id: '$id_producto',
              eventos: { $push: { datos: '$datos', cambios: '$cambios' } },
            },
          },
          {
            $project: {
              _id: 0,
              producto: {
                $reduce: {
                  input: '$eventos',
                  initialValue: {},
                  in: {
                    $mergeObjects: [
                      '$$value',
                      { $ifNull: ['$$this.datos', {}] },
                      { $ifNull: ['$$this.cambios', {}] },
                    ],
                  },
                },
              },
            },
          },
        ])
        .toArray();

      if (resultado.length === 0) {
        throw new ErrorNoEncontrado('El producto no existia en esa fecha');
      }

      return { _id: idProducto, ...(resultado[0].producto as object) } as Producto;
    } catch (error) {
      if (error instanceof ErrorValidacion || error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }
  }
}
