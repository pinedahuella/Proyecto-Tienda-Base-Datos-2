-- 013_precio_del_carrito.sql
-- `agregar_linea` acepta el precio que se le ENSENO a la persona.
--
-- Es la mitad de PostgreSQL del pendiente #1 de `docs/PENDIENTES.md`. La otra
-- mitad es del backend y esta descrita al final de este archivo.
--
--
-- El cobro incorrecto que esto arregla
-- ============================================================
-- La 007 dice, textual, que `agregar_linea` congela el precio "para que si el
-- vendedor lo sube despues, este pedido conserve el que se le mostro a la
-- persona". Eso era verdad mientras el carrito era una fila de `pedido`: entre
-- agregar y pagar podian pasar dias, y la linea ya tenia su precio escrito.
--
-- Con el carrito en Redis dejo de serlo. `POST /carrito/comprar` llama a
-- `comprar_carrito`, que crea el pedido, agrega las lineas y compra **en el
-- mismo instante**. Asi que el precio que se congela ya no es el que la persona
-- vio: es el que rige al PAGAR.
--
-- Si el vendedor lo sube mientras el carrito espera -- y puede esperar 24 horas
-- --, se cobra el nuevo. Sin error, sin aviso, sin que nadie se entere. Peor:
-- `GET /carrito` ya le enseno un precio y decidio con ese numero.
--
-- **No es un detalle de presentacion, es un cobro incorrecto silencioso**, y
-- por eso es el pendiente numero 1 de la lista.
--
--
-- Que cambia, y que NO
-- ============================================================
-- La 007 no se toca: es la regla de `migrations/README.md` y ademas no hace
-- falta. Esta migracion reemplaza el cuerpo de `agregar_linea` con
-- `CREATE OR REPLACE`, conservando su firma `(bigint, jsonb)`.
--
-- **La firma es la misma a proposito.** El precio entra como un campo mas
-- DENTRO de `p_linea`, no como un parametro nuevo, para que ningun sitio que ya
-- la llama tenga que cambiar: `comprar_carrito` de la 012 le pasa el elemento
-- del arreglo tal cual, asi que el campo viaja solo hasta aqui sin tocar la 012.
-- Un parametro nuevo habria obligado a tocar tambien esa funcion, y a decidir
-- que hacer con las dos versiones de la firma.
--
-- Todo lo demas se conserva palabra por palabra: el estado del pedido, el
-- estado de la oferta, el nombre del vendedor sacado de la base, la suma de
-- cantidades cuando la oferta ya estaba en el pedido y el chequeo de stock.
--
--
-- La comprobacion que hace que esto no sea un agujero
-- ============================================================
-- `id_precio_historial` lo manda quien llama, y un precio es dinero: si se
-- aceptara cualquiera, bastaria con pasar el id de una fila **de otra oferta**
-- -- o una vieja y barata de la misma -- para pagar lo que uno quiera.
--
-- Por eso se exige que la fila EXISTA y que sea **de esa misma oferta**. Si no
-- lo es, la funcion levanta excepcion y no cobra nada. No se acepta "el precio
-- mas parecido" ni se cae de vuelta al vigente en silencio: un id que no cuadra
-- significa que quien llama se equivoco o esta probando, y las dos cosas se
-- contestan igual.
--
-- Lo que NO se comprueba es la antiguedad. Un precio de hace 24 horas es
-- legitimo: es justo el caso para el que existe esto. Cuanto vale un precio
-- congelado es una decision de negocio y se toma arriba, no aqui.
--
--
-- Por que la funcion AVISA en vez de decidir
-- ============================================================
-- Cuando el precio congelado no es el vigente, esta funcion **cobra el
-- congelado y lo dice**: el jsonb que devuelve trae `precio_cambio`,
-- `precio_congelado` y `precio_actual`.
--
-- No bloquea la compra, y es deliberado. Si se negara a cobrar un precio viejo,
-- la base estaria decidiendo una politica comercial -- cuanto vale la palabra
-- que se le dio a un cliente -- y esa decision no es suya. Y si lo cobrara
-- callada, volveriamos al mismo fallo por el otro lado: la persona pagaria un
-- numero distinto del que vio en la pantalla anterior sin enterarse.
--
-- Asi que informa, y quien llama decide. Es exactamente el trato que
-- `POST /comprador/pedidos/:id/comprar` ya tiene con su `confirmar_cambios` y su
-- lista de `avisos`: no hay que inventar nada, hay que portarlo. Los tres campos
-- salen con los mismos nombres que usa `AvisoPrecioPedido` del backend
-- (`precio_congelado`, `precio_actual`) para que armar el aviso no pida una
-- segunda consulta.
--
--
-- Compatible hacia atras: sin el campo, se comporta igual que antes
-- ============================================================
-- Si `p_linea` no trae `id_precio_historial`, la funcion busca el vigente
-- exactamente como lo hacia la 007. Tenia que ser asi por dos motivos:
--
--   1. El backend es de Jose David y se despliega aparte. Esta migracion tiene
--      que poder correr ANTES de que el mande el campo, sin romper nada.
--   2. `migrations/datos/001_catalogo.sql` llama a `comprar_carrito` en su
--      bloque de compras y no manda el campo. Si esto fuera obligatorio, la
--      semilla dejaria de cargar.
--
-- O sea que esta migracion sola no arregla el cobro: lo HABILITA. Mientras el
-- carrito de Redis no guarde el `id_precio_historial` de cada linea, el precio
-- se sigue congelando al pagar. Ver abajo.


-- ============================================================
-- agregar_linea
-- ============================================================
CREATE OR REPLACE FUNCTION agregar_linea(
    p_id_pedido  bigint,
    p_linea      jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_estado_pedido  varchar;
    v_id_oferta      bigint;
    v_cantidad       integer;
    v_oferta         oferta%ROWTYPE;
    v_estado_oferta  varchar;
    v_id_precio      bigint;
    v_id_precio_pedido bigint;
    v_precio_usado   numeric(12,2);
    v_precio_actual  numeric(12,2);
    v_id_precio_hoy  bigint;
    v_nombre_vend    varchar(200);
    v_ya             integer;
    v_total          integer;
    v_id_linea       bigint;
BEGIN
    SELECT ep.estado_pedido_nombre INTO v_estado_pedido
    FROM pedido p JOIN estado_pedido ep USING (id_estado_pedido)
    WHERE p.id_pedido = p_id_pedido;

    IF v_estado_pedido IS NULL THEN
        RAISE EXCEPTION 'No existe el pedido %', p_id_pedido
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- Un pedido comprado ya es una venta: cambiarlo seria reescribir lo que
    -- alguien pago.
    IF v_estado_pedido <> 'pendiente' THEN
        RAISE EXCEPTION 'El pedido % esta % y ya no se puede cambiar',
                        p_id_pedido, v_estado_pedido
            USING ERRCODE = 'check_violation';
    END IF;

    v_id_oferta := (p_linea->>'id_oferta')::bigint;
    v_cantidad  := (p_linea->>'cantidad')::integer;

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad tiene que ser mayor a 0'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_oferta FROM oferta WHERE id_oferta = v_id_oferta;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la oferta %', v_id_oferta
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    SELECT estado_oferta_nombre INTO v_estado_oferta
    FROM estado_oferta WHERE id_estado_oferta = v_oferta.id_estado_oferta;

    IF v_estado_oferta <> 'activa' THEN
        RAISE EXCEPTION 'La oferta % esta % y no se puede comprar',
                        v_id_oferta, v_estado_oferta
            USING ERRCODE = 'check_violation';
    END IF;

    -- La fila de precio que rige hoy. Siempre existe: la escribe el trigger
    -- del 005 cuando nace la oferta. Se busca SIEMPRE, aunque venga un precio
    -- congelado, porque es contra ella que se compara para avisar.
    SELECT ph.id_precio_historial, ph.precio INTO v_id_precio_hoy, v_precio_actual
    FROM precio_historial ph
    WHERE ph.id_oferta = v_id_oferta
    ORDER BY ph.fecha_creacion DESC, ph.id_precio_historial DESC
    LIMIT 1;

    IF v_id_precio_hoy IS NULL THEN
        RAISE EXCEPTION 'La oferta % no tiene precio registrado', v_id_oferta
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- El precio que se le enseno a la persona, si quien llama lo mando.
    v_id_precio_pedido := (p_linea->>'id_precio_historial')::bigint;

    IF v_id_precio_pedido IS NULL THEN
        -- Sin el campo: el vigente, igual que la 007.
        v_id_precio  := v_id_precio_hoy;
        v_precio_usado := v_precio_actual;
    ELSE
        -- Con el campo: tiene que ser una fila de ESTA oferta. Ver la nota de
        -- la cabecera: sin este filtro, el id de otra oferta seria un precio a
        -- eleccion de quien llama.
        SELECT ph.precio INTO v_precio_usado
        FROM precio_historial ph
        WHERE ph.id_precio_historial = v_id_precio_pedido
          AND ph.id_oferta           = v_id_oferta;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'El precio % no es de la oferta %', v_id_precio_pedido, v_id_oferta
                USING ERRCODE = 'check_violation';
        END IF;

        v_id_precio := v_id_precio_pedido;
    END IF;

    -- El nombre del vendedor sale de la base, no del parametro
    SELECT trim(u.nombre || ' ' || coalesce(u.apellido, '')) INTO v_nombre_vend
    FROM usuarios u WHERE u.id_usuario = v_oferta.id_usuario;

    -- "Una linea por oferta" no se puede escribir como UNIQUE, porque la
    -- oferta no esta en pedido_producto: se llega a ella cruzando
    -- precio_historial. Por eso se busca a mano antes de insertar. Ver el
    -- comentario del 006.
    SELECT pp.id_pedido_producto, pp.cantidad INTO v_id_linea, v_ya
    FROM pedido_producto pp
    JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
    WHERE pp.id_pedido = p_id_pedido
      AND ph.id_oferta = v_id_oferta;

    v_total := coalesce(v_ya, 0) + v_cantidad;

    IF v_oferta.stock < v_total THEN
        RAISE EXCEPTION 'No hay suficiente stock de "%": quedan % y el pedido pide %',
                        p_linea->>'nombre_variante', v_oferta.stock, v_total
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_id_linea IS NOT NULL THEN
        -- Se le suma la cantidad y se CONSERVA el precio con el que entro.
        --
        -- Tambien cuando viene un `id_precio_historial` distinto, y no es un
        -- descuido: la linea ya existe con un precio, y cambiarlo aqui
        -- reescribiria hacia atras lo que ya estaba pactado para las unidades
        -- anteriores. Si de verdad hay que cobrar dos precios por la misma
        -- oferta, eso son dos lineas, y eso lo decide quien llama.
        UPDATE pedido_producto SET cantidad = v_total
        WHERE id_pedido_producto = v_id_linea;
    ELSE
        INSERT INTO pedido_producto (
            id_pedido, id_precio_historial,
            id_producto_mongo, id_producto_variante_mongo,
            cantidad, nombre_producto, nombre_variante, nombre_vendedor)
        VALUES (
            p_id_pedido, v_id_precio,
            (p_linea->>'id_producto')::bigint,
            (p_linea->>'id_producto_variante')::bigint,
            v_cantidad,
            p_linea->>'nombre_producto',
            p_linea->>'nombre_variante',
            v_nombre_vend
        )
        RETURNING id_pedido_producto INTO v_id_linea;
    END IF;

    RETURN jsonb_build_object(
        'id_pedido',          p_id_pedido,
        'id_pedido_producto', v_id_linea,
        'id_oferta',          v_id_oferta,
        'id_usuario_vendedor', v_oferta.id_usuario,
        'cantidad',           v_total,
        'stock_disponible',   v_oferta.stock,
        -- Los tres campos del aviso. `precio_cambio` es el unico que hay que
        -- mirar para saber si hay algo que decirle a la persona; los otros dos
        -- son para redactarlo sin volver a consultar.
        'id_precio_historial', v_id_precio,
        'precio_cambio',      (v_id_precio <> v_id_precio_hoy),
        'precio_congelado',   v_precio_usado::text,
        'precio_actual',      v_precio_actual::text
    );
END;
$fn$;

COMMENT ON FUNCTION agregar_linea(bigint, jsonb) IS
    'Agrega una oferta a un pedido pendiente. Usa el id_precio_historial de p_linea si viene (y es de esa oferta), o el vigente si no. No descuenta stock. Avisa en precio_cambio si el precio usado ya no es el vigente';


-- ============================================================
-- Lo que falta para que el cobro quede arreglado de verdad
-- ============================================================
-- Esta migracion habilita el arreglo; no lo termina. Falta la mitad de
-- `backend/`, que es de Jose David y aqui no se toca:
--
--   1. Que el carrito de Redis guarde el `id_precio_historial` de cada linea.
--      Hoy el hash es `id_oferta -> cantidad`; tiene que pasar a llevar los dos
--      datos (`cantidad:id_precio_historial`, o dos campos). El id lo tiene ya:
--      es el mismo que `GET /carrito` usa para calcular el precio que ensena.
--
--   2. Que `POST /carrito/comprar` lo mande dentro de cada linea. No hace falta
--      cambiar la llamada a `comprar_carrito`: el campo viaja dentro del
--      elemento del arreglo y llega solo hasta aqui.
--
--   3. Que mire `precio_cambio` en lo que devuelve cada linea y, si alguna vino
--      en true, conteste con `comprado: false` y la lista de `avisos` salvo que
--      venga `confirmar_cambios: true` -- igual que ya hace
--      `POST /comprador/pedidos/:id/comprar`. Los nombres de los campos ya
--      coinciden con `AvisoPrecioPedido`.
--
-- Mientras el paso 1 no exista, esta funcion se comporta exactamente como la de
-- la 007 y el precio se sigue congelando al pagar.
