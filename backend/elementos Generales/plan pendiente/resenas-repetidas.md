# Plan pendiente — Señal `resenas_repetidas`: una cuenta con reseñas casi iguales

> **Cambio 2026-10-16:** los vectores y la valoración de las reseñas ya no están
> en Elasticsearch (`mesh_comentarios`) sino en PostgreSQL (`vector_comentario`,
> pgvector). Donde este plan dice `mesh_comentarios`, hoy es `vector_comentario`,
> y lo que pide del índice o del mapping de `mesh_comentarios` en `elastic/` ya
> no hace falta. Ver `vectores-pgvector.md`.

> **Estado (2026-10-02): señal 1 HECHA y probada en local, con el backend
> corriendo. Falta la migración real del catálogo (le toca a quien lleva
> `migrations/`).** Sin ella el detector no puede guardar la señal: no existe
> el tipo `resenas_repetidas` en `tipo_senal_fraude`.
> La señal 2 (varias cuentas con reseñas muy parecidas, un anillo de texto) ya
> está hecha: ver `anillo-de-texto.md`.
>
> **Cambio 2026-10-04:** la regla pasó de "un grupo de 5 reseñas casi iguales"
> a **porcentaje**: 5 o más reseñas con una gemela (otra de la misma cuenta con
> coseno ≥ 0,92) **y** que sean el **30 %** o más de las reseñas analizadas de la
> cuenta (`PORCENTAJE_MINIMO`). Sin encadenar grupos: cada reseña cuenta solo si
> tiene su propia gemela. El largo mínimo subió de 40 a **100** caracteres (el
> mismo de todas las señales de texto). El `detalle` cambió: ahora trae
> `resenas_con_gemela`, `resenas_analizadas`, `porcentaje`, `porcentaje_minimo`
> y `min_resenas` en vez de `resenas_en_grupo`, `total_resenas_cuenta` y
> `grupos`. Las señales viejas se quedan como estaban hasta que el detector las
> vuelva a encontrar (no se borran solas). Ver `resenas-parecidas.md`.

## De dónde viene esto

El texto de cada reseña y de sus respuestas ya vive, con su vector, en
Elasticsearch (`mesh_comentarios`, ver `evento-comentario.md`). Con eso se
puede detectar fraude por texto, que el grafo de Neo4j no ve: el grafo mira la
estructura (quién reseña a quién), no lo que dicen. Una cuenta que escribe la
misma reseña una y otra vez es la firma de un bot o de alguien que copia y
pega.

## La señal

**Una cuenta con 5 o más reseñas casi iguales, que son el 30 % o más de lo que
escribió (desde 2026-10-04; antes bastaba un grupo de 5).** Se persiste como una señal
más del catálogo único (`senal_fraude`), tipo `resenas_repetidas`, familia
`patron_resenas`, fuente `elastic`. Una señal por cuenta: `clave` = el
id de la cuenta, y la cuenta entra a `senal_fraude_cuenta` como `autor` (es la
sospechosa). La evidencia (`senal_fraude_resena`) son todas las reseñas de sus
grupos de parecidas.

### Parámetros (acordados con el usuario)

| Parámetro | Valor | Nota |
|---|---|---|
| Reseñas casi iguales mínimas | **5** | Constante `MIN_RESENAS` |
| Porcentaje mínimo | **30 %** de las reseñas analizadas | `PORCENTAJE_MINIMO` (2026-10-04), a calibrar con datos reales |
| Largo mínimo de una reseña | **100 caracteres** | `MIN_CARACTERES` = `LARGO_MINIMO_VALORACION` (2026-10-04; hasta entonces 40, que el usuario había pedido) |
| Coseno mínimo | **0,92** | `UMBRAL_COSENO`, entre los vectores de dos reseñas |
| Ventana | **180 días** | `VENTANA_DIAS`. Misma idea que los 60 días de `PatronesFraudeDetectorService`: sin ventana, una señal vieja se "confirmaría activa" para siempre. Mayor que 60 porque la repetición no caduca tan rápido |
| Reseñas que se miran por cuenta | las 500 más recientes | `MAX_RESENAS_POR_CUENTA` |
| Intervalo | 15 min | Como los otros dos detectores de reseñas |

Solo cuentan las reseñas **raíz**, no las respuestas a otras reseñas
(`es_respuesta = false`).

### Cómo funciona

`ResenasRepetidasDetectorService`
(`services/fraude/resenas-repetidas-detector.service.ts`), mismo molde que
`PatronesFraudeDetectorService` (`@Interval`, bandera `procesando`, errores de
conexión solo se loguean):

1. Una agregación en `mesh_comentarios` saca las cuentas con al menos 5
   reseñas en la ventana.
2. De cada una trae sus reseñas con su vector y descarta las de menos de 100
   caracteres.
3. Compara todas contra todas (coseno, calculado en el servicio) y marca cada
   reseña que tiene una gemela: otra con coseno de 0,92 o más.
4. Si las marcadas son 5 o más y el 30 % o más de las analizadas, la cuenta es
   una señal. Se persiste con el mismo `registrarAnilloFraude` que los demás
   patrones.

`detalle` de la señal: `resenas_con_gemela`, `resenas_analizadas`,
`porcentaje`, `porcentaje_minimo`, `min_resenas`, `similitud_media`,
`similitud_minima`, `umbral_coseno`, `min_caracteres`, `ventana_dias`.

### Dónde engancha lo que ya existía

- `models/anillo-fraude.ts` y `dto/paginar-anillos-fraude.ts`: el tipo nuevo,
  para que el filtro `tipo=` de `GET /admin/fraude/alertas-resenas` lo acepte.
- `puntaje-fraude.service.ts`: **15 puntos base** (como `persistente`). No está
  en `TIPOS_FUERTES` del agrupador: por sí sola no vuelve núcleo a una cuenta.
- **Fuente propia `elastic`** (cambio del mismo día, pedido por el usuario).
  Antes el adaptador clasificaba por familia y la señal caía como `grafo`; ahora
  clasifica por la fuente que el catálogo le asigna al tipo
  (`tipo_senal_fraude.id_fuente_senal_fraude`): `neo4j` a `grafo`, `clickhouse`
  a `eventos`, `login` a `login` y `elastic` a `elastic`. Para los 25 tipos
  que ya existían da el mismo resultado que por familia. Cambió:
  `FuenteHallazgo` y `EvidenciaCasoFraude.fuente` (el valor `elastic`),
  `hallazgo-fraude-adaptador.service.ts` (`FUENTE_POR_CATALOGO`),
  `casos-fraude.service.ts` (`SQL_FUENTE_DEL_TIPO`, que antes era por familia)
  y `reglas-casi-confirmado.service.ts`.
- **Efecto en el puntaje:** `elastic` cuenta como un motor aparte. Un caso con
  señales de dos motores multiplica por 1,3 y de tres por 1,6 (el factor de
  `puntaje-fraude.service.ts`, que no cambió). Ya se nota: el caso 13 de la base
  local ahora junta grafo, login y `elastic`, tres motores.
- **Regla R-CASI-3:** pide "otro hallazgo de reseñas" (hoy `fuente === 'grafo'`).
  Ahora cuenta también `elastic`, porque la señal nueva ES un hallazgo de
  reseñas: así la regla se comporta como antes de separar la fuente.
- Las rutas de admin (`GET /admin/fraude/alertas-resenas`, `PATCH`,
  `detalle-grafo`) funcionan igual: la familia es la misma.

## Probado (local, 2026-10-02)

Con el detector corrido directamente y datos del generador más cuentas de
prueba hechas a propósito (se borraron al terminar):

| Caso | Resultado |
|---|---|
| Cuentas 3 y 7 (datos del generador, 5 reseñas idénticas cada una dentro de la ventana) | 2 señales, `similitud_media` 1, rol `autor` |
| Cuenta con 5 reseñas casi iguales, editadas (cambios de una o dos palabras, de 77 a 87 caracteres) | señal; `similitud_media` 0,995, `similitud_minima` 0,992 |
| Cuenta con 4 reseñas idénticas (por debajo de 5) | sin señal |
| Cuenta con 5 reseñas sobre temas distintos | revisada, sin señal |
| Cuenta con 5 reseñas idénticas pero de 30 caracteres | revisada, sin señal (menos de 40) |
| Agrupador de casos, cuenta de prueba con solo esta señal | caso propio de 15 puntos, nivel `informativo`, evidencia `fuente: "elastic"`, la cuenta como periferia (`es_nucleo: false`, no está en `TIPOS_FUERTES`) |
| Agrupador, cuentas 3 y 7 | se unen al caso 13 (comparten cuentas con otras señales): evidencia `elastic:resenas_repetidas` x2 junto a grafo y login, tres motores |
| `GET /admin/fraude/alertas-resenas?tipo=resenas_repetidas` y `.../detalle-grafo` | `200`, las 2 señales y las 5 reseñas de una |
| Re-ejecutar | `total_detecciones` sube a 2 y la señal no se duplica (misma fila). No se probó reabrir una señal ya revisada: eso lo decide `registrarAnilloFraude`, que no cambió |
| Limpieza | cuentas, reseñas, señal y evidencia de prueba borradas; 125 comentarios en PostgreSQL y 125 en el índice |

`tsc` y `eslint` limpios.

## Pendiente

**Fuera de `backend/` (le toca a quien lleva `migrations/`):**

- La migración real con `resenas-repetidas.sql` (este folder): agrega la fuente
  `elastic` y el tipo `resenas_repetidas` al catálogo. Idempotente, ya
  aplicado en local (la fuente se llamó `elasticsearch` un rato y el archivo la
  renombra en la base local).

**Límites conocidos y decisiones abiertas:**

- **Los casos viejos con esta señal cambian de firma.** La firma de un caso
  (`fuente:tipo:clave` por evidencia) ahora dice `elastic:resenas_repetidas`
  y no `grafo:resenas_repetidas`. Solo afecta a casos que ya tuvieran esa
  señal (de hoy), y el agrupador los recalcula en cada corrida.
- **Una frase corta muy común entre gente honesta** ("Excelente producto,
  llegó rápido y bien") puede repetirse en una cuenta que de verdad compra
  mucho. El largo mínimo y las 5 reseñas lo contienen, pero no lo eliminan. Si
  hace falta, bajar la sensibilidad con el IDF del texto (qué tan común es en
  toda la tienda).
- Los datos del generador usan solo 20 textos distintos, así que el umbral no
  se puede calibrar con ellos. El compañero cambia el generador luego.
- `total_detecciones` es "veces vista", no frecuencia real (igual que el resto
  de señales).

**De `backend/` (siguiente):**

- La señal 2, el anillo de texto, ya está hecha (`anillo-de-texto.md`).
- Más adelante, una huella por cuenta (el promedio de los vectores de sus
  reseñas) para comparar cuentas entre sí.
