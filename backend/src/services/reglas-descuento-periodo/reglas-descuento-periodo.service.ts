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
  validarEsVentaRelampago,
  validarIdOfertaCuerpo,
} from '../../helpers/validaciones-regla-descuento';
import {
  validarAnio,
  validarCascada,
  validarDia,
  validarFechasPosibles,
  validarMes,
} from '../../helpers/validaciones-regla-descuento-periodo';
import { CrearReglaDescuentoPeriodoPeticion } from '../../dto/crear-regla-descuento-periodo';
import { EditarReglaDescuentoPeriodoPeticion } from '../../dto/editar-regla-descuento-periodo';
import {
  PaginarReglasDescuentoPeriodoQuery,
  ReglasDescuentoPeriodoPaginadas,
} from '../../dto/paginar-reglas-descuento-periodo';
import { ReglaDescuentoPeriodo } from '../../models/regla-descuento-periodo';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { CORREO_TIENDA } from '../../helpers/constantes';
import { exigirSinOtroMecanismoActivo } from '../../helpers/exclusion-mecanismos-descuento';
import {
  RangoPeriodo,
  reglasDePeriodoSeSolapan,
} from '../../helpers/solape-regla-descuento-periodo';

const REGEX_ID = /^\d+$/;

/**
 * CRUD de `regla_descuento_periodo`: la configuracion de "si la fecha de
 * hoy cae en este rango de dia/mes/anio, activa un descuento o una venta
 * relampago" -- ver el modelo `ReglaDescuentoPeriodo` para la cascada. El
 * disparador real es `DisparadorReglasPeriodoService`.
 *
 * Mismo criterio de autorizacion que ReglasDescuentoAutomaticoService en
 * todo: cualquier vendedor o admin, y "propia" para un admin es de la
 * cuenta de la tienda (resolverIdEfectivo() abajo) -- nunca la de un admin
 * como tal. Una regla ajena o inexistente da el mismo 404 generico de
 * siempre.
 */
@Injectable()
export class ReglasDescuentoPeriodoService {
  private readonly logger = new Logger(ReglasDescuentoPeriodoService.name);

  /**
   * El id_usuario que de verdad hay que usar para el resto de la
   * operacion -- mismo mecanismo y mismo motivo que
   * ReglasDescuentoAutomaticoService.resolverIdEfectivo().
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
   * 409 si el rango que se esta por activar se solapa en algun dia real
   * con otra regla de periodo YA ACTIVA de la misma oferta
   * (`reglasDePeriodoSeSolapan()`). `idReglaExcluir` es la propia regla
   * cuando se llama desde `editar()` (no tiene sentido comparar una fila
   * contra si misma); `null` desde `crear()`, donde la fila todavia no
   * existe.
   */
  private async exigirSinSolapeConOtrasActivas(
    idOferta: number,
    rango: RangoPeriodo,
    idReglaExcluir: number | null,
  ): Promise<void> {
    try {
      const filas = await pool.query<{
        id_regla_descuento_periodo: string;
        dia_inicio: number;
        dia_fin: number;
        mes_inicio: number | null;
        mes_fin: number | null;
        anio: number | null;
      }>(
        `SELECT id_regla_descuento_periodo, dia_inicio, dia_fin, mes_inicio, mes_fin, anio
           FROM regla_descuento_periodo
          WHERE id_oferta = $1 AND activa
            AND id_regla_descuento_periodo IS DISTINCT FROM $2`,
        [idOferta, idReglaExcluir],
      );
      for (const fila of filas.rows) {
        if (reglasDePeriodoSeSolapan(rango, fila)) {
          throw new ErrorConflicto(
            `Esta oferta ya tiene una regla de descuento por periodo activa (id ${fila.id_regla_descuento_periodo}) que se solapa en dias con esta`,
          );
        }
      }
    } catch (error) {
      if (error instanceof ErrorConflicto) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Crea la regla de una oferta propia. La oferta tiene que ser tuya --
   * ajena o inexistente da el mismo 404 generico de siempre. A diferencia
   * de regla_descuento_automatico, no hay UNIQUE(id_oferta): una misma
   * oferta puede tener varios periodos activos a la vez (ej. uno fijo de
   * Black Friday y uno recurrente mensual) -- pero rechaza con 409 si el
   * rango nuevo se SOLAPA en algun dia real con otra regla de periodo ya
   * activa de la misma oferta (`exigirSinSolapeConOtrasActivas()`, ver
   * `helpers/solape-regla-descuento-periodo.ts`).
   *
   * Tambien rechaza con 409 si la oferta tiene un descuento manual, una venta
   * relampago manual o una regla de descuento automatico activa
   * (`exigirSinOtroMecanismoActivo()`) -- nace `activa: true`, asi que
   * crear una regla ES activarla.
   */
  async crear(
    idUsuarioToken: string,
    idRolUsuario: number,
    datos: CrearReglaDescuentoPeriodoPeticion,
  ): Promise<ReglaDescuentoPeriodo> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );

    const idOferta = validarIdOfertaCuerpo(datos.id_oferta);
    const diaInicio = validarDia(datos.dia_inicio, 'dia_inicio');
    const diaFin = validarDia(datos.dia_fin, 'dia_fin');
    const mesInicio =
      datos.mes_inicio != null
        ? validarMes(datos.mes_inicio, 'mes_inicio')
        : null;
    const mesFin =
      datos.mes_fin != null ? validarMes(datos.mes_fin, 'mes_fin') : null;
    const anio = datos.anio != null ? validarAnio(datos.anio) : null;
    validarCascada({ mes_inicio: mesInicio, mes_fin: mesFin, anio });
    validarFechasPosibles(
      {
        dia_inicio: diaInicio,
        dia_fin: diaFin,
        mes_inicio: mesInicio,
        mes_fin: mesFin,
        anio,
      },
      true,
    );
    const esVentaRelampago = validarEsVentaRelampago(datos.es_venta_relampago);
    const porcentaje = validarPorcentajeDescuento(datos.porcentaje_descuento);

    try {
      const oferta = await pool.query(
        'SELECT 1 FROM oferta WHERE id_oferta = $1 AND id_usuario = $2',
        [idOferta, idUsuario],
      );
      if (oferta.rowCount === 0) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }
      await this.exigirSinSolapeConOtrasActivas(
        idOferta,
        {
          dia_inicio: diaInicio,
          dia_fin: diaFin,
          mes_inicio: mesInicio,
          mes_fin: mesFin,
          anio,
        },
        null,
      );
      await exigirSinOtroMecanismoActivo(
        this.logger,
        pool,
        idOferta,
        'regla_periodo',
      );

      const resultado = await pool.query<ReglaDescuentoPeriodo>(
        `INSERT INTO regla_descuento_periodo
           (id_oferta, dia_inicio, dia_fin, mes_inicio, mes_fin, anio,
            es_venta_relampago, porcentaje_descuento)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING *`,
        [
          idOferta,
          diaInicio,
          diaFin,
          mesInicio,
          mesFin,
          anio,
          esVentaRelampago,
          porcentaje,
        ],
      );
      return resultado.rows[0];
    } catch (error) {
      if (
        error instanceof ErrorNoEncontrado ||
        error instanceof ErrorConflicto
      ) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Todas las reglas propias, sin paginar -- mismo criterio que
   * ReglasDescuentoAutomaticoService.listarPropias(). Para un admin,
   * "propias" son las de la cuenta de la tienda.
   */
  async listarPropias(
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<ReglaDescuentoPeriodo[]> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    try {
      const resultado = await pool.query<ReglaDescuentoPeriodo>(
        `SELECT r.*
           FROM regla_descuento_periodo r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE o.id_usuario = $1
          ORDER BY r.fecha_actualizacion DESC, r.id_regla_descuento_periodo DESC`,
        [idUsuario],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * La version paginada de listarPropias(): por numero de pagina, mismo
   * criterio que GET /vendedor/reglas-descuento/paginado.
   */
  async listarPropiasPaginado(
    idUsuarioToken: string,
    idRolUsuario: number,
    query: PaginarReglasDescuentoPeriodoQuery,
  ): Promise<ReglasDescuentoPeriodoPaginadas> {
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
           FROM regla_descuento_periodo r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE o.id_usuario = $1`,
        [idUsuario],
      );

      const filas = await cliente.query<ReglaDescuentoPeriodo>(
        `SELECT r.*
           FROM regla_descuento_periodo r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE o.id_usuario = $1
          ORDER BY r.fecha_actualizacion DESC, r.id_regla_descuento_periodo DESC
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
   * que pausar/reactivarla es la misma ruta que editar las fechas o el
   * descuento. Al menos un campo es obligatorio. Misma comprobacion de
   * dueno que el resto: la regla tiene que ser de una oferta tuya, ajena o
   * inexistente da el mismo 404 generico.
   *
   * La cascada (mes_inicio/mes_fin juntos, anio solo con mes) se valida
   * contra el estado FINAL de la fila -- lo que llega en la peticion
   * mezclado con lo que ya tenia, para dar el mismo mensaje que crear()
   * aunque la peticion solo toque uno de los tres campos.
   *
   * Si la regla queda activa despues de esta edicion (ya lo estaba y sigue,
   * o se reactiva con `activa: true`), el rango FINAL (fechas nuevas o
   * heredadas) se revisa contra las demas reglas activas de la misma
   * oferta por solape (`exigirSinSolapeConOtrasActivas()`) -- asi que
   * editar solo `dia_inicio` de una regla ya activa tambien puede rechazar
   * con 409 si el nuevo rango choca con otra.
   *
   * Reactivar (`activa: true`) ademas pasa por
   * `exigirSinOtroMecanismoActivo()`: 409 si la oferta tiene un descuento
   * manual, una venta relampago manual o una regla automatica activa.
   * Pausar (`activa: false`) nunca necesita ninguno de los dos chequeos.
   */
  async editar(
    idUsuarioToken: string,
    idRolUsuario: number,
    idReglaParametro: string,
    datos: EditarReglaDescuentoPeriodoPeticion,
  ): Promise<ReglaDescuentoPeriodo> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    if (!REGEX_ID.test(idReglaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idRegla = Number(idReglaParametro);

    if (
      datos.dia_inicio == null &&
      datos.dia_fin == null &&
      datos.mes_inicio == null &&
      datos.mes_fin == null &&
      datos.anio == null &&
      datos.es_venta_relampago == null &&
      datos.porcentaje_descuento == null &&
      datos.activa == null
    ) {
      throw new ErrorValidacion(
        'Debes enviar al menos un campo para actualizar',
      );
    }

    try {
      const actual = await pool.query<ReglaDescuentoPeriodo>(
        `SELECT r.*
           FROM regla_descuento_periodo r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE r.id_regla_descuento_periodo = $1
            AND o.id_usuario = $2`,
        [idRegla, idUsuario],
      );
      const filaActual = actual.rows[0];
      if (filaActual == null) {
        throw new ErrorNoEncontrado(
          'No existe una regla de descuento por periodo con ese id',
        );
      }

      const asignaciones: string[] = [];
      const valores: unknown[] = [];
      const agregar = (columna: string, valor: unknown) => {
        valores.push(valor);
        asignaciones.push(`${columna} = $${valores.length}`);
      };

      const diaInicioFinal =
        datos.dia_inicio != null
          ? validarDia(datos.dia_inicio, 'dia_inicio')
          : filaActual.dia_inicio;
      if (datos.dia_inicio != null) agregar('dia_inicio', diaInicioFinal);

      const diaFinFinal =
        datos.dia_fin != null
          ? validarDia(datos.dia_fin, 'dia_fin')
          : filaActual.dia_fin;
      if (datos.dia_fin != null) agregar('dia_fin', diaFinFinal);

      const mesInicioFinal =
        datos.mes_inicio != null
          ? validarMes(datos.mes_inicio, 'mes_inicio')
          : filaActual.mes_inicio;
      if (datos.mes_inicio != null) agregar('mes_inicio', mesInicioFinal);

      const mesFinFinal =
        datos.mes_fin != null
          ? validarMes(datos.mes_fin, 'mes_fin')
          : filaActual.mes_fin;
      if (datos.mes_fin != null) agregar('mes_fin', mesFinFinal);

      const anioFinal =
        datos.anio != null ? validarAnio(datos.anio) : filaActual.anio;
      if (datos.anio != null) agregar('anio', anioFinal);

      validarCascada({
        mes_inicio: mesInicioFinal,
        mes_fin: mesFinFinal,
        anio: anioFinal,
      });
      // La pantalla manda todas las fechas al guardar, cambien o no: se
      // compara con la fila para no frenar a quien solo pausa una regla vieja.
      const cambianFechas =
        diaInicioFinal !== filaActual.dia_inicio ||
        diaFinFinal !== filaActual.dia_fin ||
        mesInicioFinal !== filaActual.mes_inicio ||
        mesFinFinal !== filaActual.mes_fin ||
        anioFinal !== filaActual.anio;
      if (cambianFechas) {
        validarFechasPosibles(
          {
            dia_inicio: diaInicioFinal,
            dia_fin: diaFinFinal,
            mes_inicio: mesInicioFinal,
            mes_fin: mesFinFinal,
            anio: anioFinal,
          },
          true,
        );
      }

      if (datos.es_venta_relampago != null) {
        agregar(
          'es_venta_relampago',
          validarEsVentaRelampago(datos.es_venta_relampago),
        );
      }
      if (datos.porcentaje_descuento != null) {
        agregar(
          'porcentaje_descuento',
          validarPorcentajeDescuento(datos.porcentaje_descuento),
        );
      }
      const activaFinal =
        datos.activa != null ? validarActiva(datos.activa) : filaActual.activa;
      if (datos.activa != null) {
        agregar('activa', activaFinal);
      }

      if (activaFinal) {
        await this.exigirSinSolapeConOtrasActivas(
          Number(filaActual.id_oferta),
          {
            dia_inicio: diaInicioFinal,
            dia_fin: diaFinFinal,
            mes_inicio: mesInicioFinal,
            mes_fin: mesFinFinal,
            anio: anioFinal,
          },
          idRegla,
        );
      }

      if (datos.activa === true) {
        await exigirSinOtroMecanismoActivo(
          this.logger,
          pool,
          Number(filaActual.id_oferta),
          'regla_periodo',
        );
      }

      valores.push(idRegla, idUsuario);
      const resultado = await pool.query<ReglaDescuentoPeriodo>(
        `UPDATE regla_descuento_periodo r
            SET ${asignaciones.join(', ')}
           FROM oferta o
          WHERE r.id_oferta = o.id_oferta
            AND r.id_regla_descuento_periodo = $${valores.length - 1}
            AND o.id_usuario = $${valores.length}
          RETURNING r.*`,
        valores,
      );
      const fila = resultado.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado(
          'No existe una regla de descuento por periodo con ese id',
        );
      }
      return fila;
    } catch (error) {
      if (
        error instanceof ErrorNoEncontrado ||
        error instanceof ErrorValidacion ||
        error instanceof ErrorConflicto
      ) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Borra una regla propia -- mismo chequeo de dueno que el resto: ajena o
   * inexistente da el 404 generico. Rechaza con 409 si la regla esta
   * `activa`: borrarla mientras esta activa dejaria a `oferta` con un
   * descuento/venta relampago aplicado y NINGUNA fila de
   * `regla_descuento_periodo` que lo justifique -- el disparador
   * (`DisparadorReglasPeriodoService`) solo revisa ofertas que aparecen en
   * un JOIN contra esta tabla, asi que ese descuento quedaria huerfano para
   * siempre (el mismo caso que la limitacion conocida ya documentada en
   * `endpoints-vendedores.md` sobre una regla borrada por SQL directo).
   * Pausarla primero (`PATCH { activa: false }`) deja que el disparador la
   * reconcilie y la quite de la oferta; despues de eso, borrar es seguro.
   */
  async eliminar(
    idUsuarioToken: string,
    idRolUsuario: number,
    idReglaParametro: string,
  ): Promise<void> {
    const idUsuario = await this.resolverIdEfectivo(
      idUsuarioToken,
      idRolUsuario,
    );
    if (!REGEX_ID.test(idReglaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idRegla = Number(idReglaParametro);

    try {
      const actual = await pool.query<{ activa: boolean }>(
        `SELECT r.activa
           FROM regla_descuento_periodo r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE r.id_regla_descuento_periodo = $1
            AND o.id_usuario = $2`,
        [idRegla, idUsuario],
      );
      const fila = actual.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado(
          'No existe una regla de descuento por periodo con ese id',
        );
      }
      if (fila.activa) {
        throw new ErrorConflicto(
          'Pausa la regla (activa: false) antes de borrarla',
        );
      }

      const resultado = await pool.query(
        `DELETE FROM regla_descuento_periodo r
                USING oferta o
               WHERE r.id_oferta = o.id_oferta
                 AND r.id_regla_descuento_periodo = $1
                 AND o.id_usuario = $2`,
        [idRegla, idUsuario],
      );
      if (resultado.rowCount === 0) {
        throw new ErrorNoEncontrado(
          'No existe una regla de descuento por periodo con ese id',
        );
      }
    } catch (error) {
      if (
        error instanceof ErrorNoEncontrado ||
        error instanceof ErrorValidacion ||
        error instanceof ErrorConflicto
      ) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo.
    }
  }
}
