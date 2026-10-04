# Búsqueda híbrida y sugerencias al proponer un producto

**Fecha:** 2026-10-04.
**Alcance:** `backend/`. Sin esquema nuevo, sin tocar el mapeo ni el ETL: usa los
vectores que ya viven en `mesh_productos`.

## Por qué

Con los vectores de los productos en Elasticsearch se pueden hacer dos cosas
más: un buscador que entienda tanto el nombre como una frase en una sola lista
(**búsqueda híbrida**), y ayudar a quien propone un producto a elegir categoría y
a ver si ya existe uno parecido (**sugerencias al proponer**). Pedidas por el
usuario; la ruta híbrida queda como ruta nueva para que la use el frontend.

## Qué se hizo

- `GET /buscador/productos/hibrida?q=&limite=` (pública):
  `services/buscador/hibrida.service.ts` (`BuscadorHibridoService`),
  `controllers/buscador/hibrida.controller.ts`, `dto/buscar-hibrida.ts`. Junta la
  búsqueda por palabras (el `multi_match` difuso, con `minimum_should_match:
  2<70%` para que una frase no se llene de ruido) y la de significado (kNN, coseno
  de 0,40 o más) por **posición** (RRF, constante 60), no por puntaje. Solo
  productos activos. Si Ollama no responde, contesta solo con las palabras y lo
  dice en `modo: "solo_texto"`. Cada resultado explica por qué salió (`origen`,
  posiciones, `similitud`).
- `POST /vendedor/productos/sugerencias` (vendedor o admin, responde 200):
  `services/vendedores/sugerencias-propuesta.service.ts`
  (`SugerenciasPropuestaService`),
  `controllers/vendedores/sugerencias-propuesta.controller.ts`,
  `dto/sugerencias-propuesta.ts`. Del nombre (y la descripción) saca el vector y
  mira los 30 productos activos más cercanos: sus categorías "votan" ponderadas por
  el parecido (hasta 3, descartando las que aportan menos de 0,25) y ellos mismos
  son los `productos_similares` (hasta 5, uno por grupo de copias), con
  `posible_duplicado` si el nombre es igual o la similitud es de 0,85 o más. El
  nombre se valida con `validarNombreProducto`, el mismo de crear un producto.
- `helpers/similitud-vectores.ts`: `cosenoDePuntaje` (el puntaje de una búsqueda
  kNN con coseno, `(1 + coseno) / 2`, devuelto al coseno).
- Registrados en `app.module.ts`. Documentado en `endpoints-buscador.md`,
  `endpoints-vendedores.md` y el índice `endpoints.md`.

## Probado

En vivo contra el catálogo local (102 productos) y, para las sugerencias, con
sesión de admin (ver las secciones "Probado en vivo -- 2026-10-04" de
`endpoints-buscador.md` y `endpoints-vendedores.md`). Dos ajustes salieron de la
prueba: el `minimum_should_match` de la búsqueda híbrida (con `OR` puro, una frase
traía productos que solo comparten "para" o "algo") y el nombre igual como
criterio propio de duplicado (el nombre solo da ~0,80 de coseno contra el
producto idéntico). Compila y pasa el lint.

## Límites

- Los umbrales (0,40 en la híbrida; 0,5 / 0,85 / 0,25 en las sugerencias) se
  calibraron a mano con el catálogo local, no con datos reales.
- Si el catálogo no tiene nada parecido, las sugerencias dan la categoría "menos
  mala" (`Maceta de ceramica...` devolvió `Cocina`); `mejor_similitud` bajo
  (menos de ~0,6) indica una sugerencia débil.
- La híbrida no registra el evento `busqueda_realizada` de analítica.
- Las sugerencias solo miran productos activos, no propuestas en revisión.

## Pendiente de otros (ver `solo-backend`)

- **Frontend:** usar `GET /buscador/productos/hibrida` en el buscador, y llamar a
  `POST /vendedor/productos/sugerencias` en el formulario de proponer un producto
  (al terminar el nombre, no en cada tecla: cuesta una llamada a Ollama).
- Preguntas de sustentación y documentación general.
