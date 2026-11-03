# El rol de la sesion sale de la base y no del token

**Fecha:** 2026-11-02, en la noche. Salio de la revision entera del proyecto que pidio
Meme, con las bases de su PC (local). Toca dos archivos tuyos, sin cambiar ninguna
ruta ni lo que contesta.

## Que pasaba

`PermisoGuard` preguntaba a `rol_permiso` con el `id_rol_usuario` del token. El token
dura 2 horas, y `PATCH /admin/usuarios/:id` deja cambiarle el rol a una cuenta. Si el
admin le bajaba el rol a un vendedor, ese vendedor seguia entrando como vendedor hasta
que su token venciera. Ademas `GET /usuario/yo` traia la cuenta de la base (rol nuevo)
y los `permisos` del rol del token (el viejo), asi que el panel y el backend no
coincidian.

`SesionGuard` ya hacia una consulta por peticion para ver si la cuenta seguia activa.

## Que cambio

- `services/usuario.service.ts`: `estaActivo()` paso a ser `estadoDeSesion()`, la misma
  consulta corta pero con `id_rol_usuario` tambien. Devuelve `{ activo, id_rol_usuario }`,
  o `null` si la cuenta ya no existe.
- `guards/sesion.guard.ts`: con esa respuesta corta igual que antes (401 si la cuenta no
  existe o no esta activa) y despues pone el rol de hoy en
  `request.usuario.id_rol_usuario`. Lo que lee `@UsuarioActual()` y `PermisoGuard` ya usa
  ese. Si el rol cambio, una linea en el log por cada cambio, no por peticion.
- Con PostgreSQL caido no cambia nada: la sesion se cree al token, como desde el 20-10,
  y vale el rol del token.

No hay consulta nueva por peticion: es la misma, con una columna mas.

## Como se probo

- `bash pruebas/permisos_rol.sh` tiene una parte 9 nueva: el admin le baja el rol a
  `permvendedor` por la API y la MISMA cookie ya da 403 en `GET /vendedor/ofertas`, el
  intento queda en `auditoria_permiso` con el rol 1, y `/usuario/yo` trae los 12 permisos
  del comprador. Al devolverle el rol vuelve a pasar. Con las bases de la PC de Meme: 171
  OK, 0 FALLA.
- Rota a proposito: con tus dos archivos como estaban, la parte 9 da 4 FALLA (el vendedor
  degradado sigue viendo sus ofertas y `/usuario/yo` le da 26 permisos).
- De paso, en esa misma prueba: en local `docker exec -i` se comia la lista del
  `while read` de la parte 2 y solo se probaba el primer permiso de 38. Contra tu PC no
  pasaba porque el modo remoto va por otro camino. Arreglado con `</dev/null`.
- `tsc` 0 y `eslint` 0 en todo `src/` (de paso, los dos avisos de prettier que habia en
  `helpers/vectores-ollama.ts` y `services/productos/evento-producto-sync.service.ts`).

## Que tienes que hacer

Nada. En tu PC no hay que correr ninguna migracion. Si tienes el backend corriendo,
basta con compilar y reiniciar para que tome el cambio.
