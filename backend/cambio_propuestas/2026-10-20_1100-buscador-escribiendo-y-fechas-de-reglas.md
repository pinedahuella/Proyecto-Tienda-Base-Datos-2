# El buscador de la cabecera entiende media palabra, y las reglas por fecha solo aceptan fechas posibles

**Fecha:** 2026-10-20, de 10:00 a 11:00. Los dos los pidió Meme con capturas de la
pantalla. Sin migración. Sin commitear todavía.

## 1. GET /buscador/productos?escribiendo=1

La lista que cuelga del buscador de la cabecera busca con cada letra, y usaba la
búsqueda difusa de siempre, que da por hecho que la palabra ya está entera.
Medido contra la base de José David:

| Escrito | Antes | Ahora |
|---|---|---|
| lap | 8 veces El camino de las nubes (lap se toma por las) | 7 laptops, cada una una vez, y después El camino de las nubes |
| lapt | nada | laptops |
| labtop | laptops | laptops |

- Con `escribiendo=1`, `BuscadorProductosService.ejecutar` suma el `bool_prefix`
  sobre `nombre.escribiendo` (el mismo del autocompletado) con peso 20 a la
  difusa. El prefijo puntúa fijo, su peso, y la difusa de lap contra las llega a
  8.2, así que con 3 seguía perdiendo. En el empate manda `resenas_total`.
- Pide hasta 15 veces el tope y deja un resultado por producto
  (`helpers/copias-de-lote.ts`, `unoPorProducto`). `MARCA_DE_LOTE` se movió ahí
  desde `sugeridos.service.ts`, que la importa.
- Sin Elasticsearch, `buscarEnCopia` con la opción `prefijo`: la última palabra
  vale también como principio de una palabra del nombre, con 1.2 contra 0.8 de un
  parecido de una letra.
- Sin el parámetro todo queda igual. La página /buscar no lo manda.
- `pruebas/buscador_escribiendo.mjs`, 20 OK. `busqueda.sh` 14 OK.

## 2. Fechas de las reglas por periodo (`validarFechasPosibles`)

Se guardaban reglas que no pueden pasar, como el 31 de febrero o del 20 de
diciembre al 5 de enero de 2026, que con un solo año el disparador arma como
diciembre y enero del mismo 2026. En crear, y en editar cuando cambia alguna
fecha (pausar o cambiar el porcentaje de una regla vieja sigue funcionando):

- con mes, cada día existe en su mes (febrero 29 sin año, 28 o 29 con año);
- con año, la regla no pasa al año siguiente (para cruzar el fin de año, sin año);
- con año, la regla no terminó antes de hoy en Guatemala.

Sin mes ("del X al Y de cada mes") no cambia nada. `pruebas/reglas_periodo.sh`
da 68 OK, con siete casos nuevos.

En la base había una sola regla, la 39 (oferta 396), del 1 al 10 de enero de
2026, creada por Meme antes del arreglo. Nunca se aplicó. Meme pidió borrarla y
se borró por la API (pausada y DELETE) como `tienda@mesh.com`.

En la pantalla los dos meses van juntos, el año es una lista (este y los cuatro
siguientes) y el día máximo sigue al mes.
