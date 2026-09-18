import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { redis } from '../../database/redis';
import { ErrorNoEncontrado } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { registrarAlertaFraude } from '../../helpers/registrar-alerta-fraude';
import {
  validarFiltroEstadoAlerta,
  validarFiltroTipoAlerta,
  validarIdAlertaFraude,
} from '../../helpers/validaciones-fraude';
import {
  validarLimite,
  validarPagina,
} from '../../helpers/validaciones-productos';
import type {
  AlertasFraudePaginadas,
  PaginarAlertasFraudeQuery,
} from '../../dto/paginar-alertas-fraude';
import type {
  AlertaFraudeUsuario,
  AlertasFraudeUsuarioPaginadas,
  PaginarAlertasFraudeUsuarioQuery,
} from '../../dto/alertas-fraude-usuario';
import {
  AlertaFraude,
  EstadoAlertaFraude,
  FilaAlertaFraude,
  TipoAlertaFraude,
  ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_CUENTA,
  ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_IP,
  ID_TIPO_ALERTA_FRAUDE_IP_ROTACION_CUENTA,
  ID_TIPO_ALERTA_FRAUDE_MULTI_CUENTA_IP,
} from '../../models/alerta-fraude';

/**
 * El agregado de `notificacion_fraude` + `usuarios` para UNA alerta, como
 * subconsulta correlacionada contra `af` -- reusado tal cual en las dos
 * consultas de admin de este archivo (listado y, via
 * `fraude-login-exploracion.service.ts`, el `PATCH`). `json_agg` sobre
 * cero filas da `NULL`, de ahi el `COALESCE` a `'[]'`.
 */
const SQL_CUENTAS_AFECTADAS = `(
  SELECT COALESCE(json_agg(json_build_object(
           'id_usuario', nf.id_usuario::text,
           'usuario', u.usuario,
           'fecha_lectura', nf.fecha_lectura
         ) ORDER BY u.usuario), '[]'::json)
    FROM notificacion_fraude nf
    JOIN usuarios u ON u.id_usuario = nf.id_usuario
   WHERE nf.id_alerta_fraude = af.id_alerta_fraude
)`;

/**
 * Deteccion de fraude en el propio camino del login -- punto 4 de
 * `elementos Generales/plan pendiente/fraude-login-eventos.md`. NO es el
 * indice de Elasticsearch (eso es `EventosAutenticacionSyncService`, para
 * consultas retrospectivas): esto son contadores de Redis que se revisan
 * en cada intento, sin esperar a ningun worker, y que escriben una fila en
 * `alerta_fraude` (Postgres) apenas cruzan su umbral.
 *
 * `registrarIntento()` la llama `UsuarioController` SIN `await`, igual que
 * `LogService`: es best-effort, nunca lanza, y no debe retrasar ni tumbar
 * la respuesta del login. Si Redis o Postgres no responden, el intento de
 * login se resuelve igual -- se pierde esa senal en concreto, nada mas.
 *
 * Por decision explicita del usuario (2026-09-10): esto SOLO alerta, nunca
 * frena el login. Cruzar un umbral deja una fila en `alerta_fraude` para
 * que un admin la revise (`GET /admin/fraude/alertas-login`, tambien en
 * este servicio) -- ninguna cuenta ni IP se bloquea sola.
 *
 * Cuatro senales, las que no necesitan geolocalizacion (punto 2 del plan,
 * todavia sin decidir) ni una consulta retrospectiva -- cada una tiene su
 * espejo lento sobre Elasticsearch en `FraudeLoginRetrospectivoService`
 * (mismo nombre + sufijo `_lenta`), salvo `fuerza_bruta_ip`, que no tiene
 * version larga (no se pidio) e `ip_rotacion_cuenta`, que nacio primero del
 * lado lento y se agrego aca despues (2026-09-11, segunda ronda):
 *
 *   fuerza_bruta_ip       muchos fallos desde una misma IP en poco tiempo.
 *   fuerza_bruta_cuenta   muchos fallos contra un mismo identificador.
 *   multi_cuenta_ip       muchos identificadores distintos probados desde
 *                         la misma IP (credential stuffing).
 *   ip_rotacion_cuenta    muchas IPs distintas probando un mismo
 *                         identificador (evade un bloqueo por IP) -- el
 *                         espejo invertido de multi_cuenta_ip: agrupa por
 *                         CUENTA y cuenta IPs distintas, en vez de agrupar
 *                         por IP y contar cuentas distintas.
 *
 * Cada contador es de ventana fija: `INCR`/`SADD` y despues
 * `EXPIRE ... NX` (Redis 7+, ya en `redis:8-alpine` del compose) para que
 * el TTL se ponga UNA sola vez, al crear la clave -- si ya tenia TTL no lo
 * reinicia, asi la ventana no se alarga sola con cada intento nuevo.
 */
@Injectable()
export class FraudeLoginService {
  private readonly logger = new Logger(FraudeLoginService.name);

  private static readonly VENTANA_FALLOS_IP_SEGUNDOS = 60;
  private static readonly UMBRAL_FALLOS_IP = 8;

  private static readonly VENTANA_FALLOS_CUENTA_SEGUNDOS = 60;
  private static readonly UMBRAL_FALLOS_CUENTA = 5;

  private static readonly VENTANA_MULTICUENTA_SEGUNDOS = 300;
  private static readonly UMBRAL_MULTICUENTA = 4;

  // Mismos numeros que multi_cuenta_ip, con los roles invertidos (ver el
  // comentario de la clase) -- no hay una razon tecnica para que el umbral
  // de "cuantos distintos son sospechosos" cambie segun cual de los dos
  // lados se agrupa.
  private static readonly VENTANA_ROTACION_IP_SEGUNDOS = 300;
  private static readonly UMBRAL_ROTACION_IP = 4;

  // ---------------------------------------------------------------------
  // Deteccion (escritura) -- llamada desde UsuarioController
  // ---------------------------------------------------------------------

  async registrarIntento(datos: {
    fallo: boolean;
    ip: string | null;
    identificador: string | null;
    idUsuario: string | null;
  }): Promise<void> {
    if (datos.ip == null) {
      // Sin IP no hay a que atribuirle fuerza_bruta_ip ni multi_cuenta_ip.
      // fuerza_bruta_cuenta si podria calcularse igual, pero en la practica
      // Fastify siempre trae request.ip -- no vale la pena la senal suelta.
      return;
    }

    try {
      await Promise.all([
        this.revisarFuerzaBrutaIp(datos.ip, datos.fallo),
        this.revisarMultiCuentaIp(datos.ip, datos.identificador),
        this.revisarIpRotacionCuenta(
          datos.identificador,
          datos.ip,
          datos.idUsuario,
        ),
        datos.fallo && datos.identificador != null
          ? this.revisarFuerzaBrutaCuenta(datos.identificador, datos.idUsuario)
          : Promise.resolve(),
      ]);
    } catch (error) {
      this.logger.warn(
        `deteccion de fraude de login interrumpida: ${mensajeCorto(error)}`,
      );
    }
  }

  private async revisarFuerzaBrutaIp(
    ip: string,
    fallo: boolean,
  ): Promise<void> {
    if (!fallo) {
      return;
    }
    const clave = `mesh:fraude:fallos_ip:${ip}`;
    const fallos = await redis.incr(clave);
    await redis.expire(
      clave,
      FraudeLoginService.VENTANA_FALLOS_IP_SEGUNDOS,
      'NX',
    );

    if (fallos >= FraudeLoginService.UMBRAL_FALLOS_IP) {
      await this.registrarAlerta(
        ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_IP,
        ip,
        null,
        {
          fallos,
          ventana_segundos: FraudeLoginService.VENTANA_FALLOS_IP_SEGUNDOS,
        },
      );
    }
  }

  private async revisarFuerzaBrutaCuenta(
    identificador: string,
    idUsuario: string | null,
  ): Promise<void> {
    const clave = `mesh:fraude:fallos_cuenta:${identificador}`;
    const fallos = await redis.incr(clave);
    await redis.expire(
      clave,
      FraudeLoginService.VENTANA_FALLOS_CUENTA_SEGUNDOS,
      'NX',
    );

    if (fallos >= FraudeLoginService.UMBRAL_FALLOS_CUENTA) {
      await this.registrarAlerta(
        ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_CUENTA,
        identificador,
        idUsuario,
        {
          fallos,
          ventana_segundos: FraudeLoginService.VENTANA_FALLOS_CUENTA_SEGUNDOS,
        },
      );
    }
  }

  private async revisarMultiCuentaIp(
    ip: string,
    identificador: string | null,
  ): Promise<void> {
    if (identificador == null) {
      return;
    }
    const clave = `mesh:fraude:cuentas_ip:${ip}`;
    await redis.sadd(clave, identificador);
    await redis.expire(
      clave,
      FraudeLoginService.VENTANA_MULTICUENTA_SEGUNDOS,
      'NX',
    );
    const cuentasDistintas = await redis.scard(clave);

    if (cuentasDistintas >= FraudeLoginService.UMBRAL_MULTICUENTA) {
      const identificadores = await redis.smembers(clave);
      await this.registrarAlerta(
        ID_TIPO_ALERTA_FRAUDE_MULTI_CUENTA_IP,
        ip,
        null,
        {
          cuentas_distintas: cuentasDistintas,
          ventana_segundos: FraudeLoginService.VENTANA_MULTICUENTA_SEGUNDOS,
          // Tope de 20: es evidencia para el admin, no un conteo -- ese ya
          // esta en cuentas_distintas. Sin tope, un ataque real de miles de
          // identificadores dejaria un jsonb enorme por nada.
          identificadores: identificadores.slice(0, 20),
        },
      );
    }
  }

  /**
   * El espejo invertido de `revisarMultiCuentaIp`: en vez de "cuantas
   * cuentas distintas probo esta IP", pregunta "desde cuantas IPs distintas
   * probaron esta cuenta". Mismo mecanismo -- `SADD` + `EXPIRE ... NX` +
   * `SCARD` -- con la clave de Redis armada al reves (por identificador, no
   * por IP). Igual que `revisarMultiCuentaIp`, corre sin importar si el
   * intento fallo o no: un intento exitoso cuenta igual para la rotacion
   * (el atacante puede acertar una vez en medio de la rotacion).
   */
  private async revisarIpRotacionCuenta(
    identificador: string | null,
    ip: string,
    idUsuario: string | null,
  ): Promise<void> {
    if (identificador == null) {
      return;
    }
    const clave = `mesh:fraude:ips_cuenta:${identificador}`;
    await redis.sadd(clave, ip);
    await redis.expire(
      clave,
      FraudeLoginService.VENTANA_ROTACION_IP_SEGUNDOS,
      'NX',
    );
    const ipsDistintas = await redis.scard(clave);

    if (ipsDistintas >= FraudeLoginService.UMBRAL_ROTACION_IP) {
      const ips = await redis.smembers(clave);
      await this.registrarAlerta(
        ID_TIPO_ALERTA_FRAUDE_IP_ROTACION_CUENTA,
        identificador,
        idUsuario,
        {
          ips_distintas: ipsDistintas,
          ventana_segundos: FraudeLoginService.VENTANA_ROTACION_IP_SEGUNDOS,
          // Mismo tope de 20 que multi_cuenta_ip: evidencia para el admin,
          // no el conteo (ese ya esta en ips_distintas).
          ips: ips.slice(0, 20),
        },
      );
    }
  }

  /**
   * `ventana_inicio` es el minuto truncado de AHORA -- varios cruces del
   * umbral dentro del mismo minuto suman `contador` en vez de duplicar (ver
   * `registrarAlertaFraude`, compartida con `TomaCuentaService` y
   * `FraudeLoginRetrospectivoService`).
   */
  private async registrarAlerta(
    idTipoAlerta: number,
    clave: string,
    idUsuario: string | null,
    detalle: Record<string, unknown>,
  ): Promise<void> {
    const ventanaInicio = new Date();
    ventanaInicio.setSeconds(0, 0);

    await registrarAlertaFraude({
      idTipoAlerta,
      clave,
      idUsuario,
      detalle,
      ventanaInicio,
    });
  }

  // ---------------------------------------------------------------------
  // Listado (lectura) -- GET /admin/fraude/alertas-login
  // ---------------------------------------------------------------------

  /**
   * La version paginada, por numero de pagina (`validarLimite`/`validarPagina`
   * de `helpers/validaciones-productos.ts`, mismas reglas y mensajes que el
   * resto del proyecto), con filtros opcionales por estado de revision y por
   * tipo de senal (necesario ahora que hay siete tipos mezclados en el mismo
   * listado). Sin los filtros devuelve todas, mas recientes primero.
   */
  async listarAlertasPaginado(
    query: PaginarAlertasFraudeQuery,
  ): Promise<AlertasFraudePaginadas> {
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const estado = validarFiltroEstadoAlerta(query.estado);
    const tipo = validarFiltroTipoAlerta(query.tipo);
    const saltar = (pagina - 1) * limite;

    const { filas, total } = await this.consultarAlertasPaginado(
      estado,
      tipo,
      limite,
      saltar,
    );
    const totalPaginas = total === 0 ? 0 : Math.ceil(total / limite);

    return {
      alertas: filas.map(aAlertaFraude),
      pagina,
      limite,
      total_alertas: total,
      total_paginas: totalPaginas,
    };
  }

  /**
   * Conteo + pagina en la misma transaccion REPEATABLE READ de solo
   * lectura, mismo patron que `consultarOfertasPendientesPaginado` de
   * `OfertasVendedorService`: con READ COMMITTED cada SELECT toma su
   * propio snapshot y el total podria no cuadrar con la pagina.
   *
   * `estado` y `tipo` ya vinieron validados contra sus listas cerradas
   * (`validarFiltroEstadoAlerta`/`validarFiltroTipoAlerta`), por eso se
   * interpolan tal cual -- mismo criterio que `condicionActivo` en
   * `OfertasVendedorService`.
   */
  private async consultarAlertasPaginado(
    estado: EstadoAlertaFraude | null,
    tipo: TipoAlertaFraude | null,
    limite: number,
    saltar: number,
  ): Promise<{ filas: FilaAlertaFraude[]; total: number }> {
    const condicionEstado =
      estado === null ? '' : `AND ea.estado_alerta_fraude_nombre = '${estado}'`;
    const condicionTipo =
      tipo === null ? '' : `AND ta.tipo_alerta_fraude_nombre = '${tipo}'`;

    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM alerta_fraude af
           JOIN tipo_alerta_fraude ta
             ON ta.id_tipo_alerta_fraude = af.id_tipo_alerta_fraude
           JOIN estado_alerta_fraude ea
             ON ea.id_estado_alerta_fraude = af.id_estado_alerta_fraude
          WHERE true ${condicionEstado} ${condicionTipo}`,
      );

      const pagina = await cliente.query<FilaAlertaFraude>(
        `SELECT af.id_alerta_fraude, ta.tipo_alerta_fraude_nombre AS tipo_alerta,
                af.clave, af.detalle, af.contador,
                af.ventana_inicio, ea.estado_alerta_fraude_nombre AS estado,
                af.fecha_creacion, af.fecha_actualizacion,
                ${SQL_CUENTAS_AFECTADAS} AS cuentas_afectadas
           FROM alerta_fraude af
           JOIN tipo_alerta_fraude ta
             ON ta.id_tipo_alerta_fraude = af.id_tipo_alerta_fraude
           JOIN estado_alerta_fraude ea
             ON ea.id_estado_alerta_fraude = af.id_estado_alerta_fraude
          WHERE true ${condicionEstado} ${condicionTipo}
          ORDER BY af.fecha_actualizacion DESC, af.id_alerta_fraude DESC
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

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo. No
      // hay nada mas que hacer; sigue el error original de quien llamo.
    }
  }

  // ---------------------------------------------------------------------
  // Listado y lectura del USUARIO -- GET/PATCH /perfil/alertas-fraude
  // ---------------------------------------------------------------------

  /**
   * Las alertas del usuario logueado sobre SU PROPIA cuenta -- nunca recibe
   * un id de cuenta por parametro, `idUsuario` siempre sale de la sesion
   * (`UsuarioActual` en el controlador). Ordenado por `fecha_creacion DESC`
   * (la senal mas nueva primero) y no por `fecha_actualizacion` -- esa es
   * la actividad de revision del admin, no algo que le importe al usuario.
   */
  async listarAlertasPaginadoUsuario(
    idUsuario: string,
    query: PaginarAlertasFraudeUsuarioQuery,
  ): Promise<AlertasFraudeUsuarioPaginadas> {
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const saltar = (pagina - 1) * limite;

    const { filas, total } = await this.consultarAlertasPaginadoUsuario(
      idUsuario,
      limite,
      saltar,
    );
    const totalPaginas = total === 0 ? 0 : Math.ceil(total / limite);

    return {
      alertas: filas.map(aAlertaFraudeUsuario),
      pagina,
      limite,
      total_alertas: total,
      total_paginas: totalPaginas,
    };
  }

  /** Mismo patron de transaccion REPEATABLE READ READ ONLY que `consultarAlertasPaginado`. */
  private async consultarAlertasPaginadoUsuario(
    idUsuario: string,
    limite: number,
    saltar: number,
  ): Promise<{ filas: FilaAlertaFraudeUsuario[]; total: number }> {
    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total FROM notificacion_fraude WHERE id_usuario = $1`,
        [idUsuario],
      );

      const pagina = await cliente.query<FilaAlertaFraudeUsuario>(
        `SELECT af.id_alerta_fraude, ta.tipo_alerta_fraude_nombre AS tipo_alerta,
                af.clave, af.detalle, af.contador, af.ventana_inicio,
                af.fecha_creacion, nf.fecha_lectura
           FROM notificacion_fraude nf
           JOIN alerta_fraude af ON af.id_alerta_fraude = nf.id_alerta_fraude
           JOIN tipo_alerta_fraude ta
             ON ta.id_tipo_alerta_fraude = af.id_tipo_alerta_fraude
          WHERE nf.id_usuario = $1
          ORDER BY af.fecha_creacion DESC, af.id_alerta_fraude DESC
          LIMIT $2 OFFSET $3`,
        [idUsuario, limite, saltar],
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
   * Marca una alerta del usuario como leida -- idempotente (solo escribe si
   * todavia estaba `NULL`, no pisa la fecha de la primera lectura) y con el
   * ownership check en el propio `UPDATE`: si la alerta no existe O es de
   * otra cuenta, el mismo 404 generico en los dos casos (no se distingue,
   * para no filtrar si una alerta ajena existe -- mismo criterio que las
   * rutas de vendedor sobre ofertas ajenas).
   */
  async marcarLeida(
    idAlertaFraude: string,
    idUsuario: string,
  ): Promise<AlertaFraudeUsuario> {
    const id = validarIdAlertaFraude(idAlertaFraude);

    let actualizado;
    try {
      actualizado = await pool.query(
        `UPDATE notificacion_fraude
            SET fecha_lectura = COALESCE(fecha_lectura, now())
          WHERE id_alerta_fraude = $1 AND id_usuario = $2
          RETURNING id_notificacion`,
        [id, idUsuario],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (actualizado.rowCount === 0) {
      throw new ErrorNoEncontrado(
        'No existe una alerta con ese id para tu cuenta',
      );
    }

    return this.obtenerAlertaUsuarioPorId(id, idUsuario);
  }

  private async obtenerAlertaUsuarioPorId(
    id: string,
    idUsuario: string,
  ): Promise<AlertaFraudeUsuario> {
    let fila;
    try {
      fila = await pool.query<FilaAlertaFraudeUsuario>(
        `SELECT af.id_alerta_fraude, ta.tipo_alerta_fraude_nombre AS tipo_alerta,
                af.clave, af.detalle, af.contador, af.ventana_inicio,
                af.fecha_creacion, nf.fecha_lectura
           FROM notificacion_fraude nf
           JOIN alerta_fraude af ON af.id_alerta_fraude = nf.id_alerta_fraude
           JOIN tipo_alerta_fraude ta
             ON ta.id_tipo_alerta_fraude = af.id_tipo_alerta_fraude
          WHERE af.id_alerta_fraude = $1 AND nf.id_usuario = $2`,
        [id, idUsuario],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    return aAlertaFraudeUsuario(fila.rows[0]);
  }
}

function aAlertaFraude(fila: FilaAlertaFraude): AlertaFraude {
  return {
    id_alerta_fraude: fila.id_alerta_fraude,
    tipo_alerta: fila.tipo_alerta,
    clave: fila.clave,
    cuentas_afectadas: fila.cuentas_afectadas,
    detalle: fila.detalle,
    contador: fila.contador,
    ventana_inicio: fila.ventana_inicio,
    estado: fila.estado,
    fecha_creacion: fila.fecha_creacion,
    fecha_actualizacion: fila.fecha_actualizacion,
  };
}

/**
 * Las dos senales cuyo `detalle` trae los identificadores de OTRAS cuentas
 * afectadas por el mismo ataque (evidencia para admin) -- ver
 * `detalleParaUsuario` justo abajo.
 */
const TIPOS_DETALLE_MULTIUSUARIO: TipoAlertaFraude[] = [
  'multi_cuenta_ip',
  'multi_cuenta_ip_lenta',
];

/**
 * El `detalle` tal como lo ve el USUARIO afectado, no el admin: para
 * `multi_cuenta_ip`/`multi_cuenta_ip_lenta` se quita `identificadores` --
 * la lista de correos/usuarios de las DEMAS cuentas que esa misma IP
 * tambien probo. `cuentas_distintas` (el conteo) se conserva -- el usuario
 * sabe que no fue el unico blanco, sin enterarse de quienes fueron los
 * demas. Decision explicita del usuario (2026-09-15): version resumida,
 * no el detalle completo que ve admin.
 */
function detalleParaUsuario(
  tipoAlerta: TipoAlertaFraude,
  detalle: Record<string, unknown>,
): Record<string, unknown> {
  if (!TIPOS_DETALLE_MULTIUSUARIO.includes(tipoAlerta)) {
    return detalle;
  }
  const resto = { ...detalle };
  delete resto.identificadores;
  return resto;
}

/** Una fila del listado del USUARIO, tal como la trae `pool.query` -- sin nada de la investigacion del admin (`estado`, ni el resto de afectados). */
interface FilaAlertaFraudeUsuario {
  id_alerta_fraude: string;
  tipo_alerta: TipoAlertaFraude;
  clave: string;
  detalle: Record<string, unknown>;
  contador: number;
  ventana_inicio: Date;
  fecha_creacion: Date;
  fecha_lectura: Date | null;
}

function aAlertaFraudeUsuario(
  fila: FilaAlertaFraudeUsuario,
): AlertaFraudeUsuario {
  return {
    id_alerta_fraude: fila.id_alerta_fraude,
    tipo_alerta: fila.tipo_alerta,
    clave: fila.clave,
    detalle: detalleParaUsuario(fila.tipo_alerta, fila.detalle),
    contador: fila.contador,
    ventana_inicio: fila.ventana_inicio,
    fecha_creacion: fila.fecha_creacion,
    fecha_lectura: fila.fecha_lectura,
  };
}

/** Un mensaje de error corto para el log (mismo helper que EventosAutenticacionSyncService). */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
