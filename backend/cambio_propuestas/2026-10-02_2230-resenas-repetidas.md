# Señal de fraude `resenas_repetidas`: una cuenta con 5 o más reseñas casi iguales, detectada por el texto en Elasticsearch

**Fecha:** 2026-10-02.
**Alcance:** `backend/`. Un tipo nuevo en el catálogo de señales de PostgreSQL
que **en local está aplicado a mano**; la migración real le toca a quien lleva
`migrations/` (ver "Pendiente fuera de `backend/`").

## Por qué

El texto de las reseñas ya vive, con su vector, en `mesh_comentarios`
(`2026-10-02_2130-cola-de-comentarios.md`). Eso permite detectar un patrón que
el grafo de Neo4j no ve: una cuenta que escribe la misma reseña una y otra vez
(un bot, o alguien que copia y pega). Es la primera de dos señales acordadas;
la segunda (varias cuentas con reseñas muy parecidas, un anillo de texto) queda
para después.

## Qué se hizo

- `services/fraude/resenas-repetidas-detector.service.ts`
  (`ResenasRepetidasDetectorService`, registrado en `app.module.ts`),
  `@Interval` de 15 min, mismo molde que `PatronesFraudeDetectorService`.
  Saca de `mesh_comentarios` las cuentas con 5 o más reseñas raíz en los
  últimos 180 días, compara sus vectores (coseno) y une las que pasan de 0,92.
  Si un grupo tiene 5 o más reseñas de al menos 40 caracteres, la cuenta es una
  señal. Los parámetros están en constantes del servicio.
- Se persiste con `registrarAnilloFraude`, sin cambios: una señal por cuenta
  (`clave` = su id), la cuenta como `autor`, sus reseñas como evidencia y las
  métricas en `detalle`.
- Tipo nuevo `resenas_repetidas` en `models/anillo-fraude.ts` y en
  `dto/paginar-anillos-fraude.ts` (el filtro `tipo=` lo acepta), y 15 puntos
  base en `puntaje-fraude.service.ts`. No está en `TIPOS_FUERTES`.
- SQL de referencia, idempotente: `plan pendiente/resenas-repetidas.sql`
  (fuente `elasticsearch` nueva y el tipo, en la familia `patron_resenas`).
  Plan con parámetros, límites y lo que sigue: `plan pendiente/resenas-repetidas.md`.
- `endpoints-fraude.md`: la lista de tipos del filtro, el mensaje del `400` y
  una nota sobre el tercer detector.

## Probado (local)

Datos del generador más cuentas de prueba a propósito (ya borradas):

| Caso | Resultado |
|---|---|
| Cuentas 3 y 7 del generador | 2 señales, similitud 1, rol `autor` |
| 5 reseñas casi iguales, editadas | señal (similitud media 0,995, mínima 0,992) |
| 4 reseñas idénticas | sin señal (menos de 5) |
| 5 reseñas sobre temas distintos | sin señal |
| 5 reseñas idénticas de 30 caracteres | sin señal (menos de 40) |
| Agrupador de casos, cuenta de prueba con solo esta señal | caso propio de 15 puntos, nivel `informativo`, evidencia `fuente: "elastic"` |
| Agrupador, cuentas 3 y 7 | se unen al caso 13, junto a señales de grafo y login (tres motores) |
| Rutas de admin (`alertas-resenas?tipo=resenas_repetidas`, `detalle-grafo`) | `200` con la señal y sus reseñas |
| Limpieza | 125 comentarios en PostgreSQL y 125 en el índice, ningún caso vacío |

## Fuente propia `elastic` (mismo día, pedida por el usuario)

Al principio el agrupador de casos clasificaba cada señal por su **familia** y
`resenas_repetidas` caía como fuente `grafo`, así que no contaba como un motor
distinto. Ahora clasifica por la **fuente del catálogo** del tipo
(`tipo_senal_fraude.id_fuente_senal_fraude`) y la señal nueva es `elastic`:

- `FuenteHallazgo` y `EvidenciaCasoFraude.fuente` aceptan `elastic`.
- `hallazgo-fraude-adaptador.service.ts`: `FUENTE_POR_CATALOGO` (neo4j a
  `grafo`, clickhouse a `eventos`, login a `login`, elastic a `elastic`) en vez
  de `FUENTE_POR_FAMILIA`. Para los 25 tipos de antes da lo mismo.
- `casos-fraude.service.ts`: `SQL_FUENTE_DEL_TIPO` (antes por familia), en el
  detalle de un caso y en la firma.
- `reglas-casi-confirmado.service.ts`: R-CASI-3 ("otro hallazgo de reseñas")
  cuenta también `elastic`, así la regla se comporta como antes.
- El puntaje no cambió, pero ahora `elastic` cuenta como un motor más (dos
  motores x1,3, tres x1,6). El caso 13 de la base local junta grafo, login y
  `elastic`, y `GET /admin/fraude/casos/13` ya devuelve evidencia con
  `fuente: "elastic"`.
- `resenas-repetidas.sql` crea la fuente con el nombre `elastic` (y renombra la
  `elasticsearch` que existió un rato en la base local).

## Pendiente

**Fuera de `backend/` (le toca al compañero):**

- La migración real con `resenas-repetidas.sql` (la fuente `elastic` y el tipo).
  Sin ella el detector falla al persistir: no existe el tipo.

**Decisiones abiertas** (detalle en el plan):

- Las frases cortas muy comunes entre gente honesta pueden coincidir; el largo
  mínimo y las 5 reseñas lo contienen, no lo eliminan.
- El generador usa solo 20 textos distintos: los umbrales no se pueden calibrar
  con esos datos.
