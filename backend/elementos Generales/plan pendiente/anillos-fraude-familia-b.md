# Persistir la familia B (B.1-B.7) en `anillo_fraude`

> **Estado (2026-09-24): HECHO, aplicado en local y probado en vivo.**
> Sigue a `anillos-fraude-persistencia.md` (mismo folder), que ya dejó
> `anillo_fraude`/`anillo_fraude_resena` funcionando para A.1/A.2
> (`mutuo`/`ciclo`/`reiterado`). Este documento extiende eso a las siete
> consultas de `neo4j/consultas/B1..B7`, encontradas revisando el trabajo de
> un compañero. Ver "Probado en vivo" al final para el detalle de las
> pruebas contra Postgres/Neo4j/el backend real, y la seccion "Ajustes
> encontrados durante la implementacion" para dos cosas que el diseno
> original de abajo no tenia bien y se corrigieron al construir.

## Lo que ya se verificó (sin cambios)

Corriendo el arnés del compañero (`neo4j/correr_patrones.sh`) contra los
contenedores reales: las siete consultas dan lo mismo en Neo4j y en
PostgreSQL, sobre datos reales y sembrados, con las 8 aserciones positivas y
13 controles negativos en verde. El diseño de las consultas en sí no
necesita cambios.

También se probó a mano, quitando el bloque de `Dirección` de A.5 y B.1
(dirección queda fuera de alcance por ahora): ambas siguen encontrando
exactamente los mismos casos, solo pierden esa columna. Eso no requiere
ningún cambio de este plan.

Quedan **cuatro** cosas por resolver antes de conectar B.1-B.7 al backend.

---

## 1. Modelo y validación: los 7 tipos nuevos

**Catálogo** (`tipo_anillo_fraude`, ver el `.sql` de referencia más abajo):
el orden del INSERT fija los ids, igual que hoy. Propuesta de ids 4-10 (los
nombres caben en `varchar(20)`):

| id | nombre | consulta |
|----|--------|----------|
| 4  | `cadena_abierta`      | B.1 |
| 5  | `satelites`           | B.2 |
| 6  | `persistente`         | B.3 |
| 7  | `anillo_en_el_tiempo` | B.4 |
| 8  | `favor_devuelto`      | B.5 |
| 9  | `coordinados`         | B.6 |
| 10 | `reputacion_expres`   | B.7 |

**Código**, mismo patrón que ya existe para mutuo/ciclo/reiterado:

- `models/anillo-fraude.ts`: agregar `ID_TIPO_ANILLO_FRAUDE_CADENA_ABIERTA = 4`
  ... hasta `_REPUTACION_EXPRES = 10`, y ampliar el union type
  `TipoAnilloFraude` con los 7 nombres nuevos.
- `helpers/registrar-anillo-fraude.ts`: agregar las 7 entradas al record
  `ID_TIPO_ANILLO_FRAUDE`.
- `dto/paginar-anillos-fraude.ts`: agregar los 7 nombres a
  `TIPOS_ANILLO_FRAUDE_VALIDOS` (de ahí sale el mensaje de error de
  `validarFiltroTipoAnillo` y qué acepta `?tipo=` en el listado).

Sin esto, aunque la tabla tenga las filas del catálogo, el endpoint
rechazaría `?tipo=cadena_abierta` como inválido y el UPSERT no sabría a qué
id mapear un tipo nuevo.

---

## 2. Derivar "cuentas del anillo" -- el caso B.6

`SQL_CUENTAS_DE_ANILLO` (`fraude-anillos-persistidos.service.ts`) hoy hace
`UNION` de `resena.id_usuario` (autor) y `resena.id_usuario_vendedor`
(vendedor) de toda la evidencia. Funciona para A.1/A.2/B.1/B.3/B.4/B.5/B.7
porque ahí las cuentas sospechosas alternan de autor a vendedor entre sí (o,
en B.7/B.2, el vendedor SÍ es sospechoso -- se beneficia del fraude).

**B.6 es el único caso donde el vendedor es un tercero ajeno**: la evidencia
son dos reseñas de autores distintos (`a`, `b`) sobre el MISMO vendedor
(`v`), y el patrón sospechoso es la coincidencia entre `a` y `b`, no nada de
`v`. El `UNION` de hoy metería a `v` como sospechoso.

**Propuesta**: no hace falta columna nueva en el pivote (`anillo_fraude_resena`
solo dice "esta reseña es evidencia", eso no cambia entre patrones). Alcanza
con una condición dentro del mismo `UNION`, ya que el subquery ya puede ver
`taf` (el tipo) de la fila externa:

```sql
(SELECT COALESCE(json_agg(jsonb_build_object(
           'id_usuario', u.id_usuario::text, 'usuario', u.usuario
         ) ORDER BY u.usuario), '[]'::json)
    FROM (
      SELECT r.id_usuario AS id_usuario
        FROM anillo_fraude_resena afr
        JOIN resena r ON r.id_resena = afr.id_resena
       WHERE afr.id_anillo_fraude = af.id_anillo_fraude
      UNION
      SELECT r.id_usuario_vendedor
        FROM anillo_fraude_resena afr
        JOIN resena r ON r.id_resena = afr.id_resena
       WHERE afr.id_anillo_fraude = af.id_anillo_fraude
         AND taf.tipo_anillo_fraude_nombre <> 'coordinados'
    ) cuentas
    JOIN usuarios u ON u.id_usuario = cuentas.id_usuario
)
```

Un solo `AND` agregado a la mitad "vendedor" del `UNION`. Mismo cambio en
las dos consultas que arman esta columna (`consultarAnillosPaginado` y
`obtenerAnilloPorId`, que hoy repiten el mismo `SQL_CUENTAS_DE_ANILLO`).

---

## 3. Ventana de tiempo por consulta

`AnillosDetectorService` filtra A.1/A.2 para que **la última actividad**
esté dentro de `VENTANA_DIAS` (60) -- sin eso, un anillo de hace dos años
seguiría "confirmándose activo" para siempre. B.1-B.7 traen sus propios
parámetros (duración de la cadena, horas de sincronía, etc.) pero esos
acotan la FORMA del patrón, no su RECENCIA -- una cadena de hace 3 años que
duró 20 días sigue calificando como "cadena de 20 días" aunque no tenga
nada de reciente.

**Propuesta**: agregar a cada consulta (excepto B.4, ver abajo) la misma
condición que ya usa A.1 en su versión con ventana -- que la reseña MÁS
RECIENTE del hallazgo esté dentro de `$dias_ventana_detector` (el mismo
parámetro que ya existe en `B0_parametros.cypher` y que ya está pensado
para igualar `VENTANA_DIAS`):

- B.1, B.3, B.5, B.6: agregar `AND ultima.epochSeconds >= ...` (o
  equivalente) sobre la fecha de la reseña más reciente del hallazgo.
- B.2, B.7: mismo criterio sobre la reseña más reciente de cada satélite /
  cuenta exprés.

**B.4 es la excepción, y es a propósito**: su razón de existir es mostrar
anillos que la ventana esconde (`visible_para_el_detector = FALSE`).
Ponerle la misma ventana la volvería inútil. Propuesta: **B.4 no se persiste
como hallazgo independiente** -- no tiene sentido un `anillo_fraude` de tipo
`anillo_en_el_tiempo` compitiendo por la misma `clave` que ya ocupa un
`ciclo`/`reiterado` de A.1 sobre las mismas cuentas. En vez de eso, B.4 se
usa como **enriquecimiento**: cuando el detalle de un anillo ya persistido
sea de tipo `ciclo` o `reiterado`, `GET .../detalle-grafo` puede correr B.4
acotada a esas cuentas y devolver `vueltas`/`olas`/`visible_para_el_detector`
como dato adicional, sin fila propia en `anillo_fraude`.
**Decidido (actualizado 2026-09-25): B.4 queda FUERA DE ALCANCE.** No se
conecta al backend -- ni como fila propia ni como enriquecimiento del
detalle -- y no esta planeado hacerlo en ninguna ronda futura de este
proyecto. Es la unica de las siete que no se persiste ni se dispara; su
valor sigue siendo la consulta de diagnostico en
`neo4j/consultas/B4_anillo_en_el_tiempo.cypher` tal cual, para correr a
mano si algun dia hace falta revisar si la ventana de 60 dias esta
escondiendo algo. El id 7 del catalogo (`anillo_en_el_tiempo`) queda
reservado (no se reutiliza para otro tipo) pero sin plan de construirse.

---

## 4. Disparo: worker periódico vs. inmediato por reseña

`AnillosDetectorService` tiene dos caminos: `detectar()` (cada 15 min,
todo el grafo) y `detectarInmediato(idResena)` (acotado a la reseña recién
proyectada, exigiendo que forme parte del hallazgo).

**Propuesta**:

- **Worker periódico**: corre las seis consultas persistibles (B.1, B.2,
  B.3, B.5, B.6, B.7 -- B.4 queda fuera, ver punto 3) con ventana, mismo
  molde que `detectar()`.
- **Inmediato, por reseña nueva**: solo para los patrones donde la reseña
  recién creada participa directo del hallazgo entre DOS cuentas --
  **B.1** (cadena), **B.3** (persistente), **B.5** (favor devuelto), **B.6**
  (coordinados) -- exigiendo `$idResena` en la evidencia, igual que ya hace
  `CYPHER_CICLICOS_VENTANA_ACOTADO`.
- **B.2 (satélites) y B.7 (reputación exprés) quedan fuera del disparo
  inmediato**: agrupan por VENDEDOR, no por la reseña puntual -- "¿este
  vendedor ya tiene 3+ satélites?" es una pregunta sobre el vendedor
  completo, no algo que una sola reseña nueva conteste sola. Los cubre el
  worker periódico (15 min de rezago no es un problema real para estos dos
  patrones, que por definición se arman en más de un día).

---

## Resumen para revisar

| # | Cambio | Dónde |
|---|--------|-------|
| 1 | 7 tipos nuevos en catálogo + constantes + validación | `.sql` referencia, `models/`, `helpers/registrar-anillo-fraude.ts`, `dto/paginar-anillos-fraude.ts` |
| 2 | `AND taf.tipo_anillo_fraude_nombre <> 'coordinados'` en la mitad vendedor del `UNION` | `fraude-anillos-persistidos.service.ts` |
| 3 | Ventana de recencia en B.1/B.2/B.3/B.5/B.6/B.7; B.4 no se construye en esta ronda | `patrones-fraude-detector.service.ts` (constantes Cypher nuevas, mismo molde que `CYPHER_*_VENTANA`) |
| 4 | Worker periódico: las 6 persistibles. Inmediato por reseña: solo B.1/B.3/B.5/B.6 | `patrones-fraude-detector.service.ts` (servicio nuevo), enganchado en `resenas.service.ts` |

Además, la unicidad de `anillo_fraude.clave` pasó a
`(id_tipo_anillo_fraude, clave)`: dos patrones distintos sobre el mismo par
de cuentas (ej. B.3 y B.5 sobre el mismo par) no se pisan. Está en
`anillos-fraude-familia-b.sql` (mismo folder), aplicado en local.

---

## Ajustes encontrados durante la implementación

Dos cosas que el diseño de arriba no tenía bien, encontradas al construir y
probar (no al revisar en papel):

### A. La unicidad `(tipo, clave)` sola rompía la escalada mutuo→reiterado

El punto 2 de arriba (y la nota de unicidad) decían "pasar la unicidad a
`(tipo, clave)`" sin más detalle. Hecho así tal cual, el `UPSERT` de
`registrarAnilloFraude` (`ON CONFLICT (clave) DO UPDATE ...`) deja de
funcionar para `mutuo`/`ciclo`/`reiterado`: esos tres SI necesitan compartir
fila (son el mismo caso escalando de confianza, ver `anillos-fraude-persistencia.sql`),
y con la unicidad compuesta un nuevo hallazgo de `reiterado` ya no choca con
la fila existente de `mutuo` sobre la misma `clave` -- crearía una fila
SEPARADA en vez de escalar la existente, rompiendo el comportamiento ya
probado en la ronda anterior ("Downgrade de tipo... actualiza la fila
existente, sin crear una nueva").

**Solución**: `registrarAnilloFraude` ahora distingue dos caminos. Para
`mutuo`/`ciclo`/`reiterado`, busca primero (con `SELECT ... FOR UPDATE`) si
ya existe una fila de CUALQUIERA de los tres tipos para esa `clave`, y la
actualiza; si no existe, inserta. Para los seis tipos de B (que nunca
escalan entre sí), sigue siendo un `INSERT ... ON CONFLICT (id_tipo_anillo_fraude, clave)
DO UPDATE` directo. Confirmado con una prueba en vivo contra la base local
(ver "Probado en vivo" abajo): mutuo→reiterado sigue siendo la MISMA fila, y
un tipo de B sobre la misma `clave` que un `ciclo`/`reiterado` existente
crea una fila aparte, sin pisarlo.

### B. El filtro `$idResena` de B.6 acotado rompía su propio umbral

La primera versión de `CYPHER_B6_VENTANA_ACOTADO` filtraba por `$idResena`
en el mismo `WHERE` que arma los pares `(ra, rb)`, ANTES de contar
`coincidencias`. Eso reduce el conjunto a una sola fila (la de la reseña
nueva) antes de aplicar `WHERE coincidencias >= $min_coincidencias` -- el
conteo nunca llega a 3, así que la versión acotada nunca encontraba nada,
ni siquiera contra un caso real de coordinados de sobra. Se detectó
probando la consulta a mano contra datos sembrados: la versión sin acotar
encontraba el caso completo, la acotada (para una reseña que SI es parte de
ese caso) volvía vacía.

**Solución**: el filtro de `$idResena` se movió a DESPUÉS de agregar
`coincidencias` (`AND $idResena IN (ras.id + rbs.id)`), igual que ya hacían
bien B.1 y B.3 desde el primer diseño. Confirmado con la misma prueba: la
acotada ahora encuentra el caso completo cuando `$idResena` es cualquiera de
sus reseñas, y nada cuando no lo es.

---

## Probado en vivo -- 2026-09-24

| Caso | Resultado |
|---|---|
| Las 6 consultas "ventana" (persistir) contra datos sembrados (transacción con `ROLLBACK`, mismo método que `neo4j/correr_patrones.sh`) | Cada una encuentra exactamente el mismo caso que su consulta original, con ids de cuenta/reseña en vez de correos |
| Las 4 versiones "acotadas" (B.1/B.3/B.5/B.6), con `$idResena` de su propio caso | Encuentran el mismo caso completo |
| Las 4 acotadas, con `$idResena` de un caso de OTRO patrón | Vacío (correcto) |
| B.6 (`coordinados`): derivar cuentas de un caso fabricado con dos autores reales sobre el mismo vendedor real | Cuentas = los dos autores; el vendedor NO aparece |
| B.3 (`persistente`): mismo tipo de prueba | Cuentas = autor + vendedor (el vendedor SI aparece, correcto para este tipo) |
| Escalada `mutuo` → `reiterado` sobre la misma `clave` (llamando `registrarAnilloFraude` directo) | Misma fila (`id_anillo_fraude`), evidencia acumulada de ambas llamadas, ya no aparece como `mutuo` |
| `favor_devuelto` sobre la MISMA `clave` que el `reiterado` de arriba | Fila NUEVA y separada -- no lo pisa |
| App completa arrancando con `PatronesFraudeDetectorService` registrado | `Nest application successfully started`, sin errores |
| Worker periódico real (intervalo bajado a 5s solo para la prueba, repuesto a 15 min después) contra el grafo REAL | Encontró y persistió el caso orgánico `reputacion_expres` (cuentas 14/16/17, ya visto en la revisión inicial) que sigue en la tabla; los hallazgos sobre ids sembrados (que no existen en Postgres, por el `ROLLBACK`) fallaron por la FK de `anillo_fraude_resena` y se loguearon como advertencia sin tumbar el resto -- mismo comportamiento ya probado para A.1/A.2 |
| `GET /admin/fraude/alertas-resenas?tipo=reputacion_expres` (con sesión de admin real) | Devuelve el caso persistido, con las cuentas correctas |
| `GET /admin/fraude/alertas-resenas?tipo=no_existe` | 400 con el mensaje listando los 9 tipos válidos (`anillo_en_el_tiempo` no incluido, como corresponde) |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | Limpios |

`elementos Generales/plan pendiente/anillos-fraude-familia-b.sql` quedó
aplicado en local (catálogo + unicidad compuesta). El caso `reputacion_expres`
persistido durante la prueba (cuentas 14/16/17) es un hallazgo REAL, no un
dato de prueba -- se queda en la tabla a propósito, mismo criterio que los
hallazgos de A.1/A.2 ya persistidos contra el dataset real.

## `cadena_abierta` que sobrevive a su propio ciclo -- decisión: no se toca (2026-09-27)

Reportado por el compañero (`docs/BACKEND-PENDIENTE.md`, "la cadena_abierta
que sobra en un anillo de 3"): si A califica a B y B a C, B.1 guarda la
cadena `cadena_abierta` con esas 3 cuentas. Si despues C califica a A y el
circulo se cierra, A.1 guarda un `ciclo` NUEVO con la misma clave -- pero
nada borra ni cierra la fila vieja de la cadena, que se queda `pendiente`
para siempre.

**Confirmado en el código, no es un malentendido del reporte**: el
`NOT EXISTS { (fin)-[...2..6]->(inicio) }` de `CYPHER_B1_BASE` evita que
B.1 vuelva a CONFIRMAR esa cadena una vez que el circulo ya cerró, pero eso
solo afecta corridas futuras -- la fila que ya se insertó cuando la cadena
todavía estaba abierta no se toca. `registrarAnilloFraude` solo fusiona
tipos dentro de `TIPOS_CICLO_RESENAS` (`mutuo`/`ciclo`/`reiterado`);
`cadena_abierta` nunca estuvo en ese conjunto, así que la escalada
cadena→ciclo nunca se conecta con la fila anterior.

**Decisión del usuario: se deja así, no se arregla.** Cadena abierta y
ciclo son dos estados temporales reales y distintos (primero abierto,
después cerrado) -- conservar ambos como evidencia histórica no es un dato
corrupto. Ademas, con el agrupador de casos ya construido
(`agrupador-fraude.md`), `AgrupadorFraudeService` junta hallazgos que
comparten al menos una cuenta sin excepción para este caso: la cadena y el
ciclo, al compartir las 3 mismas cuentas, ya caen en el MISMO `caso_fraude`
como dos evidencias -- el problema práctico que motivó el reporte (el admin
revisando la misma historia dos veces, como dos casos sueltos) ya no ocurre
en el panel de casos, aunque siga viendose como dos filas separadas en el
panel viejo de anillos (`GET /admin/fraude/alertas-resenas`).

No se tocó ningún código por esta decisión -- ni `AnillosDetectorService`
ni `PatronesFraudeDetectorService` ni `registrarAnilloFraude` cambiaron.

## Lo que le toca al compañero

Nada de esquema real todavía -- `anillos-fraude-familia-b.sql` es de
referencia, igual que `anillos-fraude-persistencia.sql` antes. Cuando se
integre a `migrations/`, la migración real necesita: las 7 filas del
catálogo, y el cambio de unicidad de `anillo_fraude.clave` a
`(id_tipo_anillo_fraude, clave)` -- ver el `.sql` de este folder para el
texto exacto (ya idempotente, se puede copiar tal cual a un archivo de
migración numerado).
