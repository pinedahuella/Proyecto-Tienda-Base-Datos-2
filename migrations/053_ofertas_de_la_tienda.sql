-- ============================================================
-- 053_ofertas_de_la_tienda.sql
-- ============================================================
-- La tienda pausa, reactiva o retira la oferta de cualquier vendedor y le
-- ajusta las unidades (2026-11-07). Hasta hoy solo el dueno tocaba su oferta,
-- y el admin solo las de la cuenta de la tienda.
--
-- No hace falta tabla nueva. El estado ya vive en oferta y cada cambio de
-- unidades queda en stock_movimiento con quien lo hizo (id_usuario_modifico),
-- que desde hoy puede ser el admin. El precio sigue siendo solo del vendedor.
--
--   ofertas.administrar   el permiso de PATCH /admin/ofertas/:id y de
--                         GET /admin/ofertas, solo el admin.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- Igual que la 050: el permiso se reparte solo la primera vez que se crea.
WITH v (modulo, permiso, descripcion, roles) AS (
    VALUES
    ('ofertas', 'administrar', 'Ver todas las ofertas de un producto, pausarlas, retirarlas y ajustar sus unidades', ARRAY['admin'])
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
