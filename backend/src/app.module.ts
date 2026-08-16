import { Module } from '@nestjs/common';
import { InicioController } from './controllers/inicio.controller';
import { InicioService } from './services/inicio.service';
import { BaseDatosController } from './controllers/base-datos.controller';
import { BaseDatosService } from './services/base-datos.service';

/**
 * Modulo principal: la lista de todas las piezas de la aplicacion.
 *
 * Cada controlador nuevo se registra en "controllers" y cada servicio en
 * "providers". Si una clase no esta aqui, Nest no la conoce y su ruta no existe.
 */
@Module({
  imports: [],
  controllers: [InicioController, BaseDatosController],
  providers: [InicioService, BaseDatosService],
})
export class AppModule {}
