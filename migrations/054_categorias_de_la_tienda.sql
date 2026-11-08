-- ============================================================
-- 054_categorias_de_la_tienda.sql
-- ============================================================
-- La tienda crea categorias, les cambia el nombre y les agrega
-- caracteristicas desde el panel (2026-11-07). Hasta hoy las 17 categorias
-- salian de la semilla.
--
-- No hace falta tabla nueva. categorias, caracteristica,
-- caracteristica_variante, categoria_caracteristica y
-- categoria_caracteristica_variante son de la 003 y la 004. PostgreSQL es el
-- dueno de la paleta, y el backend copia el cambio a la coleccion categorias
-- de MongoDB en el mismo momento, con la misma forma que le da el ETL.
--
-- Cambiar el nombre no recorre los productos uno por uno. Cada producto de
-- MongoDB lleva {id_categoria, nombre} de su categoria; se cambia con un solo
-- updateMany por id_categoria y se marcan para el buscador. Agregar una
-- caracteristica no toca ningun producto, porque cada producto solo guarda
-- las que llena.
--
--   catalogo.categorias   el permiso de /admin/categorias, solo el admin.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

WITH v (modulo, permiso, descripcion, roles) AS (
    VALUES
    ('catalogo', 'categorias', 'Crear categorias, cambiarles el nombre y agregarles caracteristicas', ARRAY['admin'])
),
nuevos AS (
    INSERT INTO permiso (id_modulo_permiso, permiso_nombre, descripcion)
    SELECT m.id_modulo_permiso, v.permiso, v.descripcion
      FROM v
      JOIN modulo_permiso m ON m.modulo_permiso_nombre = v.modulo
    ON CONFLICT (id_modulo_permiso, permiso_nombre) DO NOTHING
    RETURNING id_permiso, id_modulo_permiso, permiso_nombre
)
INSERT INTO rol_permiso (id_rol_usuario, id_permiso)
SELECT r.id_rol_usuario, n.id_permiso
  FROM nuevos n
  JOIN modulo_permiso m ON m.id_modulo_permiso = n.id_modulo_permiso
  JOIN v ON v.modulo = m.modulo_permiso_nombre AND v.permiso = n.permiso_nombre
  CROSS JOIN LATERAL unnest(v.roles) AS rn(nombre)
  JOIN rol_usuario r ON r.rol_usuario_nombre = rn.nombre
ON CONFLICT DO NOTHING;

COMMIT;
