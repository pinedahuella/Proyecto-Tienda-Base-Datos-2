# Corrección: 500 en vez de 503 cuando PostgreSQL se cae a mitad de sesión

**Fecha aproximada:** 2026-09-04, mañana.
**Alcance:** solo `backend/`. Un solo archivo, sin migraciones.

Hallazgo que venía anotado desde antes como "pre-existente, fuera de
alcance, sin tocar" (`endpoints-carrito.md`), cerrado en esta sesión.

## El hallazgo, reproducido de nuevo en vivo antes de tocar código

Lo que estaba anotado decía que la causa era que `SesionGuard` no
traducía el error a `ErrorConexion`. Al reproducirlo (`docker stop
mesh-postgres` con el servidor ya corriendo — el escenario más común de
probar esto a mano, más común incluso que "Postgres nunca arrancó") la
causa real resultó más precisa:

`SesionGuard.canActivate()` **sí** pasa el error de `usuarioService.estaActivo()`
por el clasificador compartido (`manejarErrorConexion`, en
`helpers/manejar-error-db.ts`, el mismo helper que usa casi todo el
backend para clasificar errores de PostgreSQL). El problema está en ese
clasificador (`esFalloDeConexion()`): solo reconocía el fallo por su
`.code` (`08*`, `28P01`, `3D000`, `ECONNREFUSED`, `ETIMEDOUT`,
`ENOTFOUND`). Cuando PostgreSQL se cae con conexiones del **pool ya
abiertas** (el caso exacto de `docker stop` con la app corriendo), `pg`
no tira un error con código: tira un `Error` a secas con el mensaje
`"Connection terminated unexpectedly"` (confirmado en el log del server).
Sin código que revisar, `esFalloDeConexion()` devolvía `false`, el error
se relanzaba tal cual, y terminaba en el 500 genérico en vez del 503.

Como es el helper **compartido**, el bug no era solo del `SesionGuard`:
afectaba a cualquier consulta de PostgreSQL en cualquier servicio del
backend que se topara con una conexión del pool muriendo a mitad de vuelo.

## El fix

En `esFalloDeConexion()` (`src/helpers/manejar-error-db.ts`):

1. Se agrega el reconocimiento por **mensaje**, no solo por código:
   `error instanceof Error && /connection terminated/i.test(error.message)`.
2. De paso, mismo patrón: se agrega `ECONNRESET` a la lista de códigos —
   es un error de conexión del driver, de la misma familia que
   `ECONNREFUSED`/`ETIMEDOUT`/`ENOTFOUND` que ya estaban, y no había
   motivo para dejarlo fuera.

Nada más cambia: `manejarErrorConexion()` y su contrato (loguea el detalle
técnico, lanza `ErrorConexion` si es un fallo de conexión, relanza el
error tal cual si no) siguen igual.

## Probado en vivo

| Caso | Antes | Después |
|---|---|---|
| `GET /comprador/pedidos/:id` con sesión válida, `docker stop mesh-postgres` a mitad de sesión | `500` "No se pudo verificar la sesion" | `503` "No se pudo conectar con PostgreSQL" |
| `GET /productos` (ruta pública, sin sesión, solo Mongo) con Postgres caído | — | sigue en `200`, no se ve afectada (no toca Postgres) |
| PostgreSQL vuelve (`docker start`), sin reiniciar el server | — | la misma ruta autenticada vuelve a `200` sola, sin intervención |

`npx tsc --noEmit` limpio. `eslint` no agregó violaciones nuevas (mismo
conteo que en `HEAD`: 0). Finales de línea CRLF normalizados tras editar.

Documentado en `endpoints-carrito.md` (donde ya vivía la nota del
hallazgo original).
