# Endpoints de admin para los anillos de fraude persistidos

**Fecha:** 2026-09-18, continuación directa de
`2026-09-18_0015-anillos-fraude-persistencia.md` (persistencia sin
endpoints, misma sesión). **Alcance:** `backend/`, controller y servicio
nuevos, sin tocar `FraudeController`/`FraudeService` existentes.

## Qué se pidió

Tres piezas, explícitamente en un controller/servicio **separado** del
panel en vivo (`FraudeController`, Neo4j puro):

1. Listar los anillos ya persistidos, paginado, igual que
   `alertas-login`.
2. Marcar el estado de uno (revisado/descartado), igual que las otras.
3. Traer el detalle real de un anillo específico contra Neo4j, sin volver
   a correr las consultas A.1/A.2 completas.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `src/controllers/admin/admin-fraude-anillos.controller.ts` | nuevo -- `AdminFraudeAnillosController`, las 3 rutas |
| `src/services/fraude/fraude-anillos-persistidos.service.ts` | nuevo -- `FraudeAnillosPersistidosService` |
| `src/dto/paginar-anillos-fraude.ts` | nuevo -- query + forma de la página |
| `src/dto/marcar-anillo-fraude.ts` | nuevo -- cuerpo del `PATCH` |
| `src/helpers/validaciones-anillo-fraude.ts` | nuevo -- `validarFiltroTipoAnillo`/`validarIdAnilloFraude`; reusa `validarFiltroEstadoAlerta`/`validarNuevoEstadoAlerta` de `validaciones-fraude.ts` tal cual (el catálogo de estado ya es genérico) |
| `src/models/anillo-fraude.ts` | ampliado -- `AnilloFraude`, `CuentaDeAnillo`, `DetalleAnilloGrafo`, `ResenaDeAnilloGrafo` |
| `src/app.module.ts` | registra el controller y el servicio nuevos |

Mismo molde exacto que `AdminFraudeLoginController`/`FraudeLoginExploracionService`
(paginación con transacción `REPEATABLE READ READ ONLY`, `PATCH` que solo
transiciona desde `pendiente` con 404/409 según el caso).

**Cómo se resuelve `cuentas` sin una tabla propia**: como ya se decidió que
no hay `anillo_fraude_cuenta` (redundante para mutuo/ciclo/reiterado), el
listado arma las cuentas con un `UNION` sobre
`resena.id_usuario`/`id_usuario_vendedor` de las reseñas en
`anillo_fraude_resena`, unido contra `usuarios`.

**El detalle-grafo no recorre A.1/A.2** -- toma los `id_resena` ya guardados
en `anillo_fraude_resena` y le pide a Neo4j, con una consulta nueva y
simple (`CYPHER_DETALLE_RESENAS`), el autor/vendedor/producto/fecha/
calificación de esas reseñas puntuales. Es deliberadamente distinta de
`CYPHER_GRUPOS_CICLICOS`/`CYPHER_PARES_MISMO_PRODUCTO`: no busca ningún
patrón, ya se sabe cuál es la evidencia.

`GET /admin/fraude/anillos` (el panel en vivo) no se tocó.

## Probado en vivo -- 2026-09-18

Contra el servidor real (`npm run start:dev`) y las bases reales, con
sesión HTTP genuina de `admin_mesh` (login real, cookie real, no llamadas
directas al servicio para esta parte):

| Caso | Resultado |
|---|---|
| Login real (`admin@mesh.com`/`Admin123`) | `200`, cookie de sesión válida |
| `GET /admin/fraude/anillos-persistidos` (sin sesión) | `401` |
| Igual, con sesión de `compradora.norte@mesh.com` (rol comprador) | `403` |
| Igual, con sesión de admin, tras sembrar el anillo real 9/10/11 (ventana ensanchada solo en el script de siembra, sin tocar el código) | `200`, los 2 anillos (`ciclo`, `reiterado`) con `cuentas`/`resenas` correctos |
| `?tipo=ciclo` | `200`, `total_anillos: 1` |
| `?tipo=no-existe` | `400` con los 3 tipos válidos |
| `GET .../:id/detalle-grafo` de un anillo real | `200`, las reseñas exactas con autor/vendedor/producto/fecha reales, ordenadas |
| `GET .../999999999/detalle-grafo` | `404` |
| `PATCH .../:id {"estado":"descartada"}` | `200`, cambia de estado |
| Repetir el mismo `PATCH` | `409` |
| `PATCH .../999999999` | `404` |
| Filtrar `estado=pendiente` tras marcar uno | ya no lo trae |

Antes de esta ronda (por servicio directo, sin HTTP, documentado en la
ronda anterior) ya se había probado que dos escrituras concurrentes a la
misma `clave` -- incluida la carrera real entre `detectar()` y
`detectarInmediato()` -- no duplican fila; estos endpoints solo LEEN esa
misma tabla, así que no repiten esa prueba.

`npx tsc --noEmit` y `eslint` limpios sobre los siete archivos nuevos/tocados.
Datos de prueba limpiados al final (`DELETE` de las filas de
`anillo_fraude`/`anillo_fraude_resena` creadas para la prueba); `resena` y
el grafo quedaron intactos (93 reseñas en las dos bases).

## Lo que no se hizo, y por qué

- **A.4 (misma dirección)** sigue completamente fuera -- ni detección, ni
  esquema, ni endpoint.
- **`GET /admin/fraude/anillos` (el panel en vivo) no cambió** -- las dos
  rutas conviven a propósito, cada una su vista del mismo dominio.
- **Nada en el frontend** -- `PanelFraude.svelte` (fuera de `backend/`)
  sigue sin consumir estas rutas nuevas; es trabajo del equipo de frontend.
