# Señales de notas incoherentes (texto contrario a las estrellas)

**Fecha:** 2026-10-04.
**Alcance:** `backend/`. Plan completo en `elementos Generales/plan pendiente/notas-incoherentes.md`.

## Por qué

El clasificador de reseñas (`clasificador-resenas/`, regresión logística) dice si
el texto de una reseña es bueno o malo. Con las estrellas se detecta una reseña
contradictoria (texto malo con 4-5 estrellas, o bueno con 1-2; el 3 no cuenta) y,
contando por cuenta, producto y vendedor, tres señales de fraude nuevas. Para no
correr el modelo cientos de veces, la valoración se guarda una vez en
`mesh_comentarios` y se cuenta con agregaciones de Elasticsearch.

## Qué se hizo

- `helpers/valoracion-texto.ts` y `backend/modelos/regresion_logistica.json`
  (copia de los pesos): `modeloValoracion`, `probabilidadMala`, `valorarTexto`.
  Se carga solo si coincide con `OLLAMA_MODELO` y 768 dimensiones.
- `services/resenas/valoracion-comentarios.service.ts`
  (`ValoracionComentariosService`, cada 30 s): pone `valoracion_texto`
  (`mala`/`buena`/`dudosa`/`corta`), `prob_mala` y `valoracion_modelo` a las
  reseñas raíz, desde el vector ya guardado (sin Ollama). Largo mínimo 100.
- `EventoComentarioSyncService`: guarda `id_vendedor` y borra la valoración
  cuando el texto cambia.
- `services/fraude/notas-incoherentes-detector.service.ts`
  (`NotasIncoherentesDetectorService`, cada 15 min): una consulta con tres
  agregaciones; 5 o más contradictorias y 20 % (cuenta), 40 % (producto), 20 %
  (vendedor). Ventana de 180 días.
- Tipos nuevos `notas_incoherentes_cuenta|producto|vendedor` en
  `TipoAnilloFraude`, `TIPOS_ANILLO_FRAUDE_VALIDOS` (filtro `tipo` de
  `GET /admin/fraude/alertas-resenas`) y `PUNTOS_BASE` (cuenta: 10).
- La de producto y la de vendedor no entran a los casos
  (`TIPOS_SOLO_ALERTA` en `HallazgoFraudeAdaptadorService`). Ninguna es
  `TIPOS_FUERTES`.
- `registrarAnilloFraude` acepta `productos` (`senal_fraude_producto`). La
  `clave` de producto es `p<id>` para que no se tome por una cuenta.
- Ruta nueva: ninguna. Las señales salen en `GET /admin/fraude/alertas-resenas`
  y la de cuenta en `GET /admin/fraude/casos`. Documentado en `endpoints-fraude.md`.

## Probado

22 cuentas de prueba y 95 reseñas escritas a propósito: el modelo acertó las 85
largas y cada regla disparó o no como se esperaba (ver `endpoints-fraude.md`).
Cuentas, señales, caso y nodos del grafo se borraron al terminar; el grafo
cuadra con PostgreSQL (97 reseñas) y `mesh_comentarios` volvió a 125 documentos.

## Pendiente de otros (ver `solo-backend`)

- Migración real con los tres tipos (`plan pendiente/notas-incoherentes.sql`).
- Mapping de `mesh_comentarios` (`id_vendedor`, `valoracion_texto`, `prob_mala`,
  `valoracion_modelo`) en `elastic/`, y que el ETL no los borre.
- Si se reentrena el clasificador, volver a copiar el JSON a `backend/modelos/`.
