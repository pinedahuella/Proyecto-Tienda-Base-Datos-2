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
  // Fastify en lugar de Express: mismo Nest, servidor mas rapido.
  //
  // trustProxy: 'loopback' -- sin esto, `request.ip` siempre da 127.0.0.1
  // (o la IP del tunel) cuando la peticion pasa por un proxy que corre en
  // esta misma maquina: el proxy /api de Vite en desarrollo, o un tunel
  // para entrar desde el celular. Con 'loopback', Fastify confia en el
  // header X-Forwarded-For SOLO cuando quien se conecto directo es
  // 127.0.0.1/::1, y de ahi saca la IP real -- nunca confia en un
  // X-Forwarded-For que venga de una IP publica cualquiera (eso permitiria
  // falsificarla). Afecta el `ip` que se guarda en `vista_producto`,
  // `carrito_producto`, `compra_producto` y `devolucion_producto`
  // (ver `EventosService`), ademas de cualquier deteccion de fraude por IP.
  const app = await NestFactory.create<NestFastifyApplication>(
    AppModule,
    new FastifyAdapter({ trustProxy: 'loopback' }),
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
    methods: ['GET', 'HEAD', 'POST', 'PATCH', 'PUT', 'DELETE'],
  });

  // Lee la cookie de cada peticion y la deja en request.cookies. No firma
  // la cookie en si (eso ya lo hace el JWT de adentro), solo la parsea.
  await app.register(fastifyCookie);

  // 0.0.0.0 y no localhost: asi tambien responde desde un contenedor
  await app.listen(process.env.PORT ?? 3000, '0.0.0.0');
}

// El void le dice a TypeScript que la promesa se ignora a proposito
void bootstrap();
