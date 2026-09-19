import { ErrorPago, ErrorValidacion } from './errores';
import { esTextoNoVacio } from './validaciones-perfil';
import { TarjetaPeticion } from '../dto/tarjeta-pago';

/**
 * Mock de validacion de tarjeta para POST /comprador/pedidos/:id/comprar
 * cuando metodo_pago es "tarjeta". NO es una pasarela de pago de verdad:
 * no se cobra nada, no se guarda ningun dato de la tarjeta en ninguna
 * tabla (no existe ni una columna para eso -- ver migrations/006_pedidos.sql,
 * `pago` no lleva numero de tarjeta), y el numero nunca sale en un log ni
 * en una respuesta. Es solo para que el flujo de pago "haga algo" real
 * antes de llamar a comprar_pedido().
 *
 * Dos clases de rechazo, con dos codigos HTTP distintos (ver
 * manejar-error-http.ts):
 *
 *   Formato invalido (numero, vencimiento o cvv mal armados) -> 400,
 *   ErrorValidacion: el cliente mando datos que ni siquiera tienen forma
 *   de tarjeta.
 *
 *   Tarjeta con formato valido pero rechazada -> 402, ErrorPago: los datos
 *   estaban bien, el "cobro" (simulado) no paso.
 *
 * El rechazo se decide por un puñado de numeros de prueba ya publicados
 * por procesadores reales (Stripe, https://docs.stripe.com/testing) --
 * son numeros de mentira hechos para esto, no tarjetas de nadie. Cualquier
 * otro numero con formato valido se aprueba.
 */

const REGEX_SOLO_DIGITOS = /^\d+$/;
const REGEX_VENCIMIENTO = /^(0[1-9]|1[0-2])\/(\d{2})$/;
const REGEX_CVV = /^\d{3,4}$/;

/** numero de tarjeta -> por que se rechaza. Los cuatro casos clasicos de una pasarela real. */
const TARJETAS_DE_PRUEBA_RECHAZADAS: Record<string, string> = {
  '4000000000000002': 'La tarjeta fue rechazada',
  '4000000000009995': 'Fondos insuficientes',
  '4000000000000069': 'La tarjeta esta vencida',
  '4000000000000127': 'El codigo de seguridad (CVV) es incorrecto',
  '4100000000000019': 'La tarjeta fue reportada como robada',
};

/** Quita espacios y guiones antes de validar: "4242 4242 4242 4242" es tan valido como sin espacios. */
function limpiarNumero(numero: string): string {
  return numero.replace(/[\s-]/g, '');
}

/** Algoritmo de Luhn: el mismo checksum que usan todas las tarjetas de verdad. */
function pasaLuhn(numero: string): boolean {
  let suma = 0;
  let duplicar = false;

  for (let i = numero.length - 1; i >= 0; i--) {
    let digito = Number(numero[i]);
    if (duplicar) {
      digito *= 2;
      if (digito > 9) {
        digito -= 9;
      }
    }
    suma += digito;
    duplicar = !duplicar;
  }

  return suma % 10 === 0;
}

/** true si el mes/año de vencimiento ya paso. Compara contra el ultimo dia de ese mes. */
function estaVencida(mes: number, anioCorto: number): boolean {
  const anio = 2000 + anioCorto;
  const finDeMes = new Date(anio, mes, 0, 23, 59, 59);
  return finDeMes < new Date();
}

/**
 * Valida la forma de la tarjeta y decide si "el cobro" pasa. No devuelve
 * nada: si todo esta bien, simplemente no lanza.
 */
export function validarYCobrarTarjeta(tarjeta: unknown): void {
  if (tarjeta == null || typeof tarjeta !== 'object') {
    throw new ErrorValidacion(
      'El metodo de pago es tarjeta: hace falta el objeto "tarjeta" con numero, vencimiento, cvv y titular',
    );
  }

  const { numero, vencimiento, cvv, titular } = tarjeta as TarjetaPeticion;

  if (!esTextoNoVacio(titular)) {
    throw new ErrorValidacion('El titular de la tarjeta es obligatorio');
  }

  if (typeof numero !== 'string' || numero.trim() === '') {
    throw new ErrorValidacion('El numero de tarjeta es obligatorio');
  }
  const numeroLimpio = limpiarNumero(numero);
  if (
    !REGEX_SOLO_DIGITOS.test(numeroLimpio) ||
    numeroLimpio.length < 13 ||
    numeroLimpio.length > 19
  ) {
    throw new ErrorValidacion(
      'El numero de tarjeta debe tener entre 13 y 19 digitos',
    );
  }
  if (!pasaLuhn(numeroLimpio)) {
    throw new ErrorValidacion('El numero de tarjeta no es valido');
  }

  if (typeof vencimiento !== 'string') {
    throw new ErrorValidacion(
      'El vencimiento es obligatorio, en formato MM/AA',
    );
  }
  const coincidencia = REGEX_VENCIMIENTO.exec(vencimiento);
  if (!coincidencia) {
    throw new ErrorValidacion('El vencimiento debe tener el formato MM/AA');
  }
  const mes = Number(coincidencia[1]);
  const anioCorto = Number(coincidencia[2]);
  if (estaVencida(mes, anioCorto)) {
    throw new ErrorPago('La tarjeta esta vencida');
  }

  if (typeof cvv !== 'string' || !REGEX_CVV.test(cvv)) {
    throw new ErrorValidacion('El CVV debe tener 3 o 4 digitos');
  }

  // Formato correcto: aqui es donde una pasarela de verdad cobraria. Este
  // mock solo mira si el numero es uno de los de prueba que fuerzan un
  // rechazo; cualquier otro, con formato valido, se aprueba.
  const motivoRechazo = TARJETAS_DE_PRUEBA_RECHAZADAS[numeroLimpio];
  if (motivoRechazo != null) {
    throw new ErrorPago(motivoRechazo);
  }
}
