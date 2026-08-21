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
  controllers/   reciben la peticion y devuelven la respuesta
  services/      la logica y las consultas
  models/        la forma de cada tabla y de cada respuesta
  helpers/       utilidades compartidas
  middlewares/   codigo que corre antes de llegar al controlador
  database/      la conexion
```

Las carpetas usan los nombres estandar del framework. Todo lo que escribimos
nosotros (archivos, clases y funciones) esta en espanol.

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

Uno por cada tabla de la base, con el mismo nombre.

| Archivo | Interfaz | Tabla |
|---|---|---|
| `models/usuario.ts` | `Usuario` | `usuarios` |
| `models/rol-usuario.ts` | `RolUsuario` | `rol_usuario` |
| `models/estado-usuario.ts` | `EstadoUsuario` | `estado_usuario` |
| `models/tipo-login.ts` | `TipoLogin` | `tipo_login` |
| `models/log-login.ts` | `LogLogin` | `log_login` |
| `models/log-registro.ts` | `LogRegistro` | `log_registro` |
| `models/estado-api.ts` | `EstadoApi` | ninguna, es la respuesta de `GET /` |
| `models/info-conexion.ts` | `InfoConexion` | ninguna, es la respuesta de `GET /db` |

Los `id` de las tablas grandes van tipados como `string` y no como `number`.
Son `bigserial`, y el driver `pg` entrega los `bigint` como texto para no perder
precision. Si se declaran `number`, una comparacion como `id === 1` falla en
silencio porque lo que llega es `"1"`. Los catalogos si van como `number`
porque son `smallserial`.

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
