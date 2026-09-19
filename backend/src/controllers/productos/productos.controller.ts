import { Controller, Get, Param, Query, UseGuards } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { SesionGuard } from '../../guards/sesion.guard';
import type { ListarProductosQuery } from '../../dto/listar-productos';
import type { PaginarProductosQuery } from '../../dto/paginar-productos';
import { ProductosService } from '../../services/productos/productos.service';

/**
 * Controlador de las rutas /productos.
 *
 * Publico a proposito: el catalogo se puede ver sin haber iniciado sesion,
 * a diferencia de /perfil o /direccion-usuario. La unica excepcion es
 * :id/historial, que si exige sesion -- ver el guard puesto ahi mismo, no
 * en la clase, para no arrastrar esa exigencia al resto del catalogo.
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
  // Protegida: a diferencia del resto del catalogo, esta si exige sesion
  // (ver endpoints-productos.md) -- sin rol ni dueno especifico, cualquier
  // cuenta logueada puede pedirla.
  @Get(':id/historial')
  @UseGuards(SesionGuard)
  async obtenerHistorial(
    @Param('id') id: string,
    @Query('fecha') fecha: string | undefined,
  ) {
    try {
      const producto = await this.productosService.reconstruirEnFecha(
        id,
        fecha,
      );
      return exito(producto, 'Producto reconstruido correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo reconstruir el producto');
    }
  }

  // GET /productos/ofertas/:id/historial
  // Vive a la par de :id/historial, mismo criterio: protegida con
  // SesionGuard, sin restriccion de rol ni de dueño -- cualquiera con
  // sesion puede pedir el historial de precio/stock de CUALQUIER oferta,
  // no solo la propia. Pensada para completar la reconstruccion de un
  // pedido viejo: :id/historial da el producto tal como se veia, esta da
  // el precio y el stock de la oferta que se compro, tal como estaban.
  @Get('ofertas/:id/historial')
  @UseGuards(SesionGuard)
  async obtenerHistorialOferta(
    @Param('id') id: string,
    @Query('fecha') fecha: string | undefined,
  ) {
    try {
      const oferta = await this.productosService.reconstruirOfertaEnFecha(
        id,
        fecha,
      );
      return exito(oferta, 'Oferta reconstruida correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo reconstruir la oferta');
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
