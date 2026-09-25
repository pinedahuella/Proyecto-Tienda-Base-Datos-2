# GET de R2/R3, corrección del filtro de descubrimiento de R2, y llaves de referencia en Redis

**Fecha:** 2026-09-25, cierra el ciclo de R2/R3 empezado en
`2026-09-25_1240-workers-recomendaciones-r2-r3.md`: corrige el hallazgo de
ese mismo documento (llaves siempre vacías) y construye las rutas `GET`
que faltaban.
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## 1. Corrección del filtro de descubrimiento de R2

**El problema** (encontrado en la ronda anterior, corregido en esta): el
worker de R2 procesaba cualquier producto con "alguna vista" en los
últimos 30 días. Pero R2 exige que un candidato comparta al menos
`min_sesiones_en_comun` (2) sesiones con el producto base -- si el
producto base en sí fue visto por MENOS de 2 sesiones, ningún candidato
puede alcanzar ese mínimo nunca (el máximo posible está acotado por
cuántas sesiones vieron al producto base). Verificado en vivo: los 6
productos reales candidatos tenían 1 sola sesión cada uno, y las 6 claves
en Redis quedaban siempre `[]` -- ciclos completos gastados en productos
que matemáticamente no podían dar resultado.

**La corrección**: el descubrimiento ahora agrupa por `id_producto` y
exige `HAVING uniqExact(sesion) >= min_sesiones_en_comun`, en vez de
`SELECT DISTINCT id_producto ... WHERE fecha >= ...` a secas. Confirmado
en vivo con un escenario sembrado: de 5 productos candidatos (según el
criterio viejo), 1 quedó excluido por tener solo 1 sesión -- el mismo
producto que, sin la corrección, hubiera generado una clave vacía inútil.

R3 no tiene un problema análogo: no hay forma de saber de antemano si va a
salir vacío sin correr la consulta completa (depende de si alguna sesión
ajena vio lo mismo que la cuenta), así que su descubrimiento se dejó igual.

## 2. Los workers ahora resuelven Mongo (mismo patrón que `mas-vendidos`)

Antes, `TambienVieronCacheado`/`ParaTiCacheado` solo guardaban ids crudos
de ClickHouse. Se cambió para que cada worker, una vez por ciclo, resuelva
el detalle real de Mongo de TODOS los candidatos de TODOS los
productos/cuentas de esa corrida (una sola consulta con `$in`, nunca una
por producto/cuenta) y lo deje ya embebido en la caché -- mismo criterio
que `MasVendidosSyncService` desde el 2026-09-23: la ruta `GET` que lee
esto después nunca toca MongoDB, solo Redis.

## 3. Las dos rutas `GET`, controller y servicio separados por cada una

**`GET /productos/:id/tambien-vieron`** (R2) -- pública, sin sesión.
`TambienVieronController`/`Service`, lee `mesh:producto:<id>:tambien-vieron`.

**`GET /productos/para-ti`** (R3) -- **requiere sesión** (`SesionGuard`,
sin `@Roles`), a diferencia de R1: R3 no tiene sentido sin una cuenta real
de la que partir. `id_usuario` sale del token (`@UsuarioActual()`), nunca
de un parámetro. `ParaTiController`/`Service`, lee
`mesh:cuenta:<id_usuario>:para-ti`.

Las dos son puramente lectura de Redis (`manejarErrorRedis` -> `503` si
Redis está caído), mismo molde que `MasVendidosService`/`MasVendidosController`.
`clave()` pasó de método de instancia a **estático** en los dos workers,
para que el servicio de lectura arme la misma clave sin tener que inyectar
el worker completo (mismo criterio que
`MasVendidosSyncService.CLAVE_RANKING`).

## Qué se hizo

| Archivo | Qué cambió |
|---|---|
| `src/services/productos/tambien-vieron-sync.service.ts` | descubrimiento corregido (`HAVING uniqExact(sesion) >=`), resuelve Mongo una vez por ciclo, `clave()` estático |
| `src/services/productos/para-ti-sync.service.ts` | resuelve Mongo una vez por ciclo, `clave()` estático |
| `src/services/productos/tambien-vieron.service.ts` | nuevo -- lectura pura de Redis |
| `src/services/productos/para-ti.service.ts` | nuevo -- lectura pura de Redis |
| `src/controllers/productos/tambien-vieron.controller.ts` | nuevo -- `GET /productos/:id/tambien-vieron` |
| `src/controllers/productos/para-ti.controller.ts` | nuevo -- `GET /productos/para-ti` |
| `src/app.module.ts` | registra los dos controllers y los dos servicios de lectura nuevos |
| `elementos Generales/endpoints/endpoints-productos.md` | nueva sección dedicada, con las pruebas |

## Probado en vivo -- 2026-09-25

Contra el servidor, ClickHouse, MongoDB y Redis reales:

| Caso | Resultado |
|---|---|
| Filtro corregido de R2 | de 6 candidatos (criterio viejo, con datos del escenario sembrado) a 4 (criterio nuevo) -- el que tenía 1 sola sesión se excluyó |
| Escenario sembrado (Juan + 5 ajenas, ya verificado a mano antes) | `GET /productos/990001/tambien-vieron` → `[{990003, afinidad 0.707}]`, idéntico al valor ya conocido |
| Producto excluido por el filtro nuevo | `GET /productos/990004/tambien-vieron` → `200`, `[]` (nunca se calculó, nunca hubo clave) |
| Escenario de referencia con productos REALES (1 y 4) | `GET /productos/1/tambien-vieron` → el producto candidato viene con el documento COMPLETO de Mongo ("Laptop Lienzo 15"), resuelto por el worker, la ruta no tocó Mongo |
| `GET /productos/para-ti` sin sesión | `401` "No hay sesion activa" |
| `GET /productos/para-ti` con sesión real (`comprador_sur`) + escenario de referencia real | `200`, `[{4, puntaje: 1.724, porque_viste: [1], producto: "Laptop Lienzo 15"}]` |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

**Llaves de referencia dejadas a propósito en Redis** (pedido explícito del
usuario): `mesh:producto:1:tambien-vieron`, `mesh:cuenta:3:para-ti` (las
dos con "Laptop Lienzo 15" resuelto completo, para ver cómo se ve con
datos reales) y `mesh:cuenta:999101:para-ti` (cuenta ficticia, `producto:
null` porque los ids no existen -- para contrastar el caso "sin
documento"). El servidor se detuvo ANTES de borrar las filas sembradas en
ClickHouse, para que el worker no sobrescribiera estas tres claves con un
resultado vacío en su siguiente ciclo -- quedan con su último valor bueno,
sin TTL, no se van a limpiar solas (mismo comportamiento que tendría un
producto/cuenta real que deja de tener actividad -- ver la sección de
"pendiente" de la ronda anterior sobre el TTL de limpieza, todavía sin
resolver).

**Nota de infraestructura, sin relación con el código:** durante esta
ronda `mesh-clickhouse`/`mesh-neo4j` tuvieron picos de CPU muy altos
(hasta 260%) que hicieron que `tsc`/`nest --watch` tardaran hasta 8
minutos en compilar (normalmente ~15-20s) -- además se encontraron y
limpiaron ~14 procesos de Node huérfanos acumulados de rondas de prueba
anteriores en esta misma sesión larga, que agravaban el problema. Nada de
esto es un bug del código de esta ronda.

## Lo que sigue sin resolver

- TTL de limpieza para cuando un producto/cuenta deja de tener actividad
  reciente (anotado desde la ronda anterior, sigue pendiente).
- Decisión de "caer a T1 si `para-ti` viene vacío" -- queda del lado de
  quien consuma esta ruta (frontend), no resuelta en el backend.
- R4 (similares) sigue apartada -- depende de que Mongo arme la lista de
  candidatos por categoría/precio.
