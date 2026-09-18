# Notificación de fraude al usuario afectado

> **Estado: HECHO (2026-09-15, revisado en una segunda ronda el mismo
> día).** Construido, probado en vivo y documentado. La primera ronda usó
> una columna (`fecha_lectura_usuario`) pensando que cada alerta tiene UN
> solo afectado — es falso para `multi_cuenta_ip`/`multi_cuenta_ip_lenta`,
> que involucran a VARIAS cuentas a la vez. Se corrigió a una tabla de
> notificaciones (una alerta, N afectados) antes de que la migración
> llegara a mandarse — este archivo ya refleja la versión corregida, sin
> rastro de la que se descartó. Detalle completo con pruebas de las dos
> rondas: `../../cambio_propuestas/2026-09-15_1500-notificacion-fraude-usuario.md`
> (primera ronda, columna) y
> `../../cambio_propuestas/2026-09-15_1700-notificacion-fraude-multiusuario.md`
> (segunda ronda, la corrección).

Segundo pedido del profesor (el primero, el disparo por login sobre
Elasticsearch, ya quedó hecho — ver `fraude-login-eventos.md`): que las
alertas de fraude no solo las vea el admin, sino también el usuario cuya
cuenta está involucrada, "por si cualquiera desea tomar acción".

## Decisiones cerradas con el usuario

1. **Del lado admin no hace falta nada nuevo.** `alerta_fraude.id_estado_alerta_fraude`
   (`pendiente`/`revisada`/`descartada`) ya es su bandeja de notificaciones —
   agregar una estructura aparte solo para admin duplicaría lo mismo y
   arriesgaría desincronizarse. Lo único nuevo que SÍ le llega a admin es
   ver, por cada alerta, a qué cuentas se le notificó (ver abajo).
2. **Del lado del usuario hace falta una tabla, no una columna** — este es
   el punto que se corrigió en la segunda ronda. `multi_cuenta_ip`/
   `multi_cuenta_ip_lenta` (muchos identificadores distintos probados desde
   la misma IP) le tocan a TODAS las cuentas que esa IP probó, no a una
   sola — una columna en `alerta_fraude` no puede apuntar a varias cuentas
   a la vez. Una tabla de notificaciones (una alerta, N filas de
   afectados) sí.
3. **La lectura del usuario es independiente de la investigación del
   admin.** `alerta_fraude` ya tiene `id_estado_alerta_fraude`/`fecha_revision`
   (la investigación del admin). La lectura de cada usuario afectado es un
   hecho aparte — puede pasar antes o después de que el admin la revise, y
   cada cuenta afectada la lee (o no) por su cuenta — así que vive en su
   propia tabla, sin tocar esas dos columnas ni `fecha_actualizacion`.
4. **`PATCH /perfil/contrasena` ya existe** (`perfil.controller.ts`) — no
   hacía falta crearlo, se verificó antes de armar este plan.
5. **No hace falta un estado `bloqueado` en `estado_alerta_fraude`.** Ya
   existe `estado_usuario.suspendido` y `PATCH /admin/usuarios/:id` ya puede
   ponerlo — bloquear una CUENTA es una acción distinta de investigar una
   ALERTA, y mezclarlas en el mismo campo confundiría las dos preguntas.
6. **El `detalle` que ve el usuario afectado por `multi_cuenta_ip`/
   `multi_cuenta_ip_lenta` NO incluye los correos/usuarios de las demás
   cuentas afectadas por el mismo ataque** — solo el conteo
   (`cuentas_distintas`), que ya dice "no fuiste el único blanco" sin
   exponer a nadie más. Admin sigue viendo la lista completa, como hoy.
   Decisión explícita del usuario en la segunda ronda.

## Esquema (una tabla nueva: notificaciones, no una columna)

```sql
CREATE TABLE notificacion_fraude (
    id_notificacion   bigserial PRIMARY KEY,
    id_alerta_fraude  bigint NOT NULL REFERENCES alerta_fraude(id_alerta_fraude) ON DELETE RESTRICT,
    id_usuario        bigint NOT NULL REFERENCES usuarios(id_usuario) ON DELETE RESTRICT,
    fecha_creacion    timestamptz NOT NULL DEFAULT now(),
    fecha_lectura     timestamptz,
    UNIQUE (id_alerta_fraude, id_usuario)
);
```

Una fila por cada cuenta a la que le corresponde ver una alerta. `NULL` en
`fecha_lectura` = no leída. Nunca se toca `alerta_fraude.fecha_actualizacion`
al marcarla leída — esa columna es del admin (ordena su listado por
actividad de revisión); si marcar-leída también la tocara, la fila
"saltaría" en el listado del admin cada vez que un usuario entra a mirar,
un efecto colateral que no tiene sentido.

**A quién le llega, según la forma de la alerta** (ver el comentario de
`registrarAlertaFraude()` en `backend/src/helpers/registrar-alerta-fraude.ts`
para el detalle exacto):

- Las 6 señales de una sola cuenta (`fuerza_bruta_cuenta`,
  `ip_rotacion_cuenta` y sus `_lenta`, `toma_cuenta`, `viaje_imposible`) —
  una fila, esa cuenta.
- `multi_cuenta_ip`/`multi_cuenta_ip_lenta` — una fila por CADA cuenta real
  que aparezca en `detalle.identificadores` (los identificadores que no
  correspondan a ninguna cuenta, porque el intento fue contra un correo
  inventado, no generan fila).
- `fuerza_bruta_ip` — a nadie: no trae una lista de cuentas objetivo, sigue
  siendo solo-admin.

Las notificaciones se crean SOLO cuando la alerta nace (nunca en un cruce
sucesivo del umbral dentro de la misma ventana, que solo suma `contador`)
— se distingue con el truco `xmax = 0` de Postgres dentro del mismo
`UPSERT`, en una sola transacción.

## Backend (`backend/`)

1. **`GET /perfil/alertas-fraude`** — paginado, filtrado a
   `notificacion_fraude.id_usuario = <la sesión>` (nunca recibe un id de
   cuenta por parámetro). Ordenado por `fecha_creacion` de la alerta, más
   nueva primero. Cada fila trae `fecha_lectura` de la NOTIFICACIÓN de esa
   cuenta (no de la alerta en sí). `detalle` redactado para
   `multi_cuenta_ip`/`multi_cuenta_ip_lenta` (ver decisión 6).
2. **`PATCH /perfil/alertas-fraude/:id`** — marca la fila de
   `notificacion_fraude` de esa cuenta como leída (idempotente). Ownership
   check en el propio `UPDATE` (`WHERE id_alerta_fraude = $1 AND
   id_usuario = $2` sobre `notificacion_fraude`): si no existe esa
   notificación (la alerta no existe, o existe pero esta cuenta no está
   entre los afectados), mismo 404 genérico en los dos casos.
3. **`GET /admin/fraude/alertas-login` y el `PATCH` de la misma alerta**
   ahora traen `cuentas_afectadas` (array, antes era `cuenta_involucrada`
   singular) — cada afectado con su propio `fecha_lectura`, para que admin
   vea de un vistazo quién ya se enteró.
4. Todo vive en `PerfilController`/`FraudeLoginService`
   (`listarAlertasPaginadoUsuario`/`marcarLeida`) — sin controller ni
   servicio nuevos — y `helpers/registrar-alerta-fraude.ts` (la resolución
   de afectados).

## Lo que le toca al compañero (fuera de `backend/`)

- La migración real de `notificacion_fraude`: `notificacion-fraude-usuario.sql`
  (mismo folder) es la referencia, aplicada en LOCAL para desarrollar en
  paralelo — igual que el resto de este workflow. Se integra en
  `migrations/` después de la última migración real existente. **No** hace
  falta que la migración real pase primero por la versión de columna: como
  nunca se mandó, la referencia ya está en su forma final (la tabla).
- `backend/elementos Generales/endpoints/endpoints-fraude.md` y
  `endpoints.md` se actualizan desde `backend/`, no hace falta que lo haga
  el compañero.
