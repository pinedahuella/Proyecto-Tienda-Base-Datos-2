import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Post,
  UseGuards,
} from '@nestjs/common';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { AgregarLineaPeticion } from '../../dto/agregar-linea-pedido';
import type { CrearPedidoPeticion } from '../../dto/crear-pedido';
import type { ComprarPedidoPeticion } from '../../dto/comprar-pedido';
import type { TokenUsuario } from '../../dto/token-usuario';
import { PedidosCompradorService } from '../../services/compradores/pedidos.service';

/**
 * Controlador de las rutas /comprador/pedidos.
 *
 * Sin @Roles: a diferencia de /vendedor/productos o /admin/*, comprar no
 * es un privilegio de un rol en particular -- cualquiera con sesion puede
 * hacerlo, sea comprador, vendedor o admin. Solo @UseGuards(SesionGuard),
 * sin restriccion de rol.
 */
@Controller('comprador/pedidos')
@UseGuards(SesionGuard)
export class PedidosCompradorController {
  constructor(
    private readonly pedidosCompradorService: PedidosCompradorService,
  ) {}

  // POST /comprador/pedidos
  @Post()
  async crear(
    @Body() cuerpo: CrearPedidoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const idPedido = await this.pedidosCompradorService.crear(
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito({ id_pedido: idPedido }, 'Pedido creado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo crear el pedido');
    }
  }

  // GET /comprador/pedidos
  @Get()
  async listar(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const pedidos = await this.pedidosCompradorService.listar(
        usuarioActual.id_usuario,
      );
      return exito(pedidos, 'Pedidos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los pedidos');
    }
  }

  // GET /comprador/pedidos/metodos-pago
  // Va antes de :id para que "metodos-pago" no se confunda con un id.
  @Get('metodos-pago')
  async metodosPago() {
    try {
      const metodos = await this.pedidosCompradorService.metodosPago();
      return exito(metodos, 'Metodos de pago obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los metodos de pago');
    }
  }

  // GET /comprador/pedidos/:id
  @Get(':id')
  async obtener(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const pedido = await this.pedidosCompradorService.obtener(
        id,
        usuarioActual.id_usuario,
      );
      return exito(pedido, 'Pedido obtenido correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el pedido');
    }
  }

  // POST /comprador/pedidos/:id/detalles
  @Post(':id/detalles')
  async agregarLinea(
    @Param('id') id: string,
    @Body() cuerpo: AgregarLineaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const linea = await this.pedidosCompradorService.agregarLinea(
        id,
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(linea, 'Producto agregado al pedido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo agregar el producto al pedido');
    }
  }

  // DELETE /comprador/pedidos/:id/detalles/:idDetalle
  @Delete(':id/detalles/:idDetalle')
  async quitarLinea(
    @Param('id') id: string,
    @Param('idDetalle') idDetalle: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      await this.pedidosCompradorService.quitarLinea(
        id,
        idDetalle,
        usuarioActual.id_usuario,
      );
      return exito(null, 'Producto quitado del pedido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo quitar el producto del pedido');
    }
  }

  // POST /comprador/pedidos/:id/comprar
  @Post(':id/comprar')
  async comprar(
    @Param('id') id: string,
    @Body() cuerpo: ComprarPedidoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.pedidosCompradorService.comprarPedido(
        id,
        usuarioActual.id_usuario,
        cuerpo,
      );
      const mensaje = resultado.comprado
        ? 'Compra realizada correctamente'
        : 'Hay cambios que revisar antes de comprar';
      return exito(resultado, mensaje);
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo completar la compra');
    }
  }

  // POST /comprador/pedidos/:id/cancelar
  @Post(':id/cancelar')
  async cancelar(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.pedidosCompradorService.cancelarPedido(
        id,
        usuarioActual.id_usuario,
      );
      return exito(resultado, 'Pedido cancelado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo cancelar el pedido');
    }
  }
}
