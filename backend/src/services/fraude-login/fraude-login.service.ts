import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { redis } from '../../database/redis';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { validarFiltroEstadoAlerta } from '../../helpers/validaciones-fraude';
import {
  validarLimite,
  validarPagina,
} from '../../helpers/validaciones-productos';
import type {
  AlertasFraudePaginadas,
  PaginarAlertasFraudeQuery,
} from '../../dto/paginar-alertas-fraude';
import {
  AlertaFraude,
  EstadoAlertaFraude,
  FilaAlertaFraude,
  ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
  ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_CUENTA,
  ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_IP,
  ID_TIPO_ALERTA_FRAUDE_MULTI_CUENTA_IP,
} from '../../models/alerta-fraude';

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
 * Tres senales, las unicas que no necesitan geolocalizacion (punto 2 del
 * plan, todavia sin decidir) ni una consulta retrospectiva:
 *
 *   fuerza_bruta_ip       muchos fallos desde una misma IP en poco tiempo.
 *   fuerza_bruta_cuenta   muchos fallos contra un mismo identificador.
 *   multi_cuenta_ip       muchos identificadores distintos probados desde
 *                         la misma IP (credential stuffing).
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
   * El UPSERT que deja (o engorda) la fila de `alerta_fraude`. La llave de
   * conflicto es (tipo, clave, ventana_inicio) -- ventana_inicio es el
   * minuto truncado de AHORA, asi que varios cruces del umbral dentro del
   * mismo minuto suman `contador` en una sola fila en vez de duplicar; si
   * el ataque sigue al minuto siguiente, nace una fila nueva a proposito
   * (ver el comentario de la columna en el `.sql` de referencia).
   *
   * NO pisa `id_estado_alerta_fraude` en el conflicto: si un admin ya la
   * marco revisada/descartada dentro de ese mismo minuto (improbable, pero
   * posible), un cruce mas del umbral no debe reabrirla sola.
   */
  private async registrarAlerta(
    idTipoAlerta: number,
    clave: string,
    idUsuario: string | null,
    detalle: Record<string, unknown>,
  ): Promise<void> {
    const ventanaInicio = new Date();
    ventanaInicio.setSeconds(0, 0);

    await pool.query(
      `INSERT INTO alerta_fraude
         (id_tipo_alerta_fraude, clave, id_usuario, detalle, ventana_inicio,
          id_estado_alerta_fraude)
       VALUES ($1, $2, $3, $4::jsonb, $5, $6)
       ON CONFLICT (id_tipo_alerta_fraude, clave, ventana_inicio)
       DO UPDATE SET
         contador = alerta_fraude.contador + 1,
         detalle = $4::jsonb,
         fecha_actualizacion = now()`,
      [
        idTipoAlerta,
        clave,
        idUsuario,
        JSON.stringify(detalle),
        ventanaInicio,
        ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Listado (lectura) -- GET /admin/fraude/alertas-login
  // ---------------------------------------------------------------------

  /**
   * La version paginada, por numero de pagina (`validarLimite`/`validarPagina`
   * de `helpers/validaciones-productos.ts`, mismas reglas y mensajes que el
   * resto del proyecto), con un filtro opcional por estado de revision. Sin
   * el filtro devuelve todas, mas recientes primero.
   */
  async listarAlertasPaginado(
    query: PaginarAlertasFraudeQuery,
  ): Promise<AlertasFraudePaginadas> {
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const estado = validarFiltroEstadoAlerta(query.estado);
    const saltar = (pagina - 1) * limite;

    const { filas, total } = await this.consultarAlertasPaginado(
      estado,
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
   * `estado` ya vino validado contra las tres unicas cadenas posibles
   * (`validarFiltroEstadoAlerta`), por eso se interpola tal cual -- mismo
   * criterio que `condicionActivo` en `OfertasVendedorService`.
   */
  private async consultarAlertasPaginado(
    estado: EstadoAlertaFraude | null,
    limite: number,
    saltar: number,
  ): Promise<{ filas: FilaAlertaFraude[]; total: number }> {
    const condicionEstado =
      estado === null ? '' : `AND ea.estado_alerta_fraude_nombre = '${estado}'`;

    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM alerta_fraude af
           JOIN estado_alerta_fraude ea
             ON ea.id_estado_alerta_fraude = af.id_estado_alerta_fraude
          WHERE true ${condicionEstado}`,
      );

      const pagina = await cliente.query<FilaAlertaFraude>(
        `SELECT af.id_alerta_fraude, ta.tipo_alerta_fraude_nombre AS tipo_alerta,
                af.clave, af.id_usuario, u.usuario, af.detalle, af.contador,
                af.ventana_inicio, ea.estado_alerta_fraude_nombre AS estado,
                af.fecha_creacion, af.fecha_actualizacion
           FROM alerta_fraude af
           JOIN tipo_alerta_fraude ta
             ON ta.id_tipo_alerta_fraude = af.id_tipo_alerta_fraude
           JOIN estado_alerta_fraude ea
             ON ea.id_estado_alerta_fraude = af.id_estado_alerta_fraude
           LEFT JOIN usuarios u ON u.id_usuario = af.id_usuario
          WHERE true ${condicionEstado}
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
}

function aAlertaFraude(fila: FilaAlertaFraude): AlertaFraude {
  return {
    id_alerta_fraude: fila.id_alerta_fraude,
    tipo_alerta: fila.tipo_alerta,
    clave: fila.clave,
    cuenta_involucrada:
      fila.id_usuario != null && fila.usuario != null
        ? { id_usuario: fila.id_usuario, usuario: fila.usuario }
        : null,
    detalle: fila.detalle,
    contador: fila.contador,
    ventana_inicio: fila.ventana_inicio,
    estado: fila.estado,
    fecha_creacion: fila.fecha_creacion,
    fecha_actualizacion: fila.fecha_actualizacion,
  };
}

/** Un mensaje de error corto para el log (mismo helper que EventosAutenticacionSyncService). */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
