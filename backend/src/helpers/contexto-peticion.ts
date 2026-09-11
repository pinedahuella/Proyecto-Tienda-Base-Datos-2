import { createHash } from 'crypto';
import type { FastifyRequest } from 'fastify';

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

  return {
    ip: request.ip || null,
    userAgent,
    huellaCliente,
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
