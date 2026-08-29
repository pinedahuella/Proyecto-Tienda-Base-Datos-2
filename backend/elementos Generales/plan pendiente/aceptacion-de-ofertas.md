# Plan pendiente 01 — Aceptación de ofertas

> **Estado (2026-08-28): el backend está completo y probado** (creación,
> edición, los dos GET y `PATCH .../:id/revision` — 179 comprobaciones, 0
> fallos, ver "Estado de implementación" más abajo). Falta **solo la
> migración real** en `migrations/`, que lleva el compañero (hay un `.sql`
> de referencia aplicado en la base local). Este documento fija las
> decisiones de diseño acordadas con el usuario y el detalle de lo
> construido.

## El problema

Hoy, cuando un vendedor (cualquiera que no sea la tienda) publica una oferta
con `POST /vendedor/ofertas`, la oferta nace `activa` directo y ya se ve y se
compra en el catálogo — sin que la tienda la revise. Se quiere meter un paso
de aprobación: la oferta de un vendedor normal nace **pendiente**, no circula
hasta que la tienda (o un admin) la aprueba, y la tienda puede rechazarla con
un motivo.

Ya se había investigado antes (ver `../../elementos Generales/plan-crear-editar-ofertas.md`
y la memoria de estado del backend) y se había aplazado por falta de tiempo.
Esto lo retoma con las decisiones cerradas.

---

## Decisiones tomadas

### 1. Cómo se marca el estado de aprobación

Se usan **las dos cosas**, cada una para lo suyo:

- **Dos estados nuevos en `estado_oferta`:**
  - `pendiente` — `id_estado_oferta = 4`. La oferta espera revisión de la
    tienda. No circula (no se ve en la ficha, no cuenta en los campos
    calculados, no se puede comprar).
  - `rechazada` — `id_estado_oferta = 5`. La tienda la revisó y la rechazó.
    Tampoco circula.
- **Columna nueva `oferta.fecha_aprobacion`** (`timestamptz`, NULL hasta que
  se apruebe). Es el hecho histórico de "cuándo la aprobó la tienda", y
  sobrevive a que después la oferta se pause o se retire. `NULL` = nunca
  aprobada.

Por qué las dos y no una: el **estado** dice la situación de ahora mismo
(`pendiente` / `rechazada` / `activa` / `pausada` / `retirada`); la
**columna** guarda el hecho que el estado pierde en cuanto cambia. Es el
mismo criterio que ya sigue el proyecto: la fila viva lleva estado, el dato
histórico va aparte (ver `docs/base-de-datos.md`, "Los historiales no llevan
estado").

### 2. La tienda y los admin nunca pasan por aprobación

Una oferta creada por la cuenta `tienda@mesh.com` **o** por cualquier cuenta
con rol admin nace `activa` y con `fecha_aprobacion = now()` directo. La
tienda es la autoridad; no se aprueba a sí misma.

En el código, después de `resolverIdEfectivo()` (que ya sustituye la
identidad de un admin por la de la tienda), basta comparar el `idUsuario`
efectivo con el id de la cuenta de la tienda: si coinciden — sea porque es
la tienda logueada directo, sea porque es un admin ya sustituido — la oferta
nace aprobada. Cualquier otro `idUsuario` nace `pendiente`.

### 3. Solo la creación pide aprobación

Cambiar el precio (o el stock, o pausar/reactivar) de una oferta **ya
aprobada** no la vuelve a dejar pendiente. La aprobación se pide una sola
vez, al nacer.

### 4. Qué puede hacer el vendedor con su oferta

- **Antes de aprobarse** (`pendiente`): el vendedor puede editar el precio
  (sigue `pendiente`) o retirar la solicitud (`retirada`). **No** puede
  pasarla a `activa` ni a `pausada` él mismo — para eso está la tienda.
- **Después de aprobarse**: el vendedor maneja su oferta como quiera —
  `activa` ↔ `pausada` ↔ `retirada` libremente, igual que hoy. Lo único
  que la tienda controla es que **no circule de una vez** al crearse.

### 5. La tienda no modera ofertas ajenas ya activas

Por ahora, la tienda **solo** autoriza la primera vez (aprobar o rechazar una
`pendiente`). Una vez la oferta está `activa`, es del vendedor y la tienda no
la puede pausar ni retirar. Moderar ofertas ajenas queda fuera de alcance de
este cambio.

### 6. Rechazo explícito, con tabla propia

La tienda puede **rechazar** una oferta pendiente. Al rechazarla:

- La oferta pasa a estado `rechazada` (`id_estado_oferta = 5`).
- Se inserta una fila en la tabla nueva **`rechazo_oferta`**:
  - `id_rechazo_oferta` — PK, `bigserial`.
  - `id_oferta` — `bigint NOT NULL`, FK a `oferta(id_oferta)` con
    `ON DELETE RESTRICT` (misma regla que toda la cadena económica: nada de
    esto se borra).
  - `razon_rechazo` — `text NOT NULL`. La tienda tiene que decir por qué.
  - `fecha_rechazo` — `timestamptz NOT NULL DEFAULT now()`.

Es una tabla de solo-inserción (un historial): si una oferta se rechaza,
se corrige y se vuelve a rechazar, quedan dos filas — cada una con su
`fecha_rechazo`, para poder ver toda la historia de rechazos de esa oferta.

**Re-envío tras rechazo:** editar una oferta `rechazada` (un `precio` nuevo
y/o un `ajuste_stock`) la regresa a `pendiente` automáticamente, para otra
revisión — no hay que retirarla y volver a crearla. La oferta no se recrea
(el `UNIQUE` de `oferta` lo impediría igual), se reusa la misma fila, y la
fila vieja de `rechazo_oferta` se queda como historial. Si en vez de
corregirla el vendedor manda `estado: 'retirada'`, se retira y ya (no
vuelve a `pendiente`); `estado: 'activa'` o `'pausada'` sobre una
`rechazada` da 409 (no está aprobada).

### 7. GET plano de pendientes

`GET /vendedor/ofertas/pendientes` — solo tienda o admin. Devuelve **todas**
las ofertas en estado `pendiente`, de todos los vendedores, con el nombre del
producto, de la variante, del vendedor, el precio propuesto, el stock y la
`fecha_creacion`. Ordenadas por `fecha_creacion` ascendente (las más viejas
primero: es una cola de trabajo).

No hay navegación por producto para esto — es una cola plana y ya.

### 8. Endpoint para aprobar / rechazar

`PATCH /vendedor/ofertas/:id/revision` — solo tienda o admin. Body:

```json
{ "decision": "aprobar" }
```
```json
{ "decision": "rechazar", "razon": "El precio está muy por debajo del mercado" }
```

- `decision` — obligatorio, `"aprobar"` o `"rechazar"`.
- `razon` — obligatorio **solo si** `decision = "rechazar"`. Texto no vacío.
- La oferta tiene que estar en estado `pendiente`; si no, 409
  ("Esta oferta no está pendiente de revisión").
- **Aprobar** → `id_estado_oferta = activa`, `fecha_aprobacion = now()`, y
  después `recalcularCamposCalculados([idProducto])`.
- **Rechazar** → `id_estado_oferta = rechazada`, fila nueva en
  `rechazo_oferta`. (No hace falta recalcular: nunca estuvo activa, pero se
  llama igual por la regla de "toda escritura sobre oferta termina
  recalculando".)

Aprobar deja la oferta **`activa` directo**, no `pausada` — un paso menos,
y es lo que el vendedor quiere.

### 9. Las ofertas que ya existen

En la migración, todas las ofertas actuales (las 552 del conjunto de datos y
cualquier otra que se haya creado) se marcan como **ya aprobadas**:
conservan su estado actual (`activa` / `pausada` / `retirada`) y se les pone
`fecha_aprobacion = fecha_creacion`. Si no, el catálogo entero se apagaría al
aplicar el cambio.

---

## Lo que necesita la migración (NO lo hacemos nosotros)

Esto vive en `migrations/` y lo escribe quien lleva esa parte del repo
(trabajo en paralelo). Nuestro backend asume que ya está aplicado.

> **Aplicado en la base local el 2026-08-28** para poder desarrollar el
> backend sin esperar la migración: ver `aceptacion-de-ofertas.sql` en este
> mismo folder. Ese `.sql` **no es la migración** — es una referencia de la
> forma exacta y un script idempotente que se corrió contra el contenedor
> `mesh-postgres`. Un `.\arrancar.ps1 -Reiniciar` lo borra y deja solo lo
> que digan las migraciones reales. Cuando la migración del compañero esté
> lista, este `.sql` se puede tirar.

1. **`estado_oferta`** — insertar dos filas:
   `(4, 'pendiente')` y `(5, 'rechazada')`.
2. **`oferta`** — columna nueva:
   `ALTER TABLE oferta ADD COLUMN fecha_aprobacion timestamptz;` (nullable,
   sin default).
3. **Tabla nueva `rechazo_oferta`:**
   ```sql
   CREATE TABLE rechazo_oferta (
     id_rechazo_oferta bigserial PRIMARY KEY,
     id_oferta         bigint NOT NULL REFERENCES oferta(id_oferta) ON DELETE RESTRICT,
     razon_rechazo     text NOT NULL,
     fecha_rechazo     timestamptz NOT NULL DEFAULT now()
   );
   CREATE INDEX idx_rechazo_oferta_oferta ON rechazo_oferta (id_oferta);
   ```
4. **Back-fill** de lo existente:
   `UPDATE oferta SET fecha_aprobacion = fecha_creacion WHERE fecha_aprobacion IS NULL;`
   (antes de que el backend empiece a crear ofertas `pendiente`).
5. **`generador.js` / datos de prueba** — que las ofertas generadas nazcan
   con `fecha_aprobacion` puesta, para que el conjunto recién cargado siga
   teniendo todo el catálogo visible. Idealmente dejar unas pocas ofertas
   `pendiente` a propósito, para que la cola de revisión no salga vacía en
   una demo.

Notas para quien haga la migración:

- El trigger `trg_oferta_registrar_precio` se dispara igual en el INSERT
  aunque la oferta nazca `pendiente` — está bien, el precio propuesto queda
  registrado en `precio_historial` desde el inicio. **No hay que tocar el
  trigger.**
- No hace falta tocar ninguna función de `007_flujo_pedido.sql`: el chequeo
  de "la oferta está activa" antes de comprar vive en el backend
  (`revisarCambiosAntesDeComprar`), y ya es `!== 'activa'`, así que
  `pendiente` y `rechazada` se bloquean solas.

---

## Lo que se hace en el backend (esto sí es nuestro)

### Cambios en archivos existentes

1. **`models/estado-oferta.ts`** — hoy exporta
   `ESTADOS_OFERTA_VALIDOS = ['activa', 'pausada', 'retirada']`, que
   `validarEstadoOferta()` usa para el `PATCH /vendedor/ofertas/:id`. Hay que
   separar dos conceptos:
   - `ESTADOS_OFERTA` (todos, los 5) — para tipar / mostrar.
   - `ESTADOS_OFERTA_QUE_EL_VENDEDOR_PUEDE_PONER` (`activa`, `pausada`,
     `retirada`) — lo que sigue aceptando el PATCH del vendedor. `pendiente`
     y `rechazada` **no** son seteables por el vendedor por esa vía.

2. **`services/vendedores/ofertas.service.ts` → `crear()`** — hoy el INSERT
   fija `id_estado_oferta` a `'activa'` y el objeto de respuesta pone
   `estado: 'activa'`. Cambiar a:
   - Resolver el id de la cuenta de la tienda (una consulta a `usuarios` por
     `CORREO_TIENDA`, o un helper compartido).
   - Si el `idUsuario` efectivo === id de la tienda → nace `activa` +
     `fecha_aprobacion = now()`.
   - Si no → nace `pendiente`, `fecha_aprobacion = NULL`.
   - El `stock_inicial` con `reponer_stock` se sigue haciendo igual aunque
     la oferta esté `pendiente` (el kardex es independiente del estado).
   - La respuesta devuelve el estado real (`pendiente` o `activa`).

3. **`services/vendedores/ofertas.service.ts` → `editar()`** — hoy deja poner
   cualquier estado de `ESTADOS_OFERTA_VALIDOS` sin restricción. Añadir:
   - Si la oferta está `pendiente`: el vendedor puede editar `precio` /
     `ajuste_stock` (sigue `pendiente`) o mandar `estado: 'retirada'`
     (retira la solicitud). `estado: 'activa'` o `'pausada'` → 409
     ("La oferta todavía no está aprobada").
   - Si la oferta está `rechazada`: `precio` nuevo y/o `ajuste_stock` la
     devuelven a `pendiente` (re-envío automático); `estado: 'retirada'` la
     retira; `estado: 'activa'` o `'pausada'` → 409.
   - Nadie fuerza el estado de una oferta `pendiente`/`rechazada` a `activa`
     por esta ruta — ni el vendedor ni un admin. La única puerta para
     aprobar/rechazar es `PATCH /vendedor/ofertas/:id/revision`, así el
     rechazo con motivo no se puede saltar. Las ofertas de la tienda/admin
     nunca nacen `pendiente`, así que estas restricciones no las tocan.

### Archivos nuevos

4. **`GET /vendedor/ofertas/pendientes`** — **hecho** (2026-08-28). En
   `OfertasVendedorController` + `OfertasVendedorService.listarPendientes()`.
   `exigirTiendaOAdmin(idUsuarioToken, idRolUsuario)` privado en el mismo
   servicio (admin por rol, tienda por comparación contra `obtenerIdTienda()`,
   sin pedir el registro del usuario) — un vendedor normal recibe el **404
   disfrazado** `"No existe una oferta con ese id"`. Una consulta a Postgres
   (`oferta` en `pendiente` + `JOIN usuarios`) + una sola a Mongo con `$in`
   (`consultarProductosLigeros`, reusado). Orden `fecha_creacion ASC`.
   Modelo nuevo `OfertaPendiente` en `models/oferta.ts` (con el vendedor
   embebido). La cola es **global**, no hay `resolverIdEfectivo` — un admin
   ve todas las pendientes, no "las suyas".

5. **`GET /vendedor/ofertas/:id/rechazos`** — **hecho** (2026-08-28). En
   `OfertasVendedorController` + `OfertasVendedorService.listarRechazos()`.
   Historial de rechazos de una oferta propia (`obtenerFilaPropia` da el
   404 genérico si es ajena o no existe; `[]` si es propia y nunca fue
   rechazada). Orden `fecha_rechazo DESC`. Modelo nuevo
   `models/rechazo-oferta.ts` (`RechazoOferta`). Con sesión admin, "propia"
   = de la tienda (`resolverIdEfectivo`), cuyas ofertas nunca se rechazan.

6. **`PATCH /vendedor/ofertas/:id/revision`** — **hecho** (2026-08-28). En
   `OfertasVendedorController` + `OfertasVendedorService.revisar()`.
   `exigirTiendaOAdmin` lo primero (vendedor normal, incluido el dueño de
   la oferta → 404 disfrazado). DTO `dto/revisar-oferta.ts`
   (`RevisarOfertaPeticion`) + helpers `validarDecisionRevision` /
   `validarRazonRechazo` (la razón se guarda recortada). Aprobar →
   `activa` + `fecha_aprobacion = now()`; rechazar → `rechazada` + `INSERT`
   en `rechazo_oferta`, los dos en una transacción. Se comprueba que la
   oferta siga `pendiente` **dentro** de la transacción con
   `SELECT ... FOR UPDATE` sobre `oferta` (409 si no). Se extrajeron dos
   helpers privados: `armarOfertaPropia(fila)` (compartido con `editar()`)
   y `obtenerFilaPorId(idOferta)` (sin comprobación de dueño). El
   controlador devuelve `"Oferta aprobada"` / `"Oferta rechazada"` según
   la decisión.

   > **Bug encontrado y corregido durante las pruebas de concurrencia:** el
   > `SELECT ... FOR UPDATE OF o` original llevaba un `JOIN estado_oferta`.
   > Cuando dos revisiones caían sobre la misma oferta, el perdedor de la
   > carrera recibía un **404** en vez de 409: al re-evaluar la fila tras el
   > commit del ganador (EvalPlanQual de Postgres), el join se recalculaba
   > con el `id_estado_oferta` nuevo pero contra la fila de `estado_oferta`
   > vieja, y la fila quedaba fuera del resultado. Se quitó el join del
   > bloqueo: ahora se bloquea `oferta` a secas por su PK y el nombre del
   > estado se resuelve en una segunda consulta, ya con la fila bloqueada.
   > Verificado con 12 carreras seguidas: siempre exactamente un 200 y un
   > 409, estado final coherente.

### Lo que NO hay que tocar (ya funciona por lista blanca)

Verificado en el código el 2026-08-28: todo esto filtra por
`estado_oferta_nombre = 'activa'` (lista blanca), así que `pendiente` y
`rechazada` quedan fuera **sin cambios**:

- Ficha pública de un producto — `productos.service.ts`, la consulta de
  ofertas (`AND eo.estado_oferta_nombre = 'activa'`).
- Campos calculados `precio_tienda` / `precio_desde` / `stock_tienda` /
  `stock_total` / `total_ofertas` — `productos.service.ts`,
  `recalcularCamposCalculados()` y el bloque de `$facet` del catálogo,
  todos con `id_estado_oferta = (SELECT ... 'activa')`.
- Compra — `pedidos.service.ts`, `revisarCambiosAntesDeComprar()`:
  `if (fila.estado_oferta_nombre !== 'activa')` → bloqueante.
- `GET /vendedor/ofertas` (`listarPropias`) — ya devuelve todos los
  estados, así que un vendedor verá sus propias ofertas `pendiente` /
  `rechazada` con su etiqueta, sin cambios.

---

## Documentación que hay que actualizar (dentro de `backend/`)

- **`endpoints-vendedores.md`** — hecho para lo ya construido:
  `GET /vendedor/ofertas/pendientes`, `GET /vendedor/ofertas/:id/rechazos`,
  el cambio de `POST /vendedor/ofertas` (nace `pendiente` salvo
  tienda/admin) y el de `PATCH /vendedor/ofertas/:id` (restricciones sobre
  ofertas sin aprobar). Falta documentar `PATCH .../:id/revision` cuando se
  construya.
- **`plan-crear-editar-ofertas.md`** — marcar que la "decisión pendiente"
  de aprobación ya se cerró y remite aquí.

Fuera de `backend/` (lo menciona quien lleve esa parte, nosotros no lo
tocamos): `docs/base-de-datos.md` (el modelo de `oferta`, los estados, la
tabla `rechazo_oferta`) y `docs/frontend.md` / el frontend (la pantalla de
la cola de revisión).

---

## Puntos cerrados (2026-08-28)

1. **Re-envío tras rechazo:** automático. Editar `precio` / `ajuste_stock`
   de una oferta `rechazada` la regresa a `pendiente`; la fila de
   `rechazo_oferta` (con su `fecha_rechazo`) se queda como historial.
2. **Un admin solo aprueba o rechaza ofertas pendientes**, y solo por
   `PATCH /vendedor/ofertas/:id/revision`. No puede forzar estados de una
   `pendiente`/`rechazada` por `PATCH /vendedor/ofertas/:id`.
3. **Vendedor normal en `/pendientes` o `/revision`:** 404 disfrazado, como
   el resto de `/vendedor/*` restringido a la tienda.
4. **Nombre y forma del endpoint de revisión:**
   `PATCH /vendedor/ofertas/:id/revision` con `{ decision, razon? }` —
   confirmado.

Único punto que queda por comprobar (en prueba, no es una decisión): la
oferta de la tienda sobre una variante donde un vendedor ya tiene una
`pendiente` no choca, porque el `UNIQUE` es por
`(id_usuario, producto, variante)` y son usuarios distintos.

---

## Estado de implementación

### Hecho y probado (2026-08-28) — creación y edición

**`POST /vendedor/ofertas` (creación):**

- **`services/vendedores/ofertas.service.ts`**: se extrajo `obtenerIdTienda()`
  (resuelve el id de `tienda@mesh.com` por correo, reusado por
  `resolverIdEfectivo()`). En `crear()`, `esCuentaTienda = idUsuario === idTienda`
  (cubre tanto la tienda logueada directo como un admin ya sustituido);
  `estadoInicial` es `'activa'` para la tienda/admin y `'pendiente'` para
  cualquier otro. El INSERT pone `fecha_aprobacion = now()` solo cuando
  nace `'activa'` (`CASE WHEN $5 = 'activa' THEN now() ELSE NULL END`). La
  respuesta devuelve el estado real.

**`PATCH /vendedor/ofertas/:id` (edición):**

- **`editar()`**: se captura la fila actual con
  `nuncaAprobada = fila.fecha_aprobacion == null` (no el nombre del estado:
  una oferta `retirada` que nunca pasó por revisión también cuenta como sin
  aprobar). Si `nuncaAprobada`: `estado: 'activa'`/`'pausada'` → 409;
  `estado: 'retirada'` se respeta; sin `estado` (solo precio/stock) se
  fuerza `id_estado_oferta = 'pendiente'`. Si ya fue aprobada, el
  comportamiento es el de siempre. El `UPDATE` de estado corre también
  cuando solo cambia el precio, para poder devolver una `rechazada` a
  `pendiente`.
- **`models/estado-oferta.ts`**: se agregó `ESTADOS_OFERTA` (los 5);
  `ESTADOS_OFERTA_VALIDOS` (los 3 que el cliente puede enviar en un PATCH)
  quedó igual — `validarEstadoOferta` sigue rechazando `pendiente` y
  `rechazada` en el cuerpo con 400.
- **`FilaOfertaPropia`** ganó `fecha_aprobacion`, seleccionado en las tres
  consultas que la usan.

**No se tocó nada más**: catálogo, campos calculados, ficha pública,
`agregar_linea` (SQL) — todos filtran por `= 'activa'` (lista blanca), así
que `pendiente`/`rechazada` quedan fuera solos. `npx tsc --noEmit` limpio.

**Pruebas** (scripts de trabajo fuera del repo, contra la base real, con
teardown que no deja nada):

- **Creación** — 48/48.
- **Edición** — 48/48 (ofertas aprobadas: sin regresión; nunca aprobadas:
  el flujo `pendiente`/`rechazada`/`retirada-sin-aprobar` → `pendiente`, y
  los 409 al intentar autoactivar/pausar).
- **Los dos GET** — 28/28.
- **`PATCH .../:id/revision`** — 55/55 (incluye 12 carreras concurrentes
  aprobar-vs-rechazar). Ver detalle abajo.
- Re-corridas creación (48/48), edición (48/48) y GET (28/28): sin
  regresión. **179 comprobaciones, 0 fallos.**

Detalle de la creación:

| # | Caso | Resultado |
|---|---|---|
| A | tienda crea sobre variante nueva | 201, `activa`, `fecha_aprobacion` puesta, `id_usuario` = tienda |
| B | admin crea | 201, `activa`, `fecha_aprobacion` puesta, `oferta.id_usuario` = **tienda** (id 2), no admin (id 5) |
| C | vendedor normal crea | 201, `pendiente`, `fecha_aprobacion NULL`, `id_usuario` = el vendedor |
| D | otro vendedor sobre la misma variante | 201, `pendiente` |
| E | mismo vendedor, misma variante, otra vez | 409 (UNIQUE) |
| F | vendedor crea con `stock_inicial: 7` | 201, `pendiente`, stock 7 en oferta y en kardex (`reposicion`), **`fecha_aprobacion` sigue NULL** pese a que `reponer_stock` tocó `fecha_actualizacion` |
| G–O | precio no numérico / negativo / 0 → 400; falta `id_producto` → 400; producto inexistente → 404; variante ajena → 404; comprador → 403; sin sesión → 401; `stock_inicial` negativo → 400 | todos correctos |
| L | producto en `borrador` | 404 (mismo que "no existe") |
| P | ficha pública `GET /productos/:id` | muestra solo las 2 ofertas activas; las 4 `pendiente` no |
| Q | campos calculados en Mongo | `total_ofertas` y `stock_total` cuentan solo activas; una `pendiente` con stock 7 dejó `stock_total = 0` |
| R | `GET /vendedor/ofertas` del vendedor | ve su propia oferta como `pendiente` |
| S | agregar una oferta `pendiente` a un pedido | 409 "La oferta N esta pendiente y no se puede comprar" (lo rechaza `agregar_linea` en SQL, sin cambios) |
| T | regresión: tienda oferta una variante que ya tiene | 409 |

Detalle de la edición (`PATCH /vendedor/ofertas/:id`):

| Grupo | Casos | Resultado |
|---|---|---|
| Aprobadas (sin regresión) | precio (→ fila en `precio_historial`), `activa`↔`pausada`, `retirada`→`activa`, `ajuste_stock` ±, cuerpo vacío, oferta ajena, `estado` inválido | 200 / 400 / 404 según corresponde, igual que antes |
| `pendiente` + `precio` o `ajuste_stock` | — | 200, sigue `pendiente`, `fecha_aprobacion` NULL |
| `rechazada` + `precio` | — | 200, **vuelve a `pendiente`** |
| `retirada` sin haber sido aprobada + `precio` | — | 200, **vuelve a `pendiente`** (discrimina por `fecha_aprobacion` NULL, no por el nombre del estado) |
| `pendiente`/`rechazada`/`retirada`-sin-aprobar + `estado: activa` o `pausada` | — | **409** |
| `pendiente`/`rechazada` + `estado: retirada` | — | 200, se retira |
| cuerpo con `estado: "pendiente"` o `"rechazada"` | — | 400 (el cliente no los manda) |

Detalle de los dos GET (`GET /vendedor/ofertas/:id/rechazos` y
`GET /vendedor/ofertas/pendientes`):

| Caso | Resultado |
|---|---|
| `/:id/rechazos` — oferta propia con 2 rechazos | 200, array de 2, `fecha_rechazo DESC` |
| `/:id/rechazos` — oferta propia sin rechazos | 200, `[]` (no 404) |
| `/:id/rechazos` — oferta ajena (de otro vendedor o de la tienda) | 404 genérico |
| `/:id/rechazos` — oferta inexistente / id inválido / sin sesión / comprador | 404 / 400 / 401 / 403 |
| `/:id/rechazos` — tras reenviar la oferta (vuelve a `pendiente`) | el historial sigue completo |
| `/pendientes` — tienda o admin | 200, cuenta = `SELECT count(*) WHERE estado='pendiente'`, orden `fecha_creacion ASC`, vendedor y nombres embebidos |
| `/pendientes` — vendedor normal | 404 disfrazado |
| `/pendientes` — comprador / sin sesión | 403 / 401 |
| `/pendientes` — ofertas `activa`/`rechazada` | no aparecen |

Detalle de `PATCH /vendedor/ofertas/:id/revision`:

| Caso | Resultado |
|---|---|
| tienda/admin aprueba una `pendiente` | 200 "Oferta aprobada", `activa` + `fecha_aprobacion`, recalc (aparece en ficha, comprable, `precio_desde` baja) |
| tienda/admin rechaza con `razon` | 200 "Oferta rechazada", `rechazada`, 1 fila en `rechazo_oferta` (razón recortada), `fecha_aprobacion` sigue NULL, no aparece en ficha |
| vendedor (incluido el dueño de la oferta) | 404 disfrazado |
| comprador / sin sesión | 403 / 401 |
| `decision` ausente o inválida, `razon` vacía al rechazar | 400 |
| id inválido / oferta inexistente | 400 / 404 |
| revisar una oferta en cualquier estado ≠ `pendiente` | 409, sin dejar fila de rechazo (rollback) |
| ciclo `pendiente → rechazada → (corrige) → pendiente → aprobada` | funciona, conserva el historial de rechazo |
| 12 carreras concurrentes aprobar-vs-rechazar sobre la misma oferta | siempre 1×200 + 1×409, estado final coherente |

### Pendiente (no hecho todavía)

- La migración real (la lleva el compañero). Todo el backend del flujo de
  aprobación de ofertas está construido y probado.

## Cómo se prueba (el resto, cuando se implemente)

Contra la base real, con `npx tsc --noEmit` limpio antes de dar nada por
hecho, y al menos un caso de éxito y uno de cada error de negocio por ruta:

- Vendedor normal crea oferta → nace `pendiente`, no aparece en la ficha
  pública, no cuenta en `precio_desde` / `stock_total`, no se puede agregar
  al carrito ni comprar.
- Tienda crea oferta → nace `activa` + `fecha_aprobacion` puesta.
- Admin crea oferta → nace `activa` bajo la cuenta de la tienda.
- `GET /vendedor/ofertas/pendientes` como tienda → la ve; como vendedor
  normal → 404/vacío; como admin → la ve.
- `PATCH .../:id/revision` aprobar → la oferta pasa a `activa`, aparece en
  la ficha, cuenta en los campos calculados (recalculados), se puede
  comprar. `fecha_aprobacion` puesta.
- `PATCH .../:id/revision` rechazar sin `razon` → 400. Con `razon` → estado
  `rechazada`, fila en `rechazo_oferta`.
- `PATCH .../:id/revision` sobre una oferta que ya está `activa` → 409.
- Vendedor sobre su oferta `pendiente`: `estado: 'retirada'` → OK;
  `estado: 'activa'` → 409; `precio` nuevo → OK, sigue `pendiente`.
- Regresión: crear/editar/pausar/reactivar una oferta ya aprobada funciona
  igual que hoy; el flujo de compra completo sin cambios.
