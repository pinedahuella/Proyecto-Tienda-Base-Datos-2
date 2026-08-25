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
import type { TokenUsuario } from '../../dto/token-usuario';
import { ID_ROL_VENDEDOR } from '../../models/rol-usuario';
import { ProductosVendedorService } from '../../services/vendedores/productos.service';

/**
 * Controlador de las rutas /vendedor/productos.
 *
 * Un producto ya no pertenece a ningun vendedor: el catalogo es compartido
 * (modelo multi-vendedor). Estas rutas son el panel de administracion del
 * catalogo completo, y por eso estan restringidas a la cuenta de la tienda
 * (`tienda@mesh.com`, ver exigirTienda en ProductosVendedorService) -- no
 * a "vendedor" como rol en general. Un vendedor que no es la tienda no
 * tiene "sus productos" aqui; lo que tiene es su oferta sobre una
 * variante del catalogo (ver /vendedor/ofertas).
 */
@Controller('vendedor/productos')
@UseGuards(SesionGuard)
@Roles(ID_ROL_VENDEDOR)
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
