-- ============================================================
-- 050_permisos_por_rol.sql
-- ============================================================
-- El ACL de funcionalidades (2026-10-28). Hasta hoy la lista de que rol puede
-- usar que funcion vivia en el codigo, en los @Roles(...) de cada controller.
-- Desde esta migracion vive aqui, en PostgreSQL, y el backend la consulta en
-- cada peticion: cada ruta privada declara la accion que hace
-- (@Permiso('ofertas.publicar')) y PermisoGuard pregunta a rol_permiso si el
-- rol de la cuenta la tiene. Si no, 403, y el intento queda en
-- auditoria_permiso. Cambiar una fila cambia lo que puede cada rol al
-- instante, sin compilar ni reiniciar nada.
--
-- Son tres capas y no se pisan (docs/SEGURIDAD.md):
--   1. Las bases, por SERVICIO: mesh_backend, mesh_lectura, el ACL de Redis.
--   2. Las funciones, por ROL: esta migracion.
--   3. Cada oferta, por PERSONA: permiso_oferta (049). Una ruta de
--      /compartidas/ofertas pasa primero por la 2 y despues por la 3.
--
--   modulo_permiso     los grupos de funciones: ofertas, carrito, fraude...
--   permiso            cada accion, dentro de su modulo (ofertas.publicar)
--   rol_permiso        el ACL: que rol tiene que accion. Lo que no esta se niega
--   auditoria_permiso  cada intento negado y cada permiso dado o quitado
--   permisos_por_rol   vista para leer la matriz de un vistazo
--
-- Tercera forma normal: el modulo va en su tabla y no repetido como texto en
-- cada permiso (el codigo 'ofertas.publicar' se arma con un JOIN, no se
-- guarda); en rol_permiso quien lo dio y cuando dependen de la llave completa
-- (rol, permiso); en la auditoria cada columna depende solo de su id.
--
-- La semilla reproduce EXACTAMENTE los @Roles que habia antes (se comprueba con
-- pruebas/permisos_cobertura.cjs contra pruebas/permisos_matriz_antes_050.json).
-- Reparte permisos SOLO cuando el permiso se crea por primera vez: si un admin
-- le quita uno a un rol, volver a correr esta migracion no se lo devuelve.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- ============================================================
-- modulo_permiso
-- ============================================================
CREATE TABLE IF NOT EXISTS modulo_permiso (
    id_modulo_permiso      smallserial PRIMARY KEY,
    modulo_permiso_nombre  varchar(30) NOT NULL UNIQUE,
    descripcion            text NOT NULL
);

COMMENT ON TABLE modulo_permiso IS
    'Catalogo de los grupos de funciones de la tienda. El codigo de un permiso es modulo.accion';

-- ============================================================
-- permiso
-- ============================================================
CREATE TABLE IF NOT EXISTS permiso (
    id_permiso         smallserial PRIMARY KEY,
    id_modulo_permiso  smallint NOT NULL
        REFERENCES modulo_permiso(id_modulo_permiso) ON DELETE RESTRICT,
    permiso_nombre     varchar(30) NOT NULL,
    descripcion        text NOT NULL,
    CONSTRAINT permiso_unico_en_su_modulo UNIQUE (id_modulo_permiso, permiso_nombre)
);

COMMENT ON TABLE permiso IS
    'Cada accion que se puede hacer en la tienda. Cada ruta privada del backend declara una con @Permiso(modulo.accion)';

-- ============================================================
-- rol_permiso
-- ============================================================
CREATE TABLE IF NOT EXISTS rol_permiso (
    id_rol_usuario     smallint NOT NULL
        REFERENCES rol_usuario(id_rol_usuario) ON DELETE CASCADE,
    id_permiso         smallint NOT NULL
        REFERENCES permiso(id_permiso) ON DELETE CASCADE,
    -- NULL = la semilla de esta migracion.
    id_usuario_otorgo  bigint REFERENCES usuarios(id_usuario) ON DELETE SET NULL,
    fecha_otorgado     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id_rol_usuario, id_permiso)
);

COMMENT ON TABLE rol_permiso IS
    'El ACL de funcionalidades: que rol puede hacer que accion. Lo revisa PermisoGuard en cada peticion. Lo que no esta aqui se niega con 403';

CREATE INDEX IF NOT EXISTS idx_rol_permiso_permiso
    ON rol_permiso (id_permiso);

-- ============================================================
-- auditoria_permiso
-- ============================================================
-- Sin FK a usuarios a proposito, como la de la 049: es historia y se queda
-- aunque la cuenta se borre. Al rol y al permiso si, porque esos catalogos no
-- se borran mientras tengan historia (RESTRICT).
CREATE TABLE IF NOT EXISTS auditoria_permiso (
    id_auditoria_permiso  bigserial PRIMARY KEY,
    fecha                 timestamptz NOT NULL DEFAULT now(),
    accion                varchar(10) NOT NULL
        CHECK (accion IN ('negado', 'otorgar', 'revocar')),
    -- negado: quien lo intento. otorgar y revocar: el admin que lo cambio.
    id_usuario_actor      bigint NOT NULL,
    -- La entrada del ACL en juego: el rol al que le falto, o al que se le dio
    -- o se le quito, y el permiso. El rol es el que tenia en ese momento.
    id_rol_usuario        smallint NOT NULL
        REFERENCES rol_usuario(id_rol_usuario) ON DELETE RESTRICT,
    id_permiso            smallint NOT NULL
        REFERENCES permiso(id_permiso) ON DELETE RESTRICT,
    -- Solo en negado: lo que se pidio, tal como llego.
    metodo                varchar(7),
    ruta                  varchar(300),
    CONSTRAINT auditoria_permiso_ruta_solo_en_negado
        CHECK ((accion = 'negado') = (ruta IS NOT NULL AND metodo IS NOT NULL))
);

COMMENT ON TABLE auditoria_permiso IS
    'Registro del ACL de funcionalidades: cada peticion negada por falta de permiso y cada permiso dado o quitado a un rol';

CREATE INDEX IF NOT EXISTS idx_auditoria_permiso_fecha
    ON auditoria_permiso (fecha DESC);

-- ============================================================
-- Semilla
-- ============================================================
INSERT INTO modulo_permiso (modulo_permiso_nombre, descripcion)
VALUES
    ('cuenta',      'La cuenta propia: perfil, contrasena y avisos de seguridad'),
    ('direcciones', 'Las direcciones de entrega de la cuenta'),
    ('carrito',     'El carrito y el pago'),
    ('pedidos',     'Los pedidos propios'),
    ('avisos',      'Avisame cuando llegue o baje de precio'),
    ('resenas',     'Resenas, respuestas y votos'),
    ('productos',   'Lo que se ve de un producto con sesion: historial por fecha y para ti'),
    ('ofertas',     'Las ofertas del vendedor, su revision y compartirlas'),
    ('catalogo',    'El catalogo compartido: verlo, proponer, editar y revisar productos'),
    ('reglas',      'Reglas de descuento automatico y por periodo'),
    ('dashboard',   'El dashboard general del admin y sus exportaciones'),
    ('tendencias',  'Los rankings de eventos de ClickHouse'),
    ('fraude',      'Senales, alertas y casos de fraude'),
    ('usuarios',    'Las cuentas de la tienda, sus roles y estados'),
    ('reportes',    'Reportes de ventas y reservaciones'),
    ('sistema',     'El estado de las bases: cortacircuitos y conciliacion del grafo'),
    ('permisos',    'Este mismo ACL: ver y cambiar que rol puede que')
ON CONFLICT (modulo_permiso_nombre) DO NOTHING;

WITH v (modulo, permiso, descripcion, roles) AS (
    VALUES
    ('cuenta',      'ver',                'Ver la cuenta propia, el perfil y sus avisos de seguridad', ARRAY['comprador', 'vendedor', 'admin']),
    ('cuenta',      'editar',             'Cambiar el perfil y la contrasena, y marcar los avisos de seguridad', ARRAY['comprador', 'vendedor', 'admin']),
    ('direcciones', 'administrar',        'Ver, agregar y cambiar las direcciones de entrega', ARRAY['comprador', 'vendedor', 'admin']),
    ('carrito',     'usar',               'Ver el carrito, agregar, cambiar y quitar productos', ARRAY['comprador', 'vendedor', 'admin']),
    ('carrito',     'comprar',            'Pagar el carrito', ARRAY['comprador', 'vendedor', 'admin']),
    ('pedidos',     'ver',                'Ver los pedidos propios y si ya se compro un producto', ARRAY['comprador', 'vendedor', 'admin']),
    ('pedidos',     'cancelar',           'Cancelar un pedido propio', ARRAY['comprador', 'vendedor', 'admin']),
    ('avisos',      'usar',               'Pedir, ver y quitar avisos de llegada o de precio', ARRAY['comprador', 'vendedor', 'admin']),
    ('resenas',     'escribir',           'Resenar un producto comprado y responder resenas', ARRAY['comprador', 'vendedor', 'admin']),
    ('resenas',     'votar',              'Votar si una resena sirvio', ARRAY['comprador', 'vendedor', 'admin']),
    ('productos',   'historial',          'Ver como era un producto o una oferta en una fecha', ARRAY['comprador', 'vendedor', 'admin']),
    ('productos',   'para_ti',            'Ver las recomendaciones para ti', ARRAY['comprador', 'vendedor', 'admin']),
    ('ofertas',     'ver',                'Ver y buscar las ofertas propias y sus rechazos', ARRAY['vendedor', 'admin']),
    ('ofertas',     'publicar',           'Publicar una oferta nueva', ARRAY['vendedor', 'admin']),
    ('ofertas',     'editar',             'Cambiar precio, existencia y estado de una oferta propia', ARRAY['vendedor', 'admin']),
    ('ofertas',     'descuento',          'Poner y quitar el descuento de una oferta propia', ARRAY['vendedor', 'admin']),
    ('ofertas',     'venta_relampago',    'Abrir y cerrar una venta relampago', ARRAY['vendedor', 'admin']),
    ('ofertas',     'revisar',            'Ver la cola de ofertas pendientes y aprobarlas o rechazarlas', ARRAY['vendedor', 'admin']),
    ('ofertas',     'compartir',          'Dar y quitar permisos sobre una oferta propia a otra cuenta', ARRAY['vendedor', 'admin']),
    ('ofertas',     'usar_compartidas',   'Entrar a las ofertas que otra cuenta compartio', ARRAY['vendedor', 'admin']),
    ('catalogo',    'ver',                'Ver el catalogo compartido, sus categorias y su historial', ARRAY['vendedor', 'admin']),
    ('catalogo',    'proponer',           'Proponer un producto nuevo y reenviar una propuesta rechazada', ARRAY['vendedor', 'admin']),
    ('catalogo',    'editar',             'Crear y editar productos del catalogo', ARRAY['vendedor', 'admin']),
    ('catalogo',    'revisar',            'Ver las propuestas de todos y aprobarlas o rechazarlas', ARRAY['vendedor', 'admin']),
    ('catalogo',    'buscar_todo',        'Buscar en el catalogo entero, tambien lo inactivo', ARRAY['admin']),
    ('reglas',      'ver',                'Ver las reglas de descuento', ARRAY['vendedor', 'admin']),
    ('reglas',      'administrar',        'Crear, cambiar y borrar reglas de descuento', ARRAY['vendedor', 'admin']),
    ('dashboard',   'ver',                'Ver el dashboard general', ARRAY['admin']),
    ('dashboard',   'exportar',           'Exportar el dashboard a Excel o PDF y mandarlo por correo', ARRAY['admin']),
    ('tendencias',  'ver',                'Ver los rankings de vistas, carrito, busquedas y compras', ARRAY['admin']),
    ('fraude',      'ver',                'Ver senales, alertas y casos de fraude', ARRAY['admin']),
    ('fraude',      'resolver',           'Confirmar o descartar alertas y casos de fraude', ARRAY['admin']),
    ('usuarios',    'ver',                'Ver las cuentas, los roles y los estados', ARRAY['admin']),
    ('usuarios',    'editar',             'Cambiar el rol o el estado de una cuenta', ARRAY['admin']),
    ('reportes',    'ver',                'Ver los reportes de ventas y de reservaciones', ARRAY['admin']),
    ('sistema',     'ver',                'Ver el estado de los cortacircuitos y la conciliacion del grafo', ARRAY['admin']),
    ('permisos',    'ver',                'Ver que rol puede que y el registro de intentos negados', ARRAY['admin']),
    ('permisos',    'administrar',        'Dar y quitar permisos a un rol', ARRAY['admin'])
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

-- ============================================================
-- permisos_por_rol
-- ============================================================
-- La matriz de un vistazo, una fila por permiso con una columna por rol. Para
-- leerla en pgAdmin o en la demo: SELECT * FROM permisos_por_rol;
CREATE OR REPLACE VIEW permisos_por_rol AS
SELECT m.modulo_permiso_nombre || '.' || p.permiso_nombre AS permiso,
       p.descripcion,
       EXISTS (SELECT 1 FROM rol_permiso rp JOIN rol_usuario r USING (id_rol_usuario)
                WHERE rp.id_permiso = p.id_permiso AND r.rol_usuario_nombre = 'comprador') AS comprador,
       EXISTS (SELECT 1 FROM rol_permiso rp JOIN rol_usuario r USING (id_rol_usuario)
                WHERE rp.id_permiso = p.id_permiso AND r.rol_usuario_nombre = 'vendedor') AS vendedor,
       EXISTS (SELECT 1 FROM rol_permiso rp JOIN rol_usuario r USING (id_rol_usuario)
                WHERE rp.id_permiso = p.id_permiso AND r.rol_usuario_nombre = 'admin') AS admin
  FROM permiso p
  JOIN modulo_permiso m USING (id_modulo_permiso)
 ORDER BY m.id_modulo_permiso, p.permiso_nombre;

COMMENT ON VIEW permisos_por_rol IS
    'La matriz del ACL de funcionalidades: cada permiso y si lo tiene cada rol';

COMMIT;
