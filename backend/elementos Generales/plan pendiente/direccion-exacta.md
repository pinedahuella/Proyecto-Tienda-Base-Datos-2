# Plan pendiente 02 — Dirección exacta (calle) en las direcciones

> **Estado (2026-08-29): la columna está en la base local y el backend ya
> la usa** — obligatoria al crear, opcional al editar, presente en todos los
> GET y en el snapshot del pedido (228 comprobaciones de regresión, 0
> fallos; ver "Estado de implementación"). Falta **solo la migración real**
> en `migrations/` (la lleva el compañero, con el `.sql` de referencia).

## El problema

Una dirección hoy tiene `pais`, `departamento`, `ciudad` y `codigo_postal`
(opcional), pero **no la calle / número / referencia**. Con eso no se puede
entregar un pedido de verdad: "Guatemala, Guatemala, Guatemala" no lleva a
ninguna casa.

## ¿Es fácil? Sí — es un cambio puramente aditivo

Nada de lo que ya existe se rompe:

- **Las funciones SQL del pedido no se enteran.** `crear_pedido` y
  `cambiar_direccion_pedido` (`007_flujo_pedido.sql`) reciben solo un
  `id_direccion_historial bigint`; el único `JOIN` a `direcciones` que
  hacen es para comprobar el dueño (`d.id_usuario`), nunca leen
  `pais`/`ciudad`/etc. Añadir una columna no las toca.
- **No hay trigger** que copie `direcciones → direccion_historial`: lo hace
  el backend a mano, con listas de columnas explícitas. Ningún `SELECT *`
  en todo el flujo de direcciones.
- **El backend actual sigue funcionando con la columna nullable** (probado:
  `POST /direccion-usuario` da 201, la fila nueva queda con
  `direccion_exacta = NULL`, y el campo no aparece en la respuesta porque
  todas las consultas listan columnas). Cuando se actualice el backend,
  empezará a exigirla y a devolverla.

## Lo que ya se hizo (base local) — `direccion-exacta.sql` en este folder

```sql
ALTER TABLE direcciones        ADD COLUMN direccion_exacta varchar(255);   -- nullable
ALTER TABLE direccion_historial ADD COLUMN direccion_exacta varchar(255);  -- nullable
```

Más el back-fill de las 2 direcciones de prueba existentes (y sus 2 filas de
historial, con el mismo valor — nacieron a la vez que su dirección y nunca
se editaron).

**Va en las DOS tablas** por la misma razón que `pais`/`ciudad`: la vigente
en `direcciones`, y la foto en `direccion_historial` para que un pedido
recuerde a qué calle exacta se envió ese día aunque el usuario edite la
dirección después.

**Nullable, por ahora, a propósito.** El backend todavía no manda el campo;
si fuera `NOT NULL` sin default, el `POST /direccion-usuario` actual
reventaría. La migración real la puede dejar `NOT NULL` una vez que el
backend y `generador.js` la llenen siempre — igual que `pais`,
`departamento` y `ciudad`.

**`varchar(255)`** y no `varchar(100)`: una línea de calle completa en
Guatemala ("4a. Avenida 12-34, Zona 10, Edificio Plaza, Oficina 502, frente
al parque") pasa de 100 con facilidad. Un solo campo de texto libre, no
varios (calle/número/zona aparte), porque así se escriben las direcciones
aquí.

## Estado de implementación (backend) — HECHO (2026-08-29)

Todo dentro de `backend/src/`, mecánico, mismo patrón que `ciudad`:

| Archivo | Cambio |
|---|---|
| `helpers/validaciones-direccion.ts` | nueva `validarDireccionExacta()` — obligatoria, no vacía, ≤ 255. Mensajes: `"La direccion exacta es obligatoria"` / `"La direccion exacta no puede tener mas de 255 caracteres"` |
| `dto/crear-direccion.ts` | `direccion_exacta: string` (obligatoria) |
| `dto/editar-direccion.ts` | `direccion_exacta?: string \| null` (opcional, como el resto) |
| `models/direccion.ts` | `direccion_exacta: string \| null` (nullable porque la columna aún lo es) |
| `models/direccion-historial.ts` | `direccion_exacta: string \| null` |
| `services/direccion-usuario.service.ts` | `validarDireccionExacta()` en `crear()` (obligatoria) y en `actualizar()` (solo si viene); la columna en el `INSERT INTO direcciones` + `RETURNING`, el `UPDATE ... SET` (COALESCE) + `RETURNING`, los 3 `SELECT` (`listar`, `obtenerConHistorial` ×2, `obtenerHistorial`), y el `INSERT INTO direccion_historial` del snapshot |
| `services/compradores/pedidos.service.ts` | `GET /comprador/pedidos/:id` devuelve `direccion.direccion_exacta` — la calle exacta a la que se envió el pedido, congelada en el snapshot (el tipo de `PedidoCompleto.direccion` es `DireccionHistorial`, así que era obligatorio) |
| `controllers/direccion-usuario.controller.ts` | sin cambios (solo pasa el body) |

Documentación actualizada: `endpoints.md` (las 5 rutas `/direccion-usuario`
— cuerpo y respuestas) y `endpoints-compradores.md` (el snapshot en
`GET /comprador/pedidos/:id`).

**Pruebas** (script de trabajo fuera del repo, contra la base real, con
teardown): **35 / 35**.

| Bloque | Verificado |
|---|---|
| Creación | sin `direccion_exacta` → 400; vacía / solo espacios / número → 400; > 255 → 400 (con el mensaje exacto); válida → 201, el campo en la respuesta, en `direcciones` **y** en el snapshot de `direccion_historial` |
| GET | `GET /direccion-usuario`, `GET /:id` (dirección + cada fila del historial) y `GET /historial` traen el campo; las 2 direcciones del seed (back-fill) lo muestran |
| PATCH | solo `direccion_exacta` → 200, actualiza y genera snapshot nuevo con el valor nuevo; vacía / > 255 → 400; editar **otro** campo no toca `direccion_exacta` y el snapshot conserva la vigente; body vacío → 400; dirección ajena → 404 |
| Pedido | `GET /comprador/pedidos/:id` trae `direccion.direccion_exacta`; un pedido nuevo congela la `direccion_exacta` vigente de la dirección |

**Regresión**: las 5 suites del flujo de ofertas + el buscador
(193 comprobaciones) siguen 100 %, más las 35 de dirección = **228 / 228**.
`tsc --noEmit` y `nest build` limpios.

## Fuera de `backend/` (lo lleva el compañero / quien toque el frontend)

- **`migrations/002_direcciones.sql`** — la columna en las dos tablas
  (probablemente `NOT NULL` en la versión final).
- **`migrations/datos/generador.js`** — añadir `direccion_exacta` a los
  `INSERT INTO direcciones` / `INSERT INTO direccion_historial` y a la lista
  `v(correo, pais, departamento, ciudad, codigo)` con una calle por cada
  comprador de prueba.
- **`docs/base-de-datos.md`** — la sección de direcciones.
- **Frontend** (`Direcciones.svelte`, `Checkout.svelte`) — un campo de
  texto para la calle en el formulario de dirección.

## Sugerencia de nombre

Se usó **`direccion_exacta`**. Si el equipo prefiere `calle`,
`linea_direccion` o `direccion_linea1`, es solo renombrar en el `.sql` y en
la lista de arriba antes de codear.
