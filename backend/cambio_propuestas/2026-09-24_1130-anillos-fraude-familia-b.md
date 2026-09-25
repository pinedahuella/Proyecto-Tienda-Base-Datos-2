# Persistencia de la familia B (B.1-B.7) de patrones de fraude en reseñas

**Fecha:** 2026-09-24, continuación directa de
`elementos Generales/plan pendiente/anillos-fraude-familia-b.md` y de
`anillos-fraude-persistencia.md` (A.1/A.2, ronda del 2026-09-17/18).
**Alcance:** `backend/`, esquema nuevo aplicado en local + un servicio nuevo
de detección/persistencia, enganchado al mismo disparador que
`AnillosDetectorService`. **Explícitamente fuera de esta ronda**: B.4
(anillo en el tiempo) y A.4 (misma dirección) -- ninguno de los dos se
conectó al backend.

## Contexto

Un compañero (fuera del equipo de backend) escribió siete consultas Cypher
nuevas (`neo4j/consultas/B1..B7`) para detectar patrones de fraude en
reseñas que A.1/A.2/A.3/A.5 no ven: cadena abierta, satélites, persistente,
el anillo visto en el tiempo, favor devuelto, coordinados y reputación
exprés. Se revisaron a fondo (corriendo su propio arnés,
`neo4j/correr_patrones.sh`, contra los contenedores reales -- 8 aserciones
positivas y 13 controles negativos en verde) y se verificó que funcionan
igual quitándoles el bloque de `Dirección` (fuera de alcance del proyecto
por ahora). Esta ronda conecta seis de las siete (`B.4` queda fuera, ver
abajo) al mismo mecanismo de persistencia que ya existe para A.1/A.2.

## Diseño, decidido revisando el esquema existente antes de escribir nada

Cuatro cosas necesitaban resolverse porque el esquema de
`anillos-fraude-persistencia.sql` se diseñó pensando solo en
`mutuo`/`ciclo`/`reiterado`:

1. **Los 7 tipos nuevos** en el catálogo `tipo_anillo_fraude` (ids 4-10;
   `anillo_en_el_tiempo` queda reservado sin usarse) y las constantes/listas
   de validación correspondientes en el código.
2. **Derivar "cuentas del caso" se rompe para `coordinados` (B.6).** El
   `UNION` de `resena.id_usuario`/`id_usuario_vendedor` que ya existía
   asume que el vendedor de la evidencia es sospechoso -- cierto para
   `mutuo`/`ciclo`/`reiterado`/`satelites`/`reputacion_expres`, falso para
   `coordinados`, donde el vendedor es un tercero ajeno al patrón (dos
   autores que coinciden calificándolo, sin relación entre sí). Se agregó
   un `AND taf.tipo_anillo_fraude_nombre <> 'coordinados'` a la mitad
   "vendedor" del `UNION` -- sin columna nueva en el pivote.
3. **Ventana de recencia.** Los parámetros propios de cada consulta B
   (duración de la cadena, horas de sincronía, etc.) acotan la FORMA del
   patrón, no si sigue siendo reciente. Se agregó a cada una un filtro
   `>= datetime() - duration({days: $dias})`, igual criterio que
   `AnillosDetectorService.VENTANA_DIAS` -- excepto **B.4**, cuya razón de
   ser es mostrar lo que la ventana esconde; ponérsela la volvería inútil.
   Se decidió no conectar B.4 al backend en esta ronda (ni como caso propio
   ni como enriquecimiento del detalle): sigue viviendo como consulta de
   diagnóstico para correr a mano.
4. **Disparo.** Worker periódico (15 min) para las seis persistibles.
   Disparo inmediato por reseña nueva (`detectarInmediato`) solo para
   B.1/B.3/B.5/B.6, cuya evidencia gira sobre dos cuentas y la reseña
   puntual -- B.2 y B.7 agrupan por VENDEDOR, una pregunta que una sola
   reseña no contesta sola, y quedan solo en el periódico.

**Encontrado construyendo, no en el diseño de papel:** la unicidad de
`anillo_fraude.clave` tenía que pasar a `(id_tipo_anillo_fraude, clave)`
-- si no, dos patrones distintos sobre el mismo par de cuentas (ej. B.3 y
B.5) se pisarían. Pero hecho así tal cual rompía la escalada
`mutuo`→`reiterado` (que SÍ necesita compartir fila): con la unicidad
compuesta, un `reiterado` nuevo ya no choca con la fila `mutuo` existente
sobre la misma `clave`, y crearía una fila separada en vez de escalar.
`registrarAnilloFraude` ahora distingue los dos casos: para
`mutuo`/`ciclo`/`reiterado` busca primero (`SELECT ... FOR UPDATE`) una fila
existente de cualquiera de los tres y la actualiza; para los seis tipos de
B, que nunca escalan entre sí, sigue siendo un `INSERT ... ON CONFLICT`
directo. Confirmado con una prueba en vivo (ver abajo).

También se encontró un bug real probando la versión acotada de B.6: el
filtro `$idResena` iba ANTES de contar `coincidencias`, así que al reducir
la búsqueda a una sola reseña el conteo nunca llegaba al mínimo -- la
versión acotada nunca encontraba nada, ni con un caso real de sobra. Se
movió el filtro a DESPUÉS de agregar, mismo criterio que ya usaban bien B.1
y B.3.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `elementos Generales/plan pendiente/anillos-fraude-familia-b.md` | nuevo -- las cuatro decisiones de diseño, los dos ajustes encontrados al construir, y las pruebas en vivo |
| `elementos Generales/plan pendiente/anillos-fraude-familia-b.sql` | nuevo -- 7 filas de catálogo + unicidad compuesta. Aplicado en local |
| `src/models/anillo-fraude.ts` | constantes `ID_TIPO_ANILLO_FRAUDE_*` nuevas, `TipoAnilloFraude` ampliado a 10 valores |
| `src/dto/paginar-anillos-fraude.ts` | `TIPOS_ANILLO_FRAUDE_VALIDOS` con los 6 tipos B persistibles |
| `src/helpers/registrar-anillo-fraude.ts` | el UPSERT distingue la familia ciclo (mutuo/ciclo/reiterado, comparten fila) de los tipos B (cada uno independiente) |
| `src/services/fraude/fraude-anillos-persistidos.service.ts` | `SQL_CUENTAS_DE_ANILLO` excluye al vendedor para `coordinados` |
| `src/services/fraude/patrones-fraude-detector.service.ts` | nuevo -- worker + disparo inmediato para B.1/B.2/B.3/B.5/B.6/B.7, mismo molde que `AnillosDetectorService` |
| `src/services/resenas/resenas.service.ts` | engancha `PatronesFraudeDetectorService.detectarInmediato` junto al de anillos, después de proyectar la reseña al grafo |
| `src/app.module.ts` | registra el servicio nuevo |
| `elementos Generales/endpoints/endpoints-fraude.md` | actualizado -- los 6 tipos nuevos en el filtro `?tipo=`, la excepción de `coordinados` en la derivación de cuentas, B.4 documentado como fuera de alcance |

No se tocó ningún controller ni se agregó ninguna ruta -- los 6 tipos nuevos
se leen con los mismos `GET`/`PATCH /admin/fraude/alertas-resenas` que ya
existían.

## Probado en vivo -- 2026-09-24

Contra Postgres y Neo4j reales (`mesh-postgres`, `mesh-neo4j`):

| Caso | Resultado |
|---|---|
| Las 6 consultas "ventana" contra datos sembrados (transacción con `ROLLBACK`, mismo método que `correr_patrones.sh`) | Cada una encuentra el mismo caso que su consulta original, con ids en vez de correos |
| Las 4 versiones acotadas (B.1/B.3/B.5/B.6), con `$idResena` de su propio caso / de otro patrón | Encuentran el caso completo / vacío, respectivamente |
| B.6: derivar cuentas de un caso fabricado (dos autores reales, mismo vendedor real) | Cuentas = los dos autores; el vendedor no aparece |
| B.3: mismo tipo de prueba | Cuentas = autor + vendedor (correcto para este tipo) |
| Escalada `mutuo` → `reiterado` sobre la misma `clave` | Misma fila, evidencia acumulada, ya no aparece como `mutuo` |
| `favor_devuelto` sobre la misma `clave` que el `reiterado` de arriba | Fila nueva y separada -- no lo pisa |
| App completa arrancando con `PatronesFraudeDetectorService` registrado | `Nest application successfully started`, sin errores |
| Worker periódico real (intervalo bajado a 5s solo para la prueba, repuesto a 15 min después) contra el grafo REAL | Encontró y persistió el caso orgánico `reputacion_expres` (cuentas 14/16/17); los hallazgos sobre ids sembrados (que no existen en Postgres, por el `ROLLBACK`) fallaron por la FK y se loguearon como advertencia, sin tumbar el resto -- mismo comportamiento que A.1/A.2 |
| `GET /admin/fraude/alertas-resenas?tipo=reputacion_expres` (sesión admin real) | Devuelve el caso persistido, con las cuentas correctas |
| `GET /admin/fraude/alertas-resenas?tipo=no-existe` | `400` con los 9 tipos válidos |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | Limpios |

El caso `reputacion_expres` persistido durante la prueba (cuentas 14/16/17,
`prueba_admin_fraude`) es un hallazgo REAL del dataset, no un dato de
prueba -- se dejó en la tabla a propósito, mismo criterio que los hallazgos
de A.1/A.2 ya persistidos. Los datos sembrados para probar las otras cinco
consultas se limpiaron del grafo al terminar (mismo método reversible que
`correr_patrones.sh`); nada quedó en Postgres porque la siembra corrió
dentro de una transacción con `ROLLBACK`.

## Lo que no se hizo en esta ronda, y por qué

- **B.4 (anillo en el tiempo)** sigue sin construirse -- ni caso propio ni
  enriquecimiento del detalle. Su valor es de diagnóstico (qué tanto
  esconde la ventana de 60 días); se decidió no conectarlo al backend por
  ahora. El id 7 del catálogo queda reservado.
- **A.4 (misma dirección)** sigue completamente fuera de alcance, igual que
  en la ronda anterior.
- **La migración real** (`migrations/0XX_*.sql`) -- le toca al compañero.
  `anillos-fraude-familia-b.sql` ya es idempotente y se puede copiar tal
  cual a un archivo de migración numerado; necesita las 7 filas del
  catálogo y el cambio de unicidad de `anillo_fraude.clave`.
