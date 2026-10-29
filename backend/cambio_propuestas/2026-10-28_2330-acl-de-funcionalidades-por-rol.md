# El ACL de funcionalidades, por rol, en PostgreSQL (ADR-26)

**Fecha:** 2026-10-28, de 22:30 en adelante. Lo pidió Meme después de hablar con el
profesor: el control de acceso tiene que estar a nivel de base de datos (ya estaba,
ADR-14) y a nivel de funcionalidades, y la demo es llamar al backend directo con una
cuenta sin permiso y que conteste un error. Migración nueva, la 050. Probado contra
las bases de tu PC (respaldo previo en `respaldos/david_antes_050_20261028_2311.dump`;
la 050 ya está aplicada allá, dos veces, sin error).

## Qué cambió para ti

- **Los `@Roles(...)` ya no existen.** Cada ruta privada declara la acción que hace
  con `@Permiso('modulo.accion')` (en la clase o en el método; el del método manda) y
  va con `@UseGuards(SesionGuard, PermisoGuard)`. En `/compartidas/ofertas`,
  `@UseGuards(SesionGuard, PermisoGuard, PermisoOfertaGuard)`.
- **`SesionGuard` solo autentica** (401). Ya no lee roles. `decorators/roles.decorator.ts`
  se borró.
- **Una ruta nueva privada necesita su `@Permiso`.** Sin él, `PermisoGuard` la niega
  (403 "Esta ruta no declara su permiso") y lo avisa en el log. Si la acción es nueva,
  va en `models/permiso.ts` (la lista tipada, para que un código mal escrito no
  compile) y en una migración que la inserte en `permiso` y le dé `rol_permiso` a los
  roles que tocan. `node pruebas/permisos_cobertura.cjs` revisa que todo cuadre.

En `elementos Generales/endpoints/api.md` reescribí la sección de guards. Los demás
`endpoints-*.md` todavía dicen "`SesionGuard` + `@Roles(ID_ROL_ADMIN)`" en varios lugares;
quién entra a cada ruta no cambió, solo el mecanismo, y api.md lo aclara.

## Las tablas (migración 050, tercera forma normal)

- `modulo_permiso`: 17 módulos (cuenta, carrito, ofertas, fraude, permisos...).
- `permiso`: 38 acciones, únicas dentro de su módulo. El código `ofertas.publicar` se
  arma con un JOIN, no se guarda.
- `rol_permiso`: el ACL. Una fila por rol y permiso, con quién lo dio y cuándo. Lo que
  no está se niega.
- `auditoria_permiso`: cada intento negado (con método y ruta) y cada permiso dado o
  quitado. FK al rol y al permiso, no a la cuenta (es historia).
- Vista `permisos_por_rol`: la matriz, una columna por rol.

La semilla da a cada rol exactamente lo que daban los `@Roles` de antes, ruta por ruta
(comparado contra `pruebas/permisos_matriz_antes_050.json`, la matriz leída del dist
antes del cambio). Reparte solo cuando el permiso se crea: si un admin quita uno, volver
a correr la migración no lo devuelve.

## El código

- `models/permiso.ts`: `PERMISOS` y el tipo `CodigoPermiso`.
- `decorators/permiso.decorator.ts`: `@Permiso(...)`, metadata `permiso_funcion`.
- `guards/permiso.guard.ts`: lee el `@Permiso` y pregunta a `PermisosService.tiene()`
  con el `id_rol_usuario` del token (el mismo que leían los `@Roles`). 403 con
  "No tienes permiso para hacer esto (falta ofertas.publicar)" y una fila en la
  auditoría.
- `services/acl/permisos.service.ts`: la consulta va por `consultaCorta` (la de la
  sesión). Si PostgreSQL no contesta, usa la última matriz leída entera (al arrancar y
  cada minuto con `@Interval`), igual que la sesión se cree al token.
- `controllers/admin/admin-permisos.controller.ts`: `GET /admin/permisos`,
  `GET /admin/permisos/registro`, `POST` y `DELETE /admin/permisos/:idRol/:idPermiso`.
  `cuenta.ver` y `permisos.*` del admin no se quitan por la API (409).
- `GET /usuario/yo` suma `permisos`, los códigos del rol.

## Un cambio más en el ACL de ofertas (049)

`AclOfertasService.comprobar()`: sin ninguna entrada vigente sigue el 404 (no confirma
que la oferta existe). Con alguna, pero no la que pide la ruta, ahora es 403 "No tienes
el permiso editar sobre esta oferta", con `ErrorPermiso` nuevo en `helpers/errores.ts`
(lo traduce `manejarErrorHttp`). Antes quien ya veía la oferta leía "no existe".

## Pruebas

- `node pruebas/permisos_cobertura.cjs`: las 136 rutas privadas con guard y permiso,
  catálogo de la base igual al del código, y los mismos roles que antes en las 165
  rutas viejas. Rota a propósito (una fila menos, un guard menos) falla.
- `bash pruebas/permisos_rol.sh`: los 38 permisos con los tres roles llamando directo,
  quitar y devolver por la API y con SQL a mano, protegidos, y la matriz igual al final.
- `bash pruebas/acl_ofertas.sh` y `node pruebas/acl_ofertas_azar.mjs`, al día con el 403.
- Demo: `.\demo-entrega-final.ps1 -Parte permisos`.
