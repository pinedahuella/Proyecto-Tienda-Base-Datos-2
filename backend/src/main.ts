// Carga backend/.env en process.env. Va antes que todo lo demas, porque la
// conexion a PostgreSQL necesita esas variables al importarse.
import 'dotenv/config';

import { NestFactory } from '@nestjs/core';
import {
  FastifyAdapter,
  NestFastifyApplication,
} from '@nestjs/platform-fastify';
import fastifyCookie from '@fastify/cookie';
import { AppModule } from './app.module';

/**
 * Punto de arranque del backend. Es lo primero que corre.
 *
 * Levanta el servidor en el puerto 3000 y le dice que su configuracion esta
 * en AppModule.
 */
async function bootstrap() {
  // Fastify en lugar de Express: mismo Nest, servidor mas rapido
  const app = await NestFactory.create<NestFastifyApplication>(
    AppModule,
    new FastifyAdapter(),
  );

  // Permite que el frontend (puerto 5173) le hable al backend (puerto 3000).
  // Sin esto el navegador bloquea las peticiones por ser de otro origen.
  //
  // credentials: true es obligatorio para que el navegador mande la cookie
  // del token en cada peticion. Con eso, el origen ya no puede ser "*" (el
  // navegador lo rechaza), tiene que ser uno explicito.
  app.enableCors({
    origin: 'http://localhost:5173',
    credentials: true,
  });

  // Lee la cookie de cada peticion y la deja en request.cookies. No firma
  // la cookie en si (eso ya lo hace el JWT de adentro), solo la parsea.
  await app.register(fastifyCookie);

  // 0.0.0.0 y no localhost: asi tambien responde desde un contenedor
  await app.listen(process.env.PORT ?? 3000, '0.0.0.0');
}

// El void le dice a TypeScript que la promesa se ignora a proposito
void bootstrap();
