import { Body, Controller, Param, Patch, UseGuards } from '@nestjs/common';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import type { TokenUsuario } from '../../dto/token-usuario';
import { ResenasService } from '../../services/resenas/resenas.service';

/** Cuerpo de PATCH /admin/resenas/:id. */
interface ModerarResenaPeticion {
  estado?: string;
  motivo?: string | null;
}

/**
 * Controlador de /admin/resenas: la tienda oculta una resena o la vuelve a
 * publicar, sin borrarla (migracion 052). Se usa desde la ficha del producto y
 * desde el detalle de Resenas en anillo del panel de Fraude.
 *
 * @Permiso('resenas.moderar') en la clase. En la semilla solo lo tiene el admin.
 */
@Controller('admin/resenas')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('resenas.moderar')
export class AdminResenasController {
  constructor(private readonly resenasService: ResenasService) {}

  // PATCH /admin/resenas/:id   { "estado": "oculta" | "publicada", "motivo": "..." }
  @Patch(':id')
  async moderar(
    @Param('id') id: string,
    @Body() cuerpo: ModerarResenaPeticion | undefined,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.resenasService.moderar(
        id,
        cuerpo?.estado,
        usuarioActual.id_usuario,
        cuerpo?.motivo,
      );
      return exito(
        resultado,
        resultado.estado === 'oculta'
          ? 'Resena oculta'
          : 'Resena publicada otra vez',
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo cambiar la resena');
    }
  }
}
