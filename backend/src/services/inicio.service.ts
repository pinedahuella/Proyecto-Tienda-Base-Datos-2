import { Injectable } from '@nestjs/common';
import { exito, RespuestaApi } from '../helpers/respuesta';
import { EstadoApi } from '../models/estado-api';

/**
 * Servicio de la ruta raiz.
 *
 * No consulta nada: solo devuelve un texto fijo. Sirve para saber si el backend
 * arranco bien, sin depender de la base de datos.
 */
@Injectable()
export class InicioService {
  obtenerEstado(): RespuestaApi<EstadoApi> {
    return exito({ servicio: 'Mesh API', estado: 'en linea' }, 'Hello World');
  }
}
