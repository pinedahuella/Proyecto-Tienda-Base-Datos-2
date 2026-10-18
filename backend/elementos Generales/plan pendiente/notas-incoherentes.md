# Plan pendiente — Señales `notas_incoherentes_*`: el texto dice una cosa y las estrellas otra

> **Cambio 2026-10-16:** los vectores y la valoración de las reseñas ya no están
> en Elasticsearch (`mesh_comentarios`) sino en PostgreSQL (`vector_comentario`,
> pgvector). Donde este plan dice `mesh_comentarios`, hoy es `vector_comentario`,
> y lo que pide del índice o del mapping de `mesh_comentarios` en `elastic/` ya
> no hace falta. Ver `vectores-pgvector.md`.

> **Estado (2026-10-04): HECHO y probado en local, con el backend corriendo.
> Falta lo de otros (migración real, mapping de `mesh_comentarios`, ETL) — ver
> el final.** Sin el tipo en `tipo_senal_fraude` los detectores no pueden
> guardar nada.

## La señal

Una reseña es **contradictoria** si su texto suena malo y tiene 4 o 5 estrellas,
o suena bueno y tiene 1 o 2. El 3 no aplica nunca, ni los textos dudosos. El
texto lo valora una regresión logística (`clasificador-resenas/`, ya entrenada;
el backend usa los pesos de `backend/modelos/regresion_logistica.json`).

Tres señales del catálogo único (`senal_fraude`), familia `patron_resenas`,
**fuente `elastic`**. Todas piden **5 o más** reseñas contradictorias **y** un
porcentaje de las reseñas valoradas del mismo grupo:

| Tipo | Grupo | Porcentaje | `clave` | Casos |
|---|---|---|---|---|
| `notas_incoherentes_cuenta` | reseñas que escribió una cuenta | 20 % | id de la cuenta | sí, 10 puntos (no es `TIPOS_FUERTES`) |
| `notas_incoherentes_producto` | reseñas que recibió un producto | 40 % | `p<id>` | no, solo alerta |
| `notas_incoherentes_vendedor` | reseñas de los productos de un vendedor | 20 % | id del vendedor | no, solo alerta |

Producto y vendedor son solo alerta para el admin: una reseña contradictoria
tanto puede venir de quien compra reseñas como de una campaña en contra del
vendedor, así que no suman puntos ni forman casos
(`TIPOS_SOLO_ALERTA` en `HallazgoFraudeAdaptadorService`).

### Parámetros

| Parámetro | Valor | Dónde |
|---|---|---|
| Contradictorias mínimas | **5** | `MIN_CONTRADICTORIAS` |
| Porcentaje | **20 / 40 / 20 %** (cuenta / producto / vendedor) | `DIMENSIONES` |
| Texto malo / bueno | probabilidad de "malo" **≥ 0,8** / **≤ 0,2** | `umbral_fraude` del JSON del modelo; entre medio es `dudosa` |
| Largo mínimo para valorar | **100 caracteres** | `LARGO_MINIMO_VALORACION`; menos es `corta` y no cuenta |
| Largo máximo de una reseña | 350 (mínimo 40 al escribirla) | `validaciones-resena.ts` |
| Ventana | **180 días** | `VENTANA_DIAS` |
| Evidencia guardada por señal | las 100 contradictorias más recientes | `MAX_EVIDENCIA` |
| Intervalo | 15 min (detector), 30 s (valoración) | |

El porcentaje es contradictorias sobre las reseñas **valoradas** (`mala`, `buena`
o `dudosa`) del grupo en la ventana; las `corta` no cuentan en el total.

## Cómo funciona

1. **Valoración, una sola vez por reseña.**
   `EventoComentarioSyncService` ya vectoriza cada reseña (Ollama) y la indexa
   en `mesh_comentarios`. Ahora también guarda `id_vendedor` y, cuando el texto
   cambia, borra `valoracion_texto`/`prob_mala`/`valoracion_modelo`.
   `ValoracionComentariosService` (cada 30 s) busca las reseñas raíz con vector
   sin valoración, o con otra `valoracion_modelo`, y las valora **desde el
   vector que ya está guardado** (una multiplicación de 768 números, sin Ollama).
   Cubre las nuevas, las editadas, las que ya existían y un cambio de modelo,
   de umbrales o de largo mínimo (la versión incluye los tres). El `update` lleva
   `if_seq_no`: si la reseña cambió mientras tanto, se salta y se rehace.
2. **Detección con agregaciones.** `NotasIncoherentesDetectorService` (cada
   15 min) hace UNA consulta con tres `terms` (por `id_usuario`, `id_producto`
   e `id_vendedor`); cada uno cuenta sus contradictorias en una sub-agregación
   y deja pasar solo los que cumplen las dos reglas (`bucket_selector`). Después
   trae las reseñas contradictorias de cada uno como evidencia y guarda la señal
   con `registrarAnilloFraude` (que ahora acepta `productos`, para
   `senal_fraude_producto`).

### Campos nuevos de `mesh_comentarios`

| Campo | Tipo | Qué es |
|---|---|---|
| `id_vendedor` | `long` | el vendedor de la reseña (en la raíz y en las respuestas) |
| `valoracion_texto` | `keyword` | `mala`, `buena`, `dudosa` o `corta`; solo en la raíz |
| `prob_mala` | `float` | probabilidad de que el texto sea malo (no está en las `corta`) |
| `valoracion_modelo` | `keyword` | versión con la que se valoró: modelo, fecha, umbral y largo mínimo |

Ver `comentarios-indice.json`.

## El modelo

`backend/modelos/regresion_logistica.json` es una **copia** de
`clasificador-resenas/modelo/regresion_logistica.json` (17 KB). Si se reentrena,
hay que volver a copiarlo; el backend lo detecta solo (cambia la versión y todo
se revalora). Se carga únicamente si fue entrenado con el mismo modelo de
vectores (`OLLAMA_MODELO`) y las mismas 768 dimensiones; si no, la valoración
queda apagada y se avisa en el log. Ruta cambiable con `CLASIFICADOR_MODELO`.

## Probado (2026-10-04)

Ver `endpoints-fraude.md`, "Pruebas -- hechas el 2026-10-04": 22 cuentas de
prueba, 95 reseñas; el modelo acertó las 85 largas (24 malas, 61 buenas) y cada
regla disparó o no según lo esperado (14 % no, 60 % sí, 25 % de producto no,
50 % sí, 3 estrellas no, textos cortos no). Todo se borró al terminar.

## Límites

- El modelo acierta cerca del 90 % y falla con el sarcasmo. Por eso hacen falta
  5 reseñas y un porcentaje, y por eso ninguna es señal fuerte.
- Solo se valoran reseñas de 100 caracteres o más; las 97 reseñas locales del
  generador miden menos y no producen señales.
- Si se baja `LARGO_MINIMO_VALORACION` o se cambian los umbrales, la versión
  cambia y se revalora todo (barato, pero son pasadas de 200 cada 30 s).
- El rol `autor` de la cuenta en la señal de vendedor es solo cómo la guarda
  `senal_fraude_cuenta`; ahí no significa culpable.

## Pendiente de otros (no tocar, ver `solo-backend`)

- Migración real: `notas-incoherentes.sql` (los tres tipos, idempotente).
- Mapping de `mesh_comentarios` en `elastic/` (los 4 campos), y que el ETL lo
  respete (`cargar_busqueda.sh` no debe borrar `valoracion_*`).
- Las reseñas que ya existen necesitan `id_vendedor`: en local se reencolaron
  todas en `evento_comentario` (`INSERT ... SELECT id_comentario FROM comentario`);
  el worker las reescribe sin llamar a Ollama.
- Documentación general y preguntas de sustentación.
