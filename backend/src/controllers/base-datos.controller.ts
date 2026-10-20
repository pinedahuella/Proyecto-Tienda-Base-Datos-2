import {
  Controller,
  Get,
  HttpException,
  HttpStatus,
  UseGuards,
} from '@nestjs/common';
import { Roles } from '../decorators/roles.decorator';
import { SesionGuard } from '../guards/sesion.guard';
import { ID_ROL_ADMIN } from '../models/rol-usuario';
import { Cortacircuitos } from '../helpers/cortacircuitos';
import { exito } from '../helpers/respuesta';
import { BaseDatosService } from '../services/base-datos.service';

/**
 * Controlador de la ruta GET /db
 *
 * Sirve para saber si el backend esta conectado a PostgreSQL.
 */
@Controller('db')
export class BaseDatosController {
  constructor(private readonly baseDatosService: BaseDatosService) {}

  // GET /db
  @Get()
  async verificarConexion() {
    const respuesta = await this.baseDatosService.verificarConexion();

    // Si la base no responde, el codigo HTTP tambien lo dice (503). El cuerpo
    // no cambia de forma: sigue teniendo ok, mensaje y payload.
    //
    // Se usan los dos porque el codigo lo leen las herramientas (Docker,
    // monitoreo, logs) y el campo ok lo lee el frontend.
    if (!respuesta.ok) {
      throw new HttpException(respuesta, HttpStatus.SERVICE_UNAVAILABLE);
    }

    return respuesta;
  }

  // GET /db/cortacircuitos
  // Lo que el backend vio la ultima vez que le hablo a cada base
  // (helpers/cortacircuitos.ts): si respondio o desde cuando la da por caida.
  // No prueba nada, solo cuenta lo que ya paso: lo lee pruebas/caidas.mjs. Es
  // para quien mantiene la tienda, la pagina no lo usa. Solo el admin: el
  // motivo de una caida trae hosts y puertos internos, y la tienda puede estar
  // publicada (mesh.ledkid.com).
  @Get('cortacircuitos')
  @UseGuards(SesionGuard)
  @Roles(ID_ROL_ADMIN)
  cortacircuitos() {
    return exito(
      Cortacircuitos.estados(),
      'Estado de cada base segun el backend',
    );
  }
}
