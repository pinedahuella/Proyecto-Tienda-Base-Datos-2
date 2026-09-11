import { Injectable, Logger } from '@nestjs/common';
import { mongoDb } from '../database/mongo';
import type { ContextoPeticion } from '../helpers/contexto-peticion';
import type {
  EventoAutenticacion,
  MotivoFalloAutenticacion,
  ResultadoAutenticacion,
  TipoEventoAutenticacion,
} from '../models/evento-autenticacion';

const COLECCION = 'eventos_autenticacion';

/**
 * Escribe el log de seguridad de entradas al sistema en la coleccion
 * `eventos_autenticacion` de MongoDB: cada registro, login (exitoso o
 * fallido) y logout.
 *
 * Sustituye a las tablas `log_login` / `log_registro` de PostgreSQL, que
 * siguen existiendo pero ya no se escriben desde el backend (ver
 * `cambio_propuestas/2026-09-10_eventos-autenticacion-mongo.md`). El ETL de
 * ClickHouse que leia esas tablas queda pendiente de repuntar a Mongo -- lo
 * coordina el equipo, no es de `backend/`.
 *
 * A proposito nunca lanza: guardar el log es un efecto secundario de un
 * registro/login/logout que ya se resolvio (con exito, o con un 401 ya
 * decidido). Si Mongo no responde, el detalle queda en el log del servidor
 * y la peticion sigue igual. Por eso el controlador la llama SIN `await`:
 * con Mongo caido, `insertOne` tarda hasta 3 s en rendirse
 * (`serverSelectionTimeoutMS`, ver `database/mongo.ts`) y el login no tiene
 * por que esperar eso.
 */
@Injectable()
export class LogService {
  private readonly logger = new Logger(LogService.name);

  /** Registro de cuenta nueva exitoso. La llama `UsuarioController`. */
  async registrarRegistro(
    idUsuario: string,
    correoElectronico: string | null,
    contexto: ContextoPeticion,
  ): Promise<void> {
    await this.guardar({
      tipo: 'registro',
      resultado: 'exito',
      motivo: null,
      idUsuario,
      identificadorIntentado: correoElectronico,
      contexto,
    });
  }

  /** Un login que entro. */
  async registrarLoginExitoso(
    idUsuario: string,
    identificadorIntentado: string | null,
    contexto: ContextoPeticion,
  ): Promise<void> {
    await this.guardar({
      tipo: 'login',
      resultado: 'exito',
      motivo: null,
      idUsuario,
      identificadorIntentado,
      contexto,
    });
  }

  /**
   * Un login rechazado. `idUsuario` es `null` salvo que la cuenta exista
   * (contrasena incorrecta o cuenta inactiva), donde si se conoce.
   */
  async registrarLoginFallido(
    motivo: MotivoFalloAutenticacion,
    idUsuario: string | null,
    identificadorIntentado: string | null,
    contexto: ContextoPeticion,
  ): Promise<void> {
    await this.guardar({
      tipo: 'login',
      resultado: 'fallo',
      motivo,
      idUsuario,
      identificadorIntentado,
      contexto,
    });
  }

  /**
   * Un logout. Solo se llama cuando el token todavia identificaba a alguien
   * (si ya habia vencido o no habia cookie, no hay a quien atribuirlo y no
   * se guarda nada; cerrar sesion sigue funcionando igual).
   */
  async registrarLogout(
    idUsuario: string,
    contexto: ContextoPeticion,
  ): Promise<void> {
    await this.guardar({
      tipo: 'logout',
      resultado: 'exito',
      motivo: null,
      idUsuario,
      identificadorIntentado: null,
      contexto,
    });
  }

  private async guardar(datos: {
    tipo: TipoEventoAutenticacion;
    resultado: ResultadoAutenticacion;
    motivo: MotivoFalloAutenticacion | null;
    idUsuario: string | null;
    identificadorIntentado: string | null;
    contexto: ContextoPeticion;
  }): Promise<void> {
    const evento: EventoAutenticacion = {
      tipo: datos.tipo,
      resultado: datos.resultado,
      motivo: datos.motivo,
      id_usuario: datos.idUsuario,
      identificador_intentado: datos.identificadorIntentado,
      ip: datos.contexto.ip,
      user_agent: datos.contexto.userAgent,
      huella_cliente: datos.contexto.huellaCliente,
      geo: datos.contexto.geo,
      fecha: new Date(),
      // Nace pendiente de indexar en Elasticsearch; el worker
      // (EventosAutenticacionSyncService) le quita la bandera al sincronizarlo.
      pendiente_elastic: true,
    };

    try {
      await mongoDb
        .collection<EventoAutenticacion>(COLECCION)
        .insertOne(evento);
    } catch (error) {
      this.logger.error(
        `No se pudo guardar el evento de autenticacion (${datos.tipo}/${datos.resultado}): ${error}`,
      );
    }
  }
}
