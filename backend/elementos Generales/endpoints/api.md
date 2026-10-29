# API

## Estandar de respuestas

Todos los endpoints responden con la misma estructura.

```json
{
  "ok": true,
  "mensaje": "texto corto",
  "payload": {}
}
```

| Campo | Tipo | Que es |
|---|---|---|
| `ok` | boolean | Si la operacion salio bien |
| `mensaje` | string | Explicacion corta, legible para una persona |
| `payload` | cualquiera | Los datos utiles para el frontend |

### Reglas

Los tres campos van siempre. Aunque falle, `payload` viaja como `null` y nunca se
omite. Asi el frontend siempre lee la misma estructura.

`payload` es solo datos. Nada de banderas ni mensajes adentro.

`mensaje` se le puede ensenar al usuario. Los detalles tecnicos van al log del
servidor, no a la respuesta.

El frontend revisa `ok` antes de usar `payload`:

```js
const r = await fetch('/db').then(r => r.json());

if (!r.ok) {
  mostrarError(r.mensaje);
  return;
}

usarDatos(r.payload);
```

### Codigos HTTP

El codigo y `ok` siempre concuerdan.

| Codigo | Cuando | ok |
|---|---|---|
| 200 | Todo bien | true |
| 201 | Se creo algo | true |
| 400 | El cliente mando datos invalidos | false |
| 401 | No hay sesion, o el correo/usuario/contrasena/token no son validos | false |
| 403 | Hay sesion, pero el rol no alcanza para esto | false |
| 404 | No existe lo que se pidio | false |
| 409 | Conflicto, por ejemplo stock insuficiente | false |
| 503 | Una base de datos no responde | false |
| 500 | Error inesperado | false |

Se usan los dos porque el codigo lo leen las herramientas (Docker, monitoreo,
logs) y `ok` lo lee el frontend.

### Como se arma en el codigo

Los constructores estan en `backend/src/helpers/respuesta.ts`:

```ts
import { exito, fallo } from '../helpers/respuesta';

exito({ base: 'mesh' }, 'Conexion establecida');
// { ok: true, mensaje: 'Conexion establecida', payload: { base: 'mesh' } }

fallo('No se pudo conectar con PostgreSQL');
// { ok: false, mensaje: 'No se pudo conectar con PostgreSQL', payload: null }
```

No armar el objeto a mano. Si el estandar cambia, se cambia en un solo archivo.

---

## Endpoints

### GET /

Ruta de prueba. Dice que la API esta viva. HTTP 200:

```json
{
  "ok": true,
  "mensaje": "Hello World",
  "payload": {
    "servicio": "Mesh API",
    "estado": "en linea"
  }
}
```

No toca la base de datos. Si responde, el backend arranco bien.

### GET /db

Comprueba si el backend puede hablar con PostgreSQL. Le manda una consulta minima
que no toca ninguna tabla: solo interesa saber si responde.

Conectado, HTTP 200:

```json
{
  "ok": true,
  "mensaje": "Conexion establecida con PostgreSQL",
  "payload": {
    "base": "mesh",
    "hora": "2026-08-16T02:38:08.288Z",
    "version": "PostgreSQL 18.6"
  }
}
```

Sin conexion, HTTP 503:

```json
{
  "ok": false,
  "mensaje": "No se pudo conectar con PostgreSQL",
  "payload": null
}
```

Probado apagando y encendiendo el contenedor:

```bash
docker stop mesh-postgres
curl http://localhost:3000/db
docker start mesh-postgres
```

---

## Como esta organizado el backend

```
src/
  controllers/       reciben la peticion y devuelven la respuesta
    admin/           controllers de /admin/*
  services/          la logica y las consultas
    admin/           services de /admin/*
  models/            la forma de cada tabla, tal cual existe en la base de datos
  dto/               formas que solo existen dentro de la app (peticiones, respuestas, el token)
  helpers/           utilidades compartidas
  guards/            deciden si una peticion puede pasar antes de llegar al controlador
  decorators/        atajos para leer datos dentro de un controller o marcar una ruta
  database/          la conexion
  types/             ampliaciones de tipos de librerias externas (nada que se ejecute)
```

`admin/` es una subcarpeta dentro de `controllers/` y otra dentro de
`services/`, no una carpeta aparte a su mismo nivel: asi todo lo que recibe
una peticion sigue estando en `controllers/` (facil de recorrer completo),
y adentro se nota de un vistazo cual es para el usuario normal y cual es
solo para un admin.

Las carpetas usan los nombres estandar del framework (o los mas parecidos:
Nest no trae una carpeta "guards" ni "decorators" por defecto, pero es como
las llama su propia documentacion). Todo lo que escribimos nosotros
(archivos, clases y funciones) esta en espanol.

### Guards y decorators (sesion y permisos)

No hay middleware clasico en este proyecto: proteger una ruta se hace con
un **Guard**, que en Nest corre antes del controller y ya sabe a que ruta
va la peticion (un middleware normal no lo sabe).

Desde el 2026-10-28 (migracion 050, ADR-26 en `docs/DECISIONES.md`) son dos
guards en fila. `SesionGuard` dice QUIEN es (401 si nadie). `PermisoGuard` dice
QUE PUEDE: cada ruta declara su accion con `@Permiso('modulo.accion')` y el guard
le pregunta a la tabla `rol_permiso` si el rol de la cuenta la tiene (403 si
no). Los `@Roles(...)` de antes ya no existen; la semilla de la 050 deja pasar a
los mismos roles que ellos, ruta por ruta. Donde los demas `endpoints-*.md`
dicen "`SesionGuard` + `@Roles(ID_ROL_ADMIN)`", hoy es `PermisoGuard` con un
permiso que en `rol_permiso` solo tiene el admin: quien entra es lo mismo.

| Archivo | Que es |
|---|---|
| `guards/sesion.guard.ts` | `SesionGuard`. Lee la cookie del token, la verifica y revisa que la cuenta siga activa (401) |
| `guards/permiso.guard.ts` | `PermisoGuard`. Lee el `@Permiso` de la ruta y le pregunta a `rol_permiso` (403). Una ruta con este guard y sin `@Permiso` tambien se niega |
| `decorators/permiso.decorator.ts` | `@Permiso('ofertas.publicar')`, en la clase o en el metodo (el del metodo manda) |
| `models/permiso.ts` | la lista de los codigos, tipada: un codigo mal escrito no compila |
| `services/acl/permisos.service.ts` | la consulta, el registro de los negados (`auditoria_permiso`) y la API de `/admin/permisos` |
| `decorators/usuario-actual.decorator.ts` | `@UsuarioActual()`, le da al controller el usuario que `SesionGuard` ya verifico |
| `types/fastify.d.ts` | le agrega el campo `usuario` al `request` de Fastify, para que `SesionGuard` lo pueda guardar ahi |

Para proteger una ruta:

```ts
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('cuenta.ver')
@Get('yo')
obtenerYo(@UsuarioActual() usuario: TokenUsuario) { ... }
```

Lo normal es ponerlo en la clase, para que proteja todas las rutas del
controller de una sola vez, y en el metodo solo lo que cambia:

```ts
@Controller('admin/usuarios')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('usuarios.ver')
export class AdminUsuariosController {
  @Get() listar() { ... }                      // usuarios.ver
  @Permiso('usuarios.editar')
  @Patch(':id') actualizar() { ... }          // usuarios.editar
}
```

Una accion nueva va en `models/permiso.ts` y en una migracion que la inserte en
`permiso` y le de `rol_permiso` a los roles que tocan.
`node pruebas/permisos_cobertura.cjs` revisa que cada ruta privada tenga el
guard y un permiso que exista en la base.

Ningun guard se registra en `app.module.ts`: Nest los instancia cuando los ve en
un `@UseGuards(...)` (`PermisosService` si va en providers).

Detalle tecnico: `PermisoGuard` busca la metadata con
`reflector.getAllAndOverride(...)`, revisando primero el metodo y despues la
clase. Si buscara solo el metodo, un `@Permiso(...)` puesto en la clase nunca se
encontraria. Con `@Roles` esto paso de verdad al construir `/admin/usuarios`:
cualquiera logueado, sin importar el rol, pasaba el guard. Aqui no pasaria en
silencio: sin permiso encontrado la ruta se niega.

### Cada archivo y que hace

| Archivo | Que contiene |
|---|---|
| `main.ts` | arranca el servidor en el puerto 3000 |
| `app.module.ts` | la lista de controladores y servicios que existen |
| `controllers/inicio.controller.ts` | `InicioController`, la ruta `GET /` |
| `controllers/base-datos.controller.ts` | `BaseDatosController`, la ruta `GET /db` |
| `services/inicio.service.ts` | `InicioService`, devuelve el estado de la API |
| `services/base-datos.service.ts` | `BaseDatosService`, consulta a PostgreSQL |
| `helpers/respuesta.ts` | `exito()` y `fallo()`, arman el formato de respuesta |
| `database/postgres.ts` | `pool`, la conexion a PostgreSQL |

### Los modelos

`models/` es solo lo que existe en la base de datos: una interfaz por cada
tabla, con el mismo nombre y las mismas columnas. Si no hay un `CREATE
TABLE` para algo, su interfaz no va aqui.

| Archivo | Interfaz | Tabla |
|---|---|---|
| `models/usuario.ts` | `Usuario` | `usuarios` |
| `models/rol-usuario.ts` | `RolUsuario` | `rol_usuario` |
| `models/estado-usuario.ts` | `EstadoUsuario` | `estado_usuario` |
| `models/tipo-login.ts` | `TipoLogin` | `tipo_login` |
| `models/log-login.ts` | `LogLogin` | `log_login` |
| `models/log-registro.ts` | `LogRegistro` | `log_registro` |
| `models/estado-direccion.ts` | `EstadoDireccion` | `estado_direccion` |
| `models/direccion.ts` | `Direccion` | `direcciones` |
| `models/direccion-historial.ts` | `DireccionHistorial` | `direccion_historial` |

Los `id` de las tablas grandes van tipados como `string` y no como `number`.
Son `bigserial`, y el driver `pg` entrega los `bigint` como texto para no perder
precision. Si se declaran `number`, una comparacion como `id === 1` falla en
silencio porque lo que llega es `"1"`. Los catalogos si van como `number`
porque son `smallserial`.

### Los DTO

`dto/` es todo lo demas: formas de datos que la app usa para funcionar pero
que no son ninguna tabla. Cuerpos de peticion, respuestas armadas a partir
de una o varias tablas, y el payload del token de sesion.

| Archivo | Interfaz | Que es |
|---|---|---|
| `dto/estado-api.ts` | `EstadoApi` | respuesta de `GET /` |
| `dto/info-conexion.ts` | `InfoConexion` | respuesta de `GET /db` |
| `dto/registro-usuario.ts` | `RegistroUsuarioPeticion`, `UsuarioRegistrado` | cuerpo y respuesta de `POST /usuario/registro` (`UsuarioRegistrado` tambien la usan login y `GET /usuario/yo`) |
| `dto/existencia-usuario.ts` | `ExistenciaUsuario` | respuesta de `GET /usuario/registros-existentes` |
| `dto/login-usuario.ts` | `LoginUsuarioPeticion` | cuerpo de `POST /usuario/login` |
| `dto/token-usuario.ts` | `TokenUsuario` | lo que va firmado dentro del JWT |

Una forma rapida de saber donde va algo nuevo: si tiene un `CREATE TABLE`
en `migrations/`, es un modelo. Si no, es un DTO.

### El log de autenticacion (coleccion `eventos_autenticacion` de Mongo)

`services/log.service.ts` (`LogService`) escribe la coleccion
**`eventos_autenticacion` de MongoDB** — un documento por cada `login`
(exitoso **y fallido**), `logout` y `registro`. Modelo en
`models/evento-autenticacion.ts`. Lo llama `UsuarioController`, que arma un
`ContextoPeticion` (`helpers/contexto-peticion.ts`: `ip`, `user_agent` y
`huella_cliente` = SHA-256 de `user-agent` + `accept-language`) y se lo
pasa junto con el `id_usuario`, el identificador tecleado y — en los
fallos de login — el `motivo` fino (`credenciales_invalidas`,
`usuario_inexistente`, `cuenta_inactiva`, `datos_invalidos`). Ese motivo
sale de `ErrorInicioSesion` (en `helpers/errores.ts`) y **nunca** llega a
la respuesta HTTP: el cliente recibe el mismo 401 generico en los tres
casos de credenciales, para no revelar que cuentas existen.

Nunca lanza error, y el controlador lo llama **sin `await`**: guardar el
evento es best-effort y no debe retrasar ni tumbar el login. Con Mongo
caido, `insertOne` tarda hasta 3 s en rendirse (`serverSelectionTimeoutMS`,
ver `database/mongo.ts`), asi que el login no espera eso — el detalle queda
en el log del servidor (`ERROR [LogService]`) y los eventos de una caida
larga se pierden. Detalle y pruebas en
`cambio_propuestas/2026-09-10_0906-eventos-autenticacion-mongo.md`.

Para el `logout`: `POST /usuario/logout` no tiene `SesionGuard` (tiene que
funcionar aunque el token ya haya vencido), asi que antes de borrar la
cookie intenta verificar el token nada mas para saber a quien atribuirle
el evento. Si no hay cookie, o el token ya no sirve, no se guarda nada — la
ruta responde 200 igual.

**Las tablas `log_login` / `log_registro` de PostgreSQL siguen existiendo
pero el backend ya no las escribe** (los modelos `models/log-login.ts` y
`log-registro.ts` quedan sin usar). El ETL de ClickHouse que las leia queda
pendiente de repuntar a Mongo — lo coordina el equipo, ver
`plan pendiente/fraude-login-eventos.md`.

Ojo con esto al limpiar datos de prueba a mano: `usuarios` tiene `ON DELETE
RESTRICT` desde `log_login` y `log_registro`, asi que no se puede borrar un
usuario que ya tenga logs **viejos** (de antes de este cambio) sin borrar
esas filas primero — un usuario creado ahora ya no genera ninguna. Lo mismo pasa con
`direcciones` y `direccion_historial`.

### Transacciones (crear una direccion)

`POST /direccion-usuario` es la primera ruta que necesita dos `INSERT` que
tienen que pasar juntos o no pasar ninguno: crear la fila en `direcciones`
y su primera version en `direccion_historial`. Para eso `pool.query(...)`
no alcanza (cada llamada podria ir a una conexion distinta del pool);
`DireccionUsuarioService.crear()` pide un cliente dedicado con
`pool.connect()` y hace `BEGIN` / `COMMIT`, con un `ROLLBACK` en el catch
si algo sale mal. El cliente se libera en un `finally`, para devolverlo al
pool pase lo que pase.

Si algun dia otra ruta necesita "dos o mas escrituras que van juntas",
este metodo es el ejemplo a seguir.

### El recorrido de una peticion

```
navegador  ->  GET /db
  ->  BaseDatosController   recibe la peticion
  ->  BaseDatosService      hace la consulta
  ->  pool                  toma una conexion del grupo
  ->  PostgreSQL            responde
  <-  regresa como JSON
```

El controlador no tiene logica: recibe, llama al servicio y devuelve. Toda la
logica vive en el servicio. Por eso el controlador siempre es corto.

### Que es el pool

`database/postgres.ts` crea un pool de conexiones: un grupo de conexiones ya
abiertas que se reutilizan. Abrir una conexion nueva en cada consulta seria
lento, asi que el pool las mantiene listas y las va prestando.

Ese archivo tambien escucha el evento `error` del pool. No es opcional: cuando
PostgreSQL se apaga, el pool avisa que perdio una conexion en reposo, y en Node
un evento `error` que nadie escucha mata el proceso. Sin ese listener, apagar la
base tumbaba el backend completo.

Probado apagando el contenedor con el backend corriendo: `GET /db` responde 503
y `GET /` sigue respondiendo 200. Al encender la base otra vez, `GET /db` vuelve
a 200 solo, sin reiniciar nada.
