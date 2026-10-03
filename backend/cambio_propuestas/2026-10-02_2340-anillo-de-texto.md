# Señal de fraude `anillo_de_texto`: tres o más cuentas con reseñas casi iguales sobre el mismo vendedor (fuente `elastic`)

**Fecha:** 2026-10-02.
**Alcance:** `backend/`. Un tipo nuevo en el catálogo de señales de PostgreSQL
que **en local está aplicado a mano**; la migración real le toca a quien lleva
`migrations/` (ver "Pendiente fuera de `backend/`").

## Por qué

Es la segunda de las dos señales acordadas sobre el texto de las reseñas
(`2026-10-02_2230-resenas-repetidas.md` fue la primera, una cuenta que se
repite). Esta detecta un anillo: varias cuentas distintas que usan la misma
plantilla sobre un mismo vendedor, la firma de una red de bots o de cuentas
coordinadas. El grafo de Neo4j ve la estructura (quién reseña a quién), no lo que
dicen; esto lo ve el texto.

## Qué se hizo

- `services/fraude/anillo-de-texto-detector.service.ts`
  (`AnilloDeTextoDetectorService`, registrado en `app.module.ts`), `@Interval`
  de 15 min. PostgreSQL saca los vendedores con reseñas de 3 o más autores
  distintos en los últimos 180 días; de esas reseñas se traen los vectores de
  `mesh_comentarios`; dos reseñas se unen si son de autores distintos, de no más
  de 30 días de diferencia y de coseno 0,92 o más, y un grupo con 3 o más
  autores es un anillo. Mínimo de 40 caracteres por reseña.
- Se persiste con `registrarAnilloFraude`, sin cambios: una señal por anillo
  (`clave` = las cuentas ordenadas y unidas con guion), las cuentas como
  `autor`, las reseñas como evidencia y las métricas en `detalle`.
- Tipo nuevo `anillo_de_texto` en `models/anillo-fraude.ts` y
  `dto/paginar-anillos-fraude.ts` (el filtro `tipo=` lo acepta), y **25 puntos
  base** en `puntaje-fraude.service.ts`. Fuente `elastic` (la misma de
  `resenas_repetidas`, así cuenta como un motor aparte en el puntaje).
- `helpers/similitud-vectores.ts`: norma, coseno, media y agrupación por
  parecido, compartidos con `ResenasRepetidasDetectorService`, que se refactorizó
  para usarlo (mismo resultado).
- SQL de referencia, idempotente: `plan pendiente/anillo-de-texto.sql`. Plan con
  parámetros, límites y decisiones: `plan pendiente/anillo-de-texto.md`.
- `endpoints-fraude.md`: la lista de tipos del filtro, el mensaje del `400` y
  una nota sobre el detector.

## Probado (local)

Cuentas de prueba hechas a propósito (ya borradas):

| Caso | Resultado |
|---|---|
| 3 cuentas, mismo vendedor, texto casi igual, en 5 días | anillo (similitud media 0,992), cuentas como `autor`, y el adaptador lo entrega con fuente `elastic` |
| Solo 2 cuentas | sin señal |
| 3 cuentas pero a 45 y 90 días | sin señal |
| 3 cuentas con el mismo texto sobre vendedores distintos | sin señal |
| 3 cuentas, mismo vendedor, textos distintos | sin señal |
| 3 cuentas, texto casi igual de 30 caracteres | sin señal |
| El agrupador de casos, corrido entero | el anillo forma su propio caso: 25 puntos, nivel `revisar`, evidencia `elastic` / `anillo_de_texto`; visible por `GET /admin/fraude/casos` |
| `GET /admin/fraude/alertas-resenas?tipo=anillo_de_texto` | `200` con la señal (clave `53-54-55`); sin anillo, lista vacía |
| `resenas_repetidas` tras el refactor | sin cambios (2 señales) |
| Limpieza | 125 comentarios en PostgreSQL y 125 en el índice, ningún caso vacío |

## Pendiente

**Fuera de `backend/` (le toca al compañero):**

- La migración real con `anillo-de-texto.sql` (la fuente `elastic` y el tipo).
  Sin ella el detector falla al persistir: no existe el tipo.

**Decisiones abiertas** (detalle en el plan):

- Los parámetros nuevos (3 cuentas, 30 días entre reseñas, 25 puntos, no
  `TIPOS_FUERTES`) los fijé yo; se ajustan con datos reales.
- Una red que reparte su plantilla entre muchos vendedores, de a una o dos
  cuentas cada uno, no se ve: se mira dentro de un vendedor.
- El generador usa solo 20 textos distintos: los umbrales no se pueden calibrar
  con esos datos.
