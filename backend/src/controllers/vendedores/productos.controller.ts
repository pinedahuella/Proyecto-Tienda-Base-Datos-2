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
import type { AjustarInventarioPeticion } from '../../dto/ajustar-inventario-vendedor';
import type { CrearInventarioPeticion } from '../../dto/inventario-vendedor';
import type { TokenUsuario } from '../../dto/token-usuario';
import { ID_ROL_VENDEDOR } from '../../models/rol-usuario';
import { ProductosVendedorService } from '../../services/vendedores/productos.service';
import { InventarioVendedorService } from '../../services/vendedores/inventario.service';

/**
 * Controlador de las rutas /vendedor/productos.
 *
 * Solo vendedor (no admin): un producto siempre pertenece a quien lo crea,
 * y un admin no es dueno de productos propios.
 */
@Controller('vendedor/productos')
@UseGuards(SesionGuard)
@Roles(ID_ROL_VENDEDOR)
export class ProductosVendedorController {
  constructor(
    private readonly productosVendedorService: ProductosVendedorService,
    private readonly inventarioVendedorService: InventarioVendedorService,
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

  // GET /vendedor/productos/inventario
  // Va antes de :id para que "inventario" no se confunda con un id.
  @Get('inventario')
  async inventarioMio(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const inventario = await this.inventarioVendedorService.listarPropio(
        usuarioActual.id_usuario,
      );
      return exito(inventario, 'Inventario obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el inventario');
    }
  }

  // GET /vendedor/productos/inventario/motivos-ajuste
  // Va antes de :id/historial y :id para que "inventario/motivos-ajuste"
  // no se confunda con un id.
  @Get('inventario/motivos-ajuste')
  async motivosAjuste() {
    try {
      const motivos = await this.inventarioVendedorService.listarMotivosAjuste();
      return exito(motivos, 'Motivos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los motivos');
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

  // GET /vendedor/productos/:id/inventario
  // Va antes de :id para que "inventario" no se confunda con un id.
  @Get(':id/inventario')
  async inventarioDeUno(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const inventario = await this.inventarioVendedorService.obtenerPropio(
        id,
        usuarioActual.id_usuario,
      );
      return exito(inventario, 'Inventario obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el inventario');
    }
  }

  // POST /vendedor/productos/:id/inventario
  @Post(':id/inventario')
  async crearInventarioDeUno(
    @Param('id') id: string,
    @Body() cuerpo: CrearInventarioPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const inventario = await this.inventarioVendedorService.crearInicial(
        id,
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(inventario, 'Inventario creado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo crear el inventario');
    }
  }

  // PATCH /vendedor/productos/:id/inventario
  @Patch(':id/inventario')
  async ajustarInventarioDeUno(
    @Param('id') id: string,
    @Body() cuerpo: AjustarInventarioPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const inventario = await this.inventarioVendedorService.ajustar(
        id,
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(inventario, 'Inventario ajustado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo ajustar el inventario');
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
