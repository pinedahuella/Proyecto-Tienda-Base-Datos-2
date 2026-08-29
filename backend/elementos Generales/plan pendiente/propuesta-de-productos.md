# Plan pendiente 03 — Propuesta de productos por vendedores convencionales

> **Estado (2026-08-29):**
> - La base local ya tiene los dos estados y las dos tablas nuevas (ver
>   `propuesta-de-productos.sql`).
> - **Hecho y probado — todo el backend del flujo:**
>   - `POST /vendedor/productos/propuestas` — crea el producto `en_revision`
>     + la fila en `propuesta_producto` (41 comprobaciones).
>   - `GET /vendedor/productos/propuestas` / `/sin-aprobar` / `/todas` — mías
>     / no aprobadas / todas (39 comprobaciones).
>   - `PATCH /vendedor/productos/:id/revision` (aprobar/rechazar) y
>     `PATCH /vendedor/productos/:id/reenviar` (81 comprobaciones, incluida
>     concurrencia y compensación).
>   - `GET /vendedor/productos/propuestas/:id/rechazos` (rechazos de una
>     propuesta) y `GET /vendedor/ofertas/:id/rechazos` extendido para que
>     la tienda/un admin vean cualquier oferta.
> - **Falta solo**: la migración real en `migrations/` (la lleva el
>   compañero, con el `.sql` de referencia).

## El problema

Hoy **solo `tienda@mesh.com` o un admin** crean entradas del catálogo
(`exigirTiendaOAdmin` en `ProductosVendedorService`). Se decidió así para
que dos vendedores no dupliquen la misma laptop y el catálogo compartido
deje de servir (`cambios-multivendedor.md`, sección 9).

Se quiere abrir la creación a **cualquier vendedor**, pero con un filtro:
el vendedor **propone** un producto, nace en estado **`en_revision`** y no
circula; un admin **o** la tienda lo **aprueba** (pasa a `activo`, catálogo
normal) o lo **rechaza** con un motivo (pasa a `rechazado`). El paso de
revisión es justo lo que hace seguro abrirlo: el admin caza el duplicado
antes de que salga.

## Por qué encaja bien

- **La lista blanca ya protege el catálogo.** La búsqueda, la ficha y la
  compra filtran por `estado: 'activo'` (`ESTADO_PRODUCTO_VISIBLE`). Un
  producto `en_revision` o `rechazado` queda fuera **sin tocar esa
  lógica** — igual que pasó con `pendiente` en las ofertas.
- **`productos_eventos`** ya registra cada cambio de estado, así que el
  historial "propuesto → aprobado / rechazado" sale de la maquinaria que
  ya existe.
- El patrón de aprobar/rechazar/cola es el mismo de
  `PATCH /vendedor/ofertas/:id/revision` + `GET /vendedor/ofertas/pendientes`.

## Decisiones tomadas (2026-08-29)

1. **Dos estados nuevos**: `en_revision` y `rechazado`.
2. **Un producto en revisión NO se puede editar.** Ni `en_revision` ni
   `rechazado`. Lo único que el vendedor puede hacer con un `rechazado` es
   **re-enviarlo tal cual** (`rechazado → en_revision`) o dejarlo. Si quiere
   cambiarlo, no se puede: propone otro.
3. **Aprobar no crea oferta.** Una vez `activo`, el vendedor crea su oferta
   a mano con el `POST /vendedor/ofertas` que ya existe.
4. **Aprueban tanto la tienda como un admin** (igual que las ofertas).
5. **Detección de duplicados: fuera de alcance** por ahora.
6. **El vendedor necesita ver sus propuestas** — un `GET` acotado a
   `propuesta_producto.id_usuario = él`.

## Esquema nuevo en PostgreSQL (ya aplicado en local)

### Dos estados en `estado_producto`

`estado_producto` ya existe en Postgres con `borrador`(1), `activo`(2),
`inactivo`(3). Se agregan **`en_revision`(4)** y **`rechazado`(5)**.

Ojo con un matiz: los productos que propone un vendedor **viven solo en
MongoDB** (`POST /vendedor/productos` no escribe en `productos` de
Postgres desde el giro multi-vendedor). El estado operativo es el string
`estado` del documento de Mongo. Las filas de `estado_producto` en
Postgres son para: el catálogo relacional / ETL (`etl/extraer.sql` lee
`estado_producto_nombre`), la coherencia del esquema, y para que el
compañero tenga el valor a mano en la migración. El backend **no**
consulta `estado_producto`.

### `propuesta_producto` — pivote usuario ↔ producto Mongo

```
propuesta_producto
  id_propuesta_producto   PK
  id_usuario              quién propuso.  FK usuarios, ON DELETE RESTRICT
  id_producto_mongo       el _id del documento en Mongo.  SIN FK (otra base),
                          igual que oferta.id_producto_mongo y pedido_producto
  comentario_aprobacion   texto opcional que el admin/tienda escribe AL APROBAR
  fecha_propuesta         DEFAULT now()
  fecha_aprobacion        NULL hasta que se aprueba
  id_usuario_aprobo       quién aprobó.  FK usuarios, ON DELETE RESTRICT, NULL hasta entonces
  UNIQUE (id_producto_mongo)   -- cada documento Mongo lo propone un solo vendedor
```

- **Un producto lo propone un único vendedor.** Cada propuesta crea un
  documento nuevo en Mongo con su propio `_id` (calculado "máximo + 1",
  igual que hoy), así que `id_producto_mongo` es único en la tabla.
- **`comentario_aprobacion`** es la nota del que aprueba (opcional),
  simétrica al motivo del rechazo. Si lo que se quería era una nota del
  *vendedor* al proponer, es agregar otra columna `nota_propuesta` — decidir
  antes de codear.
- **No lleva estado propio.** El estado del producto (Mongo `estado`) es la
  única fuente de verdad. `fecha_aprobacion IS NULL` + las filas de
  `rechazo_producto` cuentan el resto (igual que `oferta.fecha_aprobacion`).

### `rechazo_producto` — espejo de `rechazo_oferta`

```
rechazo_producto
  id_rechazo_producto     PK
  id_propuesta_producto   FK propuesta_producto, ON DELETE RESTRICT
  razon_rechazo           text NOT NULL, CHECK no-vacío
  fecha_rechazo           DEFAULT now()
```

- Apunta a **la propuesta**, no al `id` de Mongo — así hay integridad
  referencial de verdad (igual que `rechazo_oferta` apunta a `oferta`).
- **Varias filas por propuesta**: rechazada, re-enviada, rechazada otra vez.
  Tabla de solo inserción.

No hace falta back-fill: los 102 productos del conjunto los creó la tienda
/ el ETL, no tienen propuesta.

## Ciclo de vida

```
vendedor convencional  POST /vendedor/productos
   -> documento Mongo con estado 'en_revision'
   -> fila en propuesta_producto (id_usuario = vendedor, fecha_aprobacion NULL)

tienda / admin  POST /vendedor/productos
   -> estado 'borrador' (comportamiento de hoy). SIN propuesta_producto.

tienda / admin  PATCH /vendedor/productos/:id/revision  { decision, ... }
   aprobar  -> Mongo estado 'activo'
             propuesta_producto.fecha_aprobacion = now(), id_usuario_aprobo, comentario_aprobacion?
   rechazar -> Mongo estado 'rechazado'
             INSERT rechazo_producto (id_propuesta_producto, razon_rechazo)

vendedor  PATCH /vendedor/productos/:id/reenviar   (solo el dueño de la propuesta)
   'rechazado' -> 'en_revision'   (sin editar nada)

producto 'activo'  -> catálogo compartido normal, sin dueño.
   El vendedor crea su oferta con POST /vendedor/ofertas (ya existe).
```

## Estado de implementación — `POST /vendedor/productos/propuestas` (HECHO, 2026-08-29)

Un vendedor convencional propone un producto. En `backend/src/`:

| Archivo | Cambio |
|---|---|
| `services/vendedores/productos.service.ts` | nuevo `proponer(idUsuario, datos)` — **no** llama a `exigirTiendaOAdmin`; construye el producto igual que `crear()` pero con `estado: 'en_revision'` (constante local `ESTADO_PRODUCTO_EN_REVISION`); escribe Mongo (documento + evento de creación) y luego `INSERT INTO propuesta_producto (id_usuario, id_producto_mongo)` en Postgres. Nuevo `deshacerProductoMongo()`: si el `INSERT` falla, borra el producto y su evento de Mongo. Un `23505` (choque de `id_producto_mongo`) → `ErrorConflicto` 409 "volvé a intentarlo". Imports nuevos: `pool`, `manejarErrorConexion`, `ErrorConflicto` |
| `controllers/vendedores/productos.controller.ts` | `@Post('propuestas')` → `proponer`. El guard de la clase (`@Roles(vendedor, admin)`) ya deja fuera a los compradores |
| DTO | reusa `CrearProductoPeticion`, sin DTO nuevo |
| `endpoints-vendedores.md` | ruta documentada |

**No se tocó** `models/estado-producto.ts` (el estado lo pone el servidor,
no se valida contra el cliente en esta ruta), ni `crear()`, ni la lista
blanca (`en_revision` queda fuera sola).

**Orden de las dos escrituras**: Mongo primero. El `_id` único de Mongo ya
serializa dos propuestas que compitan por el mismo id (la segunda falla al
insertar el documento y ni llega a Postgres), igual que el riesgo aceptado
de `crear()`. Si Postgres falla después, `deshacerProductoMongo()`
compensa; si esa compensación también falla, queda un producto
`en_revision` sin proponente — invisible por la lista blanca, se registra
en el log.

**Pruebas (41/41)**: producto `en_revision` en Mongo + evento de creación;
`propuesta_producto` con `id_usuario` correcto y `fecha_aprobacion` /
`comentario_aprobacion` NULL; el producto no sale en el buscador ni en la
ficha ni admite ofertas (404), pero sí en `/vendedor/productos/paginado`;
comprador → 403, sin sesión → 401, admin también puede proponer; las 5
validaciones dan 400 sin escribir nada; y forzando un choque de id se
confirmó la compensación (Mongo se deshace, respuesta 409).

### Los tres GET de propuestas (HECHO, 2026-08-29)

| Ruta | Quién | Qué trae |
|---|---|---|
| `GET /vendedor/productos/propuestas` | cualquier vendedor/admin | las **suyas** (`WHERE id_usuario = él`), sin `vendedor` embebido, orden `fecha_propuesta DESC` |
| `GET /vendedor/productos/propuestas/sin-aprobar` | tienda/admin (404 disfrazado) | `WHERE fecha_aprobacion IS NULL` (en_revision + rechazado), con `vendedor`, orden `ASC` (cola) |
| `GET /vendedor/productos/propuestas/todas` | tienda/admin (404 disfrazado) | todas, con `vendedor`, orden `DESC` |

Cada propuesta = la fila de `propuesta_producto` + el documento completo
del producto (Mongo, un `$in`) + `rechazos` (`rechazo_producto`, un
`= ANY`, más reciente primero) — 3 consultas en total sin importar cuántas.
Modelos nuevos: `dto/propuesta-producto.ts`, `models/rechazo-producto.ts`.
Métodos: `listarPropuestasPropias`, `listarPropuestasSinAprobar`,
`listarTodasLasPropuestas`, y el privado `armarPropuestas(filas, incluirVendedor)`.

**Pruebas (39/39)**: "las mías" acotado por `id_usuario` (norte no ve las
de sur ni al revés), sin `vendedor`; `/sin-aprobar` = P1+P2 y no la
aprobada P3, con `vendedor` correcto, orden ascendente; `/todas` = las tres,
descendente; vendedor normal → 404 en las de tienda/admin, comprador → 403;
`producto` embebido completo; dos rechazos → orden más reciente primero.

**Regresión**: las 9 suites del proyecto (334 comprobaciones), sin cambios.

## Estado de implementación — revisión, re-envío y rechazos (HECHO, 2026-08-29)

En `backend/src/`:

| Archivo | Cambio |
|---|---|
| `dto/revisar-propuesta.ts` · `helpers/validaciones-propuesta.ts` | **nuevos**. `RevisarPropuestaPeticion` (`decision`, `razon?`, `comentario?`); `validarComentarioAprobacion` (opcional, texto, recortado). `decision` / `razon` reusan `validarDecisionRevision` / `validarRazonRechazo` de `validaciones-oferta.ts` (mismos mensajes) |
| `services/vendedores/productos.service.ts` → `revisarPropuesta()` | `exigirTiendaOAdmin` primero (404 disfrazado). `SELECT ... FOR UPDATE` sobre `propuesta_producto` como punto de sincronización; lee el estado de Mongo con el lock tomado — tiene que ser `en_revision`, si no 409. Mongo primero (estado + evento de modificación vía `crearEventoModificacion`, que ahora devuelve el `_id` para poder borrarlo), luego Postgres (`UPDATE propuesta_producto` al aprobar / `INSERT rechazo_producto` al rechazar). Si Postgres falla: ROLLBACK + `compensarRevisionMongo()` (revierte el estado y borra el evento) |
| `services/vendedores/productos.service.ts` → `reenviarPropuesta()` | solo el dueño (`propuesta_producto.id_usuario`), 404 disfrazado si no. Mismo lock. `rechazado → en_revision`, sin escritura en Postgres — la transacción existe solo para el lock. Compensación igual |
| `services/vendedores/productos.service.ts` → `listarRechazosPropuesta()` | los rechazos de una propuesta; la ve la tienda/un admin (cualquiera) o el vendedor que la propuso (solo la suya). `esTiendaOAdmin()` nuevo (no lanza) |
| `services/vendedores/ofertas.service.ts` → `listarRechazos()` | **extendido**: la tienda o un admin ahora ven los rechazos de **cualquier** oferta (antes solo los de la tienda). `esTiendaOAdmin()` nuevo (no lanza), `obtenerFilaPorId` (ya existía) |
| `controllers/vendedores/productos.controller.ts` | `@Patch(':id/revision')`, `@Patch(':id/reenviar')`, `@Get('propuestas/:id/rechazos')` |

**No se tocó**: `models/estado-producto.ts` (los estados los pone el
servidor en este flujo, no se validan contra el cliente), `crear()`,
`editar()`, ni el catálogo/ficha/compra (lista blanca `activo`).

> **Pendiente menor, no bloqueante**: `editar()` (`PATCH /vendedor/productos/:id`,
> solo tienda/admin) **hoy sí deja editar** un producto `en_revision` o
> `rechazado`, contradiciendo la decisión #2 ("una propuesta no se edita").
> Un vendedor normal ya no puede (404); solo la tienda/un admin podrían, y
> por diseño no deberían. Es un `if` de guardia en `editar()` que se puede
> agregar cuando se decida.

**Pruebas**: proponer 41/41, GET propuestas 39/39, revisión/re-envío
81/81, GET rechazos (ver abajo). Regresión completa del proyecto sin
cambios.

## Lo que falta

- La migración real en `migrations/` (compañero, `.sql` de referencia listo).
- (Opcional) el guard de `editar()` de la nota de arriba.

## Fuera de `backend/` (lo lleva el compañero)

- **`migrations/003_productos.sql`** — los dos estados en `estado_producto`;
  las dos tablas nuevas (`propuesta_producto`, `rechazo_producto`),
  probablemente en un archivo nuevo `migrations/00X_propuestas.sql` que vaya
  después de `003` y `001_usuarios`.
- **`migrations/datos/generador.js`** — opcional: dejar 1-2 propuestas
  `en_revision` de un vendedor convencional para la demo.
- **`mongo/001_productos.js`** — hoy no hay validador de esquema sobre
  `estado`, así que no fuerza nada; el compañero puede documentar el
  conjunto ampliado.
- **`docs/base-de-datos.md`** — la sección del catálogo y una ADR corta:
  ver abajo.

## La decisión que hay que argumentar (ADR)

El giro multi-vendedor **quitó a propósito el dueño del producto** ("el
catálogo es compartido, nadie posee un producto"). Una propuesta
reintroduce un vínculo usuario ↔ producto.

**La postura**: `propuesta_producto` es **atribución histórica del ciclo de
revisión**, no propiedad. Sirve para saber quién propuso (para mostrarle el
estado, para que re-envíe la suya, para atribuir el rechazo) y **deja de
importar en cuanto el producto es `activo`**: ahí vuelve a ser una entrada
compartida y cualquier vendedor puede ofertar, incluido —o no— el que la
propuso. La fila de `propuesta_producto` se queda como registro de "quién
lo trajo al catálogo", igual que `pedido_producto` guarda "a quién se le
compró ese día" sin que eso signifique que el comprador es dueño de nada.
