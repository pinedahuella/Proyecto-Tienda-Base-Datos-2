import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Post,
  Put,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { DefinirCantidadCarritoPeticion } from '../../dto/definir-cantidad-carrito';
import type { ComprarCarritoPeticion } from '../../dto/comprar-carrito';
import type { TokenUsuario } from '../../dto/token-usuario';
import { CarritoService } from '../../services/carrito/carrito.service';

/**
 * Rutas de `/carrito` (Entrega 2). El carrito vive solo en Redis; ver
 * `CarritoService` para el modelo.
 *
 * Todas piden sesion (`SesionGuard` a nivel de clase, sin `@Roles`:
 * cualquiera con sesion tiene carrito, igual que comprar). El `id_usuario`
 * sale del token -> la clave en Redis es `mesh:carrito:<id_usuario>`. No hay
 * id de carrito que pasar.
 *
 *   GET    /carrito                    -> el carrito enriquecido
 *   PUT    /carrito/lineas/:idOferta    -> fijar la cantidad de una oferta
 *   DELETE /carrito/lineas/:idOferta    -> quitar una oferta
 *   DELETE /carrito                     -> vaciar
 *   POST   /carrito/comprar             -> el checkout (comprar_carrito)
 */
@Controller('carrito')
@UseGuards(SesionGuard)
export class CarritoController {
  constructor(private readonly carritoService: CarritoService) {}

  // GET /carrito
  @Get()
  async ver(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const carrito = await this.carritoService.verCarrito(
        usuarioActual.id_usuario,
      );
      return exito(carrito, 'Carrito obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el carrito');
    }
  }

  // PUT /carrito/lineas/:idOferta -- fija la cantidad ABSOLUTA (no +1/-1)
  @Put('lineas/:idOferta')
  async definirCantidad(
    @Param('idOferta') idOferta: string,
    @Body() cuerpo: DefinirCantidadCarritoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resumen = await this.carritoService.definirCantidad(
        usuarioActual.id_usuario,
        idOferta,
        cuerpo,
      );
      return exito(resumen, 'Cantidad actualizada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar el carrito');
    }
  }

  // DELETE /carrito/lineas/:idOferta -- quita una oferta del carrito
  @Delete('lineas/:idOferta')
  async quitarLinea(
    @Param('idOferta') idOferta: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resumen = await this.carritoService.quitarLinea(
        usuarioActual.id_usuario,
        idOferta,
      );
      return exito(resumen, 'Producto quitado del carrito');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo quitar el producto del carrito');
    }
  }

  // DELETE /carrito -- vaciar el carrito entero
  @Delete()
  async vaciar(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      await this.carritoService.vaciar(usuarioActual.id_usuario, true);
      return exito(null, 'Carrito vaciado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo vaciar el carrito');
    }
  }

  // POST /carrito/comprar -- el checkout
  @Post('comprar')
  async comprar(
    @Body() cuerpo: ComprarCarritoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
    @Req() request: FastifyRequest,
  ) {
    try {
      const resultado = await this.carritoService.comprarCarrito(
        usuarioActual.id_usuario,
        cuerpo,
        request.ip,
      );
      const mensaje = resultado.comprado
        ? 'Compra realizada correctamente'
        : 'Hay cambios que revisar antes de comprar';
      return exito(resultado, mensaje);
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo completar la compra');
    }
  }
}
