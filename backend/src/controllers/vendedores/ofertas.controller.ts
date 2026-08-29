import { Body, Controller, Get, Param, Patch, Post, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import type { CrearOfertaPeticion } from '../../dto/crear-oferta';
import type { EditarOfertaPeticion } from '../../dto/editar-oferta';
import type { RevisarOfertaPeticion } from '../../dto/revisar-oferta';
import { ID_ROL_VENDEDOR, ID_ROL_ADMIN } from '../../models/rol-usuario';
import { OfertasVendedorService } from '../../services/vendedores/ofertas.service';

/**
 * Controlador de las rutas /vendedor/ofertas.
 *
 * Cualquier vendedor (no solo tienda@mesh.com), y tambien cualquier cuenta
 * con rol admin: publicar una oferta sobre un producto que ya existe es lo
 * que cualquiera con rol vendedor o admin puede hacer -- la restriccion de
 * "solo tienda (o admin)" es unicamente para crear entradas nuevas del
 * catalogo (ver ProductosVendedorService).
 *
 * OJO: un admin NO actua bajo su propia cuenta en estas cuatro rutas.
 * OfertasVendedorService.resolverIdEfectivo() sustituye el id_usuario del
 * token por el de la cuenta de la tienda (tienda@mesh.com) apenas entra
 * un admin -- toda oferta que cree, edite o vea un admin es, a todos los
 * efectos, una oferta de la tienda. Por eso las cuatro llamadas de abajo
 * mandan tambien `usuarioActual.id_rol_usuario`, no solo el id_usuario.
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
        usuarioActual.id_rol_usuario,
      );
      return exito(ofertas, 'Ofertas obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las ofertas');
    }
  }

  // GET /vendedor/ofertas/pendientes
  // La cola de revision: todas las ofertas en estado "pendiente" de
  // cualquier vendedor. Solo la tienda o un admin -- un vendedor cualquiera
  // recibe el mismo 404 generico. Segmento literal, va antes de :id/rechazos.
  @Get('pendientes')
  async listarPendientes(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const ofertas = await this.ofertasVendedorService.listarPendientes(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
      );
      return exito(ofertas, 'Ofertas pendientes obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las ofertas pendientes');
    }
  }

  // GET /vendedor/ofertas/:id/rechazos
  // El historial de rechazos de una oferta propia (:id = id_oferta). Una
  // ajena o inexistente da 404.
  @Get(':id/rechazos')
  async listarRechazos(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const rechazos = await this.ofertasVendedorService.listarRechazos(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        id,
      );
      return exito(rechazos, 'Rechazos de la oferta obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los rechazos de la oferta');
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
        usuarioActual.id_rol_usuario,
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
        usuarioActual.id_rol_usuario,
        datos,
      );
      return exito(oferta, 'Oferta creada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo crear la oferta');
    }
  }

  // PATCH /vendedor/ofertas/:id/revision
  // La tienda (o un admin) aprueba o rechaza una oferta pendiente. Segmento
  // "revision" literal, va antes de :id.
  @Patch(':id/revision')
  async revisar(
    @Param('id') id: string,
    @Body() datos: RevisarOfertaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const oferta = await this.ofertasVendedorService.revisar(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        id,
        datos,
      );
      const mensaje =
        oferta.estado === 'activa' ? 'Oferta aprobada' : 'Oferta rechazada';
      return exito(oferta, mensaje);
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo revisar la oferta');
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
        usuarioActual.id_rol_usuario,
        id,
        datos,
      );
      return exito(oferta, 'Oferta actualizada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar la oferta');
    }
  }
}
