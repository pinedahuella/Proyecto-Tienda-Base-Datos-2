import {
  Body,
  Controller,
  HttpCode,
  HttpStatus,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import { exito } from '../helpers/respuesta';
import { manejarErrorHttp } from '../helpers/manejar-error-http';
import {
  validarIdProducto,
  validarCantidadMovimiento,
} from '../helpers/validaciones-inventario';
import { validarIdOferta } from '../helpers/validaciones-pedido';
import {
  validarOrigenEvento,
  validarSesionEvento,
  validarTerminoEvento,
  validarPosicionEvento,
} from '../helpers/validaciones-eventos';
import { idUsuarioDeCookieOpcional } from '../helpers/sesion-opcional';
import { SesionGuard } from '../guards/sesion.guard';
import { UsuarioActual } from '../decorators/usuario-actual.decorator';
import type { RegistrarVistaPeticion } from '../dto/registrar-vista';
import type { RegistrarCarritoPeticion } from '../dto/registrar-carrito';
import type { RegistrarClicBusquedaPeticion } from '../dto/registrar-clic-busqueda';
import type { TokenUsuario } from '../dto/token-usuario';
import { EventosService } from '../services/eventos/eventos.service';

/**
 * Rutas del plan de eventos en ClickHouse
 * (`elementos Generales/plan pendiente/eventos-clickhouse.md`).
 * Fire-and-forget: cada una responde `202` de inmediato, sin esperar a que
 * el evento termine de escribirse (`EventosService` nunca lanza). Un
 * `sendBeacon()` del navegador no deberia esperar nada.
 */
@Controller('eventos')
export class EventosController {
  constructor(private readonly eventosService: EventosService) {}

  /**
   * `POST /eventos/vista` -- PUBLICA, sin `SesionGuard`: la ficha de un
   * producto se puede ver sin cuenta, y exigir sesion aqui dejaria fuera
   * justo la mayoria del trafico que se quiere medir.
   */
  // POST /eventos/vista
  @Post('vista')
  @HttpCode(HttpStatus.ACCEPTED)
  async vista(
    @Body() cuerpo: RegistrarVistaPeticion,
    @Req() request: FastifyRequest,
  ) {
    let idProducto: number;
    let sesion: string;
    let origen: ReturnType<typeof validarOrigenEvento>;
    try {
      idProducto = validarIdProducto(cuerpo?.id_producto);
      sesion = validarSesionEvento(cuerpo?.sesion);
      origen = validarOrigenEvento(cuerpo?.origen);
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo registrar la vista');
      return;
    }

    void this.eventosService.registrarVista({
      idProducto,
      idUsuario: await idUsuarioDeCookieOpcional(request),
      sesion,
      ip: request.ip,
      origen,
    });

    return exito(null, 'Vista registrada');
  }

  /**
   * `POST /eventos/carrito` -- a diferencia de `vista`, SI exige sesion
   * (`@UseGuards(SesionGuard)`): el carrito siempre requiere cuenta en este
   * proyecto (no hay carrito de invitado), asi que `id_usuario` sale de
   * `@UsuarioActual()`, nunca de una cookie opcional ni del cuerpo.
   */
  // POST /eventos/carrito
  @Post('carrito')
  @UseGuards(SesionGuard)
  @HttpCode(HttpStatus.ACCEPTED)
  carrito(
    @Body() cuerpo: RegistrarCarritoPeticion,
    @Req() request: FastifyRequest,
    @UsuarioActual() usuario: TokenUsuario,
  ) {
    let idProducto: number;
    let idOferta: number;
    let cantidad: number;
    try {
      idProducto = validarIdProducto(cuerpo?.id_producto);
      idOferta = validarIdOferta(cuerpo?.id_oferta);
      cantidad = validarCantidadMovimiento(cuerpo?.cantidad);
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo registrar el agregado al carrito');
      return;
    }

    void this.eventosService.registrarCarrito({
      idProducto,
      idOferta,
      idUsuario: usuario.id_usuario,
      cantidad,
      ip: request.ip,
    });

    return exito(null, 'Evento de carrito registrado');
  }

  /**
   * `POST /eventos/busqueda-clic` -- PUBLICA, sin `SesionGuard`: buscar y
   * hacer clic en un resultado no exige cuenta, mismo criterio que `vista`.
   * A diferencia de `busqueda_realizada` (que se registra sola desde
   * `GET /buscador/productos`, el backend ya la corrio), hacer clic es una
   * interaccion pura de interfaz -- el backend no tiene forma de saber que
   * paso si el frontend no avisa.
   */
  // POST /eventos/busqueda-clic
  @Post('busqueda-clic')
  @HttpCode(HttpStatus.ACCEPTED)
  async busquedaClic(
    @Body() cuerpo: RegistrarClicBusquedaPeticion,
    @Req() request: FastifyRequest,
  ) {
    let termino: string;
    let idProducto: number;
    let posicion: number;
    let sesion: string;
    try {
      termino = validarTerminoEvento(cuerpo?.termino);
      idProducto = validarIdProducto(cuerpo?.id_producto);
      posicion = validarPosicionEvento(cuerpo?.posicion);
      sesion = validarSesionEvento(cuerpo?.sesion);
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo registrar el clic de busqueda');
      return;
    }

    void this.eventosService.registrarClicBusqueda({
      termino,
      idProducto,
      posicion,
      idUsuario: await idUsuarioDeCookieOpcional(request),
      sesion,
    });

    return exito(null, 'Clic de busqueda registrado');
  }
}
