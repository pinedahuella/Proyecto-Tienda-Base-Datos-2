import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { mongoDb } from '../../database/mongo';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import {
  conRespaldoDeMongo,
  productosDesdePostgres,
} from '../../helpers/catalogo-respaldo';
import {
  validarIdProducto,
  validarIdProductoVariante,
  validarStockInicial,
} from '../../helpers/validaciones-inventario';
import { validarPrecioObligatorio } from '../../helpers/validaciones-crear-producto';
import {
  validarLimite,
  validarPagina,
} from '../../helpers/validaciones-productos';
import {
  validarAjusteStock,
  validarDecisionRevision,
  validarDuracionVencimiento,
  validarEstadoOferta,
  validarFiltroEstadoOferta,
  validarPorcentajeDescuento,
  validarRazonRechazo,
} from '../../helpers/validaciones-oferta';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';
import {
  exigirSinOtroMecanismoActivo,
  MecanismoDescuento,
} from '../../helpers/exclusion-mecanismos-descuento';
import {
  AprobadorOferta,
  FilaOfertaNueva,
  FilaOfertaPendiente,
  FilaOfertaPropia,
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
import { AplicarDescuentoPeticion } from '../../dto/aplicar-descuento';
import {
  OfertasPendientesPaginadas,
  OfertasPropiasPaginadas,
  PaginarOfertasPendientesQuery,
  PaginarOfertasQuery,
} from '../../dto/paginar-ofertas';
import {
  ProductoConMisOfertas,
  ProductoVarianteConMiOferta,
} from '../../dto/producto-con-mis-ofertas';
import { ProductosService } from '../productos/productos.service';
import { InventarioLimitadoService } from '../inventario-limitado/inventario-limitado.service';
import { RegistroOfertasRedisService } from './registro-ofertas-redis.service';
import { CORREO_TIENDA } from '../../helpers/constantes';

/** Un producto de la copia del catalogo, recortado a lo que lleva una oferta. */
function aLigero(producto: Producto): ProductoLigero {
  return {
    _id: producto._id,
    nombre: producto.nombre,
    variantes: producto.variantes.map((v) => ({
      id_producto_variante: v.id_producto_variante,
      nombre_variante: v.nombre_variante,
      imagenes: v.imagenes ?? [],
    })),
  };
}

const REGEX_ID = /^\d+$/;
const CODIGO_UNIQUE_VIOLATION = '23505';
const CODIGO_CHECK_VIOLATION = '23514';

/**
 * Solo lo que hace falta de un producto para ponerle nombre a una oferta:
 * nada de caracteristicas ni historial. Proyeccion interna de Mongo, se
 * queda aca -- no es una fila de PostgreSQL ni una forma de la API.
 */
/** Una fila de GET /admin/ofertas?producto= (migracion 053). */
export interface OfertaDeProductoAdmin {
  id_oferta: string;
  id_producto_variante: string;
  variante: string | null;
  vendedor: string;
  correo_vendedor: string;
  precio: string;
  precio_final: string;
  stock: number;
  estado: string;
  aprobada: boolean;
  es_inventario_limitado: boolean;
}

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
 * catalogo (que decidimos que es solo de tienda@mesh.com o de una cuenta
 * admin, ver cambios-multivendedor.md seccion 9), publicar una OFERTA
 * sobre un producto que ya existe es justo lo que cualquier vendedor
 * puede hacer -- es el corazon del modelo multi-vendedor. El guard de rol
 * (los permisos `ofertas.*` de `rol_permiso`, migracion 050)
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

  constructor(
    private readonly productosService: ProductosService,
    private readonly inventarioLimitado: InventarioLimitadoService,
    private readonly registroOfertasRedis: RegistroOfertasRedisService,
  ) {}

  /**
   * El stock real de una oferta en venta relampago -- el contador de Redis,
   * que es la verdad mientras la venta esta abierta (el `stock` de
   * PostgreSQL queda congelado). `null` si la oferta no esta en venta
   * relampago o si Redis no respondio: en los dos casos el numero real es
   * el `stock` de PostgreSQL. Ver `InventarioLimitadoService.estado`.
   */
  private async stockDisponibleLimitado(
    idOferta: string,
    esInventarioLimitado: boolean,
  ): Promise<number | null> {
    if (!esInventarioLimitado) {
      return null;
    }
    const estado = await this.inventarioLimitado.estado(Number(idOferta));
    return estado?.stock ?? null;
  }

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
    const idUsuario = idRolUsuario === ID_ROL_ADMIN ? idTienda : idUsuarioToken;
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
      datos.stock_inicial != null
        ? validarStockInicial(datos.stock_inicial)
        : 0;

    let producto: ProductoLigero;
    try {
      // La oferta se escribe solo en PostgreSQL, asi que sin MongoDB se puede
      // publicar igual: el producto se comprueba en la copia del catalogo.
      const encontrado = await conRespaldoDeMongo<ProductoLigero | null>(
        () =>
          mongoDb.collection<Producto>('productos').findOne<ProductoLigero>(
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
          ),
        async () => {
          const [copia] = await productosDesdePostgres([idProducto], true);
          return copia ? aLigero(copia) : null;
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

    return {
      id_oferta: filaOferta.id_oferta,
      id_producto: idProducto,
      id_producto_variante: idProductoVariante,
      nombre_producto: producto.nombre,
      nombre_variante: variante.nombre_variante,
      imagen: variante.imagenes[0] ?? null,
      precio: filaOferta.precio,
      // Recien creada nunca tiene descuento -- se aplica aparte, con
      // POST /vendedor/ofertas/:id/descuento.
      porcentaje_descuento: null,
      precio_final: filaOferta.precio,
      stock: stockFinal,
      // Recien creada nunca esta en venta relampago: no hay contador de
      // Redis, el numero real es `stock`.
      stock_disponible: null,
      estado: estadoInicial,
      // Recien creada nunca hay aprobador: la tienda/admin nace `activa` sin
      // revisor (fecha puesta, aprobado_por null), y cualquier otro vendedor
      // nace `pendiente` (las dos cosas null).
      fecha_aprobacion: filaOferta.fecha_aprobacion,
      aprobado_por: null,
      // Una oferta recien creada nunca esta en venta relampago -- se abre
      // aparte, con POST /vendedor/ofertas/:id/venta-limitada.
      es_inventario_limitado: false,
      // Recien creada nunca vence sola -- ninguna de las dos existe todavia.
      fecha_vencimiento_descuento: null,
      fecha_vencimiento_venta_limitada: null,
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
   *     de inventario, ahora sobre la oferta. **Rechazado con 409 si la
   *     oferta esta en venta relampago** (`es_inventario_limitado`): ahi
   *     el stock real lo lleva Redis, y tocar `oferta.stock` por este
   *     camino las desincroniza -- Redis seguiria prometiendo unidades que
   *     PostgreSQL ya no tiene, y el checkout revienta con un error que no
   *     explica nada. `precio` y `estado` no se ven afectados por esto.
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
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idOferta = Number(idOfertaParametro);

    if (
      datos.precio == null &&
      datos.estado == null &&
      datos.ajuste_stock == null
    ) {
      throw new ErrorValidacion(
        'Debes enviar al menos un campo para actualizar',
      );
    }

    const precio =
      datos.precio != null ? validarPrecioObligatorio(datos.precio) : null;
    const estado =
      datos.estado != null ? validarEstadoOferta(datos.estado) : null;
    const ajusteStock =
      datos.ajuste_stock != null
        ? validarAjusteStock(datos.ajuste_stock)
        : null;

    // Comprueba dueno y de paso trae los ids de Mongo y si ya fue aprobada
    // -- se pide antes de tocar nada, para no dejar un cambio a medias si
    // la oferta es ajena.
    const filaActual = await this.obtenerFilaPropia(idOferta, idUsuario);
    const nuncaAprobada = filaActual.fecha_aprobacion == null;

    // Con la venta relampago abierta, el stock real lo lleva Redis (las
    // unidades reservadas se descuentan ahi, no en `oferta.stock`); dejar
    // que `ajuste_stock` toque la columna de PostgreSQL mientras tanto
    // desincroniza las dos y Redis puede terminar prometiendo unidades que
    // PostgreSQL ya no tiene. precio y estado no se ven afectados.
    if (ajusteStock != null && filaActual.es_inventario_limitado) {
      throw new ErrorConflicto(
        'La oferta esta en una venta relampago: cierra la venta relampago antes de ajustar su existencia',
      );
    }

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
    return this.armarOfertaPropia(filaFinal);
  }

  /**
   * Aplica un descuento a una oferta propia. `oferta.precio` NUNCA se
   * toca por esto -- sigue siendo el precio de lista; el % vigente vive
   * aparte en `oferta.porcentaje_descuento`, y el precio final se calcula
   * en cada consulta (ver `helpers/precio-descuento.ts` y
   * `elementos Generales/plan pendiente/descuentos-oferta.md`).
   *
   * Rechaza con 409 si la oferta **ya tiene** un descuento activo -- hay
   * que quitarlo primero (`DELETE .../descuento`), no se reemplaza
   * silenciosamente. El chequeo va dentro de una transaccion con
   * `SELECT ... FOR UPDATE`, mismo patron que `revisar()`: si dos
   * peticiones caen a la vez sobre la misma oferta, la segunda espera y ve
   * el descuento ya puesto, y responde 409 en vez de pisarlo.
   *
   * Tambien rechaza con 409 si la oferta tiene una regla de descuento
   * automatico o por periodo activa (`exigirSinOtroMecanismoActivo()`,
   * dentro de la misma transaccion) -- los cuatro mecanismos de
   * descuento/venta relampago son mutuamente excluyentes.
   *
   * `duracion_segundos` (agregado 2026-09-24, opcional): si viene y es
   * mayor a 0, el descuento vence solo -- guarda
   * `oferta.fecha_vencimiento_descuento = now() + duracion_segundos`, que es
   * lo unico que lee `VentasLimitadasService.revisarDescuentosVencidos()`
   * para decidir si ya vencio (desde 2026-09-27 ya NO le pregunta a Redis:
   * ver `plan pendiente/vencimiento-automatico-oferta.md`, el porque).
   * `0` (o nada) deja la columna en `NULL`: el descuento es permanente,
   * el worker nunca lo va a tocar solo. Puramente interno: no se expone en
   * ninguna respuesta, el cliente no tiene por que saber que existe.
   *
   * Solo el dueno de la oferta -- una ajena da el mismo 404 generico de
   * siempre. Si quien la aplica es admin, "dueno" se resuelve como la
   * cuenta de la tienda (ver `resolverIdEfectivo()`).
   *
   * `mecanismo` (agregado 2026-09-24, opcional, por defecto
   * `'descuento_manual'`): con QUE identidad se presenta esta activacion
   * ante `exigirSinOtroMecanismoActivo()`. `POST .../descuento` (el unico
   * llamador humano) nunca lo pasa -- usa el default. Lo pasan los
   * disparadores de las reglas automaticas (`DisparadorReglasPeriodoService`
   * hoy, `regla_automatica` el dia que exista su worker) para identificarse
   * como lo que de verdad son: si no, `exigirSinOtroMecanismoActivo()` veria
   * la propia regla que esta disparando esto como "otro mecanismo activo" y
   * se rechazaria a si misma con un 409.
   */
  async aplicarDescuento(
    idUsuarioToken: string,
    idRolUsuario: number,
    idOfertaParametro: string,
    datos: AplicarDescuentoPeticion,
    mecanismo: MecanismoDescuento = 'descuento_manual',
  ): Promise<OfertaPropia> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idOferta = Number(idOfertaParametro);
    const porcentaje = validarPorcentajeDescuento(datos.porcentaje_descuento);
    const duracion = validarDuracionVencimiento(datos.duracion_segundos);

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const bloqueo = await cliente.query<{
        porcentaje_descuento: string | null;
        id_producto_mongo: string;
      }>(
        `SELECT porcentaje_descuento, id_producto_mongo
           FROM oferta
          WHERE id_oferta = $1 AND id_usuario = $2
          FOR UPDATE`,
        [idOferta, idUsuario],
      );
      const fila = bloqueo.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }
      if (fila.porcentaje_descuento != null) {
        throw new ErrorConflicto('Esta oferta ya tiene un descuento activo');
      }
      await exigirSinOtroMecanismoActivo(
        this.logger,
        cliente,
        idOferta,
        mecanismo,
      );

      await cliente.query(
        `UPDATE oferta
            SET porcentaje_descuento = $1,
                fecha_vencimiento_descuento = CASE WHEN $3 > 0
                  THEN now() + make_interval(secs => $3) ELSE NULL END
          WHERE id_oferta = $2`,
        [porcentaje, idOferta, duracion],
      );

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

    await this.registroOfertasRedis.sincronizar(idOferta);
    return this.armarOfertaPropia(
      await this.obtenerFilaPropia(idOferta, idUsuario),
    );
  }

  /**
   * Quita el descuento activo de una oferta propia. `oferta.precio` no se
   * toca -- nunca lo estuvo -- solo se limpia `porcentaje_descuento`.
   * Rechaza con 409 si la oferta **no tiene** ningun descuento activo.
   * Rechaza tambien con 409 si la oferta esta en una venta relampago
   * (`es_inventario_limitado`): la venta relampago exige un descuento
   * activo (ver `VentasLimitadasService.abrir`), asi que quitarlo por
   * separado la dejaria en un estado sin sentido de negocio -- hay que
   * cerrar la venta relampago primero. Mismo patron de transaccion +
   * `FOR UPDATE` + chequeo de dueno que `aplicarDescuento()`.
   *
   * Tambien limpia `fecha_vencimiento_descuento` -- si no, una reaplicacion
   * futura sin `duracion_segundos` (permanente) heredaria por error la
   * fecha de un vencimiento anterior que ya no aplica.
   */
  async quitarDescuento(
    idUsuarioToken: string,
    idRolUsuario: number,
    idOfertaParametro: string,
  ): Promise<OfertaPropia> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idOferta = Number(idOfertaParametro);

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const bloqueo = await cliente.query<{
        porcentaje_descuento: string | null;
        es_inventario_limitado: boolean;
        id_producto_mongo: string;
      }>(
        `SELECT porcentaje_descuento, es_inventario_limitado, id_producto_mongo
           FROM oferta
          WHERE id_oferta = $1 AND id_usuario = $2
          FOR UPDATE`,
        [idOferta, idUsuario],
      );
      const fila = bloqueo.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }
      if (fila.porcentaje_descuento == null) {
        throw new ErrorConflicto(
          'Esta oferta no tiene ningun descuento activo',
        );
      }
      if (fila.es_inventario_limitado) {
        throw new ErrorConflicto(
          `La oferta ${idOferta} esta en una venta relampago: cierra la venta relampago antes de quitar el descuento`,
        );
      }

      await cliente.query(
        `UPDATE oferta
            SET porcentaje_descuento = NULL, fecha_vencimiento_descuento = NULL
          WHERE id_oferta = $1`,
        [idOferta],
      );

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

    await this.registroOfertasRedis.sincronizar(idOferta);
    return this.armarOfertaPropia(
      await this.obtenerFilaPropia(idOferta, idUsuario),
    );
  }

  /**
   * Todas las ofertas de un producto, de cualquier vendedor y en cualquier
   * estado (`GET /admin/ofertas?producto=`, permiso `ofertas.administrar`,
   * migracion 053). Es lo que la tienda mira en Catalogo antes de pausar o
   * retirar una: la ficha publica solo ensena las activas.
   */
  async listarDeProducto(
    idProductoParametro: unknown,
  ): Promise<OfertaDeProductoAdmin[]> {
    const texto =
      typeof idProductoParametro === 'string' ||
      typeof idProductoParametro === 'number'
        ? String(idProductoParametro)
        : '';
    if (!REGEX_ID.test(texto)) {
      throw new ErrorValidacion('producto tiene que ser el id de un producto');
    }
    try {
      const { rows } = await pool.query<OfertaDeProductoAdmin>(
        `SELECT o.id_oferta, o.id_producto_variante_mongo AS id_producto_variante,
                vc.nombre_variante AS variante,
                COALESCE(NULLIF(trim(concat_ws(' ', u.nombre, u.apellido)), ''), u.usuario) AS vendedor,
                u.correo_electronico AS correo_vendedor,
                o.precio, ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, eo.estado_oferta_nombre AS estado,
                o.fecha_aprobacion IS NOT NULL AS aprobada,
                o.es_inventario_limitado
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
           JOIN usuarios u ON u.id_usuario = o.id_usuario
           LEFT JOIN variante_catalogo vc
                  ON vc.id_producto_mongo = o.id_producto_mongo
                 AND vc.id_producto_variante_mongo = o.id_producto_variante_mongo
          WHERE o.id_producto_mongo = $1
          ORDER BY (eo.estado_oferta_nombre = 'activa') DESC, vendedor, o.id_oferta`,
        [Number(texto)],
      );
      return rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * La tienda pausa, reactiva o retira la oferta de cualquier vendedor y le
   * ajusta las unidades (`PATCH /admin/ofertas/:id`, permiso
   * `ofertas.administrar`, migracion 053). Lo mismo que `editar()` pero sin
   * exigir que sea suya, y sin el precio, que sigue siendo solo del vendedor.
   * El ajuste queda en el kardex (`stock_movimiento`) a nombre del admin.
   * Una oferta sin aprobar se resuelve en Ofertas por revisar, no aqui, y con
   * la venta relampago abierta las unidades no se tocan (las lleva Redis).
   */
  async administrar(
    idAdmin: string,
    idOfertaParametro: string,
    datos: { estado?: unknown; ajuste_stock?: unknown } | undefined,
  ): Promise<OfertaPropia> {
    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idOferta = Number(idOfertaParametro);
    if (datos?.estado == null && datos?.ajuste_stock == null) {
      throw new ErrorValidacion('Envia estado, ajuste_stock o los dos');
    }
    // Lo que no es texto cae en la validacion de abajo, con el mismo 400.
    const estado =
      datos.estado == null
        ? null
        : typeof datos.estado === 'string'
          ? datos.estado
          : '';
    if (estado != null && !['activa', 'pausada', 'retirada'].includes(estado)) {
      throw new ErrorValidacion(
        'estado tiene que ser activa, pausada o retirada',
      );
    }
    const ajusteStock =
      datos.ajuste_stock != null
        ? validarAjusteStock(datos.ajuste_stock)
        : null;

    const actual = await this.obtenerFilaPorId(idOferta);
    if (actual.fecha_aprobacion == null && estado !== 'retirada') {
      throw new ErrorConflicto(
        'Esta oferta todavia no esta aprobada: se aprueba o se rechaza en Ofertas por revisar',
      );
    }
    if (ajusteStock != null && actual.es_inventario_limitado) {
      throw new ErrorConflicto(
        'La oferta esta en una venta relampago: cierra la venta relampago antes de ajustar su existencia',
      );
    }

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');
      if (estado != null) {
        await cliente.query(
          `UPDATE oferta
              SET id_estado_oferta = (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = $1)
            WHERE id_oferta = $2`,
          [estado, idOferta],
        );
      }
      if (ajusteStock != null) {
        await cliente.query('SELECT reponer_stock($1, $2, $3, $4)', [
          idOferta,
          Math.abs(ajusteStock),
          ajusteStock > 0 ? 'reposicion' : 'ajuste',
          idAdmin,
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

    return this.armarOfertaPropia(await this.obtenerFilaPorId(idOferta));
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
      porcentaje_descuento: fila.porcentaje_descuento,
      precio_final: fila.precio_final,
      stock: fila.stock,
      stock_disponible: await this.stockDisponibleLimitado(
        fila.id_oferta,
        fila.es_inventario_limitado,
      ),
      estado: fila.estado_oferta_nombre,
      fecha_aprobacion: fila.fecha_aprobacion,
      aprobado_por: this.armarAprobador(fila),
      es_inventario_limitado: fila.es_inventario_limitado,
      fecha_vencimiento_descuento: fila.fecha_vencimiento_descuento,
      fecha_vencimiento_venta_limitada: fila.fecha_vencimiento_venta_limitada,
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
   * Orden: `fecha_actualizacion` descendente, con `id_oferta` descendente
   * de desempate -- el mismo criterio exacto que listarPropiasPaginado(),
   * para que recorrer la ruta paginada dé la misma secuencia que esta.
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
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    const ofertas = await this.consultarOfertasPropias(idUsuario);
    return this.armarOfertasPropias(ofertas);
  }

  /**
   * La version paginada de listarPropias(): las mismas ofertas del panel
   * del vendedor (cualquier estado) y la misma forma de cada una, pero por
   * numero de pagina en vez de todas de golpe -- igual que
   * GET /vendedor/productos/paginado, no por cursor -- y con un unico
   * filtro, `estado` (uno de los cinco `ESTADOS_OFERTA`, o ausente para
   * traerlas todas, ver validarFiltroEstadoOferta).
   *
   * Tres consultas, ninguna por oferta: dos a Postgres (una cuenta el total
   * que cumple el filtro, otra trae solo la pagina pedida; van en la misma
   * transaccion REPEATABLE READ para que salgan de la misma foto, el mismo
   * espiritu que el $facet de ProductosService.listarPaginado) y una sola a
   * Mongo con `$in` por los productos distintos de esa pagina. Pedir una
   * pagina mas alla del final devuelve `ofertas: []` con el `total_ofertas`
   * real, no un error.
   *
   * Misma paginacion por numero de pagina que el resto del proyecto:
   * `validarLimite`/`validarPagina` son las de helpers/validaciones-productos.ts
   * (mismas reglas y mismos mensajes que /productos y /vendedor/productos).
   *
   * Para un admin, "mis ofertas" son las de la cuenta de la tienda (ver
   * resolverIdEfectivo()), igual que en listarPropias().
   */
  async listarPropiasPaginado(
    idUsuarioToken: string,
    idRolUsuario: number,
    query: PaginarOfertasQuery,
  ): Promise<OfertasPropiasPaginadas> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const estado = validarFiltroEstadoOferta(query.estado);
    const saltar = (pagina - 1) * limite;

    const { filas, total } = await this.consultarOfertasPropiasPaginado(
      idUsuario,
      estado,
      limite,
      saltar,
    );

    const ofertas = await this.armarOfertasPropias(filas);
    const totalPaginas = total === 0 ? 0 : Math.ceil(total / limite);

    return {
      ofertas,
      pagina,
      limite,
      total_ofertas: total,
      total_paginas: totalPaginas,
    };
  }

  /**
   * Resuelve el nombre del producto y de la variante y su portada (una sola
   * consulta a Mongo con `$in`, nunca una por oferta) y el stock real de
   * Redis de las que esten en venta relampago, y arma el `OfertaPropia` de
   * cada fila cruda de `oferta`. Lo comparten listarPropias() y
   * listarPropiasPaginado().
   */
  private async armarOfertasPropias(
    filas: FilaOfertaPropia[],
  ): Promise<OfertaPropia[]> {
    if (filas.length === 0) {
      return [];
    }

    const idsProducto = [
      ...new Set(filas.map((fila) => Number(fila.id_producto_mongo))),
    ];
    const productos = await this.consultarProductosLigeros(idsProducto);
    const productoPorId = new Map(productos.map((p) => [p._id, p]));

    return Promise.all(
      filas.map(async (fila) => {
        const producto = productoPorId.get(Number(fila.id_producto_mongo));
        const variante = producto?.variantes.find(
          (v) =>
            v.id_producto_variante === Number(fila.id_producto_variante_mongo),
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
          nombre_variante:
            variante?.nombre_variante ?? '(variante no encontrada)',
          imagen: variante?.imagenes[0] ?? null,
          precio: fila.precio,
          porcentaje_descuento: fila.porcentaje_descuento,
          precio_final: fila.precio_final,
          stock: fila.stock,
          stock_disponible: await this.stockDisponibleLimitado(
            fila.id_oferta,
            fila.es_inventario_limitado,
          ),
          estado: fila.estado_oferta_nombre,
          fecha_aprobacion: fila.fecha_aprobacion,
          aprobado_por: this.armarAprobador(fila),
          es_inventario_limitado: fila.es_inventario_limitado,
          fecha_vencimiento_descuento: fila.fecha_vencimiento_descuento,
          fecha_vencimiento_venta_limitada:
            fila.fecha_vencimiento_venta_limitada,
          fecha_creacion: fila.fecha_creacion,
          fecha_actualizacion: fila.fecha_actualizacion,
        };
      }),
    );
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
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    let producto: Producto;
    try {
      // Sin MongoDB, de la copia del catalogo: sin las caracteristicas, pero
      // con las variantes, que es lo que hace falta para ver y cambiar ofertas.
      const encontrado = await conRespaldoDeMongo<Producto | null>(
        () =>
          mongoDb
            .collection<Producto>('productos')
            .findOne({ _id: idProducto }),
        async () =>
          (await productosDesdePostgres([idProducto], false))[0] ?? null,
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

    const misOfertas = await this.consultarOfertasPropiasDeProducto(
      idUsuario,
      idProducto,
    );
    const ofertaPorVariante = new Map(
      misOfertas.map((fila) => [Number(fila.id_producto_variante_mongo), fila]),
    );

    // El stock real (Redis) de mis ofertas en venta relampago, pedido de una
    // sola vez para todas antes de armar las variantes -- asi el map de abajo
    // sigue siendo sincrono. `null` cuando Redis no respondio.
    const idsLimitadas = misOfertas
      .filter((fila) => fila.es_inventario_limitado)
      .map((fila) => fila.id_oferta);
    const stocksLimitados = await Promise.all(
      idsLimitadas.map((id) => this.stockDisponibleLimitado(id, true)),
    );
    const stockLimitadoPorOferta = new Map<string, number | null>(
      idsLimitadas.map((id, i) => [id, stocksLimitados[i]]),
    );

    const variantes: ProductoVarianteConMiOferta[] = producto.variantes.map(
      (variante) => {
        const fila = ofertaPorVariante.get(variante.id_producto_variante);
        const miOferta: OfertaPropiaResumen | null = fila
          ? {
              id_oferta: fila.id_oferta,
              precio: fila.precio,
              porcentaje_descuento: fila.porcentaje_descuento,
              precio_final: fila.precio_final,
              stock: fila.stock,
              stock_disponible: fila.es_inventario_limitado
                ? (stockLimitadoPorOferta.get(fila.id_oferta) ?? null)
                : null,
              estado: fila.estado_oferta_nombre,
              fecha_aprobacion: fila.fecha_aprobacion,
              aprobado_por: this.armarAprobador(fila),
              es_inventario_limitado: fila.es_inventario_limitado,
              fecha_vencimiento_descuento: fila.fecha_vencimiento_descuento,
              fecha_vencimiento_venta_limitada:
                fila.fecha_vencimiento_venta_limitada,
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
                o.precio, o.porcentaje_descuento,
                ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, o.fecha_creacion,
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

    return this.armarOfertasPendientes(filas);
  }

  /**
   * La version paginada de listarPendientes(): la misma cola de revision
   * (todas las ofertas `pendiente`, de la mas antigua a la mas nueva) y la
   * misma forma de cada una, pero por numero de pagina -- igual que
   * GET /vendedor/productos/paginado. Sin filtros: la cola es toda
   * `pendiente` por definicion.
   *
   * Solo la tienda o un admin (`exigirTiendaOAdmin`, va lo primero, antes
   * de validar la paginacion); un vendedor cualquiera recibe el mismo 404
   * generico. No hay sustitucion de identidad: la cola es global, no "mis
   * pendientes".
   *
   * Tres consultas, ninguna por oferta: dos a Postgres (total + pagina, en
   * la misma transaccion REPEATABLE READ) y una sola a Mongo con `$in`.
   * Pedir una pagina mas alla del final devuelve `ofertas: []` con el
   * `total_ofertas` real.
   */
  async listarPendientesPaginado(
    idUsuarioToken: string,
    idRolUsuario: number,
    query: PaginarOfertasPendientesQuery,
  ): Promise<OfertasPendientesPaginadas> {
    await this.exigirTiendaOAdmin(idUsuarioToken, idRolUsuario);

    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const saltar = (pagina - 1) * limite;

    const { filas, total } = await this.consultarOfertasPendientesPaginado(
      limite,
      saltar,
    );

    const ofertas = await this.armarOfertasPendientes(filas);
    const totalPaginas = total === 0 ? 0 : Math.ceil(total / limite);

    return {
      ofertas,
      pagina,
      limite,
      total_ofertas: total,
      total_paginas: totalPaginas,
    };
  }

  /**
   * Resuelve el nombre del producto/variante y su portada contra Mongo (una
   * sola consulta con `$in`, nunca una por oferta) y arma la
   * `OfertaPendiente` de cada fila cruda -- con el vendedor embebido, que
   * quien revisa no conoce. Lo comparten listarPendientes() y
   * listarPendientesPaginado().
   */
  private async armarOfertasPendientes(
    filas: FilaOfertaPendiente[],
  ): Promise<OfertaPendiente[]> {
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
        (v) =>
          v.id_producto_variante === Number(fila.id_producto_variante_mongo),
      );

      return {
        id_oferta: fila.id_oferta,
        id_producto: Number(fila.id_producto_mongo),
        id_producto_variante: Number(fila.id_producto_variante_mongo),
        nombre_producto: producto?.nombre ?? '(producto no encontrado)',
        nombre_variante:
          variante?.nombre_variante ?? '(variante no encontrada)',
        imagen: variante?.imagenes[0] ?? null,
        precio: fila.precio,
        porcentaje_descuento: fila.porcentaje_descuento,
        precio_final: fila.precio_final,
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
                o.precio, o.porcentaje_descuento,
                ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, eo.estado_oferta_nombre, o.fecha_aprobacion,
                o.id_usuario_aprobo, o.es_inventario_limitado,
                o.fecha_vencimiento_descuento, o.fecha_vencimiento_venta_limitada,
                ua.usuario AS aprobo_usuario, ua.nombre AS aprobo_nombre,
                ua.apellido AS aprobo_apellido,
                o.fecha_creacion, o.fecha_actualizacion
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         LEFT JOIN usuarios ua ON ua.id_usuario = o.id_usuario_aprobo
         WHERE o.id_usuario = $1
         ORDER BY o.fecha_actualizacion DESC, o.id_oferta DESC`,
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
                o.precio, o.porcentaje_descuento,
                ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, eo.estado_oferta_nombre, o.fecha_aprobacion,
                o.id_usuario_aprobo, o.es_inventario_limitado,
                o.fecha_vencimiento_descuento, o.fecha_vencimiento_venta_limitada,
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

  /**
   * Una pagina de las ofertas del vendedor mas el total que cumple el mismo
   * filtro. Las dos consultas van en una transaccion REPEATABLE READ de
   * solo lectura para que el conteo y la pagina salgan de la misma foto
   * (con READ COMMITTED cada SELECT toma su propio snapshot y el total
   * podria no cuadrar con la pagina). Mismo patron de cliente dedicado +
   * BEGIN/COMMIT + intentarRollback que editar().
   *
   * El filtro `estado`: uno de los cinco `ESTADOS_OFERTA`
   * (`pendiente`/`activa`/`pausada`/`retirada`/`rechazada`), o `null` para
   * no filtrar. Va como parametro ($2), no interpolado -- a diferencia del
   * viejo filtro `activo` (que solo podia salir de dos ramas fijas del
   * codigo), `estado` es un texto que sale directo de la peticion (ya
   * validado por `validarFiltroEstadoOferta` contra la lista de cinco,
   * pero de todas formas no hay motivo para interpolarlo pudiendo
   * enlazarlo). `$2::text IS NULL OR ... = $2` deja pasar todo cuando no
   * se filtra, sin tener que armar dos textos de consulta distintos.
   *
   * Orden: `fecha_actualizacion` descendente y `id_oferta` descendente de
   * desempate. El desempate es imprescindible al paginar: `fecha_actualizacion`
   * no es unica (varias ofertas comparten el instante de una carga masiva o
   * de un recalculo de campos), y sin un segundo criterio estable una misma
   * oferta podria aparecer en dos paginas o en ninguna.
   */
  private async consultarOfertasPropiasPaginado(
    idUsuario: string,
    estado: string | null,
    limite: number,
    saltar: number,
  ): Promise<{ filas: FilaOfertaPropia[]; total: number }> {
    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
          WHERE o.id_usuario = $1
            AND ($2::text IS NULL OR eo.estado_oferta_nombre = $2)`,
        [idUsuario, estado],
      );

      const pagina = await cliente.query<FilaOfertaPropia>(
        `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.porcentaje_descuento,
                ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, eo.estado_oferta_nombre, o.fecha_aprobacion,
                o.id_usuario_aprobo, o.es_inventario_limitado,
                o.fecha_vencimiento_descuento, o.fecha_vencimiento_venta_limitada,
                ua.usuario AS aprobo_usuario, ua.nombre AS aprobo_nombre,
                ua.apellido AS aprobo_apellido,
                o.fecha_creacion, o.fecha_actualizacion
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
           LEFT JOIN usuarios ua ON ua.id_usuario = o.id_usuario_aprobo
          WHERE o.id_usuario = $1
            AND ($2::text IS NULL OR eo.estado_oferta_nombre = $2)
          ORDER BY o.fecha_actualizacion DESC, o.id_oferta DESC
          LIMIT $3 OFFSET $4`,
        [idUsuario, estado, limite, saltar],
      );

      await cliente.query('COMMIT');
      return { filas: pagina.rows, total: Number(conteo.rows[0].total) };
    } catch (error) {
      await this.intentarRollback(cliente);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }

  /**
   * Una pagina de la cola de revision (ofertas `pendiente`, de la mas
   * antigua a la mas nueva) mas el total pendiente. Misma transaccion
   * REPEATABLE READ de solo lectura y mismo motivo que
   * consultarOfertasPropiasPaginado(). El orden ya trae su propio desempate
   * (`fecha_creacion ASC, id_oferta ASC`, igual que listarPendientes()).
   */
  private async consultarOfertasPendientesPaginado(
    limite: number,
    saltar: number,
  ): Promise<{ filas: FilaOfertaPendiente[]; total: number }> {
    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
          WHERE eo.estado_oferta_nombre = 'pendiente'`,
      );

      const pagina = await cliente.query<FilaOfertaPendiente>(
        `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.porcentaje_descuento,
                ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, o.fecha_creacion,
                u.id_usuario, u.usuario, u.nombre, u.apellido
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
           JOIN usuarios u ON u.id_usuario = o.id_usuario
          WHERE eo.estado_oferta_nombre = 'pendiente'
          ORDER BY o.fecha_creacion ASC, o.id_oferta ASC
          LIMIT $1 OFFSET $2`,
        [limite, saltar],
      );

      await cliente.query('COMMIT');
      return { filas: pagina.rows, total: Number(conteo.rows[0].total) };
    } catch (error) {
      await this.intentarRollback(cliente);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }

  /**
   * El nombre, las variantes y la portada de `idsProducto`. Sin MongoDB salen
   * de la copia del catalogo en PostgreSQL (`conRespaldoDeMongo`): antes del
   * 2026-10-20 cualquier lista de ofertas daba 503, y editar una oferta
   * guardaba el cambio y aun asi contestaba 503 al armar la respuesta.
   */
  private async consultarProductosLigeros(
    idsProducto: number[],
  ): Promise<ProductoLigero[]> {
    try {
      return await conRespaldoDeMongo<ProductoLigero[]>(
        () =>
          mongoDb
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
            .toArray(),
        async () =>
          (await productosDesdePostgres(idsProducto, false)).map(aLigero),
      );
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
                o.precio, o.porcentaje_descuento,
                ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, eo.estado_oferta_nombre, o.fecha_aprobacion,
                o.id_usuario_aprobo, o.es_inventario_limitado,
                o.fecha_vencimiento_descuento, o.fecha_vencimiento_venta_limitada,
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
                o.precio, o.porcentaje_descuento,
                ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, eo.estado_oferta_nombre, o.fecha_aprobacion,
                o.id_usuario_aprobo, o.es_inventario_limitado,
                o.fecha_vencimiento_descuento, o.fecha_vencimiento_venta_limitada,
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
