import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Query,
  UseGuards,
} from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type {
  ActualizarCasoFraudePeticion,
  PaginarCasosFraudeQuery,
} from '../../dto/paginar-casos-fraude';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { CasosFraudeService } from '../../services/fraude/casos-fraude.service';

/**
 * `GET`/`PATCH /admin/fraude/casos` -- el agrupador de casos de fraude
 * (`elementos Generales/plan pendiente/agrupador-fraude.md`). Solo admin,
 * igual que el resto de paneles de fraude. Controller SEPARADO de
 * `AdminFraudeAnillosController`/`AdminFraudeEventosController`/
 * `AdminFraudeLoginController`: estos casos son la capa que los junta,
 * no reemplazan sus paneles individuales.
 */
@Controller('admin/fraude/casos')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class AdminCasosFraudeController {
  constructor(private readonly casosFraudeService: CasosFraudeService) {}

  // GET /admin/fraude/casos?nivel=&estado=&pagina=&limite=
  @Get()
  async listar(@Query() query: PaginarCasosFraudeQuery) {
    try {
      const resultado = await this.casosFraudeService.listarPaginado(query);
      return exito(resultado, 'Casos de fraude obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los casos de fraude');
    }
  }

  // GET /admin/fraude/casos/:id
  @Get(':id')
  async obtenerDetalle(@Param('id') id: string) {
    try {
      const detalle = await this.casosFraudeService.obtenerDetalle(id);
      return exito(detalle, 'Caso de fraude obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el caso de fraude');
    }
  }

  // PATCH /admin/fraude/casos/:id { estado, motivo }
  @Patch(':id')
  async actualizar(
    @Param('id') id: string,
    @Body() peticion: ActualizarCasoFraudePeticion,
  ) {
    try {
      const detalle = await this.casosFraudeService.actualizar(id, peticion);
      return exito(detalle, 'Caso de fraude actualizado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar el caso de fraude');
    }
  }
}
