import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import type { PoolClient } from 'pg';
import { consultaCorta, pool } from '../../database/postgres';
import {
  ErrorConexion,
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import {
  esFalloDeConexion,
  manejarErrorConexion,
} from '../../helpers/manejar-error-db';
import type {
  MatrizPermisos,
  ModuloDeLaMatriz,
  RegistroPermiso,
} from '../../models/permiso';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';

const REGEX_ID = /^\d+$/;

/** Cada cuanto se relee la matriz entera para la copia en memoria. */
const REFRESCO_COPIA_MS = 60_000;

/** Cuantas filas del registro se devuelven, como maximo. */
const REGISTRO_MAXIMO = 200;

/**
 * Las entradas que la API no deja quitar, porque sin ellas nadie podria
 * devolverlas (permisos.* del admin) o la sesion no abriria (cuenta.ver: la
 * pide GET /usuario/yo). Con SQL a mano si se pueden quitar.
 */
function protegidoPara(codigo: string, idsRoles: number[]): number[] {
  if (codigo === 'cuenta.ver') {
    return idsRoles;
  }
  if (codigo === 'permisos.ver' || codigo === 'permisos.administrar') {
    return [ID_ROL_ADMIN];
  }
  return [];
}

/**
 * El ACL de funcionalidades (migracion 050, ADR-26).
 *
 * 1. `tiene()`: la pregunta de `PermisoGuard` en cada peticion. Lee
 *    `rol_permiso` en ese momento, asi que un cambio en la tabla vale para la
 *    peticion siguiente, sin reiniciar nada. Si PostgreSQL no contesta, usa
 *    la ultima matriz que leyo entera (se relee al arrancar y cada minuto),
 *    igual que la sesion abierta se cree a su token cuando PostgreSQL esta
 *    caido: la tienda se sigue pudiendo mirar.
 * 2. El registro de cada intento negado (`auditoria_permiso`).
 * 3. La API del admin: la matriz, el registro, dar y quitar.
 */
@Injectable()
export class PermisosService implements OnModuleInit {
  private readonly logger = new Logger(PermisosService.name);

  /** La ultima matriz leida entera: id_rol_usuario -> codigos. */
  private copia: Map<number, Set<string>> | null = null;
  /** Cuando se aviso por ultima vez de que se esta usando la copia. */
  private ultimoAviso = 0;

  async onModuleInit(): Promise<void> {
    await this.refrescarCopia();
  }

  @Interval(REFRESCO_COPIA_MS)
  async refrescarCopia(): Promise<void> {
    try {
      const { rows } = await consultaCorta<{
        id_rol_usuario: number;
        codigo: string;
      }>(
        `SELECT rp.id_rol_usuario,
                m.modulo_permiso_nombre || '.' || p.permiso_nombre AS codigo
           FROM rol_permiso rp
           JOIN permiso p ON p.id_permiso = rp.id_permiso
           JOIN modulo_permiso m ON m.id_modulo_permiso = p.id_modulo_permiso`,
        [],
        5000,
      );
      const copia = new Map<number, Set<string>>();
      for (const fila of rows) {
        const codigos = copia.get(fila.id_rol_usuario) ?? new Set<string>();
        codigos.add(fila.codigo);
        copia.set(fila.id_rol_usuario, codigos);
      }
      this.copia = copia;
    } catch (error) {
      // Al arrancar sin PostgreSQL, o con la 050 sin correr: se reintenta en
      // el proximo intervalo. Mientras, tiene() pregunta a la base igual.
      this.logger.warn(
        `No se pudo leer la matriz de permisos: ${(error as Error).message}`,
      );
    }
  }

  // --------------------------------------------------------------------
  // 1. La pregunta del guard
  // --------------------------------------------------------------------

  /** Si el rol `idRol` tiene el permiso `codigo` (modulo.accion). */
  async tiene(idRol: number, codigo: string): Promise<boolean> {
    const [modulo, accion] = codigo.split('.');
    try {
      const { rows } = await consultaCorta<{ tiene: boolean }>(
        `SELECT EXISTS (
           SELECT 1
             FROM rol_permiso rp
             JOIN permiso p ON p.id_permiso = rp.id_permiso
             JOIN modulo_permiso m ON m.id_modulo_permiso = p.id_modulo_permiso
            WHERE rp.id_rol_usuario = $1
              AND m.modulo_permiso_nombre = $2
              AND p.permiso_nombre = $3
         ) AS tiene`,
        [idRol, modulo, accion],
      );
      return rows[0]?.tiene === true;
    } catch (error) {
      if (!esFalloDeConexion(error)) {
        manejarErrorConexion(this.logger, error);
      }
      if (this.copia == null) {
        throw new ErrorConexion(
          'No se pudo revisar el permiso: PostgreSQL no responde',
        );
      }
      this.avisarCopia();
      return this.copia.get(idRol)?.has(codigo) ?? false;
    }
  }

  /** Los codigos que tiene un rol, para GET /usuario/yo. */
  async codigosDe(idRol: number): Promise<string[]> {
    try {
      const { rows } = await consultaCorta<{ codigo: string }>(
        `SELECT m.modulo_permiso_nombre || '.' || p.permiso_nombre AS codigo
           FROM rol_permiso rp
           JOIN permiso p ON p.id_permiso = rp.id_permiso
           JOIN modulo_permiso m ON m.id_modulo_permiso = p.id_modulo_permiso
          WHERE rp.id_rol_usuario = $1
          ORDER BY 1`,
        [idRol],
      );
      return rows.map((fila) => fila.codigo);
    } catch (error) {
      if (!esFalloDeConexion(error)) {
        manejarErrorConexion(this.logger, error);
      }
      return [...(this.copia?.get(idRol) ?? [])].sort();
    }
  }

  private avisarCopia(): void {
    const ahora = Date.now();
    if (ahora - this.ultimoAviso < 60_000) {
      return;
    }
    this.ultimoAviso = ahora;
    this.logger.warn(
      'PostgreSQL no responde: los permisos salen de la ultima matriz leida',
    );
  }

  // --------------------------------------------------------------------
  // 2. El registro de lo negado
  // --------------------------------------------------------------------

  /**
   * Anota un intento negado. Nunca falla hacia afuera: si PostgreSQL no
   * contesta, el 403 sale igual y solo se pierde la fila.
   */
  async registrarNegado(
    idUsuario: string,
    idRol: number,
    codigo: string,
    metodo: string,
    ruta: string,
  ): Promise<void> {
    const [modulo, accion] = codigo.split('.');
    try {
      await consultaCorta(
        `INSERT INTO auditoria_permiso
           (accion, id_usuario_actor, id_rol_usuario, id_permiso, metodo, ruta)
         SELECT 'negado', $1, $2, p.id_permiso, $5, $6
           FROM permiso p
           JOIN modulo_permiso m ON m.id_modulo_permiso = p.id_modulo_permiso
          WHERE m.modulo_permiso_nombre = $3 AND p.permiso_nombre = $4`,
        [
          idUsuario,
          idRol,
          modulo,
          accion,
          metodo.slice(0, 7),
          ruta.slice(0, 300),
        ],
      );
    } catch (error) {
      this.logger.warn(
        `No se pudo anotar el intento negado de ${codigo}: ${(error as Error).message}`,
      );
    }
  }

  // --------------------------------------------------------------------
  // 3. La API del admin
  // --------------------------------------------------------------------

  /** La matriz entera: los roles como columnas y los permisos por modulo. */
  async matriz(): Promise<MatrizPermisos> {
    try {
      const { rows: roles } = await pool.query<{
        id_rol_usuario: number;
        rol: string;
      }>(
        `SELECT id_rol_usuario, rol_usuario_nombre AS rol
           FROM rol_usuario ORDER BY id_rol_usuario`,
      );
      const { rows } = await pool.query<{
        modulo: string;
        modulo_descripcion: string;
        id_permiso: number;
        permiso: string;
        descripcion: string;
        roles: number[];
      }>(
        `SELECT m.modulo_permiso_nombre AS modulo,
                m.descripcion AS modulo_descripcion,
                p.id_permiso, p.permiso_nombre AS permiso, p.descripcion,
                coalesce(array_agg(rp.id_rol_usuario ORDER BY rp.id_rol_usuario)
                           FILTER (WHERE rp.id_rol_usuario IS NOT NULL),
                         '{}') AS roles
           FROM permiso p
           JOIN modulo_permiso m ON m.id_modulo_permiso = p.id_modulo_permiso
           LEFT JOIN rol_permiso rp ON rp.id_permiso = p.id_permiso
          GROUP BY m.id_modulo_permiso, p.id_permiso
          ORDER BY m.id_modulo_permiso, p.permiso_nombre`,
      );
      const idsRoles = roles.map((r) => r.id_rol_usuario);
      const modulos: ModuloDeLaMatriz[] = [];
      for (const fila of rows) {
        let modulo = modulos[modulos.length - 1];
        if (modulo?.modulo !== fila.modulo) {
          modulo = {
            modulo: fila.modulo,
            descripcion: fila.modulo_descripcion,
            permisos: [],
          };
          modulos.push(modulo);
        }
        const codigo = `${fila.modulo}.${fila.permiso}`;
        modulo.permisos.push({
          id_permiso: fila.id_permiso,
          codigo,
          permiso: fila.permiso,
          descripcion: fila.descripcion,
          roles: fila.roles.map(Number),
          protegido_para: protegidoPara(codigo, idsRoles),
        });
      }
      return { roles, modulos };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** Lo ultimo del registro, lo mas nuevo primero. */
  async registro(limiteParametro?: string): Promise<RegistroPermiso[]> {
    let limite = 50;
    if (limiteParametro != null && limiteParametro !== '') {
      if (!REGEX_ID.test(limiteParametro) || Number(limiteParametro) < 1) {
        throw new ErrorValidacion('El limite tiene que ser un entero positivo');
      }
      limite = Math.min(Number(limiteParametro), REGISTRO_MAXIMO);
    }
    try {
      const { rows } = await pool.query<RegistroPermiso>(
        `SELECT a.id_auditoria_permiso::text AS id_auditoria_permiso,
                a.fecha, a.accion,
                json_build_object(
                  'id_usuario', a.id_usuario_actor::text,
                  'usuario', u.usuario,
                  'correo', u.correo_electronico) AS actor,
                r.rol_usuario_nombre AS rol,
                m.modulo_permiso_nombre || '.' || p.permiso_nombre AS codigo,
                a.metodo, a.ruta
           FROM auditoria_permiso a
           JOIN rol_usuario r ON r.id_rol_usuario = a.id_rol_usuario
           JOIN permiso p ON p.id_permiso = a.id_permiso
           JOIN modulo_permiso m ON m.id_modulo_permiso = p.id_modulo_permiso
           LEFT JOIN usuarios u ON u.id_usuario = a.id_usuario_actor
          ORDER BY a.id_auditoria_permiso DESC
          LIMIT $1`,
        [limite],
      );
      return rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Le da un permiso a un rol. Si ya lo tenia no cambia nada y lo dice.
   * La fila del registro va en la misma transaccion.
   */
  async otorgar(
    idActor: string,
    idRolParametro: string,
    idPermisoParametro: string,
  ): Promise<{ cambio: boolean; codigo: string; rol: string }> {
    const { idRol, idPermiso, codigo, rol } = await this.entrada(
      idRolParametro,
      idPermisoParametro,
    );
    const cambio = await this.enTransaccion(async (cliente) => {
      const { rowCount } = await cliente.query(
        `INSERT INTO rol_permiso (id_rol_usuario, id_permiso, id_usuario_otorgo)
         VALUES ($1, $2, $3)
         ON CONFLICT (id_rol_usuario, id_permiso) DO NOTHING`,
        [idRol, idPermiso, idActor],
      );
      if (rowCount === 0) {
        return false;
      }
      await cliente.query(
        `INSERT INTO auditoria_permiso
           (accion, id_usuario_actor, id_rol_usuario, id_permiso)
         VALUES ('otorgar', $1, $2, $3)`,
        [idActor, idRol, idPermiso],
      );
      return true;
    });
    await this.refrescarCopia();
    return { cambio, codigo, rol };
  }

  /** Le quita un permiso a un rol, salvo los protegidos. */
  async revocar(
    idActor: string,
    idRolParametro: string,
    idPermisoParametro: string,
  ): Promise<{ codigo: string; rol: string }> {
    const { idRol, idPermiso, codigo, rol, idsRoles } = await this.entrada(
      idRolParametro,
      idPermisoParametro,
    );
    if (protegidoPara(codigo, idsRoles).includes(idRol)) {
      throw new ErrorConflicto(
        codigo === 'cuenta.ver'
          ? 'cuenta.ver no se puede quitar: sin el la sesion no abre'
          : `${codigo} no se le puede quitar al admin: nadie podria devolverlo`,
      );
    }
    const quitado = await this.enTransaccion(async (cliente) => {
      const { rowCount } = await cliente.query(
        'DELETE FROM rol_permiso WHERE id_rol_usuario = $1 AND id_permiso = $2',
        [idRol, idPermiso],
      );
      if (rowCount === 0) {
        return false;
      }
      await cliente.query(
        `INSERT INTO auditoria_permiso
           (accion, id_usuario_actor, id_rol_usuario, id_permiso)
         VALUES ('revocar', $1, $2, $3)`,
        [idActor, idRol, idPermiso],
      );
      return true;
    });
    if (!quitado) {
      throw new ErrorNoEncontrado(`El rol ${rol} no tiene ${codigo}`);
    }
    await this.refrescarCopia();
    return { codigo, rol };
  }

  /** Valida los dos ids de la ruta y trae sus nombres. */
  private async entrada(
    idRolParametro: string,
    idPermisoParametro: string,
  ): Promise<{
    idRol: number;
    idPermiso: number;
    codigo: string;
    rol: string;
    idsRoles: number[];
  }> {
    if (!REGEX_ID.test(idRolParametro) || !REGEX_ID.test(idPermisoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idRol = Number(idRolParametro);
    const idPermiso = Number(idPermisoParametro);
    let fila:
      | { rol: string | null; codigo: string | null; ids_roles: number[] }
      | undefined;
    try {
      const { rows } = await pool.query<{
        rol: string | null;
        codigo: string | null;
        ids_roles: number[];
      }>(
        `SELECT (SELECT rol_usuario_nombre FROM rol_usuario
                  WHERE id_rol_usuario = $1) AS rol,
                (SELECT m.modulo_permiso_nombre || '.' || p.permiso_nombre
                   FROM permiso p
                   JOIN modulo_permiso m ON m.id_modulo_permiso = p.id_modulo_permiso
                  WHERE p.id_permiso = $2) AS codigo,
                (SELECT array_agg(id_rol_usuario ORDER BY id_rol_usuario)
                   FROM rol_usuario) AS ids_roles`,
        [idRol, idPermiso],
      );
      fila = rows[0];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    if (fila?.rol == null) {
      throw new ErrorNoEncontrado('No existe un rol con ese id');
    }
    if (fila.codigo == null) {
      throw new ErrorNoEncontrado('No existe un permiso con ese id');
    }
    return {
      idRol,
      idPermiso,
      codigo: fila.codigo,
      rol: fila.rol,
      idsRoles: fila.ids_roles.map(Number),
    };
  }

  private async enTransaccion<T>(
    trabajo: (cliente: PoolClient) => Promise<T>,
  ): Promise<T> {
    let cliente: PoolClient;
    try {
      cliente = await pool.connect();
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    try {
      await cliente.query('BEGIN');
      const resultado = await trabajo(cliente);
      await cliente.query('COMMIT');
      return resultado;
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }
}
