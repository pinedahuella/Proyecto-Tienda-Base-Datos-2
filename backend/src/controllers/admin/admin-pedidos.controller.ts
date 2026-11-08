import { Body, Controller, Param, Post, Req, UseGuards } from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import type { TokenUsuario } from '../../dto/token-usuario';
import { PedidosCompradorService } from '../../services/compradores/pedidos.service';

/** Cuerpo opcional de POST /admin/pedidos/:id/cancelar. */
interface CancelarPedidoTiendaPeticion {
  motivo?: string | null;
}

/**
 * Controlador de las rutas /admin/pedidos: la tienda gestiona los pedidos de
 * todos (migracion 051). Cancela cualquiera, tambien enviado o entregado, y
 * los marca como enviados o entregados. Los ve en el Registro de pedidos del
 * Dashboard (`GET /admin/dashboard/pedidos`).
 *
 * @Permiso('pedidos.administrar') va en la clase, igual que en
 * AdminUsuariosController: cualquier ruta que se agregue aqui queda protegida
 * por defecto. En la semilla solo lo tiene el admin.
 */
@Controller('admin/pedidos')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('pedidos.administrar')
export class AdminPedidosController {
  constructor(private readonly pedidosService: PedidosCompradorService) {}

  // POST /admin/pedidos/:id/cancelar   { "motivo": "..." }
  @Post(':id/cancelar')
  async cancelar(
    @Param('id') id: string,
    @Body() cuerpo: CancelarPedidoTiendaPeticion | undefined,
    @UsuarioActual() usuarioActual: TokenUsuario,
    @Req() request: FastifyRequest,
  ) {
    try {
      const resultado = await this.pedidosService.cancelarComoTienda(
        id,
        usuarioActual.id_usuario,
        request.ip,
        cuerpo?.motivo,
      );
      return exito(resultado, 'Pedido cancelado por la tienda');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo cancelar el pedido');
    }
  }

  // POST /admin/pedidos/:id/enviado
  @Post(':id/enviado')
  async enviado(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.pedidosService.marcarEnvio(
        id,
        'enviado',
        usuarioActual.id_usuario,
      );
      return exito(resultado, 'Pedido marcado como enviado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo marcar el pedido');
    }
  }

  // POST /admin/pedidos/:id/entregado
  @Post(':id/entregado')
  async entregado(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.pedidosService.marcarEnvio(
        id,
        'entregado',
        usuarioActual.id_usuario,
      );
      return exito(resultado, 'Pedido marcado como entregado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo marcar el pedido');
    }
  }
}
