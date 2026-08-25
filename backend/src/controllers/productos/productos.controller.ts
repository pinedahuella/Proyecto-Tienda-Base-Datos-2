import { Controller, Get, Param, Query } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { ListarProductosQuery } from '../../dto/listar-productos';
import type { PaginarProductosQuery } from '../../dto/paginar-productos';
import { ProductosService } from '../../services/productos/productos.service';

/**
 * Controlador de las rutas /productos.
 *
 * Publico a proposito: el catalogo se puede ver sin haber iniciado sesion,
 * a diferencia de /perfil o /direccion-usuario.
 *
 * Dos formas de listar, mismos filtros en las dos (ver ProductosService):
 * GET /productos es scroll infinito (cursor por _id), GET /productos/paginacion
 * es paginacion convencional (numero de pagina, con salto directo).
 */
@Controller('productos')
export class ProductosController {
  constructor(private readonly productosService: ProductosService) {}

  // GET /productos
  @Get()
  async listar(@Query() query: ListarProductosQuery) {
    try {
      const pagina = await this.productosService.listar(query);
      return exito(pagina, 'Productos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los productos');
    }
  }

  // GET /productos/paginacion
  // Va antes de :id para que "paginacion" no se confunda con un id (aunque
  // Fastify de por si prioriza las rutas estaticas sobre las parametricas).
  @Get('paginacion')
  async listarPaginado(@Query() query: PaginarProductosQuery) {
    try {
      const pagina = await this.productosService.listarPaginado(query);
      return exito(pagina, 'Productos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los productos');
    }
  }

  // GET /productos/:id/historial
  // Va antes de :id para que "historial" no se confunda con un id.
  @Get(':id/historial')
  async obtenerHistorial(
    @Param('id') id: string,
    @Query('fecha') fecha: string | undefined,
  ) {
    try {
      const producto = await this.productosService.reconstruirEnFecha(id, fecha);
      return exito(producto, 'Producto reconstruido correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo reconstruir el producto');
    }
  }

  // GET /productos/:id
  @Get(':id')
  async obtener(@Param('id') id: string) {
    try {
      const producto = await this.productosService.obtenerPublico(id);
      return exito(producto, 'Producto obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el producto');
    }
  }
}
