# Notificación de fraude al usuario afectado (columna + dos rutas en /perfil)

**Fecha:** 2026-09-15, segunda ronda del día (después de
`2026-09-15_1130-fraude-login-disparo-inmediato.md`).
**Alcance:** `backend/`, una columna nueva (`ALTER TABLE`, aplicada en
local) + dos rutas nuevas en `PerfilController`. No se tocó
`FraudeController` ni `AdminFraudeLoginController` (el lado admin no
necesitó cambios, ver más abajo).

## Contexto

Segunda mitad del pedido del profesor: que las alertas de fraude también
las vea el usuario cuya cuenta está involucrada, no solo el admin.
Decisiones de diseño completas en
`elementos Generales/plan pendiente/notificacion-fraude-usuario.md`.

## Decisiones tomadas en esta ronda (confirmadas por el usuario antes de codear)

1. **Del lado admin no hacía falta nada nuevo.**
   `alerta_fraude.id_estado_alerta_fraude` ya es su bandeja de pendientes.
2. **Del lado del usuario, una columna alcanza — no hace falta tabla
   nueva.** Cada alerta ya tiene un único `id_usuario`; una tabla de
   notificaciones normalizada aparte sería sobre-ingeniería para este
   caso.
3. **La columna nueva es independiente de la investigación del admin.**
   `fecha_lectura_usuario` no toca `fecha_actualizacion` ni
   `id_estado_alerta_fraude` — son dos hechos distintos (¿el admin ya lo
   investigó? vs. ¿el usuario ya lo vio?) que pueden divergir.
4. **`PATCH /perfil/contrasena` ya existía** — se verificó antes de armar
   el plan, no hizo falta crearlo.
5. **No hace falta un estado `bloqueado` en `estado_alerta_fraude`.** Ya
   existe `estado_usuario.suspendido` y `PATCH /admin/usuarios/:id` ya
   puede ponerlo — bloquear una cuenta es una acción distinta de
   investigar una alerta.

## Esquema

```sql
ALTER TABLE alerta_fraude
    ADD COLUMN IF NOT EXISTS fecha_lectura_usuario timestamptz;
```

Referencia completa (idempotente, con el comentario de columna) en
`elementos Generales/plan pendiente/notificacion-fraude-usuario.sql`,
aplicada en local. La migración real la integra el compañero.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `src/dto/alertas-fraude-usuario.ts` | **nuevo** — query de `GET /perfil/alertas-fraude`, forma de una alerta vista por el usuario (sin `cuenta_involucrada` ni nada del lado admin), forma de la respuesta paginada |
| `src/services/fraude-login/fraude-login.service.ts` | + `listarAlertasPaginadoUsuario`, `marcarLeida`, `consultarAlertasPaginadoUsuario`, `obtenerAlertaUsuarioPorId`, `FilaAlertaFraudeUsuario`, `aAlertaFraudeUsuario` — todo aditivo, no se tocó `listarAlertasPaginado` (la versión del admin) |
| `src/controllers/perfil.controller.ts` | + `GET /perfil/alertas-fraude`, `PATCH /perfil/alertas-fraude/:id`, inyecta `FraudeLoginService` |
| `elementos Generales/plan pendiente/notificacion-fraude-usuario.md` | **nuevo** — el plan completo |
| `elementos Generales/plan pendiente/notificacion-fraude-usuario.sql` | **nuevo** — referencia de la columna |

Documentación: `endpoints/endpoints.md` (sección nueva, junto a
`PATCH /perfil/contrasena` — mismo controller) y
`endpoints/endpoints-fraude.md` (sección nueva con la tabla de pruebas
completa, después de "alertas-login").

## Cómo quedaron las dos rutas

`GET /perfil/alertas-fraude` — paginado (`pagina`/`limite`), filtrado a
`WHERE id_usuario = <la sesión>` (nunca recibe un id de cuenta por
parámetro), ordenado por `fecha_creacion DESC` — no por
`fecha_actualizacion`, que es actividad del admin, no del usuario.

`PATCH /perfil/alertas-fraude/:id` — idempotente
(`SET fecha_lectura_usuario = COALESCE(fecha_lectura_usuario, now())`), con
el *ownership check* en el propio `UPDATE`
(`WHERE id_alerta_fraude = $1 AND id_usuario = $2`): si la alerta no
existe O es de otra cuenta (incluida una con `id_usuario NULL`, de las
tres señales por-IP), el mismo `404` genérico en los dos casos — mismo
criterio que las rutas de vendedor sobre ofertas ajenas, para no filtrar
si una alerta ajena existe.

## Probado en vivo — 2026-09-15

Contra el servidor real, dos cuentas de prueba registradas para la ocasión
(`prueba_tomacuenta_fraude`, con dos alertas reales propias sembradas en
la ronda de validación extensa de la sesión, y `prueba_comprador_fraude`,
sin alertas).

| Caso | Resultado |
|---|---|
| `GET /perfil/alertas-fraude` sin cookie | `401` |
| `GET` (dueño, 2 alertas propias) | `200`, orden por `fecha_creacion DESC`, ambas `fecha_lectura: null` |
| `GET ?limite=1&pagina=2` | `200`, segunda alerta, `total_paginas: 2` |
| `GET` (cuenta sin alertas) | `200`, `alertas: []`, `total_paginas: 0` |
| `PATCH /perfil/alertas-fraude/140` (dueño) | `200`, `fecha_lectura` puesta |
| Mismo `PATCH` otra vez | `200`, **misma** `fecha_lectura` (idempotente) |
| `PATCH` sobre la misma alerta desde OTRA cuenta | `404` |
| `PATCH` sobre una alerta con `id_usuario NULL` (`multi_cuenta_ip_lenta`) | `404` |
| `PATCH` sobre id inexistente | `404` |
| `PATCH` sobre id no numérico | `400` |

Confirmado además por SQL directo: marcar `fecha_lectura_usuario` no tocó
`fecha_actualizacion` (17:35:16, sin cambios) ni `id_estado_alerta_fraude`
(seguía en `revisada`, de una prueba anterior) de la misma fila — el
estado de revisión del admin y la lectura del usuario quedaron
completamente independientes, tal como se diseñó.

`npx tsc --noEmit` limpio. Sin errores ni warnings en el log del servidor
durante toda la ronda.

## Lo que no se hizo en esta ronda (y por qué)

- **Notificación en tiempo real (push/websocket/correo)** — fuera de
  alcance desde el principio de la conversación; esto es solo la capa de
  datos + lectura bajo demanda (el usuario ve sus alertas cuando entra a
  su perfil).
- **Filtro por leída/no-leída en el `GET`** — no se pidió; el frontend
  puede filtrar client-side con el campo `fecha_lectura` que ya trae cada
  fila.
- **Actualizar `MESH.postman_collection.json`** — se revisó y ya no tenía
  ninguna ruta de `/admin/fraude/*` cargada (ni siquiera las de rondas
  anteriores), así que no es un artefacto que este módulo mantenga
  sincronizado; no se tocó para no romper esa convención implícita sin que
  el equipo lo haya decidido.
