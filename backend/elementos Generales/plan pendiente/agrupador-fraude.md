# El agrupador de casos de fraude

**Estado (2026-09-26, cierre de la sesion): CERRADO de punta a punta,
probado en vivo.** Los 7 pasos (modelo + 3 adaptadores, agrupador union-
busqueda, puntaje, reglas R-CASI, persistencia, worker, las 3 rutas) estan
construidos y probados contra datos reales y escenarios sinteticos
(fusion de casos, reapertura tras descarte). Ver la seccion "Lo que se
construyo" mas abajo para el detalle completo, y "A.4 -- DESCARTADO" para
una decision importante del usuario que reduce el alcance de la formula
de puntaje.

## Fuente del diseno

`docs/fraude-entrega3/02-reglas-backend.md` (fuera de `backend/`, obra del
compañero -- no se toca desde aca). Es la propuesta completa: por que
agrupar, como se juntan hallazgos en casos, el puntaje, los niveles, las
cinco reglas "casi confirmado", cuando corre cada cosa, y un ejemplo real
aplicado a mano sobre los datos del 2026-09-23. Este documento solo cubre
el esquema de Postgres y lo que falta del lado del backend -- para el
"por que" de cada regla y el ejemplo completo, leer el original.

## El problema

Hoy tres fuentes de fraude no se hablan entre si: `anillo_fraude` (grafo,
Neo4j), `hallazgo_evento_fraude` (ClickHouse, F1-F6) y `alerta_fraude`
(login). Cada una tiene su propio panel y su propio ciclo de revision. Si
dos hallazgos de fuentes distintas describen el mismo problema (por
ejemplo, un ciclo de resenas del grafo y una alerta de multi-cuenta por IP
del login, con las mismas cuentas), el admin los ve como dos cosas
separadas y sin puntaje que le diga cual revisar primero.

## Renombrado respecto a la propuesta original

La propuesta original llamaba a las tres tablas nuevas de evidencia
`hallazgo_fraude`, `hallazgo_fraude_cuenta`, `hallazgo_fraude_resena`.
**Se renombraron a `evidencia_caso_fraude`, `evidencia_caso_fraude_cuenta`,
`evidencia_caso_fraude_resena`** (decision del usuario, 2026-09-26): el
nombre original chocaba con `hallazgo_evento_fraude`, que ya existe y es
una cosa completamente distinta (los F1-F6 de ClickHouse, con su propio
ciclo de vida independiente). `caso_fraude` y `nivel_caso_fraude` se
quedaron igual, no generaban confusion.

`evidencia_caso_fraude` **no reemplaza** a `anillo_fraude`/
`hallazgo_evento_fraude`/`alerta_fraude` -- esas tres se quedan exactamente
como estan, con su propio detalle rico y su propio ciclo de revision
individual. El agrupador las LEE como fuentes y arma su propia copia
normalizada (fuente, tipo, clave, puntos, metricas) en
`evidencia_caso_fraude` solo para poder calcular el puntaje del caso en un
solo lugar, sin tener que consultar tres esquemas distintos cada vez.

## El esquema (aplicado en local, `agrupador-fraude.sql` en este directorio)

| Tabla | Que guarda |
|---|---|
| `nivel_caso_fraude` | Catalogo: `informativo`, `revisar`, `prioritario`, `casi_confirmado` |
| `caso_fraude` | El caso: nivel, puntaje, estado (reusa `estado_alerta_fraude`), firma al descartar, motivo, ultima evidencia |
| `regla_casi_confirmado` | Catalogo: `R-CASI-1` .. `R-CASI-5`, con `descripcion` (la condicion y que quiere decir, en una frase) |
| `caso_fraude_regla` | Que reglas R-CASI cumplio cada caso -- puede ser mas de una a la vez (ver el caso 2 del documento original) |
| `evidencia_caso_fraude` | Enlaza UN hallazgo real de `anillo_fraude`/`hallazgo_evento_fraude`/`alerta_fraude` (exactamente una de las tres) a un caso, mas cuantos `puntos` aporta |
| `evidencia_caso_fraude_cuenta` | Que cuentas toca esa evidencia DENTRO DEL CASO, nucleo o periferia |

Mas un `INSERT`: `estado_alerta_fraude` gana el valor `confirmada` (el
unico nivel que habilita sanciones). Los tres catalogos (`nivel_caso_fraude`,
`regla_casi_confirmado`, el nuevo estado) ya vienen poblados en el mismo
`.sql`.

## Dos rondas de correccion del usuario, misma sesion (2026-09-26)

**1. `caso_fraude.reglas_cumplidas` (`text[]`) no estaba normalizado.**
Un arreglo de texto en una columna. Se reemplazo por el catalogo
`regla_casi_confirmado` mas la tabla puente `caso_fraude_regla`, mismo
patron que ya usa el resto del proyecto (`tipo_hallazgo_evento`,
`estado_alerta_fraude`) en vez de texto libre o arreglos.

**2. `evidencia_caso_fraude.fuente`/`clave` tampoco estaba lo mas
normalizado posible.** Revisando la base real se confirmo que las tres
fuentes (`anillo_fraude`, `hallazgo_evento_fraude`, `alerta_fraude`) ya
tienen exactamente una tabla persistida cada una -- asi que en vez de un
`fuente` de texto + una `clave` suelta (que habria que mantener
sincronizada a mano con la tabla real), `evidencia_caso_fraude` pasa a
tener **tres llaves foraneas reales**, exclusivas entre si
(`id_anillo_fraude`/`id_hallazgo_evento_fraude`/`id_alerta_fraude`, con
`CHECK (num_nonnulls(...) = 1)` y un indice unico parcial por columna para
que el mismo hallazgo real no pueda ser evidencia de dos casos a la vez).
Con esto:

- `tipo`/`clave`/`metricas` **ya no se copian**: se leen con un JOIN a la
  fila real, que ya los tiene cada una. `anillo_fraude` era la unica de
  las tres sin un campo de detalle -- se le agrego `detalle jsonb` para
  que las tres se lean igual.
- `evidencia_caso_fraude_resena` **se elimino por completo**: era 100%
  redundante con `anillo_fraude_resena`, que ya enlaza un anillo con sus
  resenas de evidencia. El camino ya es directo:
  `evidencia_caso_fraude -> id_anillo_fraude -> anillo_fraude_resena -> resena`.
- `evidencia_caso_fraude_cuenta` **se revisó y NO es redundante** con
  `hallazgo_evento_fraude_cuenta` (que ya existe con su propio
  `es_nucleo`): esa clasificacion es POR HALLAZGO AISLADO, la de aca es
  POR CASO (nucleo si aparece en >=2 hallazgos del caso completo, o en
  uno fuerte) -- un dato genuinamente nuevo que no existia en ningun lado,
  se recalcula cada vez que el caso se reune.
- `caso_fraude.puntaje`/`ultima_evidencia` se revisaron tambien: son
  valores calculados/cacheados (igual que `precio_tienda` en Mongo o
  `stock_total`), no violaciones de normalizacion -- se guardan por
  rendimiento (ordenar el panel sin recalcular en cada listado), no
  porque dependan de otro atributo no clave.

Probado en vivo contra la base local (dentro de transacciones con
`ROLLBACK`, sin dejar filas): el `CHECK` rechaza 0 fuentes y 2 fuentes a
la vez, y acepta exactamente 1. Aplicado en caliente sobre las tablas
vacias (sin riesgo de perder datos) y confirmado idempotente corriendo el
`.sql` completo dos veces mas.

Idempotente (`IF NOT EXISTS`/`ON CONFLICT DO NOTHING`), aplicado a mano a
la base LOCAL (`docker exec -i mesh-postgres psql -U meme -d mesh -f - < ...`)
y probado corriendolo dos veces sin fallar la segunda.

## Lo que se construyo (2026-09-26, sesion completa)

Los 7 pasos, cada uno probado antes de pasar al siguiente:

1. **El modelo del hallazgo** (`models/fraude/hallazgo.ts`) y **los tres
   adaptadores** (`HallazgoFraudeAdaptadorService`) -- leen
   `anillo_fraude`/`hallazgo_evento_fraude`/`alerta_fraude` y devuelven la
   forma comun. Filtran F1/F4 (eventos) y las alertas de login que
   describen a la victima, no al actor.
2. **El agrupador** (`AgrupadorFraudeService`, `helpers/union-find.ts`) --
   union-busqueda sobre cuentas compartidas. Dos decisiones que **se
   apartan de la propuesta original**:
   - **Cuenta concentradora**: igual que el documento (>10 contrapartes
     en resenas, nunca sirve de puente).
   - **Los hallazgos de LOGIN nunca fusionan** (decision del usuario, en
     vez de la lista de "IPs de confianza" del documento original):
     compartir una IP es un indicio, no una prueba. Un hallazgo de login
     solo se agrega como evidencia extra a un grupo que YA exista por
     evidencia estructural; si no toca ninguno, se descarta -- no forma
     caso por si solo.
3. **El puntaje** (`PuntajeFraudeService`) -- verificado a mano contra el
   Caso 1 del documento original, coincide exacto (56 puntos).
4. **Las reglas R-CASI** (`ReglasCasiConfirmadoService`) -- las 5, con
   R-CASI-3 (compra+devolucion) verificada contra el esquema real
   (`resena -> pedido -> stock_movimiento -> oferta`).
5. **La persistencia** (`PersistenciaCasoFraudeService`) -- crea, actualiza,
   **fusiona** casos existentes cuando una corrida los conecta, y
   **reabre** un caso descartado si la evidencia cambio de verdad (firma
   de tipo+clave+cuentas). Probado con datos reales y con escenarios
   sinteticos de fusion/reapertura, siempre limpiando despues.
6. **El worker** (`AgrupadorFraudeWorkerService`) -- **se aparta del
   documento**: en vez de engancharse a cada uno de los 4 detectores
   existentes ("despues de cada deteccion, solo sobre los casos
   tocados"), es un worker propio con `@Interval` (15 min) que recalcula
   todo desde cero cada vez. Mas simple, evita tocar cuatro servicios ya
   existentes; el costo es hasta 15 min de retraso en vez de ser
   instantaneo.
7. **Las 3 rutas** (`AdminCasosFraudeController`/`CasosFraudeService`) --
   `GET /admin/fraude/casos` (lista paginada, filtros nivel/estado),
   `GET .../casos/:id` (detalle con cuentas y evidencia resuelta contra
   las 3 fuentes reales), `PATCH .../casos/:id` (estado/motivo, exige
   `pendiente` como origen y `motivo` para descartar). Probadas en vivo:
   401/403/200/404/409, y el detalle completo contra un caso real armado
   por el propio pipeline.

Documentado con el detalle tecnico completo en la conversacion de esa
sesion -- este archivo se queda como el resumen de diseno y decisiones,
no repite cada prueba.

## A.4 ("misma casa con calle", via Neo4j) -- DESCARTADO (decision del usuario, 2026-09-26)

El documento original incluye A.4 como una de las tres senales de la
regla R-CASI-1 y como una linea de puntaje aparte (10 puntos, "solo si el
caso ya tiene otro hallazgo de resenas"). **El usuario decidio
descartarlo por completo**: nada que compare direcciones via Neo4j se va
a construir. No es que quede pendiente -- es alcance que YA NO se va a
hacer.

Efecto en el codigo ya escrito (sin cambios necesarios, ya estaba
preparado para esto):

- `ReglasCasiConfirmadoService`: la rama de R-CASI-1 que busca
  `tipos.has('misma_casa_calle')` sigue ahi, comentada como "sin detector
  todavia" -- ahora es mas preciso decir que ese tipo de hallazgo **nunca
  va a existir**. R-CASI-1 sigue siendo alcanzable por sus otras dos
  ramas (F3/F6), asi que la regla en si sigue siendo util.
- `PuntajeFraudeService`: nunca implemento el bono de "misma casa" (no
  hay ningun tipo `misma_casa_calle` en `PUNTOS_BASE`), asi que no hace
  falta quitar nada -- simplemente esos 10 puntos nunca van a sumar.

No se necesita ningun cambio de codigo por este descarte -- ambos
servicios ya se comportan como si A.4 no existiera, que es exactamente lo
que se decidio.

## Le queda al compañero (fuera de `backend/`)

Mandar esta migracion como la 026 real (`agrupador-fraude.sql`, este
directorio) cuando el diseno del backend este cerrado -- ya lo esta.
