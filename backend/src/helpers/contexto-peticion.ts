import { createHash } from 'crypto';
import type { FastifyRequest } from 'fastify';
import geoip from 'geoip-lite';

/** Ubicacion aproximada de una IP -- ver `geolocalizarIp` mas abajo. */
export interface GeoUbicacion {
  lat: number;
  lon: number;
  pais: string | null;
  ciudad: string | null;
}

/**
 * Los datos de la peticion HTTP que el log de seguridad
 * (`eventos_autenticacion`) necesita y que solo se pueden sacar del objeto
 * `request` de Fastify. Se extraen en el controlador para que `LogService`
 * no dependa de Fastify (igual que antes el controlador le pasaba
 * `request.ip` ya suelto).
 */
export interface ContextoPeticion {
  ip: string | null;
  userAgent: string | null;
  huellaCliente: string | null;
  geo: GeoUbicacion | null;
}

/**
 * Arma el `ContextoPeticion` a partir del `request`.
 *
 * La huella es SHA-256 de `User-Agent` + `Accept-Language`: NO identifica a
 * nadie de forma fiable (se falsea cambiando una cabecera), sirve para
 * agrupar peticiones del mismo navegador honesto. Si no hay `User-Agent` no
 * se calcula -- una huella de solo el idioma agruparia a demasiada gente
 * distinta para servir de senal.
 */
export function contextoDePeticion(request: FastifyRequest): ContextoPeticion {
  const userAgent = primeraCabecera(request, 'user-agent');
  const idioma = primeraCabecera(request, 'accept-language');
  const huellaCliente = userAgent
    ? createHash('sha256')
        .update(`${userAgent}\n${idioma ?? ''}`)
        .digest('hex')
    : null;
  const ip = request.ip || null;

  return {
    ip,
    userAgent,
    huellaCliente,
    geo: geolocalizarIp(ip),
  };
}

/**
 * Geolocaliza una IP con `geoip-lite`: busqueda 100% en memoria (la base
 * viene empaquetada con la libreria), sin llamada de red -- del orden de
 * microsegundos, por eso se calcula aqui mismo, en el camino del login, en
 * vez de diferirlo a un worker aparte.
 *
 * `null` en tres casos: sin IP, IP privada/local (192.168.x, 127.0.0.1, la
 * `172.22.192.1` que se usa para probar el backend -- ninguna geolocaliza a
 * un lugar real), o una IP anycast/CDN que `geoip-lite` no resuelve (ej.
 * `1.1.1.1`, validado en la sesion donde se probo esta libreria). En
 * cualquiera de los tres casos, quien consuma `geo` simplemente no tiene con
 * que comparar -- no es un error.
 */
export function geolocalizarIp(ip: string | null): GeoUbicacion | null {
  if (ip == null) {
    return null;
  }
  const resultado = geoip.lookup(ip);
  if (resultado == null) {
    return null;
  }
  const [lat, lon] = resultado.ll;
  if (typeof lat !== 'number' || typeof lon !== 'number') {
    // Caso `1.1.1.1`: geoip-lite a veces devuelve un objeto con `ll: [null, null]`
    // en vez de `null` directamente (IPs anycast/CDN sin ubicacion fija).
    return null;
  }
  return {
    lat,
    lon,
    pais: resultado.country || null,
    ciudad: resultado.city || null,
  };
}

function primeraCabecera(
  request: FastifyRequest,
  nombre: string,
): string | null {
  const valor = request.headers[nombre];
  if (Array.isArray(valor)) {
    return valor[0] ?? null;
  }
  return valor ?? null;
}
