import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import {
  AdminCategoriasService,
  type AgregarCaracteristicaPeticion,
  type CrearCategoriaPeticion,
} from '../../services/admin/admin-categorias.service';

/**
 * Controlador de /admin/categorias: la tienda crea categorias, les cambia el
 * nombre y les agrega caracteristicas (migracion 054). En el panel sale en
 * Catalogo, con el boton Categorias.
 *
 * @Permiso('catalogo.categorias') en la clase. En la semilla solo el admin.
 */
@Controller('admin/categorias')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('catalogo.categorias')
export class AdminCategoriasController {
  constructor(private readonly categoriasService: AdminCategoriasService) {}

  // GET /admin/categorias
  @Get()
  async listar() {
    try {
      return exito(
        await this.categoriasService.listar(),
        'Categorias obtenidas',
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las categorias');
    }
  }

  // POST /admin/categorias
  // { "nombre": "...", "id_categoria_padre": 3,
  //   "caracteristicas": [{ "nombre": "Marca", "tipo_dato": "texto" }],
  //   "caracteristicas_variante": [{ "nombre": "Color", "tipo_dato": "texto" }] }
  @Post()
  async crear(@Body() cuerpo: CrearCategoriaPeticion | undefined) {
    try {
      return exito(
        await this.categoriasService.crear(cuerpo),
        'Categoria creada',
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo crear la categoria');
    }
  }

  // PATCH /admin/categorias/:id   { "nombre": "..." }
  @Patch(':id')
  async renombrar(
    @Param('id') id: string,
    @Body() cuerpo: { nombre?: unknown } | undefined,
  ) {
    try {
      return exito(
        await this.categoriasService.renombrar(id, cuerpo?.nombre),
        'Categoria renombrada',
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo cambiar el nombre');
    }
  }

  // POST /admin/categorias/:id/caracteristicas
  // { "nombre": "...", "tipo_dato": "entero", "unidad": "W", "para": "producto" }
  @Post(':id/caracteristicas')
  async agregarCaracteristica(
    @Param('id') id: string,
    @Body() cuerpo: AgregarCaracteristicaPeticion | undefined,
  ) {
    try {
      return exito(
        await this.categoriasService.agregarCaracteristica(id, cuerpo),
        'Caracteristica agregada',
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo agregar la caracteristica');
    }
  }
}
