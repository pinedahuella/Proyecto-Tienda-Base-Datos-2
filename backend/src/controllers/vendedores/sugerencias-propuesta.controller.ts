import { Body, Controller, HttpCode, Post, UseGuards } from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { SugerenciasPropuestaPeticion } from '../../dto/sugerencias-propuesta';
import { SugerenciasPropuestaService } from '../../services/vendedores/sugerencias-propuesta.service';

/**
 * `POST /vendedor/productos/sugerencias` -- las sugerencias al proponer un
 * producto: en que categoria suele ir y que productos parecidos ya hay en el
 * catalogo. Cualquier vendedor o admin, igual que
 * `POST /vendedor/productos/propuestas`. Controlador SEPARADO de
 * `ProductosVendedorController` (que ya es muy grande) pero con el mismo prefijo
 * y el mismo guard.
 *
 * Es POST y no GET porque la descripcion puede ser larga; no crea ni cambia
 * nada, por eso responde 200 y no 201.
 */
@Controller('vendedor/productos')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('catalogo.proponer')
export class SugerenciasPropuestaController {
  constructor(
    private readonly sugerenciasPropuestaService: SugerenciasPropuestaService,
  ) {}

  // POST /vendedor/productos/sugerencias   { "nombre": "...", "descripcion": "..." }
  @Post('sugerencias')
  @HttpCode(200)
  async sugerir(@Body() cuerpo: SugerenciasPropuestaPeticion) {
    try {
      const sugerencias =
        await this.sugerenciasPropuestaService.sugerir(cuerpo);
      return exito(sugerencias, 'Sugerencias obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las sugerencias');
    }
  }
}
