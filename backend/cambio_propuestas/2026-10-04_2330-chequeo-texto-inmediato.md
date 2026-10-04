# Chequeo inmediato de las señales de texto al escribir una reseña

**Fecha:** 2026-10-04.
**Alcance:** `backend/`. Sin esquema nuevo, sin tocar el mapeo ni el ETL. Plan en
`elementos Generales/plan pendiente/chequeo-texto-inmediato.md`.

## Por qué

Las señales de texto solo las encontraba su worker de 15 minutos (y la reseña
esperaba antes hasta 10 s para indexarse y 30 s para valorarse). Pedido por el
usuario: la estructura de los anillos del grafo (al escribir, dejar todo al día y
lanzar la consulta de esa reseña), sin bloquear, y que lo que falle lo recojan las
pasadas siguientes.

## Qué se hizo

- `services/fraude/chequeo-texto-inmediato.service.ts`
  (`ChequeoTextoInmediatoService`): indexa ya, valora ya y evalúa solo esa reseña en
  las cuatro señales, en paralelo. No lanza ni reintenta.
- `ResenasService.crear`: lo lanza con `void`, después de la cadena del grafo; la
  respuesta no espera.
- `EventoComentarioSyncService.procesarAhora()` y
  `ValoracionComentariosService.valorarAhora()`: hacen una pasada y terminan cuando el
  documento ya se puede buscar. Si hay una en curso, esperan y hacen otra. La bandera
  `procesando` se cambió por la promesa de la pasada en curso; los `@Interval` siguen
  igual. Los `bulk` ahora van con `refresh: wait_for`.
- `revisarInmediato` en `ResenasRepetidasDetectorService`,
  `ResenasParecidasDetectorService` y `AnilloDeTextoDetectorService`, y
  `detectarInmediato` en `NotasIncoherentesDetectorService`. Cada uno corta pronto si la
  reseña nueva no puede cambiar el resultado (sin gemela; no contradictoria), porque la
  comparación de vectores corre en el proceso del backend.
- Las condiciones de gemela se sacaron a una función local (`sonGemelas`) para que el
  chequeo inmediato y el completo usen exactamente la misma regla.

## Probado

13 cuentas de prueba; tres escribieron la reseña por la API real. Las señales
aparecieron a los 2 o 3 segundos con `total_detecciones` 1 (las puso el chequeo
inmediato, no el worker), `POST /resenas` respondió en 15 a 32 ms y una reseña normal
no creó nada (ver `endpoints-fraude.md`). Todo se borró al terminar.

## Límites y pendiente

- No se probó apagar Ollama o Elasticsearch para ver el camino de fallo.
- Pendiente de otros (ver `solo-backend`): documentación general y preguntas de
  sustentación. No hay migración ni cambio de `elastic/`.
