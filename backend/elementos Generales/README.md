# Qué hay en esta carpeta

Reordenado el 2026-09-10 para separar lo vigente de lo histórico, después de
que un archivo de `plan pendiente/` causara una confusión real (ver ese
mismo archivo, `fraude-login-eventos.md`, para el detalle).

- **`endpoints/`** — los contratos de la API, **vigentes**: `endpoints.md`
  es el índice general; cada `endpoints-<área>.md` documenta un grupo de
  rutas a fondo (request, response, códigos de error, pruebas). Es lo
  primero a consultar para saber qué existe y cómo se comporta.
- **`plan pendiente/`** — features en preparación: un `.md` con las
  decisiones de diseño + un `.sql` de referencia (aplicado en local, no es
  la migración real) por cada una. Cuando una feature se construye, su
  `.md` se marca como hecha aquí y el detalle con pruebas pasa a
  `../cambio_propuestas/`.
- **`guias-estudio/`** — material de estudio para exponer/sustentar, no
  documentación operativa del día a día.
- **`historico/`** — planes ya completados o superados por el código
  actual. Se conservan tal cual (son un registro, no se reescribe
  historia), pero **no son la fuente de verdad de nada vigente** — para
  eso está `endpoints/`.
- **`Elementos Documentales/`** — la forma de referencia de los documentos
  de MongoDB (producto/variante), vigente.
- Sueltos en la raíz: `prueba-falla-mongo-checkout.md` y
  `plan-crear-editar-ofertas.md` (vigentes, con un punto todavía abierto
  cada uno), y los binarios de referencia (`Proyecto_TiendaYa_BasesDeDatos2.docx`
  = el enunciado del profesor, `MESH.postman_collection.json`).

`../cambio_propuestas/` (fuera de esta carpeta, en la raíz de `backend/`) es
el historial fechado de cada cambio ya construido, con sus pruebas — no se
reordena, es un registro append-only.
