# Plan pendiente — Señal `anillo_de_texto`: varias cuentas con reseñas casi iguales

> **Estado (2026-10-02): señal 2 HECHA y probada en local, con el backend
> corriendo. Falta la migración real del catálogo (le toca a quien lleva
> `migrations/`).** Sin ella el detector no puede guardar la señal: no existe
> el tipo `anillo_de_texto` en `tipo_senal_fraude`.
> Es la hermana de `resenas-repetidas.md` (una cuenta que se repite); esta mira
> VARIAS cuentas.

## La señal

**Tres o más cuentas que escribieron reseñas casi iguales sobre el mismo
vendedor, con pocos días de diferencia.** Es la firma de una red de bots o de
cuentas coordinadas que usan la misma plantilla. Se persiste como una señal más
del catálogo único (`senal_fraude`): tipo `anillo_de_texto`, familia
`patron_resenas`, **fuente `elastic`**. Una señal por anillo: `clave` = los ids
de las cuentas, ordenados y unidos con guion (como los demás anillos), y las
cuentas entran a `senal_fraude_cuenta` como `autor` (son las sospechosas). La
evidencia (`senal_fraude_resena`) son todas las reseñas del anillo.

### Parámetros

| Parámetro | Valor | Nota |
|---|---|---|
| Cuentas distintas mínimas | **3** | `MIN_CUENTAS` |
| Largo mínimo de una reseña | **100 caracteres** | `MIN_CARACTERES` = `LARGO_MINIMO_VALORACION`, el mismo de todas las señales de texto (desde 2026-10-04; antes 40). El anillo se queda por **cantidad de cuentas**, no por porcentaje: una red pequeña de bots en un vendedor grande no debe pasar desapercibida |
| Coseno mínimo | **0,92** | `UMBRAL_COSENO` |
| Diferencia máxima entre dos reseñas unidas | **30 días** | `DIAS_ENTRE_RESENAS`: una plantilla repetida a lo largo de meses es otra cosa |
| Ventana | **180 días** | `VENTANA_DIAS`, como la señal 1 |
| Reseñas que se comparan por vendedor | las 1000 más recientes | `MAX_RESENAS_POR_VENDEDOR` (la comparación es de todas contra todas) |
| Intervalo | 15 min | Como los demás detectores |

Los números (3 cuentas, 30 días) los puse yo, a partir de lo que se habló
("mismo producto o vendedor, ventana de tiempo corta, al menos 3 cuentas"). Son
constantes del servicio, fáciles de ajustar.

### Cómo funciona

`AnilloDeTextoDetectorService`
(`services/fraude/anillo-de-texto-detector.service.ts`), mismo molde que
`PatronesFraudeDetectorService`. Cruza dos bases: PostgreSQL sabe quién escribió
cada reseña, a qué vendedor y cuándo; Elasticsearch (`mesh_comentarios`) tiene
el texto y su vector.

1. PostgreSQL saca los vendedores con reseñas de 3 o más autores distintos en la
   ventana, y las reseñas de cada uno.
2. De esas reseñas trae los vectores de Elasticsearch (solo reseñas raíz) y
   descarta las de menos de 100 caracteres.
3. Dos reseñas se unen si son de **autores distintos**, de no más de 30 días de
   diferencia y de coseno 0,92 o más. Un grupo son las que se unen, directa o
   encadenadamente.
4. Si un grupo tiene 3 o más autores distintos, es un anillo y se persiste con
   `registrarAnilloFraude` (el helper no cambió).

Se mira **dentro de un vendedor**: una plantilla repetida por gente que
califica a vendedores distintos es una frase común, no un anillo. Y una cuenta
que se repite a sí misma no cuenta aquí (los pares de la misma cuenta se
descartan): eso es la otra señal.

`detalle`: `vendedor`, `cuentas`, `resenas_en_grupo`, `dias_de_diferencia`,
`similitud_media`, `similitud_minima` y los parámetros usados.

### Dónde engancha

- `models/anillo-fraude.ts` y `dto/paginar-anillos-fraude.ts`: el tipo nuevo, y
  el filtro `tipo=` de `GET /admin/fraude/alertas-resenas` lo acepta.
- `puntaje-fraude.service.ts`: **25 puntos base** (como `satelites`, la
  "granja"). Mayor que los 15 de `resenas_repetidas` porque son varias cuentas
  coordinadas. **No** está en `TIPOS_FUERTES`: por sí sola no vuelve núcleo a
  una cuenta; se deja igual que la señal 1 hasta ver cómo se comporta con datos
  reales.
- Fuente `elastic`: cuenta como un motor aparte en el puntaje (dos motores
  x1,3, tres x1,6). Ya estaba hecho para la señal 1.
- Helper nuevo `helpers/similitud-vectores.ts` (norma, coseno, media y la
  agrupación por parecido), que ahora usan las dos señales. Se refactorizó la
  señal 1 para usarlo; se volvió a probar y da lo mismo.

## Probado (local, 2026-10-02)

Con el detector corrido directamente y cuentas de prueba hechas a propósito (se
borraron al terminar):

| Caso | Resultado |
|---|---|
| 3 cuentas, mismo vendedor, texto casi igual, 0, 2 y 5 días | **anillo**: clave `32-33-34`, 3 reseñas, 5 días, similitud media 0,992 y mínima 0,989, rol `autor` |
| Solo 2 cuentas, mismo vendedor y texto casi igual | sin señal |
| 3 cuentas, texto casi igual, pero a 0, 45 y 90 días | sin señal (pasa de 30 días) |
| 3 cuentas con el mismo texto, cada una sobre un vendedor distinto | sin señal |
| 3 cuentas, mismo vendedor, textos distintos | sin señal |
| 3 cuentas, mismo vendedor, texto casi igual pero de 30 caracteres | sin señal (menos de 40) |
| El adaptador del agrupador sobre el anillo | lo entrega con `fuente: "elastic"` |
| El agrupador de casos (corrido entero) | el anillo forma su propio caso: 25 puntos, nivel `revisar`, evidencia `elastic` / `anillo_de_texto`, las tres cuentas como periferia (`es_nucleo: false`, no está en `TIPOS_FUERTES`). Visible por `GET /admin/fraude/casos` y `.../casos/:id` |
| `GET /admin/fraude/alertas-resenas?tipo=anillo_de_texto` | `200`, con el anillo la señal de clave `53-54-55`; sin él, lista vacía |
| `resenas_repetidas` (señal 1) tras el refactor | sigue dando 2 señales, las cuentas 3 y 7 |
| Limpieza | cuentas, reseñas y señal de prueba borradas; 125 comentarios en PostgreSQL y 125 en el índice, ningún caso vacío |

`tsc` y `eslint` limpios.

## Pendiente

**Fuera de `backend/` (le toca a quien lleva `migrations/`):**

- La migración real con `anillo-de-texto.sql` (este folder): agrega la fuente
  `elastic` (si falta) y el tipo `anillo_de_texto` al catálogo. Idempotente, ya
  aplicado en local.

**Límites conocidos y decisiones abiertas:**

- **Una red que reparte su plantilla entre muchos vendedores**, de a una o dos
  cuentas cada uno, no se ve: el detector mira dentro de un vendedor. Si hace
  falta, una segunda pasada global con ventana de tiempo corta.
- **El generador usa solo 20 textos distintos**, así que los umbrales no se
  pueden calibrar con sus datos (en la base local ninguna combinación llegó a 3
  cuentas distintas sobre un vendedor con la misma frase). El compañero cambia
  el generador luego.
- **Si el anillo crece, la `clave` cambia** (suma la cuenta nueva) y nace una
  señal nueva; la anterior queda. Es lo mismo que pasa con los demás anillos.
- Las frases cortas muy comunes entre gente honesta pueden coincidir; el largo
  mínimo, las 3 cuentas, el mismo vendedor y los 30 días lo contienen, no lo
  eliminan.
