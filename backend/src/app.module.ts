import { Module } from '@nestjs/common';
import { InicioController } from './controllers/inicio.controller';
import { InicioService } from './services/inicio.service';
import { BaseDatosController } from './controllers/base-datos.controller';
import { BaseDatosService } from './services/base-datos.service';
import { UsuarioController } from './controllers/usuario.controller';
import { UsuarioService } from './services/usuario.service';

/**
 * Modulo principal: la lista de todas las piezas de la aplicacion.
 *
 * Cada controlador nuevo se registra en "controllers" y cada servicio en
 * "providers". Si una clase no esta aqui, Nest no la conoce y su ruta no existe.
 */
@Module({
  imports: [],
  controllers: [InicioController, BaseDatosController, UsuarioController],
  providers: [InicioService, BaseDatosService, UsuarioService],
})
export class AppModule {}
