-- ============================================================
-- semilla-fraude/fraude.sql
-- ============================================================
-- Datos para que salgan los tipos de fraude que no se pueden armar en vivo o
-- que no tenian ninguna demo. Cada grupo es un caso de libro, con sus propias
-- cuentas (fraude.*@mesh.com), y esta hecho para disparar SOLO su senal:
--
--   satelites                    fraude.vendedor.satelites y tres cuentas
--                                nacidas hace 10 a 12 dias que solo le
--                                compran y le ponen 5 a el, a los 3 dias de
--                                nacer (B.2)
--   persistente                  fraude.persistente le compra y le pone 5 a
--                                fraude.vendedor.persistente una vez al mes
--                                durante cuatro meses, y a nadie mas (B.3).
--                                No se puede armar en vivo: pide 3 meses
--   reputacion_expres            fraude.vendedor.expres nacio hace 5 dias, y
--                                dos cuentas de hace 2 dias le ponen 5 a las
--                                6 horas de nacer (B.7)
--   resenas_repetidas            fraude.repetidas deja la misma resena, con
--                                dos o tres palabras cambiadas, en cinco
--                                productos
--   resenas_parecidas_producto   seis cuentas dejan casi la misma resena en
--                                los Guantes de portero Zarpa 300, repartidas
--                                entre sus vendedores
--   notas_incoherentes_producto  seis cuentas le ponen 5 estrellas al Sillin
--                                de ruta Vertebra SR-2 con un texto que dice
--                                que salio malo, repartidas entre sus
--                                vendedores
--   compras_en_rafaga            fraude.rafaga hace 5 pedidos en 11 minutos (F2)
--   devoluciones_seriales        fraude.devoluciones compra 4 veces y cancela 3
--                                (F5)
--
-- Por que cada uno dispara solo lo suyo, en corto: los satelites nacen mas de
-- 24 horas antes de resenar y su vendedor es viejo (no es reputacion expres);
-- reputacion expres lleva DOS cuentas y satelites pide tres; las resenas
-- repetidas caben en 25 dias y en varios vendedores (no son persistente ni
-- satelites); las parecidas y las incoherentes caen de a 2 por vendedor (no
-- llegan a las 5 que pide el vendedor ni a las 3 cuentas del anillo de texto)
-- y de a 1 por cuenta. Las cuentas de compras no resenan.
--
-- Lo de texto (repetidas, parecidas e incoherentes) necesita el vector y la
-- valoracion de cada resena, que calcula el backend con Ollama
-- (EventoComentarioSyncService); lo del grafo, que las resenas lleguen a
-- Neo4j (arrancar.ps1 lo carga despues); lo de compras, que el ETL las copie a
-- ClickHouse (arrancar.ps1 tambien). Los detectores corren solos cada 15
-- minutos, y el de compras una vez al dia; para no esperar:
--   node pruebas/correr_detectores_fraude.cjs
--
-- Lo que no esta aqui sale en vivo, con su demo (docs/FRAUDE-CATALOGO.md): el
-- login entero, las vistas infladas y una IP con 4 cuentas comprando (las dos
-- necesitan la IP de la peticion, que el ETL no trae), y los anillos, los
-- coordinados, el anillo de texto, las notas incoherentes de cuenta y de
-- vendedor y las resenas canceladas, que ya tenian la suya.
--
-- LAS FECHAS son relativas al dia en que se siembra. Los detectores miran
-- ventanas (60 dias el grafo, 180 el texto, 30 las compras); una senal que ya
-- se detecto se queda en el panel, pero en una base sembrada hace mas de un
-- mes y medio los casos ya no se vuelven a encontrar. Para renovarlos,
-- quitar.sql y arrancar otra vez.
--
-- Contrasenas: Vendedor123 para los tres vendedores, Comprador123 para las
-- demas (los mismos hashes que migrations/datos/).
--
-- Idempotente: arrancar.ps1 la corre en cada arranque. Si ya existe cualquiera
-- de las cuentas no hace nada. Todo va en una transaccion: o entra entera o no
-- entra nada. La deshace quitar.sql.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Ayudantes. Viven en pg_temp: se van al cerrar la sesion.
-- ------------------------------------------------------------

-- Una cuenta con su direccion. dias = cuantos dias antes de la siembra nacio.
CREATE FUNCTION pg_temp.sf_cuenta(p_correo text, p_nombre text, p_apellido text, p_rol text,
                                  p_dias numeric, p_ciudad text, p_departamento text, p_calle text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_id   bigint;
    v_dir  bigint;
    v_alta timestamptz := now() - make_interval(secs => p_dias * 86400);
BEGIN
    INSERT INTO usuarios (correo_electronico, usuario, nombre, apellido, contrasena_hash, fecha_creacion, id_rol_usuario, id_estado_usuario)
    SELECT p_correo, replace(split_part(p_correo, '@', 1), '.', '_'), p_nombre, p_apellido,
           CASE p_rol
               WHEN 'vendedor' THEN '1a2b3c4d5e6f708192a3b4c5d6e7f809:c4e9716408f8b9c89b81a1aca9e935ba936c2ab5c6451aca6c413cff51048b6a023ffeaf8088a0e5a0ec610bfdff9ca8c26807cd1cf24955f9dd3a2999fe83e5'
               ELSE '9f8e7d6c5b4a39281706f5e4d3c2b1a0:d3af92a164ee8d7608de4ccb96f35d5295245949d9eefffe9dbe892d2cad0cad2fb0c921d6c561264f3a0895242d86893173d1aa9235f77703ef61c86eb13d35'
           END,
           v_alta, r.id_rol_usuario, e.id_estado_usuario
    FROM rol_usuario r, estado_usuario e
    WHERE r.rol_usuario_nombre = p_rol AND e.estado_usuario_nombre = 'activo'
    RETURNING id_usuario INTO v_id;

    INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, direccion_exacta, codigo_postal, id_estado_direccion, fecha_creacion)
    SELECT v_id, 'Guatemala', p_departamento, p_ciudad, p_calle, '01001', ed.id_estado_direccion, v_alta
    FROM estado_direccion ed WHERE ed.estado_direccion_nombre = 'activa'
    RETURNING id_direccion INTO v_dir;

    INSERT INTO direccion_historial (id_direccion, pais, departamento, ciudad, direccion_exacta, codigo_postal, fecha_creacion)
    SELECT id_direccion, pais, departamento, ciudad, direccion_exacta, codigo_postal, fecha_creacion
    FROM direcciones WHERE id_direccion = v_dir;
    RETURN v_id;
END $$;

-- Una oferta de un vendedor de la semilla sobre un producto del catalogo, al
-- precio mas bajo que ya tiene ese producto, aprobada por el admin el dia que
-- nace.
CREATE FUNCTION pg_temp.sf_oferta(p_vendedor bigint, p_producto text, p_fecha timestamptz)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_base   record;
    v_id     bigint;
BEGIN
    SELECT o.id_producto_mongo, o.id_producto_variante_mongo, min(o.precio) AS precio
      INTO v_base
      FROM oferta o
      JOIN productos p      ON p.id_producto = o.id_producto_mongo
      JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
     WHERE p.nombre = p_producto AND eo.estado_oferta_nombre = 'activa'
     GROUP BY 1, 2
     ORDER BY count(*) DESC, 2
     LIMIT 1;
    IF v_base.id_producto_mongo IS NULL THEN
        RAISE EXCEPTION 'semilla de fraude: no hay ofertas activas de "%"', p_producto;
    END IF;

    INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario, precio, stock, id_estado_oferta,
                        fecha_creacion, fecha_actualizacion, fecha_aprobacion, id_usuario_aprobo)
    SELECT v_base.id_producto_mongo, v_base.id_producto_variante_mongo, p_vendedor, v_base.precio, 40,
           eo.id_estado_oferta, p_fecha, p_fecha, p_fecha,
           (SELECT id_usuario FROM usuarios WHERE correo_electronico = 'admin@mesh.com')
      FROM estado_oferta eo WHERE eo.estado_oferta_nombre = 'activa'
    RETURNING id_oferta INTO v_id;

    -- El trigger del 005 escribio el precio con now(); va con la fecha de la oferta.
    UPDATE precio_historial SET fecha_creacion = p_fecha WHERE id_oferta = v_id;
    RETURN v_id;
END $$;

-- Una oferta que ya existe de un producto, de los vendedores del catalogo (no
-- de la semilla), activa, aprobada y con stock. k reparte POR VENDEDOR: el
-- k-esimo, en rueda, ordenados por id, y de el su oferta mas vieja. Por
-- vendedor y no por oferta, y con stock de 1 y no de mas, para que la rueda no
-- cambie a media siembra (cada compra baja el stock): las parecidas y las
-- incoherentes tienen que caer parejas, de a 2 por vendedor.
CREATE FUNCTION pg_temp.sf_oferta_de(p_producto text, p_k integer)
RETURNS bigint LANGUAGE sql AS $$
    SELECT x.id_oferta FROM (
        SELECT v.id_oferta, row_number() OVER (ORDER BY v.id_usuario) - 1 AS n, count(*) OVER () AS total
          FROM (
            SELECT DISTINCT ON (o.id_usuario) o.id_usuario, o.id_oferta
              FROM oferta o
              JOIN productos p      ON p.id_producto = o.id_producto_mongo
              JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
              JOIN usuarios u       ON u.id_usuario = o.id_usuario
             WHERE p.nombre = p_producto
               AND eo.estado_oferta_nombre = 'activa'
               AND o.fecha_aprobacion IS NOT NULL
               AND NOT o.es_inventario_limitado
               AND o.stock >= 1
               AND u.correo_electronico NOT LIKE 'fraude.%'
             ORDER BY o.id_usuario, o.id_oferta
          ) v
    ) x
    WHERE x.n = p_k % x.total
$$;

-- Una compra de una unidad, pagada, con la fecha puesta.
CREATE FUNCTION pg_temp.sf_comprar(p_usuario bigint, p_oferta bigint, p_fecha timestamptz)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_dir    bigint;
    v_of     record;
    v_pedido bigint;
BEGIN
    IF p_oferta IS NULL THEN
        RAISE EXCEPTION 'semilla de fraude: falta la oferta para la cuenta %', p_usuario;
    END IF;
    SELECT dh.id_direccion_historial INTO v_dir
      FROM direcciones d JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion
     WHERE d.id_usuario = p_usuario ORDER BY dh.id_direccion_historial LIMIT 1;

    SELECT o.id_oferta, o.id_producto_mongo AS id_producto, pv.id_producto_variante, p.nombre, pv.nombre_variante
      INTO v_of
      FROM oferta o
      JOIN productos p            ON p.id_producto = o.id_producto_mongo
      JOIN productos_variantes pv ON pv.id_producto = o.id_producto_mongo
                                 AND pv.id_producto_variante = o.id_producto_variante_mongo
     WHERE o.id_oferta = p_oferta;

    v_pedido := (comprar_carrito(p_usuario, v_dir, jsonb_build_array(jsonb_build_object(
        'id_oferta',            v_of.id_oferta,
        'cantidad',             1,
        'id_producto',          v_of.id_producto,
        'id_producto_variante', v_of.id_producto_variante,
        'nombre_producto',      v_of.nombre,
        'nombre_variante',      v_of.nombre_variante
    )), 'tarjeta'::varchar)->>'id_pedido')::bigint;

    UPDATE pedido           SET fecha_creacion = p_fecha, fecha_ultima_actividad = p_fecha WHERE id_pedido = v_pedido;
    UPDATE pago             SET fecha_cancelacion = p_fecha WHERE id_pedido = v_pedido;
    UPDATE stock_movimiento SET fecha_movimiento  = p_fecha WHERE id_pedido = v_pedido;
    RETURN v_pedido;
END $$;

-- Una resena de lo que compro en ese pedido, con su fecha.
CREATE FUNCTION pg_temp.sf_resenar(p_pedido bigint, p_estrellas integer, p_texto text, p_fecha timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_linea      record;
    v_comentario bigint;
BEGIN
    SELECT p.id_usuario, pp.id_producto_mongo, o.id_usuario AS id_vendedor
      INTO v_linea
      FROM pedido p
      JOIN pedido_producto pp  ON pp.id_pedido = p.id_pedido
      JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
      JOIN oferta o            ON o.id_oferta = ph.id_oferta
     WHERE p.id_pedido = p_pedido;

    INSERT INTO comentario (id_usuario, comentario, fecha_publicacion)
    VALUES (v_linea.id_usuario, p_texto, p_fecha)
    RETURNING id_comentario INTO v_comentario;

    INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo, calificacion, id_comentario)
    VALUES (v_linea.id_usuario, v_linea.id_vendedor, v_linea.id_producto_mongo, p_estrellas, v_comentario);
END $$;

-- ------------------------------------------------------------
-- La siembra
-- ------------------------------------------------------------
DO $fraude$
DECLARE
    v_ya       integer;
    v_vendedor bigint;
    v_cuenta   bigint;
    v_pedido   bigint;
    v_oferta   bigint;
    v_ofertas  bigint[];
    v_alta     timestamptz;
    v_hoy      timestamptz := now();
    v_textos   text[];
    v_pedidos  bigint[];
BEGIN
    SELECT count(*) INTO v_ya FROM usuarios WHERE correo_electronico LIKE 'fraude.%@mesh.com';
    IF v_ya > 0 THEN
        RAISE NOTICE 'semilla de fraude: ya estaban % cuentas fraude.*@mesh.com, no se toco nada', v_ya;
        RETURN;
    END IF;

    -- ---------------- satelites (B.2) ----------------
    v_vendedor := pg_temp.sf_cuenta('fraude.vendedor.satelites@mesh.com', 'Gimnasio', 'Volcan', 'vendedor', 200,
                                    'Guatemala', 'Guatemala', '6a. Avenida 9-14, Zona 9');
    v_ofertas := ARRAY[
        pg_temp.sf_oferta(v_vendedor, 'Set de bandas elasticas',  v_hoy - interval '190 days'),
        pg_temp.sf_oferta(v_vendedor, 'Pesa rusa Yunque',         v_hoy - interval '190 days'),
        pg_temp.sf_oferta(v_vendedor, 'Tapete de yoga Raiz 6 mm', v_hoy - interval '190 days')];
    v_textos := ARRAY[
        'Las bandas son de buen latex, no huelen feo y vienen con su bolsita. Las uso para la rutina de piernas y aguantan bien. Muy buen vendedor, lo recomiendo.',
        'La pesa rusa llego completa y sin golpes, el agarre es comodo y la pintura no se cae. Excelente atencion, respondio rapido por el chat.',
        'El tapete es grueso y no resbala ni con sudor. Lo enrolle varias veces y no se marca. Envio rapido, todo perfecto con este vendedor.'];
    FOR i IN 1..3 LOOP
        v_cuenta := pg_temp.sf_cuenta('fraude.satelite' || i || '@mesh.com',
                                      (ARRAY['Rocio', 'Mynor', 'Karla'])[i], (ARRAY['Chet', 'Batz', 'Cutzal'])[i], 'comprador',
                                      13 - i, 'Guatemala', 'Guatemala', (6 + i) || 'a. Calle 2-' || (10 + i) || ', Zona 1');
        v_alta := now() - make_interval(days => 13 - i);
        v_pedido := pg_temp.sf_comprar(v_cuenta, v_ofertas[i], v_alta + interval '2 days');
        PERFORM pg_temp.sf_resenar(v_pedido, 5, v_textos[i], v_alta + interval '3 days 4 hours');
    END LOOP;

    -- ---------------- persistente (B.3) ----------------
    v_vendedor := pg_temp.sf_cuenta('fraude.vendedor.persistente@mesh.com', 'Botica', 'Quetzal', 'vendedor', 300,
                                    'Mixco', 'Guatemala', '3a. Calle 7-20, Zona 4');
    -- Una resena por producto y vendedor (UNIQUE de resena): cuatro productos,
    -- uno por mes.
    v_ofertas := ARRAY[
        pg_temp.sf_oferta(v_vendedor, 'Serum de niacinamida 10%',       v_hoy - interval '290 days'),
        pg_temp.sf_oferta(v_vendedor, 'Limpiador en gel Verdo',         v_hoy - interval '290 days'),
        pg_temp.sf_oferta(v_vendedor, 'Crema hidratante nocturna Alba', v_hoy - interval '290 days'),
        pg_temp.sf_oferta(v_vendedor, 'Protector solar mineral FPS 50', v_hoy - interval '290 days')];
    v_cuenta := pg_temp.sf_cuenta('fraude.persistente@mesh.com', 'Ingrid', 'Socop', 'comprador', 300,
                                  'Mixco', 'Guatemala', '9a. Avenida 1-05, Zona 6');
    v_textos := ARRAY[
        'El serum llego sellado y con fecha larga, en un mes ya se notan menos las manchas. Este vendedor nunca falla, le sigo comprando.',
        'Pedi el limpiador como cada mes y llego en dos dias. Deja la piel limpia sin resecar. Siempre le compro a esta botica.',
        'La crema de noche es suave y no deja la cara grasosa. Producto original y bien empacado. Cinco estrellas como siempre.',
        'Mi compra de cada mes, ahora el protector solar. No deja blanco y aguanta el sol del mediodia. No le compro a nadie mas que a ellos.'];
    FOR i IN 1..4 LOOP
        v_pedido := pg_temp.sf_comprar(v_cuenta, v_ofertas[i],
                                       v_hoy - make_interval(days => 130 - 30 * i, hours => 5));
        PERFORM pg_temp.sf_resenar(v_pedido, 5, v_textos[i], v_hoy - make_interval(days => 128 - 30 * i));
    END LOOP;

    -- ---------------- reputacion expres (B.7) ----------------
    v_vendedor := pg_temp.sf_cuenta('fraude.vendedor.expres@mesh.com', 'Perfumeria', 'Relampago', 'vendedor', 5,
                                    'Villa Nueva', 'Guatemala', '11a. Calle 4-33, Zona 3');
    v_oferta := pg_temp.sf_oferta(v_vendedor, 'Agua de colonia Amanecer Citrico', v_hoy - interval '4 days 12 hours');
    v_textos := ARRAY[
        'La colonia huele riquisimo, fresca y dura todo el dia. Llego en pocas horas, super recomendado este vendedor.',
        'Excelente perfumeria, el aroma citrico es igual al de la tienda y el frasco vino perfecto. Volvere a comprar.'];
    FOR i IN 1..2 LOOP
        v_cuenta := pg_temp.sf_cuenta('fraude.expres' || i || '@mesh.com',
                                      (ARRAY['Byron', 'Lesly'])[i], (ARRAY['Ixcot', 'Tum'])[i], 'comprador',
                                      2.5 - i * 0.5, 'Villa Nueva', 'Guatemala', (2 + i) || 'a. Avenida 8-0' || i || ', Zona 2');
        v_alta := now() - make_interval(secs => (2.5 - i * 0.5) * 86400);
        v_pedido := pg_temp.sf_comprar(v_cuenta, v_oferta, v_alta + interval '2 hours');
        PERFORM pg_temp.sf_resenar(v_pedido, 5, v_textos[i], v_alta + interval '6 hours');
    END LOOP;

    -- ---------------- resenas repetidas ----------------
    v_cuenta := pg_temp.sf_cuenta('fraude.repetidas@mesh.com', 'Walter', 'Coyoy', 'comprador', 200,
                                  'Quetzaltenango', 'Quetzaltenango', '14a. Avenida 3-18, Zona 1');
    v_textos := ARRAY[
        'Llego rapido y bien empacado, el producto es tal cual la foto y funciona perfecto. El vendedor contesto todas mis dudas. Cinco estrellas, lo recomiendo sin pensarlo.',
        'Llego rapido y muy bien empacado, el producto es tal cual la foto y funciona perfecto. El vendedor contesto todas mis preguntas. Cinco estrellas, lo recomiendo sin pensarlo.',
        'Llego super rapido y bien empacado, el producto es tal cual la foto y funciona perfecto. El vendedor contesto todas mis dudas. Cinco estrellas, se los recomiendo sin pensarlo.',
        'Llego rapido y bien empacado, el articulo es tal cual la foto y funciona perfecto. El vendedor respondio todas mis dudas. Cinco estrellas, lo recomiendo sin pensarlo.',
        'Llego rapido y bien empacado, el producto es igual a la foto y funciona perfecto. El vendedor contesto todas mis dudas. Cinco estrellas, lo recomiendo sin pensarlo dos veces.'];
    FOR i IN 1..5 LOOP
        v_oferta := pg_temp.sf_oferta_de((ARRAY['Lampara de escritorio Faro', 'Casco de ruta Aerodino', 'Sandalia de cuero Litoral',
                                                'Audifonos Brisa Sport', 'Camisa de mezclilla Remache'])[i], i);
        v_pedido := pg_temp.sf_comprar(v_cuenta, v_oferta, v_hoy - make_interval(days => 30 - 5 * i));
        PERFORM pg_temp.sf_resenar(v_pedido, 5, v_textos[i], v_hoy - make_interval(days => 27 - 5 * i));
    END LOOP;

    -- ---------------- resenas parecidas en un producto ----------------
    -- Seis cuentas en tres vendedores o mas: de a 2 por vendedor. Con menos
    -- vendedores caerian 3 en uno, y eso ya es un anillo de texto.
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['Guantes de portero Zarpa 300', 'Sillin de ruta Vertebra SR-2']) AS x(producto)
                WHERE (SELECT count(DISTINCT o.id_usuario) FROM generate_series(0, 5) k
                         JOIN oferta o ON o.id_oferta = pg_temp.sf_oferta_de(x.producto, k)) < 3) THEN
        RAISE EXCEPTION 'semilla de fraude: los Guantes de portero Zarpa 300 y el Sillin de ruta Vertebra SR-2 necesitan ofertas activas de 3 vendedores o mas';
    END IF;
    v_textos := ARRAY[
        'Los mejores guantes de portero que he tenido, el agarre es increible aun con la pelota mojada. Las munequeras ajustan firme. Totalmente recomendados para el equipo.',
        'Los mejores guantes de portero que he usado, el agarre es increible aun con el balon mojado. Las munequeras ajustan firme. Totalmente recomendados para el equipo.',
        'Los mejores guantes de portero que he tenido, el agarre es increible incluso con la pelota mojada. Las munequeras ajustan bien firme. Totalmente recomendados para el equipo.',
        'Los mejores guantes de portero que tuve, el agarre es increible aun con la pelota mojada. Las munequeras ajustan firme. Totalmente recomendados para todo el equipo.',
        'Los mejores guantes de portero que he tenido, el agarre es buenisimo aun con la pelota mojada. Las munequeras ajustan firme. Totalmente recomendados para el equipo.',
        'Los mejores guantes de portero que he tenido, el agarre es increible aun con la pelota mojada. La munequera ajusta firme. Totalmente recomendados para el equipo de futbol.'];
    FOR i IN 1..6 LOOP
        v_cuenta := pg_temp.sf_cuenta('fraude.parecidas' || i || '@mesh.com',
                                      (ARRAY['Edwin', 'Sindy', 'Otto', 'Marleny', 'Kevin', 'Yesenia'])[i],
                                      (ARRAY['Raxon', 'Pu', 'Sapalu', 'Choc', 'Saquic', 'Tuy'])[i], 'comprador',
                                      150 - i, 'Escuintla', 'Escuintla', (i + 1) || 'a. Calle 5-' || (20 + i) || ', Zona 1');
        v_oferta := pg_temp.sf_oferta_de('Guantes de portero Zarpa 300', i);
        v_pedido := pg_temp.sf_comprar(v_cuenta, v_oferta, v_hoy - make_interval(days => 24 - 2 * i));
        PERFORM pg_temp.sf_resenar(v_pedido, 5, v_textos[i], v_hoy - make_interval(days => 21 - 2 * i));
    END LOOP;

    -- ---------------- notas incoherentes en un producto ----------------
    v_textos := ARRAY[
        'El sillin se rajo por un lado a la segunda semana y el riel se doblo en un bache. Me lastima en las salidas largas. Muy mala calidad, no lo vuelvo a comprar.',
        'Pesimo asiento, el relleno se hundio en pocos dias y ahora siento los tornillos. Lo tuve que cambiar porque ya no aguantaba ni media hora pedaleando.',
        'Vino con la funda rota y despegada en la punta. Ademas cruje todo el tiempo y no hay forma de ajustarlo. Perdi mi dinero con este producto.',
        'Horrible, me dio dolor y adormecimiento en la primera rodada. La forma no sirve para ruta y el material se pela con el sol. Una decepcion total.',
        'El riel del sillin se partio en la primera bajada y casi me caigo. Es peligroso y de material barato. No lo recomiendo para nada, devuelvanme el dinero.',
        'Se desarmo a las tres semanas, la base de plastico se quebro y el cuero se desprendio. Malisima compra, no vale ni la mitad de lo que cuesta.'];
    FOR i IN 1..6 LOOP
        v_cuenta := pg_temp.sf_cuenta('fraude.incoherente' || i || '@mesh.com',
                                      (ARRAY['Hugo', 'Flor', 'Elmer', 'Brenda', 'Selvin', 'Wendy'])[i],
                                      (ARRAY['Coc', 'Xol', 'Ajcalon', 'Yax', 'Toj', 'Mux'])[i], 'comprador',
                                      140 - i, 'Chimaltenango', 'Chimaltenango', (i + 2) || 'a. Avenida 3-' || (30 + i) || ', Zona 2');
        v_oferta := pg_temp.sf_oferta_de('Sillin de ruta Vertebra SR-2', i);
        v_pedido := pg_temp.sf_comprar(v_cuenta, v_oferta, v_hoy - make_interval(days => 34 - 3 * i));
        PERFORM pg_temp.sf_resenar(v_pedido, 5, v_textos[i], v_hoy - make_interval(days => 30 - 3 * i));
    END LOOP;

    -- ---------------- compras en rafaga (F2) ----------------
    v_cuenta := pg_temp.sf_cuenta('fraude.rafaga@mesh.com', 'Julio', 'Ixtabalan', 'comprador', 90,
                                  'Antigua Guatemala', 'Sacatepequez', '4a. Calle Oriente 12, Zona 1');
    FOR i IN 1..5 LOOP
        v_oferta := pg_temp.sf_oferta_de((ARRAY['Serum de niacinamida 10%', 'Set de bandas elasticas', 'Agua de colonia Amanecer Citrico',
                                                'Camisa oxford clasica', 'Bases de datos distribuidas'])[i], i);
        PERFORM pg_temp.sf_comprar(v_cuenta, v_oferta,
                                   date_trunc('day', v_hoy) - interval '9 days' + interval '15 hours'
                                   + make_interval(mins => (ARRAY[0, 2, 5, 8, 11])[i]));
    END LOOP;

    -- ---------------- devoluciones seriales (F5) ----------------
    v_cuenta := pg_temp.sf_cuenta('fraude.devoluciones@mesh.com', 'Mirna', 'Quiej', 'comprador', 90,
                                  'Coban', 'Alta Verapaz', '1a. Calle 5-60, Zona 3');
    v_pedidos := ARRAY[]::bigint[];
    FOR i IN 1..4 LOOP
        v_oferta := pg_temp.sf_oferta_de((ARRAY['Pesa rusa Yunque', 'Lampara de escritorio Faro', 'Sandalia de cuero Litoral',
                                                'Casco de ruta Aerodino'])[i], i + 1);
        v_pedidos := v_pedidos || pg_temp.sf_comprar(v_cuenta, v_oferta, v_hoy - make_interval(days => 22 - 2 * i));
    END LOOP;
    FOR i IN 1..3 LOOP
        PERFORM cancelar_pedido(v_pedidos[i]);
        UPDATE stock_movimiento sm SET fecha_movimiento = v_hoy - make_interval(days => 21 - 2 * i)
          FROM motivo_movimiento mm
         WHERE mm.id_motivo_movimiento = sm.id_motivo_movimiento AND mm.motivo_nombre = 'devolucion'
           AND sm.id_pedido = v_pedidos[i];
        UPDATE pedido SET fecha_ultima_actividad = v_hoy - make_interval(days => 21 - 2 * i) WHERE id_pedido = v_pedidos[i];
    END LOOP;

    RAISE NOTICE 'semilla de fraude: 3 vendedores y 21 compradores fraude.*@mesh.com, 26 resenas, 35 pedidos (3 cancelados)';
END
$fraude$;

COMMIT;
