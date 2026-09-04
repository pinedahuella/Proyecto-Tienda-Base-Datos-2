# Cambio: `sincronizacion` en `GET /admin/fraude/anillos` — cierra el outbox del grafo

**Fecha aproximada:** 2026-09-04, mañana.
**Alcance:** solo `backend/`. No tocó migraciones, Mongo, `etl/` ni `neo4j/`.

Es la **pieza 5**, la última que faltaba, del plan
`elementos Generales/plan pendiente/outbox-grafo.md`. Con esto las cinco
piezas del lado del backend quedan hechas y probadas — cierra la parte de
Entrega 2 de este outbox (lo único que queda es la migración real `015` y
el ajuste del ETL, del compañero, fuera de `backend/`).

## El problema

`GET /admin/fraude/anillos` recorre el grafo de Neo4j, que es una
**proyección** de `resena` en PostgreSQL. Si el grafo se atrasó (la cola
del outbox tiene eventos pendientes, o Neo4j estuvo caído un rato), el
panel enseñaba un análisis **completo en apariencia pero incompleto de
verdad**, sin ninguna señal — eso es peor que fallar.

## Qué hace

`GET /admin/fraude/anillos` ahora devuelve un campo más en el payload:

```json
"sincronizacion": {
  "ultima_sincronizacion": "2026-09-04T06:21:57.459Z",
  "pendientes": 0,
  "apartados": 0
}
```

- `ultima_sincronizacion`: `max(procesado_en)` de `evento_grafo`, o `null`
  si nada se ha procesado todavía.
- `pendientes`: eventos sin aplicar (`procesado_en IS NULL`, `intentos < 5`).
- `apartados`: eventos que fallaron 5 veces y no se reintentan más.

Son los mismos tres números que ya devolvía `GET /admin/grafo/conciliacion`
(`ultima_sincronizacion` y `cola`), calculados con la misma consulta —no se
duplicó la lógica, se expuso un segundo consumidor de ella.

**`sincronizacion` completo puede salir `null`**, y eso es a propósito: es
un dato auxiliar de un panel cuyo trabajo principal es otro (detectar
anillos de fraude en Neo4j). Si Postgres no responde a tiempo o si
`evento_grafo` todavía no existe (falta la migración `015`), el campo se
apaga solo — el resto de la respuesta (`anillos`, `analizado`) sigue
funcionando igual, la ruta no se cae por un dato secundario.

## Diseño

`GrafoSyncService.estadoSincronizacion()` (método público nuevo) envuelve el
`estadoCola()` privado que ya existía (el que usa `conciliar()`), con dos
diferencias a propósito frente a como lo usa la conciliación:

1. **Nunca lanza.** `estadoCola()` ya devolvía `null` si la tabla no existe
   (`42P01`), pero para cualquier otro error de conexión llamaba
   `manejarErrorConexion`, que lanza — correcto para `conciliar()` (su
   trabajo ES esa comparación, si Postgres está caído tiene sentido que su
   propia ruta responda 503). Para el panel de fraude eso sería
   desproporcionado: Postgres caído no debería tumbar un análisis que en
   realidad solo necesita Neo4j. `estadoSincronizacion()` atrapa cualquier
   error, lo loguea como warning, y devuelve `null`. Mismo criterio que
   `InventarioLimitadoService.estado()` con Redis (memoria de sesiones
   anteriores: "NO lanza si Redis falla -> warn + null").
2. **Límite de tiempo más corto** (3 s, constante aparte,
   `LIMITE_MS_SINCRONIZACION`) que el de 15 s del análisis de Neo4j — es un
   dato secundario, no debería alargar la respuesta si Postgres está lento.

`FraudeService` recibe `GrafoSyncService` por constructor (ambos ya eran
providers en el `AppModule` plano, sin cambios de módulo) y llama
`estadoSincronizacion()` después de las cuatro consultas Cypher del
análisis, fuera del `conLimiteDeTiempo` de 15 s que las protege (tiene el
suyo propio, más corto).

## Archivos tocados

- `src/models/grafo.ts` — interfaz `SincronizacionGrafo` nueva.
- `src/services/grafo/grafo-sync.service.ts` — método público
  `estadoSincronizacion()` + constante `LIMITE_MS_SINCRONIZACION`.
- `src/models/fraude.ts` — campo `sincronizacion: SincronizacionGrafo | null`
  en `RespuestaFraude`.
- `src/services/fraude/fraude.service.ts` — constructor con
  `GrafoSyncService`, llenar el campo en `analizar()`.

Sin cambios de esquema ni de módulo (`AppModule` ya tenía los dos providers).

## Probado (contra el servidor y las bases reales)

- Caso base (cola al día): `sincronizacion` sale igual a
  `ultima_sincronizacion`/`cola` de `GET /admin/grafo/conciliacion` en el
  mismo instante.
- Evento insertado a mano en `evento_grafo` y leído **antes** de que el
  worker lo aplicara (dentro de la ventana de 10 s del `@Interval`) →
  `pendientes: 1`.
- El mismo evento, tras el siguiente tick del worker → `pendientes: 0`,
  `ultima_sincronizacion` avanza a la hora del tick.
- Evento insertado con `intentos = 5` (simulando uno apartado) →
  `apartados: 1`; confirmado que el worker nunca lo toca
  (`WHERE intentos < 5`).
- Tabla `evento_grafo` renombrada (simulando la migración `015` sin
  aplicar) → `sincronizacion: null`; `anillos` y `analizado` siguen
  presentes, la ruta sigue en `200`. El log del worker mostró el mismo
  warning ya existente de "la tabla evento_grafo todavía no existe" — no
  uno nuevo, es el mismo camino de código (`estadoCola()`).
- Neo4j caído (con la cola normal) → sigue en `503` "No se pudo conectar
  con Neo4j" en el mismo punto de antes, sin llegar siquiera a leer
  `sincronizacion` — el comportamiento de la ruta ante Neo4j caído no
  cambió.
- Sin sesión → `401` sin cambios (no se tocó el guard).

`npx tsc --noEmit` y `eslint` limpios sobre los cuatro archivos tocados.
Todos los eventos de prueba insertados a mano en `evento_grafo` se
borraron al terminar; no quedó ningún residuo en Postgres ni en Neo4j.

## Documentación actualizada

`elementos Generales/endpoints-fraude.md` (ejemplo de `200`, tabla de
campos, sección de pruebas) y
`elementos Generales/plan pendiente/outbox-grafo.md` (piezas 4 y 5
marcadas como hechas, el encabezado de estado).
