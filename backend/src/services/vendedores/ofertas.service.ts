import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
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
  validarDecisionRevision,
  validarEstadoOferta,
  validarRazonRechazo,
} from '../../helpers/validaciones-oferta';
import {
  AprobadorOferta,
  OfertaPendiente,
  OfertaPropia,
  OfertaPropiaResumen,
} from '../../models/oferta';
import { RechazoOferta } from '../../models/rechazo-oferta';
import { Producto } from '../../models/producto';
import { ESTADO_PRODUCTO_VISIBLE } from '../../models/estado-producto';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { CrearOfertaPeticion } from '../../dto/crear-oferta';
import { EditarOfertaPeticion } from '../../dto/editar-oferta';
import { RevisarOfertaPeticion } from '../../dto/revisar-oferta';
import {
  ProductoConMisOfertas,
  ProductoVarianteConMiOferta,
} from '../../dto/producto-con-mis-ofertas';
import { ProductosService } from '../productos/productos.service';
import { CORREO_TIENDA } from '../../helpers/constantes';

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
  /** NULL mientras la tienda no la haya aprobado (ver flujo de aprobacion de ofertas). */
  fecha_aprobacion: Date | null;
  /** NULL si no consta aprobador: oferta de la tienda/admin, o anterior al flujo. */
  id_usuario_aprobo: string | null;
  aprobo_usuario: string | null;
  aprobo_nombre: string | null;
  aprobo_apellido: string | null;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}

/** Fila cruda de la cola de revisión: `oferta` pendiente + su vendedor (JOIN a `usuarios`). */
interface FilaOfertaPendiente {
  id_oferta: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  precio: string;
  stock: number;
  fecha_creacion: Date;
  id_usuario: string;
  usuario: string;
  nombre: string;
  apellido: string | null;
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
  /** now() si nace `activa` (tienda/admin); NULL si nace `pendiente`. */
  fecha_aprobacion: Date | null;
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
 * catalogo (que decidimos que es solo de tienda@mesh.com o de una cuenta
 * admin, ver cambios-multivendedor.md seccion 9), publicar una OFERTA
 * sobre un producto que ya existe es justo lo que cualquier vendedor
 * puede hacer -- es el corazon del modelo multi-vendedor. El guard de rol
 * (@Roles(ID_ROL_VENDEDOR, ID_ROL_ADMIN) en OfertasVendedorController)
 * deja pasar tanto a un vendedor como a un admin.
 *
 * OJO: un admin NO opera bajo su propia cuenta aqui. Decision explicita
 * del equipo (25 ago 2026): un admin que crea, edita o lista ofertas lo
 * hace **como la cuenta de la tienda** (tienda@mesh.com) -- no como un
 * vendedor mas con su propio id_usuario. resolverIdEfectivo(), llamada al
 * principio de las cuatro acciones publicas de esta clase, es la que hace
 * ese cambio: si quien esta logueado es admin, sustituye el idUsuario del
 * token por el id_usuario real de tienda@mesh.com antes de tocar
 * cualquier otra cosa. Para un vendedor que no es admin, no cambia nada
 * -- sigue actuando bajo su propia cuenta, como siempre.
 */
@Injectable()
export class OfertasVendedorService {
  private readonly logger = new Logger(OfertasVendedorService.name);

  constructor(private readonly productosService: ProductosService) {}

  /**
   * El id_usuario que de verdad hay que usar para el resto de la
   * operacion. Si quien esta logueado es admin, sustituye por el
   * id_usuario real de la cuenta de la tienda (tienda@mesh.com) -- toda
   * oferta que cree, edite o liste un admin es, a todos los efectos, una
   * oferta de la tienda (misma cuenta que ve `es_tienda: true` y alimenta
   * `precio_tienda`/`stock_tienda` en el catalogo publico). Para
   * cualquier otro rol (vendedor normal) no hace nada: devuelve el mismo
   * idUsuario que ya traia.
   *
   * Si la cuenta de la tienda no existiera (no deberia pasar nunca, es
   * parte de los datos base) falla fuerte en vez de dejar a un admin
   * operando por accidente bajo su propia cuenta.
   */
  private async resolverIdEfectivo(
    idUsuario: string,
    idRolUsuario: number,
  ): Promise<string> {
    if (idRolUsuario !== ID_ROL_ADMIN) {
      return idUsuario;
    }
    return this.obtenerIdTienda();
  }

  /**
   * Segundo filtro, más fino, para las rutas que son solo de la tienda o
   * de un admin (la cola de revisión de ofertas pendientes) -- el mismo
   * papel que `ProductosVendedorService.exigirTiendaOAdmin`, pero aquí sin
   * pedir el registro del usuario: el rol viene del token y la identidad
   * de la tienda se compara contra `obtenerIdTienda()`.
   *
   * Un vendedor cualquiera recibe el **mismo 404 genérico** que usa el
   * resto del proyecto para "no es tuyo": no se le confirma que la ruta
   * existe.
   */
  private async exigirTiendaOAdmin(
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<void> {
    if (!(await this.esTiendaOAdmin(idUsuarioToken, idRolUsuario))) {
      throw new ErrorNoEncontrado('No existe una oferta con ese id');
    }
  }

  /**
   * Version que NO lanza, para las rutas donde la autorizacion tiene mas de
   * una via -- el historial de rechazos de una oferta, que puede ver la
   * tienda/un admin (cualquiera) o el vendedor (solo la suya).
   */
  private async esTiendaOAdmin(
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<boolean> {
    if (idRolUsuario === ID_ROL_ADMIN) {
      return true;
    }
    const idTienda = await this.obtenerIdTienda();
    return idUsuarioToken === idTienda;
  }

  /**
   * El id_usuario real de la cuenta de la tienda (tienda@mesh.com),
   * resuelto por correo contra la base -- nunca por un id fijo. Si no
   * existe (no deberia pasar nunca, es parte de los datos base) falla
   * fuerte en vez de seguir con un id equivocado.
   */
  private async obtenerIdTienda(): Promise<string> {
    try {
      const resultado = await pool.query<{ id_usuario: string }>(
        'SELECT id_usuario FROM usuarios WHERE correo_electronico = $1',
        [CORREO_TIENDA],
      );
      const fila = resultado.rows[0];
      if (fila == null) {
        throw new Error('No existe la cuenta de la tienda (tienda@mesh.com)');
      }
      return fila.id_usuario;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Publica una oferta sobre una variante que ya existe en el catalogo.
   * Cualquier vendedor o admin, no solo tienda -- esto es justo lo que
   * hace a alguien vendedor en el modelo multi-vendedor.
   *
   * **El estado con el que nace depende de quien la crea** (ver
   * `elementos Generales/plan pendiente/aceptacion-de-ofertas.md`):
   *   - La tienda (tienda@mesh.com) y los admin -- que actuan como la
   *     tienda -- nacen `activa` y con `fecha_aprobacion = now()`: son la
   *     autoridad del catalogo, no se aprueban a si mismos.
   *   - Cualquier otro vendedor nace `pendiente` y con `fecha_aprobacion`
   *     en NULL: no circula (la ficha publica, los campos calculados y la
   *     compra ya filtran por `activa`) hasta que la tienda la apruebe con
   *     `PATCH /vendedor/ofertas/:id/revision`.
   *
   * Nace con `stock = 0`; si viene `stock_inicial > 0` se repone aparte,
   * con `reponer_stock`, para que el kardex explique tambien esas unidades
   * (nunca se mete stock directo en el INSERT). El stock se repone aunque
   * la oferta este `pendiente` -- el kardex es independiente del estado.
   *
   * Si quien crea es admin, la oferta nace bajo la cuenta de la tienda,
   * no bajo la del admin (ver resolverIdEfectivo() arriba).
   *
   * Solo sobre productos activos: uno oculto (`inactivo`/`borrador`) da el
   * mismo 404 que uno que no existe, igual que en el catalogo publico y en
   * `agregar_linea` -- nadie mas lo ve, no deberia poder recibir una oferta
   * nueva tampoco.
   */
  async crear(
    idUsuarioToken: string,
    idRolUsuario: number,
    datos: CrearOfertaPeticion,
  ): Promise<OfertaPropia> {
    const idTienda = await this.obtenerIdTienda();
    const idUsuario =
      idRolUsuario === ID_ROL_ADMIN ? idTienda : idUsuarioToken;
    // La tienda (y los admin, que actuan como ella) publican ya aprobado y
    // activo; cualquier otro vendedor nace `pendiente`.
    const esCuentaTienda = idUsuario === idTienda;
    const estadoInicial = esCuentaTienda ? 'activa' : 'pendiente';

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
        `INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario, precio, id_estado_oferta, fecha_aprobacion)
         VALUES ($1, $2, $3, $4,
                 (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = $5),
                 CASE WHEN $5 = 'activa' THEN now() ELSE NULL END)
         RETURNING id_oferta, precio, stock, fecha_aprobacion, fecha_creacion, fecha_actualizacion`,
        [idProducto, idProductoVariante, idUsuario, precio, estadoInicial],
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
      estado: estadoInicial,
      // Recien creada nunca hay aprobador: la tienda/admin nace `activa` sin
      // revisor (fecha puesta, aprobado_por null), y cualquier otro vendedor
      // nace `pendiente` (las dos cosas null).
      fecha_aprobacion: filaOferta.fecha_aprobacion,
      aprobado_por: null,
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
   *   - `estado`: un UPDATE sobre `oferta.id_estado_oferta`. Para una
   *     oferta **ya aprobada** (`fecha_aprobacion` no NULL) el dueno la
   *     maneja como quiera, incluida "retirada" hacia "activa" de nuevo.
   *     Para una oferta que **nunca fue aprobada** (`fecha_aprobacion`
   *     NULL: esta `pendiente`, `rechazada`, o `retirada` sin haber pasado
   *     por revision) el vendedor no puede ponerla `activa` ni `pausada`
   *     por su cuenta (409) -- solo `retirada`; y cualquier otra edicion
   *     (precio y/o stock) la deja o la devuelve a `pendiente`, para que
   *     la tienda la revise de nuevo. Es el mecanismo de re-envio tras un
   *     rechazo, sin recrear la oferta (ver plan pendiente/aceptacion-de-ofertas.md).
   *   - `ajuste_stock`: un entero con signo, nunca 0. Positivo llama a
   *     `reponer_stock(..., 'reposicion', ...)`, negativo llama con
   *     'ajuste' y la magnitud (`Math.abs`) -- los mismos dos motivos que
   *     ya admite esa funcion fuera del flujo del pedido. Es la misma
   *     correccion manual (sube o baja) que ya existia en el modelo viejo
   *     de inventario, ahora sobre la oferta.
   *
   * Solo el dueno de la oferta -- una ajena da el mismo 404 generico que
   * una que no existe, mismo criterio de siempre. Si quien edita es
   * admin, "dueno" se resuelve como la cuenta de la tienda (ver
   * resolverIdEfectivo() arriba): un admin puede editar cualquier oferta
   * de la tienda, pero sigue sin poder tocar la de otro vendedor.
   *
   * El UPDATE de precio/estado y el SELECT reponer_stock() van en una
   * sola transaccion (BEGIN/COMMIT con un cliente dedicado, no con
   * pool.query), igual que ya se hace en direccion-usuario.service.ts y
   * en comprarPedido(): si el ajuste de stock revienta (por ejemplo,
   * dejaria el stock en negativo), el ROLLBACK deshace tambien el cambio
   * de precio/estado, para que nunca quede un precio nuevo guardado
   * mientras el ajuste que vino junto con el fallo.
   */
  async editar(
    idUsuarioToken: string,
    idRolUsuario: number,
    idOfertaParametro: string,
    datos: EditarOfertaPeticion,
  ): Promise<OfertaPropia> {
    const idUsuario = await this.resolverIdEfectivo(idUsuarioToken, idRolUsuario);
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

    // Comprueba dueno y de paso trae los ids de Mongo y si ya fue aprobada
    // -- se pide antes de tocar nada, para no dejar un cambio a medias si
    // la oferta es ajena.
    const filaActual = await this.obtenerFilaPropia(idOferta, idUsuario);
    const nuncaAprobada = filaActual.fecha_aprobacion == null;

    // Que estado va a quedar escrito. Para una oferta aprobada, lo que pida
    // el vendedor tal cual (comportamiento de siempre). Para una que nunca
    // fue aprobada: no puede autoactivarse ni pausarse; si el vendedor la
    // retira se respeta; cualquier otra edicion la (de)vuelve a `pendiente`.
    let estadoAEscribir = estado;
    if (nuncaAprobada) {
      if (estado === 'activa' || estado === 'pausada') {
        throw new ErrorConflicto(
          'Esta oferta todavia no fue aprobada por la tienda: no puedes activarla ni pausarla. Editala (precio o stock) y queda pendiente de revision otra vez.',
        );
      }
      if (estado == null) {
        estadoAEscribir = 'pendiente';
      }
    }

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      if (precio != null || estadoAEscribir != null) {
        const asignaciones: string[] = [];
        const valores: unknown[] = [];
        if (precio != null) {
          asignaciones.push(`precio = $${valores.length + 1}`);
          valores.push(precio);
        }
        if (estadoAEscribir != null) {
          asignaciones.push(
            `id_estado_oferta = (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = $${valores.length + 1})`,
          );
          valores.push(estadoAEscribir);
        }
        valores.push(idOferta);

        await cliente.query(
          `UPDATE oferta SET ${asignaciones.join(', ')} WHERE id_oferta = $${valores.length}`,
          valores,
        );
      }

      if (ajusteStock != null) {
        const motivo = ajusteStock > 0 ? 'reposicion' : 'ajuste';
        const cantidad = Math.abs(ajusteStock);
        await cliente.query('SELECT reponer_stock($1, $2, $3, $4)', [
          idOferta,
          cantidad,
          motivo,
          idUsuario,
        ]);
      }

      await cliente.query('COMMIT');
    } catch (error) {
      await this.intentarRollback(cliente);
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }

    const filaFinal = await this.obtenerFilaPropia(idOferta, idUsuario);
    await this.productosService.recalcularCamposCalculados([
      Number(filaFinal.id_producto_mongo),
    ]);
    return this.armarOfertaPropia(filaFinal);
  }

  /**
   * Revisa una oferta pendiente: la aprueba (pasa a `activa`, le pone
   * `fecha_aprobacion` y guarda en `id_usuario_aprobo` quien la reviso) o
   * la rechaza (pasa a `rechazada` y guarda el motivo en `rechazo_oferta`).
   * `:id` es `id_oferta`.
   *
   * Solo la cuenta de la tienda o un admin -- un vendedor cualquiera, aun
   * siendo el dueno de la oferta, recibe el **404 disfrazado**: no aprueba
   * su propia oferta. `exigirTiendaOAdmin()` va lo primero, antes de
   * validar el id o el cuerpo, para no revelar que la ruta existe.
   *
   * La comprobacion de que la oferta siga `pendiente` va DENTRO de la
   * transaccion, con `SELECT ... FOR UPDATE`: si dos revisiones caen a la
   * vez sobre la misma oferta, la segunda se queda esperando y al
   * desbloquearse ve el estado ya cambiado y responde 409 -- nunca queda
   * una oferta aprobada y rechazada a la vez. Mismo patron que
   * `PedidosCompradorService.comprarPedido()`.
   *
   * El bloqueo es sobre `oferta` a secas, SIN join a `estado_oferta`: con
   * el join, cuando la otra transaccion cambia `id_estado_oferta` y hace
   * commit, el EvalPlanQual de Postgres re-evalua la fila contra la
   * version vieja de `estado_oferta` y la descarta -- el perdedor de la
   * carrera recibiria un 404 en vez del 409. El nombre del estado se
   * resuelve en una segunda consulta, ya con la fila bloqueada.
   *
   * En el rechazo, el `UPDATE oferta` y el `INSERT rechazo_oferta` van en
   * la misma transaccion: o los dos o ninguno.
   */
  async revisar(
    idUsuarioToken: string,
    idRolUsuario: number,
    idOfertaParametro: string,
    datos: RevisarOfertaPeticion,
  ): Promise<OfertaPropia> {
    await this.exigirTiendaOAdmin(idUsuarioToken, idRolUsuario);

    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idOferta = Number(idOfertaParametro);

    const decision = validarDecisionRevision(datos.decision);
    const razon =
      decision === 'rechazar' ? validarRazonRechazo(datos.razon) : null;

    let idProductoMongo: number;

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const bloqueo = await cliente.query<{
        id_producto_mongo: string;
        id_estado_oferta: number;
      }>(
        `SELECT id_producto_mongo, id_estado_oferta
           FROM oferta
          WHERE id_oferta = $1
          FOR UPDATE`,
        [idOferta],
      );

      const fila = bloqueo.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }

      const estado = await cliente.query<{ estado_oferta_nombre: string }>(
        'SELECT estado_oferta_nombre FROM estado_oferta WHERE id_estado_oferta = $1',
        [fila.id_estado_oferta],
      );
      const estadoActual = estado.rows[0]?.estado_oferta_nombre;
      if (estadoActual !== 'pendiente') {
        throw new ErrorConflicto(
          `Esta oferta no esta pendiente de revision (esta ${estadoActual})`,
        );
      }
      idProductoMongo = Number(fila.id_producto_mongo);

      if (decision === 'aprobar') {
        // `id_usuario_aprobo` es quien REVISA, no la cuenta efectiva: se
        // guarda el id del token tal cual (un admin queda como el admin
        // real, no sustituido por la tienda), igual que
        // ProductosVendedorService.revisarPropuesta. El dueno de la oferta
        // sigue saliendo de `oferta.id_usuario`, que no se toca aqui.
        await cliente.query(
          `UPDATE oferta
              SET id_estado_oferta = (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = 'activa'),
                  fecha_aprobacion = now(),
                  id_usuario_aprobo = $2
            WHERE id_oferta = $1`,
          [idOferta, idUsuarioToken],
        );
      } else {
        await cliente.query(
          `UPDATE oferta
              SET id_estado_oferta = (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = 'rechazada')
            WHERE id_oferta = $1`,
          [idOferta],
        );
        await cliente.query(
          'INSERT INTO rechazo_oferta (id_oferta, razon_rechazo) VALUES ($1, $2)',
          [idOferta, razon],
        );
      }

      await cliente.query('COMMIT');
    } catch (error) {
      await this.intentarRollback(cliente);
      if (
        error instanceof ErrorConflicto ||
        error instanceof ErrorNoEncontrado
      ) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }

    await this.productosService.recalcularCamposCalculados([idProductoMongo]);

    return this.armarOfertaPropia(await this.obtenerFilaPorId(idOferta));
  }

  /**
   * Arma el DTO `OfertaPropia` a partir de una fila ya leida de `oferta`:
   * resuelve el nombre del producto y de la variante con una consulta a
   * Mongo (si el producto no aparece -- no deberia, el catalogo no borra --
   * se avisa en el nombre en vez de reventar). Lo comparten `editar()` y
   * `revisar()`.
   */
  private async armarOfertaPropia(
    fila: FilaOfertaPropia,
  ): Promise<OfertaPropia> {
    const idProducto = Number(fila.id_producto_mongo);
    const idProductoVariante = Number(fila.id_producto_variante_mongo);

    const [producto] = await this.consultarProductosLigeros([idProducto]);
    const variante = producto?.variantes.find(
      (candidata) => candidata.id_producto_variante === idProductoVariante,
    );

    return {
      id_oferta: fila.id_oferta,
      id_producto: idProducto,
      id_producto_variante: idProductoVariante,
      nombre_producto: producto?.nombre ?? '(producto no encontrado)',
      nombre_variante: variante?.nombre_variante ?? '(variante no encontrada)',
      imagen: variante?.imagenes[0] ?? null,
      precio: fila.precio,
      stock: fila.stock,
      estado: fila.estado_oferta_nombre,
      fecha_aprobacion: fila.fecha_aprobacion,
      aprobado_por: this.armarAprobador(fila),
      fecha_creacion: fila.fecha_creacion,
      fecha_actualizacion: fila.fecha_actualizacion,
    };
  }

  /**
   * El vendedor/tienda que aprobo la oferta, resuelto desde el LEFT JOIN a
   * `usuarios` por `oferta.id_usuario_aprobo`. `null` cuando no consta
   * aprobador -- la oferta nunca fue aprobada (`pendiente`/`rechazada`/
   * `retirada` sin revision), es de la propia tienda o de un admin (nacen
   * aprobadas sin revisor), o es anterior al flujo de aprobacion de
   * ofertas (migrations/010_aprobacion_ofertas.sql).
   */
  private armarAprobador(fila: FilaOfertaPropia): AprobadorOferta | null {
    if (fila.id_usuario_aprobo == null) {
      return null;
    }
    return {
      id_usuario: fila.id_usuario_aprobo,
      usuario: fila.aprobo_usuario as string,
      nombre: fila.aprobo_nombre as string,
      apellido: fila.aprobo_apellido ?? null,
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
   *
   * Para un admin, "mis ofertas" son las de la cuenta de la tienda (ver
   * resolverIdEfectivo() arriba), no las que hubiera creado el admin bajo
   * su propio id -- no deberia haber ninguna, porque crear() ya las
   * atribuye a la tienda.
   */
  async listarPropias(
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<OfertaPropia[]> {
    const idUsuario = await this.resolverIdEfectivo(idUsuarioToken, idRolUsuario);
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
        fecha_aprobacion: fila.fecha_aprobacion,
        aprobado_por: this.armarAprobador(fila),
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
   *
   * Para un admin, `mi_oferta` es la de la cuenta de la tienda (ver
   * resolverIdEfectivo() arriba), igual que en listarPropias().
   */
  async obtenerConMisOfertas(
    idProductoParametro: string,
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<ProductoConMisOfertas> {
    const idUsuario = await this.resolverIdEfectivo(idUsuarioToken, idRolUsuario);
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
              fecha_aprobacion: fila.fecha_aprobacion,
              aprobado_por: this.armarAprobador(fila),
              fecha_creacion: fila.fecha_creacion,
              fecha_actualizacion: fila.fecha_actualizacion,
            }
          : null;

        return { ...variante, mi_oferta: miOferta };
      },
    );

    return { ...producto, variantes };
  }

  /**
   * El historial completo de rechazos de una oferta **propia**: cada vez
   * que la tienda la rechazó, con su motivo y su fecha, de la más reciente
   * a la más vieja. `:id` es `id_oferta`.
   *
   * Solo el dueño de la oferta -- una ajena (o inexistente) da el mismo
   * 404 genérico de siempre, resuelto por `obtenerFilaPropia`. Una oferta
   * propia que nunca fue rechazada devuelve `[]`, no un 404. Para un
   * admin, "propia" es de la cuenta de la tienda (ver `resolverIdEfectivo`),
   * cuyas ofertas nacen aprobadas y por tanto nunca se rechazan: devolverá
   * `[]`.
   */
  async listarRechazos(
    idUsuarioToken: string,
    idRolUsuario: number,
    idOfertaParametro: string,
  ): Promise<RechazoOferta[]> {
    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idOferta = Number(idOfertaParametro);

    // La tienda o un admin ven los rechazos de CUALQUIER oferta; un vendedor
    // cualquiera, solo los de las suyas. En los dos casos, una oferta que no
    // existe (o que no es suya) da el mismo 404 generico.
    if (await this.esTiendaOAdmin(idUsuarioToken, idRolUsuario)) {
      await this.obtenerFilaPorId(idOferta);
    } else {
      await this.obtenerFilaPropia(idOferta, idUsuarioToken);
    }

    try {
      const resultado = await pool.query<RechazoOferta>(
        `SELECT id_rechazo_oferta, razon_rechazo, fecha_rechazo
         FROM rechazo_oferta
         WHERE id_oferta = $1
         ORDER BY fecha_rechazo DESC, id_rechazo_oferta DESC`,
        [idOferta],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * La cola de revisión: todas las ofertas en estado `pendiente`, de
   * cualquier vendedor, de la más antigua a la más nueva (la que lleva más
   * tiempo esperando primero). Solo la tienda o un admin
   * (`exigirTiendaOAdmin`); un vendedor cualquiera recibe el mismo 404
   * genérico.
   *
   * Cada fila trae el vendedor embebido (quien revisa no lo conoce) y el
   * nombre del producto/variante ya resueltos desde Mongo -- dos consultas
   * en total, una a Postgres y una sola a Mongo con `$in`, nunca una por
   * oferta.
   */
  async listarPendientes(
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<OfertaPendiente[]> {
    await this.exigirTiendaOAdmin(idUsuarioToken, idRolUsuario);

    let filas: FilaOfertaPendiente[];
    try {
      const resultado = await pool.query<FilaOfertaPendiente>(
        `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.stock, o.fecha_creacion,
                u.id_usuario, u.usuario, u.nombre, u.apellido
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         JOIN usuarios u ON u.id_usuario = o.id_usuario
         WHERE eo.estado_oferta_nombre = 'pendiente'
         ORDER BY o.fecha_creacion ASC, o.id_oferta ASC`,
      );
      filas = resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (filas.length === 0) {
      return [];
    }

    const idsProducto = [
      ...new Set(filas.map((fila) => Number(fila.id_producto_mongo))),
    ];
    const productos = await this.consultarProductosLigeros(idsProducto);
    const productoPorId = new Map(productos.map((p) => [p._id, p]));

    return filas.map((fila) => {
      const producto = productoPorId.get(Number(fila.id_producto_mongo));
      const variante = producto?.variantes.find(
        (v) => v.id_producto_variante === Number(fila.id_producto_variante_mongo),
      );

      return {
        id_oferta: fila.id_oferta,
        id_producto: Number(fila.id_producto_mongo),
        id_producto_variante: Number(fila.id_producto_variante_mongo),
        nombre_producto: producto?.nombre ?? '(producto no encontrado)',
        nombre_variante: variante?.nombre_variante ?? '(variante no encontrada)',
        imagen: variante?.imagenes[0] ?? null,
        precio: fila.precio,
        stock: fila.stock,
        fecha_creacion: fila.fecha_creacion,
        vendedor: {
          id_usuario: fila.id_usuario,
          usuario: fila.usuario,
          nombre: fila.nombre,
          apellido: fila.apellido,
        },
      };
    });
  }

  private async consultarOfertasPropias(
    idUsuario: string,
  ): Promise<FilaOfertaPropia[]> {
    try {
      const resultado = await pool.query<FilaOfertaPropia>(
        `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.stock, eo.estado_oferta_nombre, o.fecha_aprobacion,
                o.id_usuario_aprobo,
                ua.usuario AS aprobo_usuario, ua.nombre AS aprobo_nombre,
                ua.apellido AS aprobo_apellido,
                o.fecha_creacion, o.fecha_actualizacion
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         LEFT JOIN usuarios ua ON ua.id_usuario = o.id_usuario_aprobo
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
                o.precio, o.stock, eo.estado_oferta_nombre, o.fecha_aprobacion,
                o.id_usuario_aprobo,
                ua.usuario AS aprobo_usuario, ua.nombre AS aprobo_nombre,
                ua.apellido AS aprobo_apellido,
                o.fecha_creacion, o.fecha_actualizacion
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         LEFT JOIN usuarios ua ON ua.id_usuario = o.id_usuario_aprobo
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
                o.precio, o.stock, eo.estado_oferta_nombre, o.fecha_aprobacion,
                o.id_usuario_aprobo,
                ua.usuario AS aprobo_usuario, ua.nombre AS aprobo_nombre,
                ua.apellido AS aprobo_apellido,
                o.fecha_creacion, o.fecha_actualizacion
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         LEFT JOIN usuarios ua ON ua.id_usuario = o.id_usuario_aprobo
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
   * Una oferta por id, SIN comprobar de quien es -- para las rutas donde la
   * autorizacion no es "es mia" sino "soy la tienda o un admin"
   * (`revisar()`). Mismo 404 generico si no existe. Se usa despues de la
   * transaccion para re-leer la oferta ya revisada y devolverla.
   */
  private async obtenerFilaPorId(idOferta: number): Promise<FilaOfertaPropia> {
    try {
      const resultado = await pool.query<FilaOfertaPropia>(
        `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.stock, eo.estado_oferta_nombre, o.fecha_aprobacion,
                o.id_usuario_aprobo,
                ua.usuario AS aprobo_usuario, ua.nombre AS aprobo_nombre,
                ua.apellido AS aprobo_apellido,
                o.fecha_creacion, o.fecha_actualizacion
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         LEFT JOIN usuarios ua ON ua.id_usuario = o.id_usuario_aprobo
         WHERE o.id_oferta = $1`,
        [idOferta],
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

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo.
      // No hay nada mas que hacer; sigue el error original de quien llamo.
    }
  }
}
