import { Body, Controller, Get, Param, Patch, Post, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import type { CrearOfertaPeticion } from '../../dto/crear-oferta';
import type { EditarOfertaPeticion } from '../../dto/editar-oferta';
import { ID_ROL_VENDEDOR, ID_ROL_ADMIN } from '../../models/rol-usuario';
import { OfertasVendedorService } from '../../services/vendedores/ofertas.service';

/**
 * Controlador de las rutas /vendedor/ofertas.
 *
 * Cualquier vendedor (no solo tienda@mesh.com), y tambien cualquier cuenta
 * con rol admin: publicar una oferta sobre un producto que ya existe es lo
 * que cualquiera con rol vendedor o admin puede hacer -- la restriccion de
 * "solo tienda (o admin)" es unicamente para crear entradas nuevas del
 * catalogo (ver ProductosVendedorService). A diferencia de alli, aqui no
 * hace falta ningun chequeo de cuenta especifica: OfertasVendedorService ya
 * scoped todo (crear, editar, listar) al id_usuario de quien esta
 * logueado, asi que una oferta creada por un admin nace bajo su propia
 * cuenta, igual que la de cualquier otro vendedor -- no hay ninguna cuenta
 * "de la tienda" involucrada aqui.
 */
@Controller('vendedor/ofertas')
@UseGuards(SesionGuard)
@Roles(ID_ROL_VENDEDOR, ID_ROL_ADMIN)
export class OfertasVendedorController {
  constructor(
    private readonly ofertasVendedorService: OfertasVendedorService,
  ) {}

  // GET /vendedor/ofertas
  @Get()
  async listar(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const ofertas = await this.ofertasVendedorService.listarPropias(
        usuarioActual.id_usuario,
      );
      return exito(ofertas, 'Ofertas obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las ofertas');
    }
  }

  // GET /vendedor/ofertas/producto/:idProducto
  // El segmento "producto" es literal y no un :id, para no chocar con lo
  // que va a ser GET /vendedor/ofertas/:id (por id_oferta) mas adelante.
  @Get('producto/:idProducto')
  async obtenerPorProducto(
    @Param('idProducto') idProducto: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const producto = await this.ofertasVendedorService.obtenerConMisOfertas(
        idProducto,
        usuarioActual.id_usuario,
      );
      return exito(producto, 'Producto obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el producto');
    }
  }

  // POST /vendedor/ofertas
  @Post()
  async crear(
    @Body() datos: CrearOfertaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const oferta = await this.ofertasVendedorService.crear(
        usuarioActual.id_usuario,
        datos,
      );
      return exito(oferta, 'Oferta creada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo crear la oferta');
    }
  }

  // PATCH /vendedor/ofertas/:id
  @Patch(':id')
  async editar(
    @Param('id') id: string,
    @Body() datos: EditarOfertaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const oferta = await this.ofertasVendedorService.editar(
        usuarioActual.id_usuario,
        id,
        datos,
      );
      return exito(oferta, 'Oferta actualizada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar la oferta');
    }
  }
}
