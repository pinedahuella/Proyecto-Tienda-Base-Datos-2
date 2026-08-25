-- extraer_categorias.sql
-- Saca la paleta: que caracteristicas OFRECE cada categoria.
--
-- Es un archivo aparte de extraer.sql porque son dos colecciones distintas y
-- cada consulta devuelve una linea por documento. Juntarlas obligaria a
-- marcar cada linea con su tipo y a separarlas otra vez del otro lado.
--
-- Esta coleccion no dice que tiene un producto, dice que se le puede
-- preguntar a quien publica en esa categoria. La categoria propone y el
-- producto dispone: por eso una categoria ofrece mas de lo que cualquier
-- producto suyo llena, y por eso el catalogo sale disparejo.
--
-- Salen TODAS las categorias, tambien las raices. Una raiz (Electronica,
-- Hogar) no ofrece ninguna caracteristica y no lleva productos: es un rotulo
-- para agrupar, y su lista sale vacia a proposito. Se escribe igual para que
-- el arbol quede completo y el formulario pueda recorrerlo sin huecos.
--
-- El arbol tiene dos niveles y solo dos, garantizado por el trigger del 003.
-- Asi que 'categoria_padre' es NULL en las raices y siempre una raiz en las
-- hojas: no hace falta recorrer nada hacia arriba.

SET TIME ZONE 'UTC';

SELECT jsonb_build_object(

    'id_categoria',        c.id_categoria,
    'nombre',              c.nombre,
    'categoria_padre',     cp.nombre,
    'es_raiz',             (c.id_categoria_padre IS NULL),
    'fecha_creacion',      c.fecha_creacion,

    -- Cada entrada trae el tipo y la unidad, que es lo que el formulario
    -- necesita para pintar el campo: un entero con unidad GB no se pide igual
    -- que un texto libre. El valor no va aqui, porque aqui no hay valores.
    'caracteristicas', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'nombre',    ca.nombre,
                   'tipo_dato', td.tipo_dato,
                   'unidad',    ca.unidad
               ) ORDER BY ca.id_caracteristica), '[]'::jsonb)
        FROM categoria_caracteristica cc
        JOIN caracteristica ca ON ca.id_caracteristica = cc.id_caracteristica
        JOIN tipo_dato      td ON td.id_tipo_dato      = ca.id_tipo_dato
        WHERE cc.id_categoria = c.id_categoria
    ),

    -- Las de variante van en su propia lista y no mezcladas con las de
    -- arriba: el formulario las pide en otro momento, cuando ya se esta
    -- creando una talla o un color concreto.
    'caracteristicas_variante', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'nombre',    cv.nombre,
                   'tipo_dato', td.tipo_dato,
                   'unidad',    cv.unidad
               ) ORDER BY cv.id_caracteristica), '[]'::jsonb)
        FROM categoria_caracteristica_variante ccv
        JOIN caracteristica_variante cv
             ON cv.id_caracteristica = ccv.id_caracteristica_variante
        JOIN tipo_dato td ON td.id_tipo_dato = cv.id_tipo_dato
        WHERE ccv.id_categoria = c.id_categoria
    )
)
FROM categorias c
-- LEFT: una categoria raiz no tiene padre y tiene que salir igual
LEFT JOIN categorias cp ON cp.id_categoria = c.id_categoria_padre
ORDER BY c.id_categoria;
