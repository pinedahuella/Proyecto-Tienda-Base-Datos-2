-- extraer_notas.sql
-- Saca la nota de cada producto agrupando la tabla resena, y NADA MAS.
--
-- POR QUE EXISTE ESTE ARCHIVO, si extraer.sql ya calcula los mismos dos
-- numeros. Porque extraer.sql los calcula recorriendo `FROM productos p`, o
-- sea la tabla de PostgreSQL, y hay productos que no estan ahi.
--
-- Un producto publicado desde el panel del vendedor nace en MongoDB y no deja
-- fila en PostgreSQL. Ese producto tiene ofertas, se puede comprar y se puede
-- resenar hoy, pero extraer.sql no pasa por el jamas: su nota se queda para
-- siempre en el 0 con que lo rellena mongo/002_resenas.js. Esta consulta no
-- recorre productos, recorre RESENAS, asi que lo alcanza igual.
--
-- Y arregla el caso simetrico, que es el que se vio primero. Cuando se borra
-- la ultima resena de un producto, la fila desaparece de `resena` y el
-- documento de Mongo se queda con la nota vieja. Medido el 2026-09-04 sobre la
-- base viva: el producto 1 decia resenas_total 1 y promedio 4 con CERO filas
-- en `resena`. Esta consulta no lo puede arreglar sola -- un producto sin
-- resenas no sale por aqui, porque no tiene de donde salir -- y por eso el
-- apagado lo hace cargar_notas.js, que sabe cuales NO vinieron en esta lista.
--
-- NO HAY JOIN CONTRA productos, y es a proposito. `resena.id_producto_mongo`
-- es un bigint suelto sin clave foranea (migrations/011_resenas.sql), y esa
-- ausencia es justamente lo que permite resenar un producto que solo vive en
-- Mongo. Meter un JOIN aqui volveria a dejar fuera a los mismos productos que
-- este archivo existe para alcanzar.
--
-- EL REDONDEO ES EL MISMO QUE EL DE extraer.sql, letra por letra
-- (`round(avg(r.calificacion), 2)`), y tiene que seguir siendolo. Los dos
-- numeros se escriben sobre el mismo campo del mismo documento, asi que si un
-- dia dejaran de coincidir el valor del catalogo dependeria de cual de las dos
-- etapas corrio de ultima. El arnes pruebas/notas.sh compara las dos y falla
-- si divergen.
--
-- Sale una linea por producto CON resenas. Los que no tienen ninguna no
-- aparecen, y eso no es un hueco: es la senal que cargar_notas.js necesita
-- para apagar los que quedaron marcados de antes.

SET TIME ZONE 'UTC';

SELECT jsonb_build_object(

    'id_producto',      r.id_producto_mongo,

    -- coalesce no hace falta aqui y ponerlo seria mentir sobre lo que puede
    -- pasar: un grupo existe porque tiene al menos una fila, y calificacion es
    -- NOT NULL con CHECK BETWEEN 1 AND 5. El avg de un grupo nunca es NULL.
    'resenas_promedio', round(avg(r.calificacion), 2),
    'resenas_total',    count(*)
)
FROM resena r
GROUP BY r.id_producto_mongo
ORDER BY r.id_producto_mongo;
