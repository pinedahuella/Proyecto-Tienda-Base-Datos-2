-- datos/004_subcategorias.sql
-- Baja a una subcategoria los dos productos que habian quedado colgando de una
-- categoria raiz.
--
-- El problema: el balon estaba en Deportes y la novela en Libros, que son
-- raices. El backend no deja publicar en una raiz -- GET /vendedor/categorias
-- solo devuelve las que tienen padre, y GET /vendedor/categorias/:id contesta
-- 404 para una raiz -- asi que el panel del vendedor no podia ni abrirlos para
-- editarlos. Una raiz es un estante que ordena, no un sitio donde se publica.
--
-- Se crean las dos subcategorias que faltaban, se mueven los productos, y la
-- paleta de caracteristicas se muda con ellos: las que ofrecia la raiz pasan a
-- ofrecerlas la hija, porque son las que sus productos ya tienen llenas. Si no
-- se mudara, los productos quedarian usando caracteristicas que su categoria
-- nueva no ofrece.
--
-- Los id continuan donde termino datos/003: categorias va por 27 y su historial
-- por 28. Los de las tablas de paleta se calculan con max()+1 porque son
-- cientos de filas y escribirlas a mano no aporta nada.
--
-- Todo con ON CONFLICT DO NOTHING y con UPDATE idempotente: correrlo dos veces
-- deja lo mismo.


-- ------------------------------------------------------------
-- Las dos subcategorias
-- ------------------------------------------------------------
-- La comision es la misma que tenia su raiz: mover un producto de estante no
-- deberia cambiarle lo que se le cobra.

INSERT INTO categorias (id_categoria, nombre, porcentaje_comision, fecha_creacion, id_categoria_padre) VALUES
    (28, 'Futbol',     (SELECT porcentaje_comision FROM categorias WHERE id_categoria = 23), '2026-04-01 08:00:00-06', 23),
    (29, 'Literatura', (SELECT porcentaje_comision FROM categorias WHERE id_categoria = 26), '2026-04-01 08:00:00-06', 26)
ON CONFLICT DO NOTHING;

INSERT INTO categorias_historial (id_categoria_historial, id_categoria, nombre, porcentaje_comision, fecha_creacion) VALUES
    (29, 28, 'Futbol',     (SELECT porcentaje_comision FROM categorias WHERE id_categoria = 28), '2026-04-01 08:00:00-06'),
    (30, 29, 'Literatura', (SELECT porcentaje_comision FROM categorias WHERE id_categoria = 29), '2026-04-01 08:00:00-06')
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- La paleta se muda de la raiz a la hija
-- ------------------------------------------------------------
-- Primero se copia a la hija y despues se quita de la raiz. En ese orden: al
-- reves, se perderia que ofrecia la raiz y no habria de donde copiar.

INSERT INTO categoria_caracteristica (id_categoria_caracteristica, id_categoria, id_caracteristica)
SELECT (SELECT coalesce(max(id_categoria_caracteristica), 0) FROM categoria_caracteristica)
           + row_number() OVER (ORDER BY cc.id_categoria, cc.id_caracteristica),
       CASE cc.id_categoria WHEN 23 THEN 28 ELSE 29 END,
       cc.id_caracteristica
FROM categoria_caracteristica cc
WHERE cc.id_categoria IN (23, 26)
ON CONFLICT DO NOTHING;

INSERT INTO categoria_caracteristica_variante (id_categoria_caracteristica_variante, id_categoria, id_caracteristica_variante)
SELECT (SELECT coalesce(max(id_categoria_caracteristica_variante), 0) FROM categoria_caracteristica_variante)
           + row_number() OVER (ORDER BY cc.id_categoria, cc.id_caracteristica_variante),
       CASE cc.id_categoria WHEN 23 THEN 28 ELSE 29 END,
       cc.id_caracteristica_variante
FROM categoria_caracteristica_variante cc
WHERE cc.id_categoria IN (23, 26)
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Los productos bajan a su subcategoria
-- ------------------------------------------------------------
-- Por nombre y no por id: es lo que identifica al producto sin depender de
-- como quedo numerado.

UPDATE productos SET id_categoria = 28 WHERE nombre = 'Balon de futbol numero 5';
UPDATE productos SET id_categoria = 29 WHERE nombre = 'El camino de las nubes';


-- ------------------------------------------------------------
-- Las raices dejan de ofrecer nada
-- ------------------------------------------------------------
-- Ya no cuelga ningun producto de ellas, y una raiz que ofrece caracteristicas
-- invita a publicar donde no se puede.

DELETE FROM categoria_caracteristica          WHERE id_categoria IN (23, 26);
DELETE FROM categoria_caracteristica_variante WHERE id_categoria IN (23, 26);


-- ------------------------------------------------------------
-- Secuencias
-- ------------------------------------------------------------

SELECT setval(pg_get_serial_sequence('categorias',           'id_categoria'),           max(id_categoria))           FROM categorias;
SELECT setval(pg_get_serial_sequence('categorias_historial', 'id_categoria_historial'), max(id_categoria_historial)) FROM categorias_historial;
SELECT setval(pg_get_serial_sequence('categoria_caracteristica', 'id_categoria_caracteristica'), max(id_categoria_caracteristica)) FROM categoria_caracteristica;
SELECT setval(pg_get_serial_sequence('categoria_caracteristica_variante', 'id_categoria_caracteristica_variante'), max(id_categoria_caracteristica_variante)) FROM categoria_caracteristica_variante;
