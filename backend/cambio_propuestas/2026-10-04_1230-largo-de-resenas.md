# Largo del texto de reseñas y respuestas: 40 a 350 / hasta 350

**Fecha:** 2026-10-04.
**Alcance:** `backend/`. Sin migración: la base solo exige que el texto no esté
vacío (`comentario.comentario`, migración 011).

## Por qué

Vienen tres señales de fraude por texto (cuenta, producto y vendedor con muchas
reseñas "contradictorias": texto malo con 4-5 estrellas o texto bueno con 1-2).
El clasificador (`clasificador-resenas/`) se entrenó con reseñas de más de 150
caracteres, así que las reseñas muy cortas no son confiables. Se acordó:

- Reseña: **mínimo 40**, máximo **350** (antes: hasta 250, sin mínimo).
- Respuesta: máximo **350**, **sin mínimo** (antes: hasta 250). "Gracias por tu
  compra" es una respuesta normal y no lleva estrellas.
- Las señales nuevas analizarán solo reseñas raíz de 100 a 350 caracteres; ese
  corte lo hará el detector, no la validación.

## Qué se hizo

- `helpers/validaciones-resena.ts`: máximo 350 y mínimo de reseña 40.
  `validarComentarioResena` (reseña, 40 a 350) y la nueva `validarRespuestaResena`
  (respuesta, hasta 350) comparten el máximo y el mensaje de "muy largo".
  Mensaje nuevo: `El comentario debe tener al menos 40 caracteres`.
- `services/resenas/resenas.service.ts`: `responder` usa `validarRespuestaResena`;
  `crear` sigue con `validarComentarioResena`.
- Comentarios de `dto/crear-resena.ts` y `dto/responder-resena.ts`.
- Documentado en `endpoints-resenas.md` (reseña y respuesta) y aclarado en
  `endpoints-buscador.md` que el tope de 250 de `/intencion` es propio de esa
  ruta y no cambia.
- Lo que NO cambia: el corte de 15 caracteres para que una respuesta lleve vector
  en `mesh_comentarios` (`MIN_CARACTERES_RESPUESTA`), porque las respuestas
  siguen pudiendo ser cortas.

## Probado

Las dos funciones desde `dist/`: reseña con 0, 1, 39 (error), 40, 350 (ok), 351
(error); respuesta con 0 (error), 1, 21, 350 (ok), 351 (error); el largo se
cuenta después de recortar espacios. Compila sin errores.

## Límites y pendiente de otros (ver `solo-backend`)

- Los comentarios que ya existen no se tocan, aunque midan menos de 40.
- Si el frontend tiene un contador o un `maxlength` de 250 para el texto, hay que
  subirlo a 350 y poner el mínimo de 40 en el formulario de reseña (no en el de
  respuesta). En `frontend/src` no encontré un 250 escrito para esto.
- Preguntas de sustentación o guías que citen "250 caracteres".
