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

**401** — mismo mensaje si el identificador no existe o si la contrasena no
coincide, a proposito: no hay forma de usar esta ruta para averiguar que
correos o usuarios estan registrados.

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
