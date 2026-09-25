# Endpoints

## GET /

**200**

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

---

## GET /db

**200**

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

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

---

## GET /documental

**200**

```json
{
  "ok": true,
  "mensaje": "Conexion establecida con MongoDB",
  "payload": {
    "base": "mesh",
    "version": "MongoDB 8.2.12"
  }
}
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

---

## GET /clave-valor

Comprueba la conexion con **Redis** (el almacen clave-valor: carrito y
oferta limitada de la Entrega 2). Mismo patron que `GET /db` y
`GET /documental`. No lee ni escribe ninguna clave, solo hace `PING` +
`INFO server`. Si Redis no responde en 5 s, corta con 503 (no se queda
colgada).

**200**

```json
{
  "ok": true,
  "mensaje": "Conexion establecida con Redis",
  "payload": {
    "version": "8.10.1",
    "modo": "standalone"
  }
}
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
```

---

## GET /grafo

Comprueba la conexion con **Neo4j** (el grafo de deteccion de fraude de la
Entrega 2). Mismo patron. Verifica la conexion Bolt y de paso cuenta los
nodos: `nodos: 0` significa que conecta pero el grafo esta vacio (falta
correr `etl/cargar_grafo.sh`). Timeout de 6 s -> 503.

**200**

```json
{
  "ok": true,
  "mensaje": "Conexion establecida con Neo4j",
  "payload": {
    "version": "Neo4j/5.26.30",
    "nodos": 150
  }
}
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con Neo4j", "payload": null }
```

> El **panel de fraude** que consume este grafo
> (`GET`/`PATCH /admin/fraude/alertas-resenas` y `GET .../:id/detalle-grafo`,
> solo admin, controller y servicio aparte, alimentados por el worker
> `AnillosDetectorService`), la **conciliación** del grafo con
> PostgreSQL (`GET /admin/grafo/conciliacion`, solo admin) y las **alertas
> de fraude de login** -- nueve señales: fuerza bruta / multi-cuenta /
> rotación de IP con contadores de Redis, más toma de cuenta, viaje
> imposible y tres patrones lentos/repartidos (los mismos tres, en ventana
> de 24h) consultados contra Elasticsearch
> (`GET /admin/fraude/alertas-login`, solo admin -- no toca el grafo) están
> documentados aparte, en `endpoints-fraude.md`.

---

## GET /buscador

Comprueba la conexion con **Elasticsearch** (el motor de busqueda de la
Entrega 3). Mismo patron que `GET /documental`, `GET /clave-valor` y
`GET /grafo`. De paso cuenta los documentos del indice `mesh_productos`:
`documentos: 0` significa que conecta pero el indice esta vacio o no existe
todavia (falta correr `etl/cargar_busqueda.sh`) -- eso NO se trata como una
caida, solo como "no hay nada que buscar". Timeout de 6 s -> 503.

**200**

```json
{
  "ok": true,
  "mensaje": "Conexion establecida con Elasticsearch",
  "payload": {
    "version": "8.15.3",
    "estado_cluster": "green",
    "documentos": 102
  }
}
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con Elasticsearch", "payload": null }
```

> La ruta que de verdad **busca productos**, `GET /buscador/productos`, esta
> documentada aparte, en `endpoints-buscador.md`.

---

> **`POST /eventos/vista`** (pública), **`POST /eventos/carrito`** (exige
> sesión) y **`POST /eventos/busqueda-clic`** (pública) -- registran en
> ClickHouse que alguien vio la ficha de un producto, lo agregó al carrito,
> o hizo clic en un resultado de búsqueda (fire-and-forget, `202`). Las
> seis piezas del plan de eventos de producto/buscador ya están
> construidas -- las otras tres (compra, devolución, búsqueda realizada)
> no tienen ruta propia, van directo enganchadas al código existente.
> `GET /admin/eventos/*` (seis rutas, solo admin) expone el ranking de
> tendencias de cada tabla (agrupado por producto o por término, "los
> primeros M" o "los últimos M" de "N" días hacia atrás) -- ya no filas
> crudas, esa versión se reemplazó por completo. Todo documentado en
> `endpoints-eventos.md`.
>
> **`GET /productos/mas-vendidos`** (pública, sin sesión) -- el ranking de
> productos más vendidos, calculado agregando `compra_producto` de
> ClickHouse cada 10 minutos (`MasVendidosSyncService`) y publicado en un
> ZSET de Redis; la ruta lee ese ZSET y trae el detalle real a MongoDB.
> Documentado en `endpoints-productos.md`.
>
> **`GET /admin/eventos/tendencias|embudo|busquedas-sin-respuesta`**
> (agregado 2026-09-25, solo admin) -- las tres consultas de "Tendencias"
> de la propuesta de fraude del compañero (`docs/fraude-entrega3/`, T1-T3):
> productos en ascenso, embudo vista→carrito→compra→devolución con
> diagnóstico, y términos buscados sin respuesta. Controller y servicio
> separados de `AdminTendenciasController` (`AdminTendenciasAvanzadasController`/
> `Service`), aunque comparten el prefijo `/admin/eventos`. Documentado en
> `endpoints-eventos.md`.
>
> **`GET /productos/vistos-recientemente`** (pública, sesión opcional),
> **`GET /productos/:id/tambien-vieron`** (pública) y
> **`GET /productos/para-ti`** (requiere sesión) -- las tres primeras
> consultas de "Recomendaciones" de la misma propuesta (R1-R3). R1 se
> calcula al pedir; R2 y R3 nunca calculan en vivo, leen de Redis lo que
> dejó `TambienVieronSyncService`/`ParaTiSyncService` (cada 15 min, mismo
> principio que `mas-vendidos`). R4 (similares) queda pendiente -- depende
> de que Mongo arme la lista de candidatos por categoría/precio.
> Documentado en `endpoints-productos.md`.

---

## POST /usuario/registro

Cuerpo:

```json
{
  "correo_electronico": "ana@correo.com",
  "usuario": "ana99",
  "nombre": "Ana",
  "apellido": "Gomez",
  "contrasena": "unaClaveLarga123",
  "fecha_nacimiento": "2000-05-14"
}
```

`apellido` y `fecha_nacimiento` son opcionales. Entra siempre como rol
`comprador` y estado `activo`.

**201**

```json
{
  "ok": true,
  "mensaje": "Usuario registrado correctamente",
  "payload": {
    "id_usuario": "1",
    "correo_electronico": "ana@correo.com",
    "usuario": "ana99",
    "nombre": "Ana",
    "apellido": "Gomez",
    "fecha_nacimiento": "2000-05-14",
    "fecha_creacion": "2026-08-21T20:10:00.000Z",
    "id_rol_usuario": 1,
    "id_estado_usuario": 1
  }
}
```

**400**

```json
{ "ok": false, "mensaje": "El correo electronico es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El correo electronico no puede tener mas de 255 caracteres", "payload": null }
{ "ok": false, "mensaje": "El correo electronico no es valido", "payload": null }
{ "ok": false, "mensaje": "El usuario es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El usuario no puede tener mas de 50 caracteres", "payload": null }
{ "ok": false, "mensaje": "El nombre es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El nombre no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "El apellido no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "La contrasena es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La contrasena debe tener al menos 8 caracteres", "payload": null }
{ "ok": false, "mensaje": "La contrasena debe tener al menos una letra mayuscula", "payload": null }
{ "ok": false, "mensaje": "La contrasena debe tener al menos un caracter especial", "payload": null }
{ "ok": false, "mensaje": "La fecha de nacimiento debe tener el formato AAAA-MM-DD", "payload": null }
{ "ok": false, "mensaje": "La fecha de nacimiento no es valida", "payload": null }
{ "ok": false, "mensaje": "El usuario debe ser mayor de 18 anos", "payload": null }
```

**409**

```json
{ "ok": false, "mensaje": "El correo electronico ya esta registrado", "payload": null }
{ "ok": false, "mensaje": "El usuario ya esta registrado", "payload": null }
{ "ok": false, "mensaje": "El correo electronico y el usuario ya estan registrados", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo registrar el usuario", "payload": null }
```

---

## GET /usuario/registros-existentes

Query params: `correo`, `usuario`. Ambos opcionales, pero al menos uno debe
venir.

```
GET /usuario/registros-existentes?correo=ana@correo.com&usuario=ana99
```

**200**

```json
{
  "ok": true,
  "mensaje": "Disponibilidad consultada",
  "payload": {
    "correo_existente": false,
    "usuario_existente": true
  }
}
```

**400**

```json
{ "ok": false, "mensaje": "Debes indicar un correo electronico o un usuario a verificar", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo verificar el usuario", "payload": null }
```

---

## POST /usuario/login

Cuerpo:

```json
{
  "identificador": "ana@correo.com",
  "contrasena": "unaClaveLarga123"
}
```

`identificador` puede ser el correo electronico o el usuario; el backend
revisa contra los dos.

Si las credenciales son correctas, ademas de la respuesta deja una cookie
`mesh_token` (httpOnly, 2 horas) con el token de sesion.

**200**

```json
{
  "ok": true,
  "mensaje": "Sesion iniciada correctamente",
  "payload": {
    "id_usuario": "1",
    "correo_electronico": "ana@correo.com",
    "usuario": "ana99",
    "nombre": "Ana",
    "apellido": "Gomez",
    "fecha_nacimiento": "2000-05-14",
    "fecha_creacion": "2026-08-21T20:10:00.000Z",
    "id_rol_usuario": 1,
    "id_estado_usuario": 1
  }
}
```

**400**

```json
{ "ok": false, "mensaje": "El correo electronico o el usuario es obligatorio", "payload": null }
{ "ok": false, "mensaje": "La contrasena es obligatoria", "payload": null }
```

**401** — mismo mensaje si el identificador no existe, si la contrasena no
coincide, o si la cuenta no esta activa (`id_estado_usuario` distinto de
activo). A proposito: no hay forma de usar esta ruta para averiguar que
correos o usuarios estan registrados, ni cuales estan suspendidos. (El
motivo real de cada fallo si se guarda, pero solo en el log de seguridad —
coleccion `eventos_autenticacion` de Mongo, ver `api.md` — nunca en la
respuesta.)

```json
{ "ok": false, "mensaje": "Correo electronico, usuario o contrasena incorrectos", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo iniciar sesion", "payload": null }
```

---

## POST /usuario/logout

Sin cuerpo. Borra la cookie `mesh_token`. Funciona aunque no hubiera sesion
o el token ya estuviera vencido.

**200**

```json
{ "ok": true, "mensaje": "Sesion cerrada", "payload": null }
```

---

## GET /usuario/yo

Requiere la cookie `mesh_token` (la deja `POST /usuario/login`). Devuelve el
perfil de quien esta logueado.

En cada peticion, ademas de verificar el token, se revisa que la cuenta siga
activa en la base ahora mismo (no solo en el momento del login): si la
suspenden mientras el token todavia es valido, esta ruta empieza a rechazar
de inmediato, sin esperar a que el token venza solo.

**200**

```json
{
  "ok": true,
  "mensaje": "Sesion activa",
  "payload": {
    "id_usuario": "1",
    "correo_electronico": "ana@correo.com",
    "usuario": "ana99",
    "nombre": "Ana",
    "apellido": "Gomez",
    "fecha_nacimiento": "2000-05-14",
    "fecha_creacion": "2026-08-21T20:10:00.000Z",
    "id_rol_usuario": 1,
    "id_estado_usuario": 1
  }
}
```

**401** — no hay cookie, o el token no es valido, o ya vencio:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo obtener el usuario", "payload": null }
```

---

## GET /admin/usuarios

Requiere la cookie `mesh_token` **y** rol admin (`id_rol_usuario` 3). Trae
todos los usuarios menos el admin que hace la peticion. No filtra por
estado: tambien salen las cuentas inactivas o suspendidas, para que se
puedan gestionar.

**200**

```json
{
  "ok": true,
  "mensaje": "Usuarios obtenidos",
  "payload": [
    {
      "id_usuario": "2",
      "correo_electronico": "ana@correo.com",
      "usuario": "ana99",
      "nombre": "Ana",
      "apellido": "Gomez",
      "fecha_nacimiento": "2000-05-14",
      "fecha_creacion": "2026-08-21T20:10:00.000Z",
      "id_rol_usuario": 1,
      "id_estado_usuario": 1
    }
  ]
}
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**403** — hay sesion, pero el rol no es admin:

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo obtener la lista de usuarios", "payload": null }
```

---

## PATCH /admin/usuarios/:id

Requiere la cookie `mesh_token` y rol admin. Edita `nombre`, `apellido`,
`fecha_nacimiento`, `id_rol_usuario` y/o `id_estado_usuario` de cualquier
**otro** usuario (un admin no puede editarse a si mismo con esta ruta),
**excepto la cuenta de la tienda** (`tienda@mesh.com`), que esta
bloqueada por completo — ver la nota de abajo. Cada campo es
independiente: el que venga en `null` (o no venga) no se toca. Debe venir
al menos uno.

**Bloqueo total sobre la cuenta de la tienda** (agregado el 26 de agosto
de 2026): ningun admin puede editar `tienda@mesh.com` desde aqui, ni
siquiera `nombre` o `apellido` — no solo `id_rol_usuario`/
`id_estado_usuario`. Medio catálogo depende de que esa cuenta exista,
siga con su correo exacto, su rol vendedor y su estado activo
(`CORREO_TIENDA`, `ProductosVendedorService.exigirTiendaOAdmin()`,
`OfertasVendedorService.resolverIdEfectivo()`, la bandera `es_tienda` y
los campos calculados `precio_tienda`/`stock_tienda` del catálogo
público) — cambiarle el rol la dejaría con 403 en sus propias rutas de
`/vendedor/*`, y desactivarla le impediría volver a loguearse (el login
revisa `id_estado_usuario`). `correo_electronico` y `usuario` ya estaban
protegidos de por sí (`EditarUsuarioAdminPeticion` ni siquiera los
acepta); este bloqueo cierra el resto de la cuenta también, con el mismo
tipo de error (400) que ya usa el bloqueo de auto-edición.

`nombre`, `apellido` y `fecha_nacimiento` usan exactamente las mismas
reglas que `POST /usuario/registro` (mismos mensajes de error incluidos),
para que un dato nunca sea valido al registrarse e invalido al editarlo, o
al reves. `id_rol_usuario` e `id_estado_usuario` se revisan contra los
catalogos de `GET /admin/roles` y `GET /admin/estados`: un id que no existe
ahi no sirve.

```json
{
  "nombre": "Ana",
  "apellido": null,
  "fecha_nacimiento": "2000-05-14",
  "id_rol_usuario": 2,
  "id_estado_usuario": null
}
```

**200**

```json
{
  "ok": true,
  "mensaje": "Usuario actualizado correctamente",
  "payload": {
    "id_usuario": "2",
    "correo_electronico": "ana@correo.com",
    "usuario": "ana99",
    "nombre": "Ana",
    "apellido": "Gomez",
    "fecha_nacimiento": "2000-05-14",
    "fecha_creacion": "2026-08-21T20:10:00.000Z",
    "id_rol_usuario": 1,
    "id_estado_usuario": 1
  }
}
```

**400**

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "No puedes editar tu propia cuenta desde aqui", "payload": null }
{ "ok": false, "mensaje": "No se puede editar la cuenta de la tienda desde aqui", "payload": null }
{ "ok": false, "mensaje": "Debes enviar al menos un campo para actualizar", "payload": null }
{ "ok": false, "mensaje": "El nombre es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El nombre no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "El apellido no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "La fecha de nacimiento debe tener el formato AAAA-MM-DD", "payload": null }
{ "ok": false, "mensaje": "La fecha de nacimiento no es valida", "payload": null }
{ "ok": false, "mensaje": "El usuario debe ser mayor de 18 anos", "payload": null }
{ "ok": false, "mensaje": "El rol no es valido", "payload": null }
{ "ok": false, "mensaje": "El estado no es valido", "payload": null }
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**403** — hay sesion, pero el rol no es admin:

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

**404** — no existe un usuario con ese id:

```json
{ "ok": false, "mensaje": "No existe un usuario con ese id", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo actualizar el usuario", "payload": null }
```

---

## GET /admin/roles

Requiere la cookie `mesh_token` y rol admin. Trae el catalogo completo de
`rol_usuario`, para armar selects en el frontend con los ids reales.

**200**

```json
{
  "ok": true,
  "mensaje": "Roles obtenidos",
  "payload": [
    { "id_rol_usuario": 1, "rol_usuario_nombre": "comprador" },
    { "id_rol_usuario": 2, "rol_usuario_nombre": "vendedor" },
    { "id_rol_usuario": 3, "rol_usuario_nombre": "admin" }
  ]
}
```

**401** / **403** — mismos casos que las demas rutas de `/admin/*`.

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo obtener los roles", "payload": null }
```

---

## GET /admin/estados

Requiere la cookie `mesh_token` y rol admin. Trae el catalogo completo de
`estado_usuario`.

**200**

```json
{
  "ok": true,
  "mensaje": "Estados obtenidos",
  "payload": [
    { "id_estado_usuario": 1, "estado_usuario_nombre": "activo" },
    { "id_estado_usuario": 2, "estado_usuario_nombre": "inactivo" },
    { "id_estado_usuario": 3, "estado_usuario_nombre": "suspendido" }
  ]
}
```

**401** / **403** — mismos casos que las demas rutas de `/admin/*`.

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo obtener los estados", "payload": null }
```

---

## GET /perfil

Requiere la cookie `mesh_token` (cualquier usuario logueado, no solo
admin). Es distinta de `GET /usuario/yo`: trae los mismos datos, mas el
nombre del rol y del estado (no solo el id), para mostrarlos directo en un
perfil sin tener que ir a `/admin/roles` o `/admin/estados` (que ademas son
solo para admin).

**200**

```json
{
  "ok": true,
  "mensaje": "Perfil obtenido",
  "payload": {
    "id_usuario": "1",
    "correo_electronico": "ana@correo.com",
    "usuario": "ana99",
    "nombre": "Ana",
    "apellido": "Gomez",
    "fecha_nacimiento": "2000-05-14",
    "fecha_creacion": "2026-08-21T20:10:00.000Z",
    "id_rol_usuario": 1,
    "id_estado_usuario": 1,
    "rol_usuario_nombre": "comprador",
    "estado_usuario_nombre": "activo"
  }
}
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo obtener el perfil", "payload": null }
```

---

## PATCH /perfil

Requiere la cookie `mesh_token`. Deja que el usuario cambie su propio
`nombre` y/o `apellido`. Cada campo es independiente: el que venga en
`null` (o no venga) no se toca. Debe venir al menos uno.

Mismas reglas y mensajes que en `POST /usuario/registro` (comparten
`validarNombre` y `validarApellido`).

```json
{
  "nombre": "Ana",
  "apellido": null
}
```

**200**

```json
{
  "ok": true,
  "mensaje": "Perfil actualizado correctamente",
  "payload": {
    "id_usuario": "1",
    "correo_electronico": "ana@correo.com",
    "usuario": "ana99",
    "nombre": "Ana",
    "apellido": "Gomez",
    "fecha_nacimiento": "2000-05-14",
    "fecha_creacion": "2026-08-21T20:10:00.000Z",
    "id_rol_usuario": 1,
    "id_estado_usuario": 1,
    "rol_usuario_nombre": "comprador",
    "estado_usuario_nombre": "activo"
  }
}
```

**400**

```json
{ "ok": false, "mensaje": "Debes enviar al menos un campo para actualizar", "payload": null }
{ "ok": false, "mensaje": "El nombre es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El nombre no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "El apellido no puede tener mas de 100 caracteres", "payload": null }
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo actualizar el perfil", "payload": null }
```

---

## PATCH /perfil/contrasena

Requiere la cookie `mesh_token`. Cambia la propia contrasena. Pide la
actual (para confirmar identidad) y la nueva dos veces (contrasena y
confirmacion), para agarrar un error de tipeo.

La nueva contrasena sigue las mismas reglas que en el registro (8
caracteres minimo, una mayuscula, un caracter especial), y ademas tiene
que ser distinta de la actual.

```json
{
  "contrasena_actual": "ClaveVieja123!",
  "contrasena_nueva": "ClaveNueva456!",
  "contrasena_nueva_confirmacion": "ClaveNueva456!"
}
```

**200**

```json
{ "ok": true, "mensaje": "Contrasena actualizada correctamente", "payload": null }
```

**400**

```json
{ "ok": false, "mensaje": "La contrasena actual es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La nueva contrasena es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La confirmacion de la nueva contrasena es obligatoria", "payload": null }
{ "ok": false, "mensaje": "Las contrasenas nuevas no coinciden", "payload": null }
{ "ok": false, "mensaje": "La contrasena actual no es correcta", "payload": null }
{ "ok": false, "mensaje": "La nueva contrasena debe ser diferente a la actual", "payload": null }
{ "ok": false, "mensaje": "La contrasena debe tener al menos 8 caracteres", "payload": null }
{ "ok": false, "mensaje": "La contrasena debe tener al menos una letra mayuscula", "payload": null }
{ "ok": false, "mensaje": "La contrasena debe tener al menos un caracter especial", "payload": null }
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo actualizar la contrasena", "payload": null }
```

---

## GET /perfil/alertas-fraude

Requiere la cookie `mesh_token`. Las alertas de fraude que le corresponden
al usuario logueado -- nunca recibe un id de cuenta por parametro, siempre
sale del token. Paginado (`pagina`/`limite`, mismas reglas que el resto
del proyecto), ordenado por `fecha_creacion` mas reciente primero. Lee la
tabla `notificacion_fraude` (una fila por cada cuenta a la que le
corresponde ver una alerta -- no una columna de `alerta_fraude`, ver
`endpoints-fraude.md` para el porque).

Aparecen las senales que ya traen la cuenta resuelta (`fuerza_bruta_cuenta`,
`ip_rotacion_cuenta` y sus `_lenta`, `toma_cuenta`, `viaje_imposible`) **y
tambien** `multi_cuenta_ip`/`multi_cuenta_ip_lenta` si esta cuenta fue una
de las que esa IP probo (con el `detalle` redactado: sin los
correos/usuarios de las DEMAS cuentas afectadas, solo el conteo). Solo
`fuerza_bruta_ip` sigue sin llegarle a nadie -- no trae una lista de
cuentas objetivo, sigue siendo solo para el panel de admin
(`GET /admin/fraude/alertas-login`, documentado en `endpoints-fraude.md`,
con el detalle completo del diseno). Cada fila trae `fecha_lectura` de LA
NOTIFICACION de esa cuenta (`null` = no leida).

**200**

```json
{
  "ok": true,
  "mensaje": "Alertas de fraude obtenidas",
  "payload": {
    "alertas": [
      {
        "id_alerta_fraude": "140",
        "tipo_alerta": "viaje_imposible",
        "clave": "usuario_afectado",
        "detalle": { "distancia_km": 14313, "velocidad_kmh": 80520 },
        "contador": 1,
        "ventana_inicio": "2026-09-15T17:34:00.000Z",
        "fecha_creacion": "2026-09-15T17:34:54.600Z",
        "fecha_lectura": null
      }
    ],
    "pagina": 1,
    "limite": 20,
    "total_alertas": 1,
    "total_paginas": 1
  }
}
```

**401** — no hay cookie, o el token no es valido:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
```

---

## PATCH /perfil/alertas-fraude/:id

Requiere la cookie `mesh_token`. Marca la NOTIFICACION de esta cuenta sobre
esa alerta como leida (`notificacion_fraude.fecha_lectura`) — idempotente,
si ya estaba leida no pisa la fecha original. El *ownership check* va en
el propio `UPDATE`: si no existe esa notificacion (la alerta no existe, o
existe pero esta cuenta nunca estuvo entre los afectados), el mismo `404`
generico en los dos casos, para no filtrar si una alerta ajena existe. En
una alerta con varios afectados (`multi_cuenta_ip`/`multi_cuenta_ip_lenta`),
cada cuenta marca la suya por separado — no es un estado compartido.

Sin cuerpo.

**200**

Misma forma que una fila del `GET`, con `fecha_lectura` ya puesta.

**400**

```json
{ "ok": false, "mensaje": "El id de la alerta debe ser un numero entero", "payload": null }
```

**401** — mismo criterio que el resto de `/perfil`.

**404**

```json
{ "ok": false, "mensaje": "No existe una alerta con ese id para tu cuenta", "payload": null }
```

**Pruebas — hechas el 2026-09-15.** Detalle completo (con tabla de casos)
en `endpoints-fraude.md`, seccion "GET /perfil/alertas-fraude y PATCH
/perfil/alertas-fraude/:id" — se documenta alli en vez de duplicarlo aqui
porque es la misma ronda de pruebas que las otras rutas de `alerta_fraude`.

---

## POST /direccion-usuario

Requiere la cookie `mesh_token`. Crea una direccion para el usuario
logueado (el id sale del token, no del cuerpo). Siempre entra con estado
activa, y de paso crea su primera fila en `direccion_historial` (el
snapshot inicial) — las dos cosas pasan juntas, en una sola transaccion.

```json
{
  "pais": "Guatemala",
  "departamento": "Guatemala",
  "ciudad": "Guatemala",
  "direccion_exacta": "4a. Avenida 12-34, Zona 10, Edificio Plaza, Oficina 502",
  "codigo_postal": "01001"
}
```

`direccion_exacta` es **obligatoria** — la calle, el numero, la zona y las
referencias en una sola linea; sin ella no se puede entregar un pedido.
Maximo 255 caracteres. `codigo_postal` sigue siendo opcional.

**201**

```json
{
  "ok": true,
  "mensaje": "Direccion creada correctamente",
  "payload": {
    "id_direccion": "1",
    "id_usuario": "23",
    "pais": "Guatemala",
    "departamento": "Guatemala",
    "ciudad": "Guatemala",
    "direccion_exacta": "4a. Avenida 12-34, Zona 10, Edificio Plaza, Oficina 502",
    "codigo_postal": "01001",
    "fecha_creacion": "2026-08-22T03:03:20.679Z",
    "id_estado_direccion": 1
  }
}
```

**400**

```json
{ "ok": false, "mensaje": "El pais es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El pais no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "El departamento es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El departamento no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "La ciudad es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La ciudad no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "La direccion exacta es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La direccion exacta no puede tener mas de 255 caracteres", "payload": null }
{ "ok": false, "mensaje": "El codigo postal no puede tener mas de 20 caracteres", "payload": null }
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo crear la direccion", "payload": null }
```

---

## PATCH /direccion-usuario/:id

Requiere la cookie `mesh_token`. Edita `pais`, `departamento`, `ciudad`,
`direccion_exacta` y/o `codigo_postal` de una direccion **propia**. Cada
campo es independiente: el que venga en `null` (o no venga) no se toca.
Debe venir al menos uno. `direccion_exacta`, si viene, no puede quedar
vacia ni pasar de 255 caracteres (aqui es opcional, a diferencia de
`POST`, donde es obligatoria).

Solo puede editar sus propias direcciones: una direccion de otro usuario
da el mismo 404 que un id que no existe (no hay forma de usar esta ruta
para confirmar que direcciones tiene otra persona).

Deja una fila nueva en `direccion_historial` con el estado **completo** de
la direccion despues del cambio (no solo los campos que llegaron en la
peticion) — es el mismo comportamiento de `POST /direccion-usuario`, en
una sola transaccion.

```json
{
  "pais": null,
  "departamento": null,
  "ciudad": "Mixco",
  "direccion_exacta": "7a. Calle 1-50, Zona 4, Casa 12",
  "codigo_postal": null
}
```

**200**

```json
{
  "ok": true,
  "mensaje": "Direccion actualizada correctamente",
  "payload": {
    "id_direccion": "3",
    "id_usuario": "24",
    "pais": "Guatemala",
    "departamento": "Guatemala",
    "ciudad": "Mixco",
    "direccion_exacta": "7a. Calle 1-50, Zona 4, Casa 12",
    "codigo_postal": "01001",
    "fecha_creacion": "2026-08-22T03:17:18.338Z",
    "id_estado_direccion": 1
  }
}
```

**400**

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "Debes enviar al menos un campo para actualizar", "payload": null }
{ "ok": false, "mensaje": "El pais es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El pais no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "El departamento es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El departamento no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "La ciudad es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La ciudad no puede tener mas de 100 caracteres", "payload": null }
{ "ok": false, "mensaje": "La direccion exacta es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La direccion exacta no puede tener mas de 255 caracteres", "payload": null }
{ "ok": false, "mensaje": "El codigo postal no puede tener mas de 20 caracteres", "payload": null }
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**404** — no existe una direccion con ese id (o no es tuya):

```json
{ "ok": false, "mensaje": "No existe una direccion con ese id", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo actualizar la direccion", "payload": null }
```

---

## GET /direccion-usuario

Requiere la cookie `mesh_token`. Trae las direcciones vigentes del usuario
logueado, mas recientes primero. Solo las suyas: no hay forma de traer las
de otra persona.

**200**

```json
{
  "ok": true,
  "mensaje": "Direcciones obtenidas",
  "payload": [
    {
      "id_direccion": "4",
      "id_usuario": "27",
      "pais": "Guatemala",
      "departamento": "Guatemala",
      "ciudad": "Mixco",
      "direccion_exacta": "4a. Avenida 12-34, Zona 10, Edificio Plaza, Oficina 502",
      "codigo_postal": "01001",
      "fecha_creacion": "2026-08-22T18:15:02.423Z",
      "id_estado_direccion": 1
    }
  ]
}
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo obtener las direcciones", "payload": null }
```

---

## GET /direccion-usuario/:id

Requiere la cookie `mesh_token`. Trae la version vigente de una direccion
propia mas todo su historial de cambios completo, mas reciente primero (no
una fecha puntual: todas las versiones por las que ha pasado). Solo la
suya: una direccion de otro usuario da el mismo 404 que un id que no
existe.

```
GET /direccion-usuario/4
```

**200**

```json
{
  "ok": true,
  "mensaje": "Direccion obtenida",
  "payload": {
    "direccion": {
      "id_direccion": "4",
      "id_usuario": "27",
      "pais": "Guatemala",
      "departamento": "Guatemala",
      "ciudad": "Mixco",
      "direccion_exacta": "7a. Calle 1-50, Zona 4, Casa 12",
      "codigo_postal": "01001",
      "fecha_creacion": "2026-08-22T18:15:02.423Z",
      "id_estado_direccion": 1
    },
    "historial": [
      {
        "id_direccion_historial": "9",
        "id_direccion": "4",
        "pais": "Guatemala",
        "departamento": "Guatemala",
        "ciudad": "Mixco",
        "direccion_exacta": "7a. Calle 1-50, Zona 4, Casa 12",
        "codigo_postal": "01001",
        "fecha_creacion": "2026-08-22T18:15:09.808Z"
      },
      {
        "id_direccion_historial": "8",
        "id_direccion": "4",
        "pais": "Guatemala",
        "departamento": "Guatemala",
        "ciudad": "Guatemala",
        "direccion_exacta": "4a. Avenida 12-34, Zona 10, Edificio Plaza, Oficina 502",
        "codigo_postal": "01001",
        "fecha_creacion": "2026-08-22T18:15:02.423Z"
      }
    ]
  }
}
```

**400**

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**404** — no existe una direccion con ese id (o no es tuya):

```json
{ "ok": false, "mensaje": "No existe una direccion con ese id", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo obtener la direccion", "payload": null }
```

---

## GET /direccion-usuario/historial

Requiere la cookie `mesh_token`. Reconstruye como estaban las direcciones
del usuario logueado en una fecha especifica: para cada una, la version de
`direccion_historial` mas reciente que ya regia ese dia. Si una direccion se
creo despues de esa fecha, no sale (todavia no existia). Solo las suyas.

Query params: `fecha`, obligatorio, formato `AAAA-MM-DD`.

```
GET /direccion-usuario/historial?fecha=2026-08-22
```

**200**

```json
{
  "ok": true,
  "mensaje": "Historial de direcciones obtenido",
  "payload": [
    {
      "id_direccion_historial": "9",
      "id_direccion": "4",
      "pais": "Guatemala",
      "departamento": "Guatemala",
      "ciudad": "Mixco",
      "direccion_exacta": "7a. Calle 1-50, Zona 4, Casa 12",
      "codigo_postal": "01001",
      "fecha_creacion": "2026-08-22T18:15:09.808Z"
    }
  ]
}
```

**400**

```json
{ "ok": false, "mensaje": "La fecha es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La fecha debe tener el formato AAAA-MM-DD", "payload": null }
{ "ok": false, "mensaje": "La fecha no es valida", "payload": null }
```

**401** — no hay cookie, o el token no es valido, o la cuenta ya no esta
activa:

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

**503**

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

**500**

```json
{ "ok": false, "mensaje": "No se pudo obtener el historial de direcciones", "payload": null }
```
