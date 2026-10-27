import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { CORREO_TIENDA } from '../../helpers/constantes';
import { ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';
import { ID_ESTADO_ACTIVO } from '../../models/estado-usuario';
import {
  EntradaPermisoOferta,
  OfertaCompartida,
  PERMISOS_OFERTA,
  PermisoOfertaNombre,
  PermisoOfertaResuelto,
  RegistroPermisoOferta,
} from '../../models/permiso-oferta';
import { ID_ROL_ADMIN, ID_ROL_COMPRADOR } from '../../models/rol-usuario';

const REGEX_ID = /^\d+$/;

/** El mismo 404 que da una oferta ajena en /vendedor/ofertas. */
const NO_EXISTE = 'No existe una oferta con ese id';

/** Cuantas filas del registro se le ensenan al dueno. */
const REGISTRO_LIMITE = 30;

/** Una accion del registro (ver el CHECK de la 049). */
export type AccionAcl =
  | 'otorgar'
  | 'revocar'
  | 'editar'
  | 'poner_descuento'
  | 'quitar_descuento'
  | 'negado';

/** Lo que se pide para dar permisos sobre una oferta. */
export interface OtorgarPermisoPeticion {
  correo?: unknown;
  permisos?: unknown;
  /** ISO 8601, en el futuro. Ausente o null = no vence. */
  fecha_vencimiento?: unknown;
}

/**
 * El ACL de la aplicacion, por oferta (migracion 049, ADR-24).
 *
 * Tres cosas, en este orden de importancia:
 *
 * 1. `comprobar()`: la pregunta del guard. Esta cuenta, esta oferta, este
 *    permiso, y una entrada vigente. Lo que no esta en la lista se niega con
 *    el 404 de siempre, y el intento queda en el registro.
 * 2. Lo compartido conmigo: la lista y una oferta, solo con lo que la cuenta
 *    tiene permiso de ver.
 * 3. Repartir permisos: solo el dueno de la oferta (o un admin, a nombre de la
 *    tienda, igual que en el resto de /vendedor/ofertas). Cada permiso dado o
 *    quitado queda en el registro en la MISMA transaccion.
 *
 * Las acciones por la via compartida (editar, descuento) NO estan aqui: el
 * controller llama a `OfertasVendedorService`, el de siempre, a nombre del
 * dueno, y despues anota en el registro quien lo hizo de verdad con
 * `registrar()`.
 */
@Injectable()
export class AclOfertasService {
  private readonly logger = new Logger(AclOfertasService.name);

  // --------------------------------------------------------------------
  // 1. La pregunta del guard
  // --------------------------------------------------------------------

  /**
   * Si `idActor` puede hacer `permiso` sobre la oferta `idOfertaParametro`.
   * `ver` lo da cualquier entrada vigente; `editar` y `descuento` piden la
   * suya. Devuelve la oferta y su dueno, o lanza `ErrorNoEncontrado`.
   */
  async comprobar(
    idActor: string,
    idOfertaParametro: string,
    permiso: PermisoOfertaNombre,
  ): Promise<PermisoOfertaResuelto> {
    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idOferta = Number(idOfertaParametro);

    let fila: { id_dueno: string; permisos: string[] } | undefined;
    try {
      const { rows } = await pool.query<{
        id_dueno: string;
        permisos: string[];
      }>(
        `SELECT o.id_usuario::text AS id_dueno,
                array_agg(t.tipo_permiso_oferta_nombre::text) AS permisos
           FROM permiso_oferta p
           JOIN oferta o ON o.id_oferta = p.id_oferta
           JOIN tipo_permiso_oferta t
             ON t.id_tipo_permiso_oferta = p.id_tipo_permiso_oferta
          WHERE p.id_oferta = $1 AND p.id_usuario = $2
            AND (p.fecha_vencimiento IS NULL OR p.fecha_vencimiento > now())
          GROUP BY o.id_usuario`,
        [idOferta, idActor],
      );
      fila = rows[0];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    const permitido =
      fila != null && (permiso === 'ver' || fila.permisos.includes(permiso));
    if (!permitido) {
      await this.registrarSinFallar({
        id_oferta: idOferta,
        id_usuario_actor: idActor,
        id_usuario_dueno: fila?.id_dueno ?? null,
        accion: 'negado',
        permiso,
        detalle: {
          motivo:
            fila == null
              ? 'sin entrada vigente para esta cuenta y esta oferta'
              : `tiene ${fila.permisos.join(', ')}, no ${permiso}`,
        },
      });
      throw new ErrorNoEncontrado(NO_EXISTE);
    }
    return { id_oferta: idOferta, id_dueno: fila.id_dueno, permiso };
  }

  /**
   * Anota una accion en el registro. La usa el controller despues de editar o
   * de poner o quitar un descuento por la via compartida.
   */
  async registrar(fila: FilaRegistro, cliente?: PoolClient): Promise<void> {
    await (cliente ?? pool).query(
      `INSERT INTO auditoria_permiso_oferta
         (id_oferta, id_usuario_actor, id_usuario_dueno, id_usuario_receptor,
          accion, permiso, detalle)
       VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)`,
      [
        fila.id_oferta,
        fila.id_usuario_actor,
        fila.id_usuario_dueno ?? null,
        fila.id_usuario_receptor ?? null,
        fila.accion,
        fila.permiso ?? null,
        JSON.stringify(fila.detalle ?? {}),
      ],
    );
  }

  /**
   * Igual que `registrar()`, pero un fallo del registro no cambia la
   * respuesta: la accion ya se hizo (o ya se nego), y eso es lo que manda.
   */
  async registrarSinFallar(fila: FilaRegistro): Promise<void> {
    try {
      await this.registrar(fila);
    } catch (error) {
      this.logger.warn(
        `no se pudo anotar en auditoria_permiso_oferta (${fila.accion} sobre la oferta ${fila.id_oferta}): ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  // --------------------------------------------------------------------
  // 2. Lo compartido conmigo
  // --------------------------------------------------------------------

  /** Las ofertas sobre las que `idActor` tiene al menos una entrada vigente. */
  async listarCompartidas(idActor: string): Promise<OfertaCompartida[]> {
    try {
      const { rows } = await pool.query<OfertaCompartida>(
        `${SQL_COMPARTIDAS} ORDER BY o.id_oferta`,
        [idActor],
      );
      return rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** Una oferta compartida. El guard ya comprobo que se puede ver. */
  async obtenerCompartida(
    idActor: string,
    idOferta: number,
  ): Promise<OfertaCompartida> {
    let fila: OfertaCompartida | undefined;
    try {
      const { rows } = await pool.query<OfertaCompartida>(
        `${SQL_COMPARTIDAS} HAVING o.id_oferta = $2`,
        [idActor, idOferta],
      );
      fila = rows[0];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    if (fila == null) {
      // El permiso vencio entre el guard y aqui.
      throw new ErrorNoEncontrado(NO_EXISTE);
    }
    return fila;
  }

  // --------------------------------------------------------------------
  // 3. Repartir permisos (solo el dueno)
  // --------------------------------------------------------------------

  /** Las entradas del ACL de una oferta propia y su registro. */
  async listarPermisos(
    idActor: string,
    idRolUsuario: number,
    idOfertaParametro: string,
  ): Promise<{
    permisos: EntradaPermisoOferta[];
    registro: RegistroPermisoOferta[];
  }> {
    const idOferta = await this.exigirDueno(
      idActor,
      idRolUsuario,
      idOfertaParametro,
    );
    return this.leerPermisos(idOferta);
  }

  /**
   * Da uno o mas permisos sobre una oferta propia a la cuenta de `correo`.
   * Volver a dar uno que ya estaba actualiza su vencimiento. Todo en una
   * transaccion, con su fila en el registro por cada permiso.
   */
  async otorgar(
    idActor: string,
    idRolUsuario: number,
    idOfertaParametro: string,
    datos: OtorgarPermisoPeticion,
  ): Promise<{
    permisos: EntradaPermisoOferta[];
    registro: RegistroPermisoOferta[];
  }> {
    const correo = validarCorreo(datos?.correo);
    const permisos = validarPermisos(datos?.permisos);
    const vence = validarVencimiento(datos?.fecha_vencimiento);

    const idOferta = await this.exigirDueno(
      idActor,
      idRolUsuario,
      idOfertaParametro,
    );
    const idDueno = await this.duenoDe(idOferta);
    const receptor = await this.cuentaPorCorreo(correo);

    if (receptor == null) {
      throw new ErrorValidacion('No hay una cuenta con ese correo');
    }
    if (receptor.id_usuario === idActor) {
      throw new ErrorValidacion('No puedes darte permisos a ti mismo');
    }
    if (receptor.id_usuario === idDueno) {
      throw new ErrorValidacion('Esa cuenta ya es la duena de la oferta');
    }
    if (receptor.id_estado_usuario !== ID_ESTADO_ACTIVO) {
      throw new ErrorValidacion('Esa cuenta no esta activa');
    }
    if (receptor.id_rol_usuario === ID_ROL_COMPRADOR) {
      throw new ErrorValidacion(
        'Solo se comparte con cuentas de vendedor o de administrador',
      );
    }

    const cliente = await this.conectar();
    try {
      await cliente.query('BEGIN');
      for (const permiso of permisos) {
        await cliente.query(
          `INSERT INTO permiso_oferta
             (id_oferta, id_usuario, id_tipo_permiso_oferta,
              id_usuario_otorgo, fecha_vencimiento)
           SELECT $1, $2, t.id_tipo_permiso_oferta, $3, $5
             FROM tipo_permiso_oferta t
            WHERE t.tipo_permiso_oferta_nombre = $4
           ON CONFLICT ON CONSTRAINT permiso_oferta_unico DO UPDATE
              SET fecha_vencimiento = EXCLUDED.fecha_vencimiento,
                  id_usuario_otorgo = EXCLUDED.id_usuario_otorgo,
                  fecha_otorgado    = now()`,
          [idOferta, receptor.id_usuario, idActor, permiso, vence],
        );
        await this.registrar(
          {
            id_oferta: idOferta,
            id_usuario_actor: idActor,
            id_usuario_dueno: idDueno,
            id_usuario_receptor: receptor.id_usuario,
            accion: 'otorgar',
            permiso,
            detalle: { fecha_vencimiento: vence },
          },
          cliente,
        );
      }
      await cliente.query('COMMIT');
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
    return this.leerPermisos(idOferta);
  }

  /** Quita una entrada del ACL de una oferta propia. */
  async revocar(
    idActor: string,
    idRolUsuario: number,
    idOfertaParametro: string,
    idPermisoParametro: string,
  ): Promise<{
    permisos: EntradaPermisoOferta[];
    registro: RegistroPermisoOferta[];
  }> {
    if (!REGEX_ID.test(idPermisoParametro)) {
      throw new ErrorValidacion('El id del permiso no es valido');
    }
    const idOferta = await this.exigirDueno(
      idActor,
      idRolUsuario,
      idOfertaParametro,
    );
    const idDueno = await this.duenoDe(idOferta);

    const cliente = await this.conectar();
    let quitado: { id_usuario: string; permiso: string } | undefined;
    try {
      await cliente.query('BEGIN');
      const { rows } = await cliente.query<{
        id_usuario: string;
        permiso: string;
      }>(
        `DELETE FROM permiso_oferta p
          USING tipo_permiso_oferta t
          WHERE p.id_permiso_oferta = $1 AND p.id_oferta = $2
            AND t.id_tipo_permiso_oferta = p.id_tipo_permiso_oferta
        RETURNING p.id_usuario::text AS id_usuario,
                  t.tipo_permiso_oferta_nombre::text AS permiso`,
        [idPermisoParametro, idOferta],
      );
      quitado = rows[0];
      if (quitado != null) {
        await this.registrar(
          {
            id_oferta: idOferta,
            id_usuario_actor: idActor,
            id_usuario_dueno: idDueno,
            id_usuario_receptor: quitado.id_usuario,
            accion: 'revocar',
            permiso: quitado.permiso,
            detalle: {},
          },
          cliente,
        );
      }
      await cliente.query('COMMIT');
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
    if (quitado == null) {
      throw new ErrorNoEncontrado('Esa oferta no tiene ese permiso');
    }
    return this.leerPermisos(idOferta);
  }

  // --------------------------------------------------------------------
  // Lo de adentro
  // --------------------------------------------------------------------

  /**
   * Comprueba que la oferta sea del actor y devuelve su id. Un admin actua
   * como la tienda, igual que en `OfertasVendedorService.resolverIdEfectivo`.
   * Ajena o inexistente: el mismo 404.
   */
  private async exigirDueno(
    idActor: string,
    idRolUsuario: number,
    idOfertaParametro: string,
  ): Promise<number> {
    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idOferta = Number(idOfertaParametro);
    let es: boolean;
    try {
      const { rows } = await pool.query<{ es: boolean }>(
        `SELECT EXISTS (
           SELECT 1 FROM oferta o
            WHERE o.id_oferta = $1
              AND o.id_usuario = CASE WHEN $3::int = $4::int
                                      THEN (SELECT id_usuario FROM usuarios
                                             WHERE correo_electronico = $5)
                                      ELSE $2::bigint END
         ) AS es`,
        [idOferta, idActor, idRolUsuario, ID_ROL_ADMIN, CORREO_TIENDA],
      );
      es = rows[0]?.es === true;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    if (!es) {
      throw new ErrorNoEncontrado(NO_EXISTE);
    }
    return idOferta;
  }

  private async duenoDe(idOferta: number): Promise<string> {
    try {
      const { rows } = await pool.query<{ id_usuario: string }>(
        'SELECT id_usuario::text AS id_usuario FROM oferta WHERE id_oferta = $1',
        [idOferta],
      );
      if (rows[0] == null) {
        throw new ErrorNoEncontrado(NO_EXISTE);
      }
      return rows[0].id_usuario;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  private async cuentaPorCorreo(
    correo: string,
  ): Promise<
    | { id_usuario: string; id_rol_usuario: number; id_estado_usuario: number }
    | undefined
  > {
    try {
      const { rows } = await pool.query<{
        id_usuario: string;
        id_rol_usuario: number;
        id_estado_usuario: number;
      }>(
        `SELECT id_usuario::text AS id_usuario, id_rol_usuario, id_estado_usuario
           FROM usuarios
          WHERE lower(correo_electronico) = lower($1)`,
        [correo],
      );
      return rows[0];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async conectar(): Promise<PoolClient> {
    try {
      return await pool.connect();
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async leerPermisos(idOferta: number): Promise<{
    permisos: EntradaPermisoOferta[];
    registro: RegistroPermisoOferta[];
  }> {
    try {
      const { rows: permisos } = await pool.query<EntradaPermisoOferta>(
        `SELECT p.id_permiso_oferta::text AS id_permiso_oferta,
                t.tipo_permiso_oferta_nombre AS permiso,
                json_build_object(
                  'id_usuario', r.id_usuario::text, 'usuario', r.usuario,
                  'nombre', r.nombre, 'apellido', r.apellido,
                  'correo', r.correo_electronico) AS receptor,
                g.usuario AS otorgado_por,
                p.fecha_otorgado, p.fecha_vencimiento,
                (p.fecha_vencimiento IS NULL OR p.fecha_vencimiento > now()) AS vigente
           FROM permiso_oferta p
           JOIN tipo_permiso_oferta t
             ON t.id_tipo_permiso_oferta = p.id_tipo_permiso_oferta
           JOIN usuarios r ON r.id_usuario = p.id_usuario
           JOIN usuarios g ON g.id_usuario = p.id_usuario_otorgo
          WHERE p.id_oferta = $1
          ORDER BY r.usuario, t.id_tipo_permiso_oferta`,
        [idOferta],
      );
      const { rows: registro } = await pool.query<RegistroPermisoOferta>(
        `SELECT a.fecha, a.accion, a.permiso,
                ua.usuario AS actor, ur.usuario AS receptor, a.detalle
           FROM auditoria_permiso_oferta a
           LEFT JOIN usuarios ua ON ua.id_usuario = a.id_usuario_actor
           LEFT JOIN usuarios ur ON ur.id_usuario = a.id_usuario_receptor
          WHERE a.id_oferta = $1
          ORDER BY a.fecha DESC, a.id_auditoria_permiso_oferta DESC
          LIMIT $2`,
        [idOferta, REGISTRO_LIMITE],
      );
      return { permisos, registro };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}

/** Una fila para `auditoria_permiso_oferta`. */
export interface FilaRegistro {
  id_oferta: number;
  id_usuario_actor: string;
  id_usuario_dueno?: string | null;
  id_usuario_receptor?: string | null;
  accion: AccionAcl;
  permiso?: string | null;
  detalle?: Record<string, unknown>;
}

/**
 * Las ofertas que `$1` tiene compartidas, con sus permisos vigentes. Termina
 * en el GROUP BY para que el llamador agregue `ORDER BY` o `HAVING`.
 */
const SQL_COMPARTIDAS = `
  SELECT o.id_oferta::text                     AS id_oferta,
         o.id_producto_mongo::text             AS id_producto,
         o.id_producto_variante_mongo::text    AS id_variante,
         pc.nombre                             AS producto,
         vc.nombre_variante                    AS variante,
         vc.imagen                             AS imagen,
         o.precio::text                        AS precio,
         o.porcentaje_descuento,
         ${expresionPrecioFinal('o')}::text    AS precio_final,
         o.stock,
         eo.estado_oferta_nombre               AS estado,
         o.es_inventario_limitado,
         o.fecha_vencimiento_descuento,
         json_build_object(
           'id_usuario', d.id_usuario::text, 'usuario', d.usuario,
           'nombre', d.nombre, 'apellido', d.apellido,
           'correo', d.correo_electronico)     AS dueno,
         json_agg(json_build_object(
           'permiso', t.tipo_permiso_oferta_nombre,
           'fecha_vencimiento', p.fecha_vencimiento)
           ORDER BY t.id_tipo_permiso_oferta)  AS permisos
    FROM permiso_oferta p
    JOIN tipo_permiso_oferta t
      ON t.id_tipo_permiso_oferta = p.id_tipo_permiso_oferta
    JOIN oferta o          ON o.id_oferta = p.id_oferta
    JOIN estado_oferta eo  ON eo.id_estado_oferta = o.id_estado_oferta
    JOIN usuarios d        ON d.id_usuario = o.id_usuario
    LEFT JOIN producto_catalogo pc
      ON pc.id_producto_mongo = o.id_producto_mongo
    LEFT JOIN variante_catalogo vc
      ON vc.id_producto_mongo = o.id_producto_mongo
     AND vc.id_producto_variante_mongo = o.id_producto_variante_mongo
   WHERE p.id_usuario = $1
     AND (p.fecha_vencimiento IS NULL OR p.fecha_vencimiento > now())
   GROUP BY o.id_oferta, pc.nombre, vc.nombre_variante, vc.imagen,
            eo.estado_oferta_nombre, d.id_usuario
`;

function validarCorreo(valor: unknown): string {
  if (typeof valor !== 'string' || valor.trim() === '' || valor.length > 255) {
    throw new ErrorValidacion('Escribe el correo de la cuenta');
  }
  return valor.trim();
}

function validarPermisos(valor: unknown): PermisoOfertaNombre[] {
  if (!Array.isArray(valor) || valor.length === 0) {
    throw new ErrorValidacion('Elige al menos un permiso');
  }
  const unicos = [...new Set(valor)];
  for (const p of unicos) {
    if (!PERMISOS_OFERTA.includes(p as PermisoOfertaNombre)) {
      throw new ErrorValidacion(
        `Permiso desconocido. Son ${PERMISOS_OFERTA.join(', ')}`,
      );
    }
  }
  return unicos as PermisoOfertaNombre[];
}

function validarVencimiento(valor: unknown): string | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (typeof valor !== 'string') {
    throw new ErrorValidacion('La fecha de vencimiento no es valida');
  }
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime())) {
    throw new ErrorValidacion('La fecha de vencimiento no es valida');
  }
  if (fecha.getTime() <= Date.now()) {
    throw new ErrorValidacion('La fecha de vencimiento ya paso');
  }
  return fecha.toISOString();
}
