import { Controller, Get, Param, UseGuards } from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { CategoriasService } from '../../services/vendedores/categorias.service';

/**
 * Controlador de las rutas /vendedor/categorias.
 *
 * Protegido en la clase: solo vendedor y admin pueden ver el menu de
 * categorias y caracteristicas para publicar un producto. Un comprador no
 * necesita esto.
 */
@Controller('vendedor/categorias')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('catalogo.ver')
export class CategoriasController {
  constructor(private readonly categoriasService: CategoriasService) {}

  // GET /vendedor/categorias
  @Get()
  async listarValidas() {
    try {
      const categorias = await this.categoriasService.listarValidas();
      return exito(categorias, 'Categorias obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las categorias');
    }
  }

  // GET /vendedor/categorias/:id
  @Get(':id')
  async obtener(@Param('id') id: string) {
    try {
      const categoria = await this.categoriasService.obtenerPorId(id);
      return exito(categoria, 'Categoria obtenida');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener la categoria');
    }
  }
}
