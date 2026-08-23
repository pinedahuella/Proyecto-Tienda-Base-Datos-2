import { Controller, Get, Param } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { CategoriasService } from '../../services/vendedores/categorias.service';

/**
 * Controlador publico de /categorias: el mismo menu de categorias y
 * caracteristicas que ya expone CategoriasService para quien publica un
 * producto, pero sin sesion, para que cualquiera pueda armar filtros de
 * busqueda sobre el catalogo (ver interpretarFiltroCaracteristica en
 * validaciones-productos.ts).
 *
 * Publico a proposito, igual que /productos: no requiere la cookie
 * mesh_token.
 */
@Controller('categorias')
export class CategoriasPublicoController {
  constructor(private readonly categoriasService: CategoriasService) {}

  // GET /categorias
  @Get()
  async listar() {
    try {
      const categorias = await this.categoriasService.listarValidas();
      return exito(categorias, 'Categorias obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las categorias');
    }
  }

  // GET /categorias/:id
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
