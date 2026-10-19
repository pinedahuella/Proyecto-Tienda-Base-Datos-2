-- ============================================================
-- semilla-combos/combos.sql
-- ============================================================
-- Pedidos de 2 y 3 productos que tienen sentido juntos, para que los combos
-- (GET /productos/combos, ClickHouse), "tambien compraron" y "para ti" (Neo4j)
-- tengan de donde salir. Hasta el 2026-10-18 casi todos los pedidos eran de
-- un solo producto y en la base local habia 4 combos. Lo pidio Jose David en
-- backend/cambio_propuestas/2026-10-17_0015-combos.md.
--
--   8 cuentas compradoras nuevas, combo1@mesh.com a combo8@mesh.com, cada una
--   con su direccion. 18 pedidos de 8 combos del catalogo curado, cada combo
--   en 2 o 3 pedidos de cuentas distintas.
--
-- Las compras van por crear_pedido, agregar_linea y comprar_pedido, el mismo
-- camino de la aplicacion (como los dos pedidos de migrations/datos/), asi que
-- quedan su pago, su kardex y el stock descontado. Despues se les corrigen las
-- fechas que esas funciones escriben con now().
--
-- LAS FECHAS son relativas al dia en que se siembra (de 8 a 160 dias atras),
-- porque los combos solo cuentan los ultimos 180 dias. En una base sembrada
-- hace mas de medio ano los primeros van saliendo de la ventana; para
-- renovarlos, quitar.sql y arrancar otra vez.
--
-- QUE NO PLANTA FRAUDE. Lo que mira compras:
--   F2 compras en rafaga   5 pedidos de una cuenta en 15 min. Aqui cada cuenta
--                          tiene 2 o 3 pedidos, con 47 dias o mas entre uno y
--                          otro.
--   F3 una IP, 4 cuentas   el ETL copia las compras con la IP comodin '::', que
--                          F3 descarta. Y no hay logins de estas cuentas.
--   F5 devoluciones        ninguna devolucion.
--   F1 vistas, la granja de registros y las alertas de login salen de vistas,
--   registros y logins, y aqui no hay ninguno. Los detectores del grafo y de
--   texto (anillos, patrones, notas incoherentes, resenas parecidas o
--   canceladas) miran resenas, y aqui no hay resenas.
--
-- Idempotente: arrancar.ps1 la corre en cada arranque. Si ya existe cualquiera
-- de las 8 cuentas no hace nada. Todo va en una transaccion: o entra entera o
-- no entra nada. La deshace quitar.sql.
-- ============================================================

BEGIN;

DO $combos$
DECLARE
    v_correos   text[] := ARRAY['combo1@mesh.com', 'combo2@mesh.com', 'combo3@mesh.com', 'combo4@mesh.com',
                                'combo5@mesh.com', 'combo6@mesh.com', 'combo7@mesh.com', 'combo8@mesh.com'];
    v_ya        integer;
    v_fila      record;
    v_combo     record;
    v_of        record;
    v_nombre    text;
    v_pos       integer;
    v_n         integer := 0;
    v_lineas    integer := 0;
    v_usuario   bigint;
    v_dir       bigint;
    v_pedido    bigint;
    v_fecha     timestamptz;
    v_desde     timestamptz;
    v_elegidas  jsonb;
BEGIN
    SELECT count(*) INTO v_ya FROM usuarios WHERE correo_electronico = ANY (v_correos);
    IF v_ya > 0 THEN
        RAISE NOTICE 'semilla de combos: ya estaban % de las 8 cuentas, no se toco nada', v_ya;
        RETURN;
    END IF;

    -- Las cuentas: Comprador123, el mismo hash que los compradores de
    -- migrations/datos/generador.js. Nacen 200 dias antes de la siembra, antes
    -- que el primer pedido.
    INSERT INTO usuarios (correo_electronico, usuario, nombre, apellido, contrasena_hash, fecha_creacion, id_rol_usuario, id_estado_usuario)
    SELECT v.correo, v.usuario, v.nombre, v.apellido,
           '9f8e7d6c5b4a39281706f5e4d3c2b1a0:d3af92a164ee8d7608de4ccb96f35d5295245949d9eefffe9dbe892d2cad0cad2fb0c921d6c561264f3a0895242d86893173d1aa9235f77703ef61c86eb13d35',
           now() - make_interval(days => v.dias), r.id_rol_usuario, e.id_estado_usuario
    FROM (VALUES
        ('combo1@mesh.com', 'combo1', 'Andres',  'Lopez',   205),
        ('combo2@mesh.com', 'combo2', 'Brenda',  'Sican',   200),
        ('combo3@mesh.com', 'combo3', 'Carlos',  'Xicara',  196),
        ('combo4@mesh.com', 'combo4', 'Diana',   'Ajanel',  192),
        ('combo5@mesh.com', 'combo5', 'Edgar',   'Tzul',    188),
        ('combo6@mesh.com', 'combo6', 'Fabiola', 'Monzon',  184),
        ('combo7@mesh.com', 'combo7', 'Gerardo', 'Pac',     180),
        ('combo8@mesh.com', 'combo8', 'Helena',  'Yool',    176)
    ) AS v(correo, usuario, nombre, apellido, dias)
    JOIN rol_usuario    r ON r.rol_usuario_nombre    = 'comprador'
    JOIN estado_usuario e ON e.estado_usuario_nombre = 'activo';

    -- Su direccion y su primera version en el historial: el pedido apunta ahi.
    INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, direccion_exacta, codigo_postal, id_estado_direccion, fecha_creacion)
    SELECT u.id_usuario, 'Guatemala', v.departamento, v.ciudad, v.calle, v.postal, ed.id_estado_direccion, u.fecha_creacion
    FROM (VALUES
        ('combo1@mesh.com', 'Guatemala',      'Guatemala',         '4a. Avenida 12-31, Zona 1',   '01001'),
        ('combo2@mesh.com', 'Guatemala',      'Mixco',             '7a. Calle 3-15, Zona 4',      '01057'),
        ('combo3@mesh.com', 'Sacatepequez',   'Antigua Guatemala', '2a. Avenida Sur 8, Zona 1',   '03001'),
        ('combo4@mesh.com', 'Quetzaltenango', 'Quetzaltenango',    '15a. Avenida 5-22, Zona 3',   '09001'),
        ('combo5@mesh.com', 'Escuintla',      'Escuintla',         '9a. Calle 6-40, Zona 2',      '05001'),
        ('combo6@mesh.com', 'Guatemala',      'Villa Nueva',       '3a. Calle 11-09, Zona 5',     '01064'),
        ('combo7@mesh.com', 'Chimaltenango',  'Chimaltenango',     '1a. Avenida 4-18, Zona 2',    '04001'),
        ('combo8@mesh.com', 'Alta Verapaz',   'Coban',             '5a. Calle 2-47, Zona 1',      '16001')
    ) AS v(correo, departamento, ciudad, calle, postal)
    JOIN usuarios u          ON u.correo_electronico = v.correo
    JOIN estado_direccion ed ON ed.estado_direccion_nombre = 'activa';

    INSERT INTO direccion_historial (id_direccion, pais, departamento, ciudad, direccion_exacta, codigo_postal, fecha_creacion)
    SELECT d.id_direccion, d.pais, d.departamento, d.ciudad, d.direccion_exacta, d.codigo_postal, d.fecha_creacion
    FROM direcciones d
    JOIN usuarios u ON u.id_usuario = d.id_usuario
    WHERE u.correo_electronico = ANY (v_correos);

    -- Los pedidos, del mas viejo al mas nuevo. dias = cuantos dias antes de la
    -- siembra, hora = la de Guatemala. Los combos son:
    --   A  Laptop Aurora 14 + Monitor Nube 22 + Audifonos Colibri Micro TWS   3 pedidos
    --   B  Escritorio Roble 120 + Lampara de escritorio Faro                   3 pedidos
    --   C  Casco de ruta Aerodino + Guantes de ciclismo Palma Corta
    --      + Candado plegable Cerrojo F8                                       2 pedidos
    --   D  Tapete de yoga Raiz 6 mm + Set de bandas elasticas                  2 pedidos
    --   E  Balon de futbol numero 5 + Espinilleras Muralla
    --      + Zapato de tacos Relampago FG                                      2 pedidos
    --   F  Olla arrocera Grano 8 tazas + Cacerola honda Comal 18               2 pedidos
    --   G  Limpiador en gel Verdo + Serum de niacinamida 10%
    --      + Crema hidratante nocturna Alba                                    2 pedidos
    --   H  Camisa oxford clasica + Pantalon chino resistente                   2 pedidos
    FOR v_fila IN
        SELECT * FROM (VALUES
            ('combo1@mesh.com', 'A', 160, '10:20', 'tarjeta'),
            ('combo2@mesh.com', 'B', 150, '16:45', 'tarjeta'),
            ('combo4@mesh.com', 'D', 140, '07:55', 'transferencia'),
            ('combo5@mesh.com', 'G', 130, '19:10', 'tarjeta'),
            ('combo3@mesh.com', 'A', 120, '12:35', 'tarjeta'),
            ('combo6@mesh.com', 'C', 110, '09:05', 'efectivo contra entrega'),
            ('combo7@mesh.com', 'E', 100, '17:30', 'tarjeta'),
            ('combo1@mesh.com', 'C',  95, '08:40', 'tarjeta'),
            ('combo8@mesh.com', 'F',  85, '13:15', 'efectivo contra entrega'),
            ('combo2@mesh.com', 'E',  70, '18:50', 'transferencia'),
            ('combo4@mesh.com', 'H',  60, '11:25', 'tarjeta'),
            ('combo5@mesh.com', 'A',  45, '20:05', 'tarjeta'),
            ('combo3@mesh.com', 'F',  40, '14:40', 'transferencia'),
            ('combo7@mesh.com', 'D',  30, '07:20', 'tarjeta'),
            ('combo1@mesh.com', 'G',  25, '21:00', 'tarjeta'),
            ('combo6@mesh.com', 'H',  20, '15:55', 'tarjeta'),
            ('combo4@mesh.com', 'B',  12, '10:50', 'efectivo contra entrega'),
            ('combo8@mesh.com', 'B',   8, '16:10', 'tarjeta')
        ) AS t(correo, combo, dias, hora, metodo)
        ORDER BY dias DESC
    LOOP
        v_n := v_n + 1;

        SELECT c.productos INTO v_combo
        FROM (VALUES
            ('A', ARRAY['Laptop Aurora 14', 'Monitor Nube 22', 'Audifonos Colibri Micro TWS']),
            ('B', ARRAY['Escritorio Roble 120', 'Lampara de escritorio Faro']),
            ('C', ARRAY['Casco de ruta Aerodino', 'Guantes de ciclismo Palma Corta', 'Candado plegable Cerrojo F8']),
            ('D', ARRAY['Tapete de yoga Raiz 6 mm', 'Set de bandas elasticas']),
            ('E', ARRAY['Balon de futbol numero 5', 'Espinilleras Muralla', 'Zapato de tacos Relampago FG']),
            ('F', ARRAY['Olla arrocera Grano 8 tazas', 'Cacerola honda Comal 18']),
            ('G', ARRAY['Limpiador en gel Verdo', 'Serum de niacinamida 10%', 'Crema hidratante nocturna Alba']),
            ('H', ARRAY['Camisa oxford clasica', 'Pantalon chino resistente'])
        ) AS c(combo, productos)
        WHERE c.combo = v_fila.combo;

        SELECT u.id_usuario, dh.id_direccion_historial INTO v_usuario, v_dir
        FROM usuarios u
        JOIN direcciones d          ON d.id_usuario = u.id_usuario
        JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion
        WHERE u.correo_electronico = v_fila.correo
        ORDER BY dh.id_direccion_historial
        LIMIT 1;

        v_fecha := (((now() AT TIME ZONE 'America/Guatemala')::date - v_fila.dias) + v_fila.hora::time)
                   AT TIME ZONE 'America/Guatemala';

        -- Una oferta por producto: activa, aprobada, sin inventario limitado y
        -- con stock de sobra, y que ya existiera un dia antes de la compra. Se
        -- va rotando entre las que hay, para que los pedidos caigan en
        -- vendedores distintos. Si ninguna existia todavia (una base sembrada
        -- hoy con fechas raras), cualquiera, y la compra se corre a despues.
        v_elegidas := '[]'::jsonb;
        v_desde := NULL;
        v_pos := 0;
        FOREACH v_nombre IN ARRAY v_combo.productos LOOP
            v_pos := v_pos + 1;
            v_of := NULL;
            FOR i IN 1..2 LOOP
                SELECT x.* INTO v_of
                FROM (
                    SELECT p.id_producto, p.nombre, o.id_oferta, pv.id_producto_variante, pv.nombre_variante,
                           COALESCE(o.fecha_aprobacion, o.fecha_creacion) AS desde,
                           row_number() OVER (ORDER BY o.id_oferta) - 1 AS k,
                           count(*) OVER () AS total
                    FROM productos p
                    JOIN oferta o               ON o.id_producto_mongo = p.id_producto
                    JOIN estado_oferta eo       ON eo.id_estado_oferta = o.id_estado_oferta AND eo.estado_oferta_nombre = 'activa'
                    JOIN productos_variantes pv ON pv.id_producto = o.id_producto_mongo
                                               AND pv.id_producto_variante = o.id_producto_variante_mongo
                    WHERE p.nombre = v_nombre
                      AND o.fecha_aprobacion IS NOT NULL
                      AND NOT o.es_inventario_limitado
                      AND o.stock >= 3
                      AND (i = 2 OR COALESCE(o.fecha_aprobacion, o.fecha_creacion) <= v_fecha - interval '1 day')
                ) x
                WHERE x.k = (v_n + v_pos) % x.total;
                EXIT WHEN v_of.id_oferta IS NOT NULL;
            END LOOP;

            IF v_of.id_oferta IS NULL THEN
                RAISE EXCEPTION 'semilla de combos: no hay una oferta activa con stock de "%"', v_nombre;
            END IF;

            v_desde := GREATEST(v_desde, v_of.desde);
            v_elegidas := v_elegidas || jsonb_build_object(
                'id_oferta',            v_of.id_oferta,
                'cantidad',             1,
                'id_producto',          v_of.id_producto,
                'id_producto_variante', v_of.id_producto_variante,
                'nombre_producto',      v_of.nombre,
                'nombre_variante',      v_of.nombre_variante);
        END LOOP;

        v_fecha := LEAST(GREATEST(v_fecha, v_desde + interval '1 day'), now() - interval '1 hour');

        v_pedido := crear_pedido(v_usuario, v_dir);
        FOR i IN 0..jsonb_array_length(v_elegidas) - 1 LOOP
            PERFORM agregar_linea(v_pedido, v_elegidas -> i);
            v_lineas := v_lineas + 1;
        END LOOP;
        PERFORM comprar_pedido(v_pedido, v_fila.metodo::varchar);

        UPDATE pedido           SET fecha_creacion = v_fecha, fecha_ultima_actividad = v_fecha WHERE id_pedido = v_pedido;
        UPDATE pago             SET fecha_cancelacion = v_fecha WHERE id_pedido = v_pedido;
        UPDATE stock_movimiento SET fecha_movimiento  = v_fecha WHERE id_pedido = v_pedido;
    END LOOP;

    RAISE NOTICE 'semilla de combos: 8 cuentas nuevas, % pedidos, % lineas', v_n, v_lineas;
END
$combos$;

COMMIT;
