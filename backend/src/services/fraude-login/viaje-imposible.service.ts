import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { registrarAlertaFraude } from '../../helpers/registrar-alerta-fraude';
import type { GeoUbicacion } from '../../helpers/contexto-peticion';
import { ID_TIPO_ALERTA_FRAUDE_VIAJE_IMPOSIBLE } from '../../models/alerta-fraude';

const INDICE =
  process.env.ELASTIC_INDICE_EVENTOS ?? 'mesh_eventos_autenticacion';

/** Radio de la Tierra en km, para haversine. */
const RADIO_TIERRA_KM = 6371;

/**
 * `geo_punto`/`geo_pais`/`geo_ciudad` van aplanados en el indice -- no un
 * objeto `geo` anidado -- porque un campo `geo_point` en Elasticsearch SOLO
 * acepta `lat`/`lon` (ver `documento-elastic.ts` para el detalle del bug
 * real que esto evita).
 */
interface DocumentoLoginAnterior {
  geo_punto: { lat: number; lon: number };
  geo_pais: string | null;
  geo_ciudad: string | null;
  fecha: string;
}

/**
 * Viaje imposible: el login actual de una cuenta comparado contra su login
 * exitoso INMEDIATAMENTE anterior -- si la distancia entre los dos
 * implicaria una velocidad mayor a la de un vuelo comercial, algo no
 * cuadra (la cuenta viajo "imposible", o mas probable, alguien mas la esta
 * usando desde otro lugar). Punto 3 del plan.
 *
 * Igual que `TomaCuentaService`: dispara en cada login EXITOSO
 * (fire-and-forget, sin bloquear la respuesta), no es una ventana de
 * tiempo ni pasa por el worker de 15 min -- es una comparacion puntual
 * entre dos eventos.
 *
 * Requiere que ambos logins tengan `geo` (ver `contextoDePeticion` /
 * `geolocalizarIp`, calculado con `geoip-lite`). Sin `geo` en cualquiera de
 * los dos (IP privada, o `geoip-lite` no la resolvio), no hay nada que
 * comparar -- no se evalua nada, no es un error.
 *
 * Limitacion conocida y ACEPTADA (no es un bug): un usuario con VPN da un
 * falso positivo legitimo -- "viaja imposible" sin haberse movido. Es
 * ademas la unica forma practica de demostrar este patron en una demo sin
 * depender de gente real en paises distintos (decision del usuario,
 * 2026-09-11).
 */
@Injectable()
export class ViajeImposibleService {
  private readonly logger = new Logger(ViajeImposibleService.name);

  /** Velocidad implicita, en km/h, por encima de la cual se marca. Mas rapido que un vuelo comercial, con margen. */
  private static readonly UMBRAL_KMH = 800;

  async revisarLogin(datos: {
    idUsuario: string;
    identificador: string | null;
    geo: GeoUbicacion | null;
    fecha: Date;
  }): Promise<void> {
    if (datos.geo == null || datos.identificador == null) {
      // Sin geo del login actual no hay con que comparar; sin identificador
      // no hay `clave` para la alerta (mismo criterio que las otras dos
      // senales que corren en el login).
      return;
    }

    try {
      const respuesta = await elasticClient.search<DocumentoLoginAnterior>({
        index: INDICE,
        size: 1,
        query: {
          bool: {
            filter: [
              { term: { 'id_usuario.keyword': datos.idUsuario } },
              { term: { 'tipo.keyword': 'login' } },
              { term: { 'resultado.keyword': 'exito' } },
              { exists: { field: 'geo_punto' } },
            ],
          },
        },
        sort: [{ fecha: 'desc' }],
      });

      const anterior = respuesta.hits.hits[0]?._source;
      if (anterior == null) {
        // Primer login con geo conocida de esta cuenta -- nada contra que
        // comparar todavia.
        return;
      }

      const fechaAnterior = new Date(anterior.fecha);
      const horas =
        (datos.fecha.getTime() - fechaAnterior.getTime()) / (1000 * 60 * 60);
      if (horas <= 0) {
        // El evento "anterior" que trajo Elasticsearch no es realmente
        // anterior (reloj desalineado, o el propio login actual ya se
        // indexo antes de que esta consulta corriera) -- no se puede
        // calcular una velocidad con tiempo cero o negativo.
        return;
      }

      const geoAnterior: GeoUbicacion = {
        lat: anterior.geo_punto.lat,
        lon: anterior.geo_punto.lon,
        pais: anterior.geo_pais,
        ciudad: anterior.geo_ciudad,
      };
      const km = distanciaHaversineKm(geoAnterior, datos.geo);
      const kmh = km / horas;

      if (kmh >= ViajeImposibleService.UMBRAL_KMH) {
        const ventanaInicio = new Date();
        ventanaInicio.setSeconds(0, 0);

        await registrarAlertaFraude({
          idTipoAlerta: ID_TIPO_ALERTA_FRAUDE_VIAJE_IMPOSIBLE,
          clave: datos.identificador,
          idUsuario: datos.idUsuario,
          detalle: {
            distancia_km: Math.round(km),
            horas_transcurridas: Number(horas.toFixed(2)),
            velocidad_kmh: Math.round(kmh),
            ubicacion_anterior: geoAnterior,
            ubicacion_actual: datos.geo,
          },
          ventanaInicio,
        });
      }
    } catch (error) {
      this.logger.warn(
        `deteccion de viaje imposible interrumpida: ${mensajeCorto(error)}`,
      );
    }
  }
}

/** Distancia entre dos puntos (lat/lon) sobre la superficie terrestre, en km. */
function distanciaHaversineKm(a: GeoUbicacion, b: GeoUbicacion): number {
  const toRad = (grados: number): number => (grados * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const senoMitad =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  const angulo = 2 * Math.atan2(Math.sqrt(senoMitad), Math.sqrt(1 - senoMitad));
  return RADIO_TIERRA_KM * angulo;
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
