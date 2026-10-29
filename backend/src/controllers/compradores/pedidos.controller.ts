import { Controller, Get, Param, Post, Req, UseGuards } from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import { PedidosCompradorService } from '../../services/compradores/pedidos.service';

/**
 * Controlador de las rutas /comprador/pedidos.
 *
 * `pedidos.ver` y `pedidos.cancelar`, que en la semilla tienen los tres roles: a
 * diferencia de /vendedor/productos o /admin/*, comprar no
 * es un privilegio de un rol en particular -- cualquiera con sesion puede
 * hacerlo, sea comprador, vendedor o admin. Solo @UseGuards(SesionGuard, PermisoGuard),
 * sin restriccion de rol.
 *
 * Solo leer y cancelar. Se arma y se compra por /carrito: el pedido
 * `pendiente` de cada cuenta es su carrito (ver PedidosCompradorService). Las
 * rutas viejas que armaban un pedido a mano (`POST /comprador/pedidos`,
 * `POST|PATCH|DELETE /:id/detalles`, `PATCH /:id`, `POST /:id/comprar`) se
 * quitaron el 2026-10-17: ninguna pantalla las usaba y pasaban por encima del
 * carrito.
 */
@Controller('comprador/pedidos')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('pedidos.ver')
export class PedidosCompradorController {
  constructor(
    private readonly pedidosCompradorService: PedidosCompradorService,
  ) {}

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

  // POST /comprador/pedidos/:id/cancelar
  @Permiso('pedidos.cancelar')
  @Post(':id/cancelar')
  async cancelar(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
    @Req() request: FastifyRequest,
  ) {
    try {
      const resultado = await this.pedidosCompradorService.cancelarPedido(
        id,
        usuarioActual.id_usuario,
        request.ip,
      );
      return exito(resultado, 'Pedido cancelado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo cancelar el pedido');
    }
  }
}
