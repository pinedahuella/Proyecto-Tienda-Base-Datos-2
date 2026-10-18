# Plan pendiente — Señales `resenas_parecidas_*`: un vendedor o un producto con reseñas copiadas

> **Cambio 2026-10-16:** los vectores y la valoración de las reseñas ya no están
> en Elasticsearch (`mesh_comentarios`) sino en PostgreSQL (`vector_comentario`,
> pgvector). Donde este plan dice `mesh_comentarios`, hoy es `vector_comentario`,
> y lo que pide del índice o del mapping de `mesh_comentarios` en `elastic/` ya
> no hace falta. Ver `vectores-pgvector.md`.

> **Estado (2026-10-04): HECHO y probado en local, con el backend corriendo.
> Falta lo de otros (migración real, ETL, docs) — ver el final.** Sin el tipo en
> `tipo_senal_fraude` los detectores no pueden guardar nada.
> Complementa `resenas-repetidas.md` (una cuenta que se repite) y
> `anillo-de-texto.md` (varias cuentas con una plantilla).

## La señal

Un vendedor, o un producto, cuyas reseñas son en buena parte **copias de reseñas
de otras cuentas**: la firma de reseñas automatizadas o hechas con una plantilla.
Dos señales del catálogo único (`senal_fraude`), familia `patron_resenas`,
**fuente `elastic`**:

| Tipo | Grupo | Porcentaje | `clave` | Casos |
|---|---|---|---|---|
| `resenas_parecidas_vendedor` | reseñas de los productos de un vendedor | 20 % | id del vendedor | no, solo alerta |
| `resenas_parecidas_producto` | reseñas de un producto | 40 % | `p<id>` | no, solo alerta |

Las dos piden además **5 o más** reseñas con gemela. Son solo alerta para el admin
(`GET /admin/fraude/alertas-resenas`): no forman casos ni suman puntos
(`TIPOS_SOLO_ALERTA` en `HallazgoFraudeAdaptadorService`), porque el vendedor o el
producto pueden ser tanto quien compra reseñas como la víctima de una campaña.

### Qué es una "gemela"

Una reseña tiene gemela si existe otra, de **otra cuenta**, con coseno de 0,92 o
más entre sus vectores y **30 días o menos** de diferencia. Las de la misma cuenta
no cuentan: esa repetición es `resenas_repetidas`, la señal de la cuenta. Y **no
se encadena**: cada reseña cuenta solo si tiene su propia gemela (así un grupo
grande no infla el porcentaje, como pasaba con la unión en grupos).

### Parámetros

| Parámetro | Valor | Dónde |
|---|---|---|
| Reseñas con gemela mínimas | **5** | `MIN_RESENAS` (también el mínimo de analizadas) |
| Porcentaje | **20 % vendedor / 40 % producto** | `DIMENSIONES`; valores de partida, a calibrar |
| Coseno mínimo | **0,92** | `UMBRAL_COSENO` |
| Diferencia máxima entre gemelas | **30 días** | `DIAS_ENTRE_RESENAS` |
| Largo mínimo de una reseña | **100 caracteres** | `LARGO_MINIMO_VALORACION` (todas las señales de texto) |
| Ventana | **180 días** | `VENTANA_DIAS` |
| Reseñas que se comparan por vendedor/producto | las 1000 más recientes | `MAX_RESENAS` (comparación de todas contra todas) |
| Evidencia guardada por señal | las 100 con gemela más recientes | `MAX_EVIDENCIA` |
| Intervalo | 15 min | como los demás detectores |

El porcentaje es reseñas con gemela sobre las **analizadas**: raíz, con vector, de
los últimos 180 días y de 100 caracteres o más.

## Cómo funciona

`ResenasParecidasDetectorService`
(`services/fraude/resenas-parecidas-detector.service.ts`), mismo molde que
`ResenasRepetidasDetectorService`. Todo sale de `mesh_comentarios`, que ya trae
`id_usuario`, `id_vendedor`, `id_producto` y `fecha_publicacion`: no se consulta
PostgreSQL (el anillo de texto sí lo hace para el vendedor y la fecha).

1. Una agregación saca los vendedores (y los productos) con al menos 5 reseñas en
   la ventana.
2. De cada uno trae sus reseñas con el vector y descarta las de menos de 100
   caracteres.
3. `marcarConGemela` (`helpers/similitud-vectores.ts`, nuevo) marca las reseñas
   con gemela de otra cuenta.
4. Si las marcadas son 5 o más y el porcentaje llega, guarda la señal con
   `registrarAnilloFraude` (las marcadas más recientes como evidencia; el producto
   se liga en `senal_fraude_producto`).

`detalle`: `resenas_con_gemela`, `resenas_analizadas`, `porcentaje`,
`porcentaje_minimo`, `min_resenas`, `cuentas_con_gemela`, `similitud_media`,
`similitud_minima`, `umbral_coseno`, `min_caracteres`, `dias_entre_resenas`,
`ventana_dias`.

## Cambios en las señales que ya existían (mismo día)

- `resenas_repetidas`: ahora por **porcentaje** (30 % y 5 o más), ver
  `resenas-repetidas.md`.
- `anillo_de_texto`: se queda por **cantidad de cuentas** (decisión del usuario);
  solo sube el largo mínimo de 40 a 100.

## Probado (2026-10-04)

Ver `endpoints-fraude.md`, "Pruebas -- hechas el 2026-10-04 (reseñas parecidas)":
28 cuentas de prueba y 80 reseñas escritas a propósito (30 textos distintos con
coseno máximo 0,67 entre sí; 4 plantillas con variantes de coseno 0,97 o más).
Cada regla disparó o no según lo esperado. Todo se borró al terminar.

## Límites

- Los porcentajes (30 / 20 / 40) son de partida: no hay datos reales para
  calibrarlos. Las 97 reseñas locales del generador miden menos de 100 caracteres
  y solo hay 17 textos distintos; no producen señales ni sirven para calibrar.
- La comparación es de todas contra todas con tope de 1000: un vendedor con más
  reseñas analiza solo las más recientes.
- `anillo_de_texto` guarda su `clave` solo con las cuentas: dos anillos de las
  mismas cuentas sobre vendedores distintos comparten una señal (se suma la
  evidencia y sube `total_detecciones`).
- Las señales viejas de `resenas_repetidas` (las cuentas 3 y 7 del generador)
  siguen en la base aunque ya no se detectarían: el detector no cierra señales.

## Pendiente de otros (no tocar, ver `solo-backend`)

- Migración real: `resenas-parecidas.sql` (los dos tipos, idempotente).
- Documentación general y preguntas de sustentación.
