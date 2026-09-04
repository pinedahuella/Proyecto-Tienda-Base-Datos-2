import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { CORREO_TIENDA } from '../../helpers/constantes';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { InventarioLimitadoService } from '../inventario-limitado/inventario-limitado.service';
import { AbrirVentaLimitadaPeticion } from '../../dto/abrir-venta-limitada';
import { VentaLimitadaAbierta } from '../../models/oferta';

const REGEX_ID = /^\d+$/;

/**
 * Tope de la duracion de una venta relampago: 7 dias. Mas que eso ya no es
 * "relampago", y una promocion que nadie cierra ocupando memoria de Redis
 * indefinidamente es justo lo que el TTL evita.
 */
const MAX_DURACION_SEGUNDOS = 7 * 24 * 60 * 60;

/**
 * Paso 2 de `elementos Generales/plan pendiente/inventario-limitado.md`:
 * el vendedor abre o cierra la venta relampago (inventario limitado en
 * Redis) de UNA oferta suya.
 *
 * Va en su propio servicio, aparte de `OfertasVendedorService`, a
 * proposito: el CRUD de ofertas es PostgreSQL puro y el mecanismo de venta
 * relampago vive en Redis (`InventarioLimitadoService` + el script Lua).
 * Aqui solo estan la autorizacion (la oferta tiene que ser del vendedor) y
 * la validacion del cuerpo; el trabajo real lo hace
 * `InventarioLimitadoService.activar` / `revertir`, que ya existian y ya
 * las usa tambien `CarritoService`.
 */
@Injectable()
export class VentasLimitadasService {
  private readonly logger = new Logger(VentasLimitadasService.name);

  constructor(
    private readonly inventarioLimitadoService: InventarioLimitadoService,
  ) {}

  /**
   * Abre la venta relampago: siembra el contador de Redis con el `stock`
   * que la oferta tiene AHORA en PostgreSQL y marca
   * `oferta.es_inventario_limitado`.
   *
   * `activar()` hace el resto y lanza los dos 409 que el panel distingue:
   * la oferta no esta `activa`, o ya esta en modo venta relampago (un
   * segundo clic no puede volver a sembrar: borraria las reservas vivas).
   */
  async abrir(
    idOfertaParametro: string,
    idUsuarioToken: string,
    idRolUsuario: number,
    datos: AbrirVentaLimitadaPeticion,
  ): Promise<VentaLimitadaAbierta> {
    const idOferta = this.validarIdOferta(idOfertaParametro);
    const duracion = this.validarDuracion(datos.duracion_segundos);

    await this.exigirOfertaPropia(idOferta, idUsuarioToken, idRolUsuario);

    const { stock_sembrado } = await this.inventarioLimitadoService.activar(
      idOferta,
      duracion,
    );

    return { id_oferta: String(idOferta), stock_sembrado };
  }

  /**
   * Cierra la venta relampago: `revertir()` apaga la columna y borra las
   * dos claves de Redis de la oferta. Rechaza con 409 si la oferta no
   * estaba en una venta relampago (el panel no deberia ofrecer el boton
   * "Cerrar" en ese caso, pero se comprueba igual).
   *
   * OJO: `revertir` NO confirma las reservas que hubiera en curso -- lo que
   * de verdad quedo vendido solo se sabe con `confirmar` por ticket, y eso
   * es el flujo del checkout. Por ahora cerrar una venta con reservas
   * vivas las descarta; sirve para cerrar una venta tranquila o deshacer
   * una prueba, no para cortar en seco una que esta caliente.
   */
  async cerrar(
    idOfertaParametro: string,
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<void> {
    const idOferta = this.validarIdOferta(idOfertaParametro);

    const fila = await this.exigirOfertaPropia(
      idOferta,
      idUsuarioToken,
      idRolUsuario,
    );

    if (!fila.es_inventario_limitado) {
      throw new ErrorConflicto(
        `La oferta ${idOferta} no esta en una venta relampago`,
      );
    }

    await this.inventarioLimitadoService.revertir(idOferta);
  }

  // ---------------------------------------------------------------------
  // Privados
  // ---------------------------------------------------------------------

  private validarIdOferta(valor: string): number {
    if (!REGEX_ID.test(valor)) {
      throw new ErrorValidacion('El id no es valido');
    }
    return Number(valor);
  }

  private validarDuracion(valor: number | undefined): number {
    if (valor == null) {
      return 0; // sin vencimiento de la venta entera
    }
    if (
      typeof valor !== 'number' ||
      !Number.isInteger(valor) ||
      valor < 0 ||
      valor > MAX_DURACION_SEGUNDOS
    ) {
      throw new ErrorValidacion(
        `La duracion_segundos debe ser un entero entre 0 y ${MAX_DURACION_SEGUNDOS} (7 dias); 0 = sin vencimiento`,
      );
    }
    return valor;
  }

  /**
   * La oferta tiene que ser del vendedor que la toca. Un admin actua como
   * la cuenta de la tienda (mismo criterio que `OfertasVendedorService`).
   * Una oferta ajena o inexistente da el MISMO 404 generico que usa el
   * resto del panel -- nunca se confirma que exista.
   *
   * Devuelve la marca `es_inventario_limitado` de paso, que `cerrar()`
   * necesita.
   */
  private async exigirOfertaPropia(
    idOferta: number,
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<{ es_inventario_limitado: boolean }> {
    try {
      const idDueno =
        idRolUsuario === ID_ROL_ADMIN
          ? await this.obtenerIdTienda()
          : idUsuarioToken;

      const resultado = await pool.query<{ es_inventario_limitado: boolean }>(
        `SELECT o.es_inventario_limitado
           FROM oferta o
          WHERE o.id_oferta = $1 AND o.id_usuario = $2`,
        [idOferta, idDueno],
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
   * El id_usuario real de la cuenta de la tienda (tienda@mesh.com),
   * resuelto por correo -- nunca por un id fijo. Si no existe (no deberia:
   * es parte de los datos base) falla fuerte.
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
}
