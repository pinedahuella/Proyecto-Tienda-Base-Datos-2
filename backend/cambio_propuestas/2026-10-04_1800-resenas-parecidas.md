# Señales de reseñas parecidas, y las de texto por porcentaje

**Fecha:** 2026-10-04.
**Alcance:** `backend/`. Plan completo en `elementos Generales/plan pendiente/resenas-parecidas.md`.

## Por qué

Con los vectores de las reseñas en `mesh_comentarios` se pueden detectar reseñas
copiadas o automatizadas, no solo por cuenta sino por **vendedor** y por
**producto**. Y las señales por cantidad castigan el volumen (quien escribe mucho
repite alguna frase por casualidad), así que las de cuenta pasan a porcentaje.
Acordado con el usuario: todo con largo mínimo de 100 caracteres, el anillo de
texto se queda por cantidad de cuentas, y los porcentajes (30 / 20 / 40 %) son de
partida, a calibrar después.

## Qué se hizo

- `helpers/similitud-vectores.ts`: `marcarConGemela` — marca cada reseña que
  tiene una gemela, sin encadenar grupos.
- `ResenasRepetidasDetectorService` (`resenas_repetidas`): ahora **5 o más reseñas
  con gemela de la misma cuenta y el 30 % o más** de las analizadas (antes un
  grupo de 5). Largo mínimo 100. El `detalle` cambia (ver el plan).
- `AnilloDeTextoDetectorService` (`anillo_de_texto`): sigue por cantidad de
  cuentas; solo el largo mínimo sube de 40 a 100.
- **Nuevo** `services/fraude/resenas-parecidas-detector.service.ts`
  (`ResenasParecidasDetectorService`, cada 15 min): `resenas_parecidas_vendedor`
  (20 %) y `resenas_parecidas_producto` (40 %). Una reseña tiene gemela si otra
  de **otra cuenta** se le parece (coseno ≥ 0,92, hasta 30 días de diferencia);
  piden 5 o más con gemela y el porcentaje. Solo alerta (no forman casos), igual
  que las notas incoherentes de vendedor y producto (`TIPOS_SOLO_ALERTA`).
- Tipos nuevos en `TipoAnilloFraude`, `TIPOS_ANILLO_FRAUDE_VALIDOS` (filtro `tipo`
  de `GET /admin/fraude/alertas-resenas`) y `HallazgoTipado`. Todo se lee de
  `mesh_comentarios`; no se consulta PostgreSQL.
- Documentado en `endpoints-fraude.md` y en los planes de `resenas-repetidas`,
  `anillo-de-texto` y el nuevo `resenas-parecidas`.

## Probado

28 cuentas de prueba y 80 reseñas escritas a propósito (30 textos distintos con
coseno máximo 0,67; 4 plantillas con copias de coseno ≥ 0,97): cada regla disparó
o no según lo esperado (ver `endpoints-fraude.md`). Cuentas, señales, casos y nodos
del grafo se borraron al terminar; el grafo cuadra con PostgreSQL.

## Pendiente de otros (ver `solo-backend`)

- Migración real con los dos tipos (`plan pendiente/resenas-parecidas.sql`).
- Documentación general y preguntas de sustentación.
- Las señales viejas de `resenas_repetidas` de las cuentas 3 y 7 (generador)
  siguen en la base local; el detector no cierra señales.
