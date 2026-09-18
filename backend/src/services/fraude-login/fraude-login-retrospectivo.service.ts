import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { elasticClient } from '../../database/elastic';
import { registrarAlertaFraude } from '../../helpers/registrar-alerta-fraude';
import {
  ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_CUENTA_LENTA,
  ID_TIPO_ALERTA_FRAUDE_IP_ROTACION_CUENTA_LENTA,
  ID_TIPO_ALERTA_FRAUDE_MULTI_CUENTA_IP_LENTA,
} from '../../models/alerta-fraude';

const INDICE =
  process.env.ELASTIC_INDICE_EVENTOS ?? 'mesh_eventos_autenticacion';

interface BucketConMuestra {
  key: string;
  doc_count: number;
  cardinalidad?: { value: number };
  muestra?: { buckets: { key: string }[] };
  id_usuario_visto?: { buckets: { key: string }[] };
}

/**
 * Patrones lentos/repartidos -- punto 3 de
 * `elementos Generales/plan pendiente/fraude-login-eventos.md`. Lo que
 * ningun contador de Redis (ventanas de 1-5 min) puede ver: un ataque
 * repartido en horas para no cruzar un umbral corto.
 *
 * Worker `@Interval`, mismo molde que `EventosAutenticacionSyncService` /
 * `GrafoSyncService`: corre cada `INTERVALO_MS`, un flag `procesando` evita
 * que se solape con la corrida anterior, y un error interrumpe la corrida
 * sin tumbar el proceso.
 *
 * En cada corrida se re-evaluan las ULTIMAS 24 HORAS completas -- no solo
 * eventos nuevos desde la corrida anterior -- porque el patron depende de
 * acumulacion en el tiempo, no de un evento aislado. El worker no decide a
 * quien mirar: cada agregacion de Elasticsearch devuelve YA FILTRADA la
 * lista de sospechosos (via `min_doc_count` y `bucket_selector`), el worker
 * solo convierte cada bucket que vuelve en una fila de `alerta_fraude`.
 *
 * `ventana_inicio` se trunca a la HORA (no al minuto, como Redis): con un
 * intervalo de 15 min, truncar al minuto crearia una fila nueva casi en
 * cada corrida mientras el patron siga activo. Truncar a la hora da una
 * alerta por hora persistente sin perder la reaparicion si el ataque sigue
 * horas despues.
 *
 * Ademas del worker de 15 min, expone `evaluarInmediato()`: la llama
 * `UsuarioController` justo despues de cada login (ya con el evento
 * sincronizado en Elasticsearch via
 * `EventosAutenticacionSyncService.sincronizarAhora()`), y corre una
 * version ACOTADA de las mismas tres senales -- filtrada a la cuenta y/o
 * la IP de ESE login, no a las 24h completas de todas las cuentas. Mismo
 * `idTipoAlerta` y misma hora truncada que la version de abajo: si el
 * disparo inmediato y el worker de 15 min coinciden en la misma hora, se
 * juntan en una sola fila via el `ON CONFLICT` de `registrarAlertaFraude`
 * en vez de duplicar -- es la misma senal, detectada mas rapido, no una
 * distinta. El worker de 15 min sigue de respaldo tal cual (cubre lo que
 * el disparo inmediato se pierda: una corrida concurrente saltada, Elastic
 * caido en ese instante).
 */
@Injectable()
export class FraudeLoginRetrospectivoService {
  private readonly logger = new Logger(FraudeLoginRetrospectivoService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;
  private static readonly VENTANA_ELASTIC = 'now-24h';

  // Umbrales propuestos, no medidos contra datos reales -- ajustables.
  private static readonly UMBRAL_FUERZA_BRUTA_CUENTA_LENTA = 15;
  private static readonly UMBRAL_MULTICUENTA_IP_LENTA = 8;
  private static readonly UMBRAL_IP_ROTACION_CUENTA = 5;

  private static readonly TAMANO_BUCKETS = 1000;
  private static readonly TAMANO_MUESTRA = 20;

  private procesando = false;

  @Interval(
    'fraude-login-retrospectivo',
    FraudeLoginRetrospectivoService.INTERVALO_MS,
  )
  async evaluar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      await Promise.all([
        this.evaluarFuerzaBrutaCuentaLenta(),
        this.evaluarMultiCuentaIpLenta(),
        this.evaluarIpRotacionCuenta(),
      ]);
    } catch (error) {
      this.logger.warn(
        `worker de patrones lentos interrumpido: ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /** Muchos fallos contra UNA cuenta, repartidos en 24h (no en 60s como Redis). */
  private async evaluarFuerzaBrutaCuentaLenta(): Promise<void> {
    const respuesta = await elasticClient.search<
      unknown,
      { por_cuenta: { buckets: BucketConMuestra[] } }
    >({
      index: INDICE,
      size: 0,
      query: {
        bool: {
          filter: [
            { term: { 'tipo.keyword': 'login' } },
            { term: { 'resultado.keyword': 'fallo' } },
            {
              range: {
                fecha: { gte: FraudeLoginRetrospectivoService.VENTANA_ELASTIC },
              },
            },
          ],
        },
      },
      aggs: {
        por_cuenta: {
          terms: {
            field: 'identificador_intentado.keyword',
            min_doc_count:
              FraudeLoginRetrospectivoService.UMBRAL_FUERZA_BRUTA_CUENTA_LENTA,
            size: FraudeLoginRetrospectivoService.TAMANO_BUCKETS,
          },
          aggs: {
            id_usuario_visto: {
              terms: { field: 'id_usuario.keyword', size: 1 },
            },
          },
        },
      },
    });

    const ventanaInicio = horaTruncada();
    for (const bucket of respuesta.aggregations?.por_cuenta.buckets ?? []) {
      await registrarAlertaFraude({
        idTipoAlerta: ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_CUENTA_LENTA,
        clave: bucket.key,
        idUsuario: bucket.id_usuario_visto?.buckets[0]?.key ?? null,
        detalle: {
          fallos: bucket.doc_count,
          ventana_horas: 24,
        },
        ventanaInicio,
      });
    }
  }

  /** Muchas cuentas distintas probadas desde la misma IP, repartidas en 24h. */
  private async evaluarMultiCuentaIpLenta(): Promise<void> {
    const respuesta = await elasticClient.search<
      unknown,
      { por_ip: { buckets: BucketConMuestra[] } }
    >({
      index: INDICE,
      size: 0,
      query: {
        bool: {
          filter: [
            { term: { 'tipo.keyword': 'login' } },
            {
              range: {
                fecha: { gte: FraudeLoginRetrospectivoService.VENTANA_ELASTIC },
              },
            },
          ],
        },
      },
      aggs: {
        por_ip: {
          terms: {
            field: 'ip.keyword',
            min_doc_count:
              FraudeLoginRetrospectivoService.UMBRAL_MULTICUENTA_IP_LENTA,
            size: FraudeLoginRetrospectivoService.TAMANO_BUCKETS,
          },
          aggs: {
            cardinalidad: {
              cardinality: { field: 'identificador_intentado.keyword' },
            },
            muestra: {
              terms: {
                field: 'identificador_intentado.keyword',
                size: FraudeLoginRetrospectivoService.TAMANO_MUESTRA,
              },
            },
            filtro_umbral: {
              bucket_selector: {
                buckets_path: { cuentas: 'cardinalidad' },
                script: `params.cuentas >= ${FraudeLoginRetrospectivoService.UMBRAL_MULTICUENTA_IP_LENTA}`,
              },
            },
          },
        },
      },
    });

    const ventanaInicio = horaTruncada();
    for (const bucket of respuesta.aggregations?.por_ip.buckets ?? []) {
      await registrarAlertaFraude({
        idTipoAlerta: ID_TIPO_ALERTA_FRAUDE_MULTI_CUENTA_IP_LENTA,
        clave: bucket.key,
        idUsuario: null, // el origen es la IP, no una cuenta -- mismo criterio que multi_cuenta_ip en Redis
        detalle: {
          cuentas_distintas: bucket.cardinalidad?.value ?? 0,
          ventana_horas: 24,
          identificadores: (bucket.muestra?.buckets ?? []).map((b) => b.key),
        },
        ventanaInicio,
      });
    }
  }

  /** Una misma cuenta probada desde muchas IPs distintas, repartidas en 24h. */
  private async evaluarIpRotacionCuenta(): Promise<void> {
    const respuesta = await elasticClient.search<
      unknown,
      { por_cuenta: { buckets: BucketConMuestra[] } }
    >({
      index: INDICE,
      size: 0,
      query: {
        bool: {
          filter: [
            { term: { 'tipo.keyword': 'login' } },
            {
              range: {
                fecha: { gte: FraudeLoginRetrospectivoService.VENTANA_ELASTIC },
              },
            },
          ],
        },
      },
      aggs: {
        por_cuenta: {
          terms: {
            field: 'identificador_intentado.keyword',
            min_doc_count:
              FraudeLoginRetrospectivoService.UMBRAL_IP_ROTACION_CUENTA,
            size: FraudeLoginRetrospectivoService.TAMANO_BUCKETS,
          },
          aggs: {
            cardinalidad: { cardinality: { field: 'ip.keyword' } },
            muestra: {
              terms: {
                field: 'ip.keyword',
                size: FraudeLoginRetrospectivoService.TAMANO_MUESTRA,
              },
            },
            id_usuario_visto: {
              terms: { field: 'id_usuario.keyword', size: 1 },
            },
            filtro_umbral: {
              bucket_selector: {
                buckets_path: { ips: 'cardinalidad' },
                script: `params.ips >= ${FraudeLoginRetrospectivoService.UMBRAL_IP_ROTACION_CUENTA}`,
              },
            },
          },
        },
      },
    });

    const ventanaInicio = horaTruncada();
    for (const bucket of respuesta.aggregations?.por_cuenta.buckets ?? []) {
      await registrarAlertaFraude({
        idTipoAlerta: ID_TIPO_ALERTA_FRAUDE_IP_ROTACION_CUENTA_LENTA,
        clave: bucket.key,
        idUsuario: bucket.id_usuario_visto?.buckets[0]?.key ?? null,
        detalle: {
          ips_distintas: bucket.cardinalidad?.value ?? 0,
          ventana_horas: 24,
          ips: (bucket.muestra?.buckets ?? []).map((b) => b.key),
        },
        ventanaInicio,
      });
    }
  }

  // ---------------------------------------------------------------------
  // Version acotada -- un solo login, no las 24h de todas las cuentas.
  // Mismos umbrales y mismo tipo de alerta que los tres metodos de arriba,
  // ver el comentario de clase.
  // ---------------------------------------------------------------------

  /** Entrada unica para `UsuarioController`: los tres chequeos acotados a UN login. */
  async evaluarInmediato(datos: {
    identificador: string | null;
    ip: string | null;
    idUsuario: string | null;
  }): Promise<void> {
    try {
      await Promise.all([
        datos.identificador != null
          ? this.evaluarFuerzaBrutaCuentaLentaAcotado(
              datos.identificador,
              datos.idUsuario,
            )
          : Promise.resolve(),
        datos.ip != null
          ? this.evaluarMultiCuentaIpLentaAcotado(datos.ip)
          : Promise.resolve(),
        datos.identificador != null
          ? this.evaluarIpRotacionCuentaAcotado(
              datos.identificador,
              datos.idUsuario,
            )
          : Promise.resolve(),
      ]);
    } catch (error) {
      this.logger.warn(
        `chequeo acotado de patrones lentos interrumpido: ${mensajeCorto(error)}`,
      );
    }
  }

  private async evaluarFuerzaBrutaCuentaLentaAcotado(
    identificador: string,
    idUsuario: string | null,
  ): Promise<void> {
    const { count } = await elasticClient.count({
      index: INDICE,
      query: {
        bool: {
          filter: [
            { term: { 'tipo.keyword': 'login' } },
            { term: { 'resultado.keyword': 'fallo' } },
            { term: { 'identificador_intentado.keyword': identificador } },
            {
              range: {
                fecha: { gte: FraudeLoginRetrospectivoService.VENTANA_ELASTIC },
              },
            },
          ],
        },
      },
    });

    if (
      count >= FraudeLoginRetrospectivoService.UMBRAL_FUERZA_BRUTA_CUENTA_LENTA
    ) {
      await registrarAlertaFraude({
        idTipoAlerta: ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_CUENTA_LENTA,
        clave: identificador,
        idUsuario,
        detalle: { fallos: count, ventana_horas: 24 },
        ventanaInicio: horaTruncada(),
      });
    }
  }

  private async evaluarMultiCuentaIpLentaAcotado(ip: string): Promise<void> {
    const respuesta = await elasticClient.search<
      unknown,
      { cardinalidad: { value: number }; muestra: BucketDeMuestra }
    >({
      index: INDICE,
      size: 0,
      query: {
        bool: {
          filter: [
            { term: { 'tipo.keyword': 'login' } },
            { term: { 'ip.keyword': ip } },
            {
              range: {
                fecha: { gte: FraudeLoginRetrospectivoService.VENTANA_ELASTIC },
              },
            },
          ],
        },
      },
      aggs: {
        cardinalidad: {
          cardinality: { field: 'identificador_intentado.keyword' },
        },
        muestra: {
          terms: {
            field: 'identificador_intentado.keyword',
            size: FraudeLoginRetrospectivoService.TAMANO_MUESTRA,
          },
        },
      },
    });

    const cuentasDistintas = respuesta.aggregations?.cardinalidad.value ?? 0;
    if (
      cuentasDistintas >=
      FraudeLoginRetrospectivoService.UMBRAL_MULTICUENTA_IP_LENTA
    ) {
      await registrarAlertaFraude({
        idTipoAlerta: ID_TIPO_ALERTA_FRAUDE_MULTI_CUENTA_IP_LENTA,
        clave: ip,
        idUsuario: null,
        detalle: {
          cuentas_distintas: cuentasDistintas,
          ventana_horas: 24,
          identificadores: (respuesta.aggregations?.muestra.buckets ?? []).map(
            (b) => b.key,
          ),
        },
        ventanaInicio: horaTruncada(),
      });
    }
  }

  private async evaluarIpRotacionCuentaAcotado(
    identificador: string,
    idUsuario: string | null,
  ): Promise<void> {
    const respuesta = await elasticClient.search<
      unknown,
      { cardinalidad: { value: number }; muestra: BucketDeMuestra }
    >({
      index: INDICE,
      size: 0,
      query: {
        bool: {
          filter: [
            { term: { 'tipo.keyword': 'login' } },
            { term: { 'identificador_intentado.keyword': identificador } },
            {
              range: {
                fecha: { gte: FraudeLoginRetrospectivoService.VENTANA_ELASTIC },
              },
            },
          ],
        },
      },
      aggs: {
        cardinalidad: { cardinality: { field: 'ip.keyword' } },
        muestra: {
          terms: {
            field: 'ip.keyword',
            size: FraudeLoginRetrospectivoService.TAMANO_MUESTRA,
          },
        },
      },
    });

    const ipsDistintas = respuesta.aggregations?.cardinalidad.value ?? 0;
    if (
      ipsDistintas >= FraudeLoginRetrospectivoService.UMBRAL_IP_ROTACION_CUENTA
    ) {
      await registrarAlertaFraude({
        idTipoAlerta: ID_TIPO_ALERTA_FRAUDE_IP_ROTACION_CUENTA_LENTA,
        clave: identificador,
        idUsuario,
        detalle: {
          ips_distintas: ipsDistintas,
          ventana_horas: 24,
          ips: (respuesta.aggregations?.muestra.buckets ?? []).map(
            (b) => b.key,
          ),
        },
        ventanaInicio: horaTruncada(),
      });
    }
  }
}

/** Un bucket de agregacion `terms` usado solo para la muestra de evidencia. */
interface BucketDeMuestra {
  buckets: { key: string }[];
}

/** La hora actual truncada a en punto -- la granularidad de dedup de este worker. */
function horaTruncada(): Date {
  const fecha = new Date();
  fecha.setMinutes(0, 0, 0);
  return fecha;
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
