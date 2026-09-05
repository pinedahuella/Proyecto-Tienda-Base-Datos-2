import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { BuscarProductosQuery } from '../../dto/buscar-productos';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { BuscadorProductosService } from '../../services/buscador/productos.service';

/**
 * Controlador de las rutas /buscador/productos.
 *
 * Dos rutas, no una:
 *
 *   GET /buscador/productos        publica, igual que /productos: se puede
 *                                  buscar sin haber iniciado sesion. Solo ve
 *                                  productos `activo` -- el filtro esta
 *                                  fijo en BuscadorProductosService.buscar(),
 *                                  no aca ni en ningun query param.
 *   GET /buscador/productos/admin  protegida, solo admin. Trae cualquier
 *                                  producto en cualquier estado -- pensada
 *                                  para revisar el catalogo completo,
 *                                  incluyendo lo que no circula.
 */
@Controller('buscador/productos')
export class BuscadorProductosController {
  constructor(
    private readonly buscadorProductosService: BuscadorProductosService,
  ) {}

  // GET /buscador/productos?nombre=...&limite=...
  @Get()
  async buscar(@Query() query: BuscarProductosQuery) {
    try {
      const resultados = await this.buscadorProductosService.buscar(
        query.nombre,
        query.limite,
      );
      return exito(resultados, 'Busqueda completada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo completar la busqueda');
    }
  }

  // GET /buscador/productos/admin?nombre=...&limite=...
  // Va despues de la raiz para que Nest la registre como ruta estatica
  // aparte -- no hay ningun :id en este controller con el que pudiera
  // confundirse.
  @Get('admin')
  @UseGuards(SesionGuard)
  @Roles(ID_ROL_ADMIN)
  async buscarAdmin(@Query() query: BuscarProductosQuery) {
    try {
      const resultados = await this.buscadorProductosService.buscarAdmin(
        query.nombre,
        query.limite,
      );
      return exito(resultados, 'Busqueda completada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo completar la busqueda');
    }
  }
}
