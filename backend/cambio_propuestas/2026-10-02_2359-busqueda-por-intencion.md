# Búsqueda por intención: `GET /buscador/productos/intencion`

**Fecha:** 2026-10-02.
**Alcance:** `backend/`. Sin esquema nuevo: usa los vectores que ya viven en
`mesh_comentarios` (reseñas) y en `mesh_productos` (catálogo).

## Por qué

Con los vectores de reseñas y de productos en Elasticsearch se puede buscar por
**lo que la persona quiere lograr**, no por palabras. El ejemplo que lo motivó:
"mi ventana está muy solitaria" tiene que encontrar la maceta cuya reseña dice
"decora muy bien la ventana", sin que compartan ninguna palabra. Las reseñas son
mejores que las descripciones para esto: la descripción habla como vendedor, la
reseña como alguien que lo usó.

## Qué se hizo

- `GET /buscador/productos/intencion?q=&limite=&calificacion_minima=`, pública.
  `controllers/buscador/intencion.controller.ts`,
  `services/buscador/intencion.service.ts` (`BuscadorIntencionService`) y
  `dto/buscar-intencion.ts`, registrados en `app.module.ts`.
- La frase se convierte en vector con Ollama (el mismo modelo) y se hacen dos
  búsquedas kNN: sobre las reseñas raíz de `calificacion_minima` o más
  (por defecto 4), y sobre los productos activos. Se juntan por producto; el
  `puntaje` es el mejor de los dos parecidos (coseno), con un umbral por origen
  (0,45 reseñas, 0,40 productos). Cada resultado trae el `motivo` (la reseña más
  cercana) para poder mostrar "por qué te lo recomendamos".
- Solo productos `activo`, fijo en el código como en `GET /buscador/productos`,
  también para los que salen solo por una reseña.
- `helpers/vectores-ollama.ts`: `pedirVectores` ahora acepta un tiempo límite
  (`limiteMs`); los workers siguen con los 30 s, esta ruta espera 8 s.
- Documentada en `endpoints-buscador.md`, junto a la búsqueda por nombre, con la
  tabla "cuándo usar cuál", y con una nota en `endpoints.md`.

## Probado (local, con el backend corriendo)

El catálogo no tiene ninguna maceta: se probó con reseñas de prueba escritas a
propósito sobre productos que sí existen (ya borradas; los productos recalcularon
su nota a 0 solos).

| Caso | Resultado |
|---|---|
| "mi ventana esta muy solitaria" | el farol solar de jardín primero (0,582), con su reseña como `motivo` |
| "me duele la espalda de estar sentado todo el dia" | la silla ergonómica (0,64), por su reseña |
| "quiero preparar bebidas rapido" | cafetera y licuadora (con `motivo`) |
| frase sin sentido | `200` con `[]` |
| `calificacion_minima=1` | cuenta también la reseña de 2 estrellas |
| `q` vacío, `calificacion_minima=9` | `400` |

`tsc` y `eslint` limpios sobre todo `src/`.

## Límites

- Los umbrales se calibraron con unas pocas frases, no con datos reales.
- Por descripción de producto hay ruido (devolvió perfumes para "bebidas
  rápido"); por reseña es mucho más confiable.
- Los datos del generador usan solo 20 textos de reseña, casi todos de envío:
  con ellos la ruta casi no encuentra nada por intención.
- Necesita Ollama en cada búsqueda (503 si no responde).
- No registra el evento de analítica `busqueda_realizada`.

## Pendiente

Nada fuera de `backend/`. Si se quiere, una segunda pasada: usar la frase también
para buscar en texto (búsqueda híbrida) y registrar el evento de analítica.
