# Plan pendiente — Chequeo inmediato de las señales de texto

> **Estado (2026-10-04): HECHO y probado en local, con el backend corriendo.** No
> necesita migración ni cambios en `elastic/`: usa lo que ya existía.

## Qué es

Hasta ahora las cuatro señales de texto (`resenas_repetidas`, `resenas_parecidas_*`,
`anillo_de_texto`, `notas_incoherentes_*`) solo las encontraba su worker de 15
minutos, y antes de eso la reseña esperaba hasta 10 s a indexarse y hasta 30 s a
valorarse. Ahora siguen la misma estructura que los anillos del grafo: **al escribir
una reseña, se indexa ya, se valora ya y se evalúa solo esa reseña**, sin bloquear la
respuesta.

## Cómo funciona

`ResenasService.crear`, al terminar de insertar, lanza sin esperar (`void`)
`ChequeoTextoInmediatoService.ejecutar(...)`
(`services/fraude/chequeo-texto-inmediato.service.ts`):

1. **Indexar ya:** `EventoComentarioSyncService.procesarAhora()` hace una pasada del
   worker de comentarios (la reseña ya está en la cola `evento_comentario` por el
   trigger), con su vector de Ollama. Si ya hay una pasada en curso, **espera a que
   termine y hace otra**: la reseña nueva pudo quedar fuera de la que ya había
   empezado. El `bulk` va con `refresh: wait_for` para que, al volver, el documento
   ya se pueda buscar.
2. **Valorar ya:** `ValoracionComentariosService.valorarAhora()`, igual (espera la
   pasada en curso y hace otra, con `refresh: wait_for`).
3. **Evaluar solo esta reseña,** en paralelo:

| Señal | Método | Qué mira |
|---|---|---|
| `resenas_repetidas` | `ResenasRepetidasDetectorService.revisarInmediato` | la cuenta de la reseña |
| `resenas_parecidas_vendedor` / `_producto` | `ResenasParecidasDetectorService.revisarInmediato` | el vendedor y el producto de la reseña |
| `anillo_de_texto` | `AnilloDeTextoDetectorService.revisarInmediato` | el vendedor de la reseña |
| `notas_incoherentes_cuenta` / `_producto` / `_vendedor` | `NotasIncoherentesDetectorService.detectarInmediato` | la cuenta, el producto y el vendedor de la reseña |

## Por qué cortan pronto

A diferencia de los anillos (la consulta la hace Neo4j), estas señales comparan
vectores **en el proceso del backend**: un vendedor con 1000 reseñas son unas 500 mil
comparaciones de 768 números, cerca de un segundo que bloquea el proceso. Por eso cada
detector solo hace la cuenta completa si la reseña nueva puede cambiar su resultado:

- `resenas_repetidas`, `resenas_parecidas_*` y `anillo_de_texto`: un porcentaje solo
  puede **subir** si la reseña nueva tiene una gemela. Primero se compara la nueva
  contra las demás (una pasada); si no tiene gemela (o es corta o sin vector), se
  corta ahí. La cuenta de todas contra todas solo ocurre cuando la tiene.
- `notas_incoherentes_*`: solo se evalúa si la reseña nueva es contradictoria (texto
  malo con 4-5 estrellas, o bueno con 1-2); si no, solo pudo bajar un porcentaje. Las
  agregaciones las hace Elasticsearch, acotadas a la cuenta, el producto y el
  vendedor de esa reseña.

## Si algo falla

`ChequeoTextoInmediatoService` no lanza ni reintenta: si no se pudo indexar o valorar
(Ollama o Elasticsearch caídos), o un detector falla, solo se loguea. El evento de la
reseña sigue en la cola y los workers periódicos de cada señal (10 s, 30 s, 15 min) la
recogen en su próxima pasada. Los workers periódicos **no cambiaron**: son la red de
seguridad y los que cuentan todo desde cero.

## Probado (2026-10-04)

Ver `endpoints-fraude.md`, "Pruebas -- hechas el 2026-10-04 (chequeo inmediato de
texto)": reseñas escritas por la API real; las señales aparecieron a los 2 o 3
segundos y la respuesta de `POST /resenas` tardó 15 a 32 ms.

## Límites

- No se probó apagar Ollama o Elasticsearch; el camino de fallo está en el código pero
  no se ejercitó.
- La comparación de la reseña nueva contra las demás tiene el mismo tope que el worker
  (500 reseñas por cuenta, 1000 por vendedor o producto).
- Solo reseñas (`POST /resenas`): una respuesta no lleva estrellas ni entra a estas
  señales, así que no dispara nada.
- Las dos señales de reseñar y cancelar (`resena_positiva_cancelada`,
  `resenas_negativas_canceladas_vendedor`) no pasan por aquí: su disparador es la
  cancelación del pedido (`resenas-canceladas.md`).
