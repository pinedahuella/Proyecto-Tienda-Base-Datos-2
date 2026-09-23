import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import {
  validarLimite,
  validarPagina,
} from '../../helpers/validaciones-productos';
import { validarPorcentajeDescuento } from '../../helpers/validaciones-oferta';
import {
  validarActiva,
  validarDuracionSegundos,
  validarEsVentaRelampago,
  validarIdOfertaCuerpo,
  validarUmbralUnidades,
  validarVentanaMinutos,
} from '../../helpers/validaciones-regla-descuento';
import { CrearReglaDescuentoPeticion } from '../../dto/crear-regla-descuento';
import { EditarReglaDescuentoPeticion } from '../../dto/editar-regla-descuento';
import {
  PaginarReglasDescuentoQuery,
  ReglasDescuentoPaginadas,
} from '../../dto/paginar-reglas-descuento';
import { ReglaDescuentoAutomatico } from '../../models/regla-descuento-automatico';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { CORREO_TIENDA } from '../../helpers/constantes';

const REGEX_ID = /^\d+$/;
const CODIGO_UNIQUE_VIOLATION = '23505';

/**
 * CRUD de `regla_descuento_automatico`: la configuracion de "si se venden
 * umbral_unidades en ventana_minutos, activa un descuento o una venta
 * relampago". Solo la configuracion -- el disparo real (leer ClickHouse y
 * decidir si activar, y de ahi llamar a lo que ya existe en
 * OfertasVendedorService/VentasLimitadasService) todavia no esta construido.
 *
 * Mismo criterio de autorizacion que OfertasVendedorService en todo:
 * cualquier vendedor o admin, y "propia" para un admin es de la cuenta de
 * la tienda (resolverIdEfectivo() abajo) -- nunca la de un admin como tal.
 * Una regla ajena o inexistente da el mismo 404 generico de siempre.
 */
@Injectable()
export class ReglasDescuentoAutomaticoService {
  private readonly logger = new Logger(ReglasDescuentoAutomaticoService.name);

  /**
   * El id_usuario que de verdad hay que usar para el resto de la
   * operacion -- mismo mecanismo y mismo motivo que
   * OfertasVendedorService.resolverIdEfectivo().
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
   * Crea la regla de una oferta propia. La oferta tiene que ser tuya --
   * ajena o inexistente da el mismo 404 generico de siempre. Rechaza con
   * 409 si esa oferta **ya tiene** una regla (UNIQUE(id_oferta) en la
   * base): no se pueden duplicar, hay que editar la existente en vez de
   * crear una segunda.
   */
  async crear(
    idUsuarioToken: string,
    idRolUsuario: number,
    datos: CrearReglaDescuentoPeticion,
  ): Promise<ReglaDescuentoAutomatico> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );

    const idOferta = validarIdOfertaCuerpo(datos.id_oferta);
    const umbralUnidades = validarUmbralUnidades(datos.umbral_unidades);
    const ventanaMinutos = validarVentanaMinutos(datos.ventana_minutos);
    const esVentaRelampago = validarEsVentaRelampago(datos.es_venta_relampago);
    const duracionSegundos = validarDuracionSegundos(datos.duracion_segundos);
    const porcentaje = validarPorcentajeDescuento(datos.porcentaje_descuento);

    try {
      const oferta = await pool.query(
        'SELECT 1 FROM oferta WHERE id_oferta = $1 AND id_usuario = $2',
        [idOferta, idUsuario],
      );
      if (oferta.rowCount === 0) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }

      const resultado = await pool.query<ReglaDescuentoAutomatico>(
        `INSERT INTO regla_descuento_automatico
           (id_oferta, umbral_unidades, ventana_minutos, es_venta_relampago,
            duracion_segundos, porcentaje_descuento)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING *`,
        [
          idOferta,
          umbralUnidades,
          ventanaMinutos,
          esVentaRelampago,
          duracionSegundos,
          porcentaje,
        ],
      );
      return resultado.rows[0];
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      if (this.esReglaDuplicada(error)) {
        throw new ErrorConflicto(
          'Esta oferta ya tiene una regla de descuento automatico',
        );
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Todas las reglas propias, sin paginar -- mismo criterio que
   * OfertasVendedorService.listarPropias(). Para un admin, "propias" son
   * las de la cuenta de la tienda.
   */
  async listarPropias(
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<ReglaDescuentoAutomatico[]> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    try {
      const resultado = await pool.query<ReglaDescuentoAutomatico>(
        `SELECT r.*
           FROM regla_descuento_automatico r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE o.id_usuario = $1
          ORDER BY r.fecha_actualizacion DESC, r.id_regla_descuento_automatico DESC`,
        [idUsuario],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * La version paginada de listarPropias(): por numero de pagina, mismo
   * criterio que GET /vendedor/ofertas/paginado. Sin filtros -- esta lista
   * no tiene un "estado" que filtrar, solo activa/inactiva, y no se pidio
   * ese filtro.
   */
  async listarPropiasPaginado(
    idUsuarioToken: string,
    idRolUsuario: number,
    query: PaginarReglasDescuentoQuery,
  ): Promise<ReglasDescuentoPaginadas> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const saltar = (pagina - 1) * limite;

    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM regla_descuento_automatico r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE o.id_usuario = $1`,
        [idUsuario],
      );

      const filas = await cliente.query<ReglaDescuentoAutomatico>(
        `SELECT r.*
           FROM regla_descuento_automatico r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE o.id_usuario = $1
          ORDER BY r.fecha_actualizacion DESC, r.id_regla_descuento_automatico DESC
          LIMIT $2 OFFSET $3`,
        [idUsuario, limite, saltar],
      );

      await cliente.query('COMMIT');

      const total = Number(conteo.rows[0].total);
      return {
        reglas: filas.rows,
        pagina,
        limite,
        total_reglas: total,
        total_paginas: total === 0 ? 0 : Math.ceil(total / limite),
      };
    } catch (error) {
      await this.intentarRollback(cliente);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }

  /**
   * Edita una o mas columnas de una regla propia -- incluye `activa`, asi
   * que pausar/reactivarla es la misma ruta que editar los numeros. Al
   * menos un campo es obligatorio. Misma comprobacion de dueno que el
   * resto: la regla tiene que ser de una oferta tuya, ajena o inexistente
   * da el mismo 404 generico.
   */
  async editar(
    idUsuarioToken: string,
    idRolUsuario: number,
    idReglaParametro: string,
    datos: EditarReglaDescuentoPeticion,
  ): Promise<ReglaDescuentoAutomatico> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    if (!REGEX_ID.test(idReglaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idRegla = Number(idReglaParametro);

    if (
      datos.umbral_unidades == null &&
      datos.ventana_minutos == null &&
      datos.es_venta_relampago == null &&
      datos.duracion_segundos == null &&
      datos.porcentaje_descuento == null &&
      datos.activa == null
    ) {
      throw new ErrorValidacion(
        'Debes enviar al menos un campo para actualizar',
      );
    }

    const asignaciones: string[] = [];
    const valores: unknown[] = [];
    const agregar = (columna: string, valor: unknown) => {
      valores.push(valor);
      asignaciones.push(`${columna} = $${valores.length}`);
    };

    if (datos.umbral_unidades != null) {
      agregar('umbral_unidades', validarUmbralUnidades(datos.umbral_unidades));
    }
    if (datos.ventana_minutos != null) {
      agregar('ventana_minutos', validarVentanaMinutos(datos.ventana_minutos));
    }
    if (datos.es_venta_relampago != null) {
      agregar(
        'es_venta_relampago',
        validarEsVentaRelampago(datos.es_venta_relampago),
      );
    }
    if (datos.duracion_segundos != null) {
      agregar(
        'duracion_segundos',
        validarDuracionSegundos(datos.duracion_segundos),
      );
    }
    if (datos.porcentaje_descuento != null) {
      agregar(
        'porcentaje_descuento',
        validarPorcentajeDescuento(datos.porcentaje_descuento),
      );
    }
    if (datos.activa != null) {
      agregar('activa', validarActiva(datos.activa));
    }

    try {
      valores.push(idRegla, idUsuario);
      const resultado = await pool.query<ReglaDescuentoAutomatico>(
        `UPDATE regla_descuento_automatico r
            SET ${asignaciones.join(', ')}
           FROM oferta o
          WHERE r.id_oferta = o.id_oferta
            AND r.id_regla_descuento_automatico = $${valores.length - 1}
            AND o.id_usuario = $${valores.length}
          RETURNING r.*`,
        valores,
      );
      const fila = resultado.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado(
          'No existe una regla de descuento con ese id',
        );
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
   * 23505 es unique_violation: el UNIQUE(id_oferta) de
   * regla_descuento_automatico rechazando una segunda regla sobre la misma
   * oferta.
   */
  private esReglaDuplicada(error: unknown): boolean {
    const codigo = (error as { code?: string } | undefined)?.code;
    return codigo === CODIGO_UNIQUE_VIOLATION;
  }

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo.
    }
  }
}
