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

### Guards y decorators (sesion)

No hay middleware clasico en este proyecto: proteger una ruta se hace con
un **Guard**, que en Nest corre antes del controller y ya sabe a que ruta
va la peticion (un middleware normal no lo sabe).

| Archivo | Que es |
|---|---|
| `guards/sesion.guard.ts` | `SesionGuard`. Lee la cookie del token, la verifica, y si la ruta tiene `@Roles(...)` tambien revisa el rol |
| `decorators/roles.decorator.ts` | `@Roles(...ids)`, marca una ruta como restringida a ciertos `id_rol_usuario` |
| `decorators/usuario-actual.decorator.ts` | `@UsuarioActual()`, le da al controller el usuario que `SesionGuard` ya verifico |
| `types/fastify.d.ts` | le agrega el campo `usuario` al `request` de Fastify, para que `SesionGuard` lo pueda guardar ahi |

Para proteger una ruta:

```ts
@UseGuards(SesionGuard)
@Get('yo')
obtenerYo(@UsuarioActual() usuario: TokenUsuario) { ... }
```

Y para ademas restringirla a un rol (por ejemplo, solo admin), lo normal es
ponerlo en la clase, para que proteja todas las rutas del controller de
una sola vez:

```ts
@Controller('admin/usuarios')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class AdminUsuariosController { ... }
```

`SesionGuard` no se registra en `app.module.ts`: Nest lo instancia solo
cuando lo ve en un `@UseGuards(...)`.

Detalle tecnico si algun dia `@Roles(...)` da problemas: adentro,
`SesionGuard` busca esa metadata con `reflector.getAllAndOverride(...)`
revisando primero el metodo y despues la clase. Si buscara solo el metodo
(`reflector.get(ROLES_KEY, contexto.getHandler())`), un `@Roles(...)`
puesto en la clase nunca se encontraria y la restriccion de rol quedaria
sin efecto en silencio, aunque el token siga verificandose bien. Esto paso
de verdad al construir `/admin/usuarios`: cualquiera logueado, sin importar
el rol, pasaba el guard.

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

### Los logs (log_registro, log_login)

`services/log.service.ts` (`LogService`) escribe en esas dos tablas. Las
llama `UsuarioController`, no `UsuarioService`: despues de que `registrar()`
o `iniciarSesion()` ya tuvieron exito, el controller le pasa el id del
usuario y la IP de la peticion (`request.ip`, de Fastify).

Nunca lanza error. Si el `INSERT` del log falla, se loguea el detalle
tecnico y ahi se queda: un log que no se pudo guardar no puede tumbar un
registro, un login o un logout que si funcionaron. Por eso no cambia nada
de la respuesta que ya devolvian esas rutas.

`log_login` guarda entradas y salidas (`login` y `logout`). Para el logout
hay un detalle: `POST /usuario/logout` no tiene `SesionGuard` (tiene que
funcionar aunque el token ya haya vencido), asi que antes de borrar la
cookie intenta verificar el token nada mas para saber a quien atribuirle
el logout. Si no hay cookie, o el token ya no sirve, simplemente no se
guarda ese log — la ruta sigue respondiendo 200 igual, cerrar sesion nunca
depende de que el log se haya podido escribir.

Ojo con esto al limpiar datos de prueba a mano: `usuarios` tiene `ON DELETE
RESTRICT` desde `log_login` y `log_registro`, asi que no se puede borrar un
usuario que ya tenga logs sin borrar esas filas primero.

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
