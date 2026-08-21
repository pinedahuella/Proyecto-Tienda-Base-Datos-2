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
