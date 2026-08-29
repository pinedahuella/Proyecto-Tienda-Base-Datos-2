import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { CrearProductoPeticion } from '../../dto/crear-producto';
import type { EditarProductoPeticion } from '../../dto/editar-producto';
import type { RevisarPropuestaPeticion } from '../../dto/revisar-propuesta';
import type { PaginarProductosVendedorQuery } from '../../dto/paginar-productos-vendedor';
import type { TokenUsuario } from '../../dto/token-usuario';
import { ID_ROL_VENDEDOR, ID_ROL_ADMIN } from '../../models/rol-usuario';
import { ProductosVendedorService } from '../../services/vendedores/productos.service';

/**
 * Controlador de las rutas /vendedor/productos.
 *
 * Un producto ya no pertenece a ningun vendedor: el catalogo es compartido
 * (modelo multi-vendedor). Estas rutas son el panel de administracion del
 * catalogo completo, y por eso estan restringidas a la cuenta de la tienda
 * (`tienda@mesh.com`) o a cualquier cuenta con rol admin (ver
 * exigirTiendaOAdmin en ProductosVendedorService) -- no a "vendedor" como
 * rol en general. Un vendedor que no es la tienda ni admin no tiene "sus
 * productos" aqui; lo que tiene es su oferta sobre una variante del
 * catalogo (ver /vendedor/ofertas).
 */
@Controller('vendedor/productos')
@UseGuards(SesionGuard)
@Roles(ID_ROL_VENDEDOR, ID_ROL_ADMIN)
export class ProductosVendedorController {
  constructor(
    private readonly productosVendedorService: ProductosVendedorService,
  ) {}

  // GET /vendedor/productos
  @Get()
  async listarMios(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const productos = await this.productosVendedorService.listarPropios(
        usuarioActual.id_usuario,
      );
      return exito(productos, 'Productos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los productos');
    }
  }

  // GET /vendedor/productos/paginado
  // Va antes de :id para que "paginado" no se confunda con un id (aunque
  // Fastify de por si prioriza las rutas estaticas sobre las parametricas).
  // Todo el catalogo, sin excluir ningun estado -- igual que listarMios()
  // -- pero paginado por numero de pagina y con un solo filtro: nombre
  // "contiene", insensible a mayusculas y a tildes.
  @Get('paginado')
  async listarMiosPaginado(
    @Query() query: PaginarProductosVendedorQuery,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const pagina = await this.productosVendedorService.listarPropiosPaginado(
        usuarioActual.id_usuario,
        query,
      );
      return exito(pagina, 'Productos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los productos');
    }
  }

  // GET /vendedor/productos/propuestas
  // Las propuestas del vendedor logueado (solo las suyas). Cualquier
  // vendedor o admin. Va antes de :id (segmento estatico).
  @Get('propuestas')
  async listarPropuestasMias(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const propuestas =
        await this.productosVendedorService.listarPropuestasPropias(
          usuarioActual.id_usuario,
        );
      return exito(propuestas, 'Propuestas obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las propuestas');
    }
  }

  // GET /vendedor/productos/propuestas/sin-aprobar
  // Todas las propuestas sin aprobar (en_revision o rechazado). Solo tienda
  // o admin -- un vendedor cualquiera recibe el mismo 404 generico.
  @Get('propuestas/sin-aprobar')
  async listarPropuestasSinAprobar(
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const propuestas =
        await this.productosVendedorService.listarPropuestasSinAprobar(
          usuarioActual.id_usuario,
        );
      return exito(propuestas, 'Propuestas sin aprobar obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las propuestas');
    }
  }

  // GET /vendedor/productos/propuestas/todas
  // Todas las propuestas, en cualquier estado. Solo tienda o admin.
  @Get('propuestas/todas')
  async listarTodasLasPropuestas(
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const propuestas =
        await this.productosVendedorService.listarTodasLasPropuestas(
          usuarioActual.id_usuario,
        );
      return exito(propuestas, 'Propuestas obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las propuestas');
    }
  }

  // GET /vendedor/productos/propuestas/:id/rechazos
  // El historial de rechazos de una propuesta. La ve la tienda/un admin (de
  // cualquiera) o el vendedor que la propuso (solo la suya).
  @Get('propuestas/:id/rechazos')
  async listarRechazosPropuesta(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const rechazos =
        await this.productosVendedorService.listarRechazosPropuesta(
          usuarioActual.id_usuario,
          id,
        );
      return exito(rechazos, 'Rechazos de la propuesta obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los rechazos de la propuesta');
    }
  }

  // GET /vendedor/productos/:id/historial
  // Va antes de :id para que "historial" no se confunda con un id (aunque
  // Fastify de por si prioriza las rutas estaticas sobre las parametricas).
  @Get(':id/historial')
  async obtenerHistorialMio(
    @Param('id') id: string,
    @Query('fecha') fecha: string | undefined,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const producto = await this.productosVendedorService.obtenerHistorialPropio(
        id,
        usuarioActual.id_usuario,
        fecha,
      );
      return exito(producto, 'Producto reconstruido correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo reconstruir el producto');
    }
  }

  // GET /vendedor/productos/:id
  @Get(':id')
  async obtenerMio(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const producto = await this.productosVendedorService.obtenerPropio(
        id,
        usuarioActual.id_usuario,
      );
      return exito(producto, 'Producto obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el producto');
    }
  }

  // POST /vendedor/productos
  @Post()
  async crear(
    @Body() cuerpo: CrearProductoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const producto = await this.productosVendedorService.crear(
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(producto, 'Producto creado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo crear el producto');
    }
  }

  // POST /vendedor/productos/propuestas
  // Un vendedor convencional PROPONE un producto: nace en Mongo con estado
  // `en_revision` (no circula) y se registra la propuesta en PostgreSQL.
  // A diferencia de POST /vendedor/productos, no exige ser la tienda ni
  // admin -- el guard de la clase ya deja fuera a los compradores.
  @Post('propuestas')
  async proponer(
    @Body() cuerpo: CrearProductoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const producto = await this.productosVendedorService.proponer(
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(producto, 'Propuesta de producto enviada a revision');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo enviar la propuesta');
    }
  }

  // PATCH /vendedor/productos/:id/revision
  // La tienda o un admin aprueba o rechaza una propuesta en revision.
  // Segmento "revision" literal, va antes de :id.
  @Patch(':id/revision')
  async revisarPropuesta(
    @Param('id') id: string,
    @Body() cuerpo: RevisarPropuestaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const producto = await this.productosVendedorService.revisarPropuesta(
        usuarioActual.id_usuario,
        id,
        cuerpo,
      );
      const mensaje =
        producto.estado === 'activo'
          ? 'Propuesta aprobada'
          : 'Propuesta rechazada';
      return exito(producto, mensaje);
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo revisar la propuesta');
    }
  }

  // PATCH /vendedor/productos/:id/reenviar
  // El vendedor re-envia su propia propuesta rechazada a revision.
  @Patch(':id/reenviar')
  async reenviarPropuesta(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const producto = await this.productosVendedorService.reenviarPropuesta(
        usuarioActual.id_usuario,
        id,
      );
      return exito(producto, 'Propuesta reenviada a revision');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo reenviar la propuesta');
    }
  }

  // PATCH /vendedor/productos/:id
  @Patch(':id')
  async editar(
    @Param('id') id: string,
    @Body() cuerpo: EditarProductoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const producto = await this.productosVendedorService.editar(
        id,
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(producto, 'Producto actualizado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar el producto');
    }
  }
}
