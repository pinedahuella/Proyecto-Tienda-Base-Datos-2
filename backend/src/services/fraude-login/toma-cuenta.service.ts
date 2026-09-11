import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { registrarAlertaFraude } from '../../helpers/registrar-alerta-fraude';
import { ID_TIPO_ALERTA_FRAUDE_TOMA_CUENTA } from '../../models/alerta-fraude';

const INDICE =
  process.env.ELASTIC_INDICE_EVENTOS ?? 'mesh_eventos_autenticacion';

/**
 * Toma de cuenta: IP nueva para una cuenta, comparada contra TODO su
 * historial -- justo lo que los contadores de Redis de `FraudeLoginService`
 * (ventanas de 1-5 min) no pueden ver. Punto 3 de
 * `elementos Generales/plan pendiente/fraude-login-eventos.md`.
 *
 * A diferencia de `FraudeLoginRetrospectivoService` (worker periodico sobre
 * una ventana de 24h), esto es un chequeo puntual de UNA cuenta: encaja
 * mejor en el mismo punto donde ya se llama
 * `fraudeLoginService.registrarIntento` -- `UsuarioController.iniciarSesion`,
 * SIN `await`, solo en login EXITOSO (un login fallido no revela nada sobre
 * quien es realmente el dueno de la cuenta). Nunca lanza: si Elasticsearch
 * no responde, se pierde esta senal en concreto, el login ya se resolvio.
 */
@Injectable()
export class TomaCuentaService {
  private readonly logger = new Logger(TomaCuentaService.name);

  /**
   * Cuantos logins exitosos previos necesita tener la cuenta antes de
   * evaluar nada -- sin esto, el primer login de una cuenta nueva siempre
   * tendria "IP nueva" (nunca tuvo ninguna) y se marcaria como sospechoso
   * sin serlo.
   */
  private static readonly MINIMO_HISTORIAL = 3;

  /** Cuantas IPs/huellas distintas se traen para comparar -- de sobra para el tamano de este proyecto. */
  private static readonly TAMANO_AGREGACION = 1000;

  async revisarLogin(datos: {
    idUsuario: string;
    identificador: string | null;
    ip: string | null;
    huellaCliente: string | null;
  }): Promise<void> {
    if (datos.ip == null || datos.identificador == null) {
      // Sin IP no hay contra que comparar; sin identificador no hay `clave`
      // para la alerta (mismo criterio que fuerza_bruta_cuenta en Redis).
      return;
    }

    try {
      const respuesta = await elasticClient.search<
        unknown,
        {
          ips_conocidas: { buckets: { key: string }[] };
          huellas_conocidas: { buckets: { key: string }[] };
        }
      >({
        index: INDICE,
        size: 0,
        query: {
          bool: {
            filter: [
              { term: { 'id_usuario.keyword': datos.idUsuario } },
              { term: { 'tipo.keyword': 'login' } },
              { term: { 'resultado.keyword': 'exito' } },
            ],
          },
        },
        aggs: {
          ips_conocidas: {
            terms: {
              field: 'ip.keyword',
              size: TomaCuentaService.TAMANO_AGREGACION,
            },
          },
          huellas_conocidas: {
            terms: {
              field: 'huella_cliente.keyword',
              size: TomaCuentaService.TAMANO_AGREGACION,
            },
          },
        },
      });

      const totalHistorial =
        typeof respuesta.hits.total === 'number'
          ? respuesta.hits.total
          : (respuesta.hits.total?.value ?? 0);

      if (totalHistorial < TomaCuentaService.MINIMO_HISTORIAL) {
        return;
      }

      const ipsConocidas = new Set(
        (respuesta.aggregations?.ips_conocidas.buckets ?? []).map((b) => b.key),
      );
      if (ipsConocidas.has(datos.ip)) {
        return;
      }

      const huellasConocidas = new Set(
        (respuesta.aggregations?.huellas_conocidas.buckets ?? []).map(
          (b) => b.key,
        ),
      );
      const huellaNueva =
        datos.huellaCliente != null &&
        !huellasConocidas.has(datos.huellaCliente);

      const ventanaInicio = new Date();
      ventanaInicio.setSeconds(0, 0);

      await registrarAlertaFraude({
        idTipoAlerta: ID_TIPO_ALERTA_FRAUDE_TOMA_CUENTA,
        clave: datos.identificador,
        idUsuario: datos.idUsuario,
        detalle: {
          ip_nueva: datos.ip,
          ips_conocidas: ipsConocidas.size,
          huella_nueva: huellaNueva,
          logins_exitosos_previos: totalHistorial,
        },
        ventanaInicio,
      });
    } catch (error) {
      this.logger.warn(
        `deteccion de toma de cuenta interrumpida: ${mensajeCorto(error)}`,
      );
    }
  }
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
