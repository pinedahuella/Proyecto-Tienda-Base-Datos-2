import { Injectable, Logger } from '@nestjs/common';
import nodemailer from 'nodemailer';
import { ErrorConexion, ErrorValidacion } from '../../helpers/errores';

/**
 * Manda el dashboard exportado por correo, como adjunto. El servidor de correo
 * sale de backend/.env y no tiene valores por defecto, para que ninguna
 * contrasena quede en el repositorio:
 *
 *   SMTP_HOST=smtp.gmail.com
 *   SMTP_PORT=587
 *   SMTP_USUARIO=cuenta@gmail.com
 *   SMTP_CONTRASENA=la contrasena de aplicacion
 *   SMTP_REMITENTE=Mesh <cuenta@gmail.com>     (opcional, si no el usuario)
 *
 * Sin SMTP_HOST la ruta contesta 503 diciendo que falta, y el resto del
 * dashboard (Excel y PDF para descargar) sigue igual.
 */

const CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAXIMO_CORREOS = 10;

@Injectable()
export class DashboardCorreoService {
  private readonly logger = new Logger(DashboardCorreoService.name);

  /** Los correos validos y sin repetir, o un error que dice cual no sirve. */
  limpiarCorreos(correos: unknown): string[] {
    if (!Array.isArray(correos)) {
      throw new ErrorValidacion('correos tiene que ser una lista');
    }
    const lista = [
      ...new Set(
        correos
          .map((c) => String(c).trim().toLowerCase())
          .filter((c) => c !== ''),
      ),
    ];
    if (lista.length === 0) {
      throw new ErrorValidacion('Pon al menos un correo');
    }
    if (lista.length > MAXIMO_CORREOS) {
      throw new ErrorValidacion(`Hasta ${MAXIMO_CORREOS} correos a la vez`);
    }
    const malos = lista.filter((c) => !CORREO.test(c) || c.length > 254);
    if (malos.length > 0) {
      throw new ErrorValidacion(
        `Estos correos no son validos: ${malos.join(', ')}`,
      );
    }
    return lista;
  }

  async enviar(datos: {
    correos: string[];
    asunto: string;
    html: string;
    adjunto: Buffer;
    nombreAdjunto: string;
    tipo: string;
  }): Promise<void> {
    // Se acepta tambien "host:puerto", como lo guarda el .env de LEDKID.
    const [host, puertoDelHost] = (process.env.SMTP_HOST?.trim() ?? '').split(
      ':',
    );
    if (!host) {
      throw new ErrorConexion(
        'El correo no esta configurado: falta SMTP_HOST en backend/.env',
      );
    }
    const puerto = Number(process.env.SMTP_PORT ?? puertoDelHost ?? 587);
    const usuario = process.env.SMTP_USUARIO?.trim();
    const transporte = nodemailer.createTransport({
      host,
      port: puerto,
      secure: puerto === 465,
      auth: usuario
        ? { user: usuario, pass: process.env.SMTP_CONTRASENA ?? '' }
        : undefined,
      connectionTimeout: 10_000,
      greetingTimeout: 10_000,
      socketTimeout: 30_000,
    });
    try {
      await transporte.sendMail({
        from: process.env.SMTP_REMITENTE?.trim() || usuario || `mesh@${host}`,
        to: datos.correos,
        subject: datos.asunto,
        html: datos.html,
        attachments: [
          {
            filename: datos.nombreAdjunto,
            content: datos.adjunto,
            contentType: datos.tipo,
          },
        ],
      });
    } catch (error) {
      this.logger.error(
        `No se pudo mandar el dashboard: ${error instanceof Error ? error.message : String(error)}`,
      );
      throw new ErrorConexion(
        'No se pudo mandar el correo, el servidor de correo no respondio',
      );
    } finally {
      transporte.close();
    }
  }
}
