-- 012_comprar_carrito.sql
-- Crear el pedido, meterle todas sus lineas y comprarlo: una sola llamada.
--
-- Hoy la compra son tres viajes desde la aplicacion -- `crear_pedido`,
-- `agregar_linea` una vez por producto, y `comprar_pedido` -- y entre viaje y
-- viaje la fila de `pedido` se queda escrita en `pendiente`. Esta funcion hace
-- lo mismo en una sola ida.
--
--
-- Las tres funciones de la 007 NO se tocan
-- ============================================================
-- Siguen ahi, iguales, y el backend las sigue usando. Esta no las reemplaza:
-- las COMPONE. Adentro llama exactamente a las mismas tres, asi que no hay una
-- segunda version de las reglas de negocio que se pueda desincronizar de la
-- primera.
--
-- Es deliberado no copiar su contenido. `agregar_linea` congela el precio,
-- comprueba el estado de la oferta y arma el nombre del vendedor; reescribir
-- todo eso aqui significaria que el dia que alguien corrija un caso lo corrija
-- en un solo lado y el otro se quede mintiendo. Es el mismo fallo que ya
-- costo caro antes: un arreglo tiene gemelo en el otro camino.
--
--
-- Por que es atomica sin escribir un BEGIN
-- ============================================================
-- El cuerpo de una funcion de PostgreSQL corre dentro de una sola transaccion.
-- Si `comprar_pedido` levanta una excepcion en la ultima linea, se deshacen
-- TAMBIEN el `INSERT` del pedido y todas sus lineas.
--
-- Eso es lo que gana de verdad, mas alla de los viajes: hoy, si la compra falla
-- por falta de stock, el pedido y sus lineas YA quedaron escritos y la fila se
-- queda en `pendiente` para siempre. Con esto, un intento fallido no deja
-- rastro. La base termina o con la venta completa o como estaba.
--
--
-- Y esto es lo que el carrito de Redis va a necesitar
-- ============================================================
-- Cuando el carrito se mude al almacen clave-valor (Entrega 2), ya no existira
-- una fila de `pedido` mientras la persona compra: el carrito sera una clave de
-- Redis con su expiracion. El pedido nacera recien al pagar, con todas sus
-- lineas de golpe.
--
-- Esta funcion es exactamente esa forma. No se escribio para Redis, pero es la
-- pieza que Redis pide.
--
--
-- LA CONSECUENCIA QUE HAY QUE MIRAR DE FRENTE: el precio deja de congelarse
-- ============================================================
-- `agregar_linea` congela el precio en el momento de agregar al carrito, y la
-- 007 dice por que, textual: "si el vendedor lo sube despues, este pedido
-- conserva el que se le mostro a la persona".
--
-- Con esta funcion, agregar y comprar pasan en el mismo instante. El precio que
-- se congela es el del momento de PAGAR, no el que la persona vio cuando puso
-- el producto en el carrito. Si el vendedor lo subio en el medio, cobra el
-- nuevo.
--
-- Hoy da igual: la aplicacion sigue usando las tres funciones y el carrito vive
-- en PostgreSQL. Pero el dia que el carrito se mude a Redis, esta funcion es la
-- que se va a usar, y ahi la garantia se pierde de verdad, en silencio y sin
-- ningun error.
--
-- La salida, para cuando toque: que el carrito de Redis guarde tambien el
-- `id_precio_historial` de cada linea, y que se le pueda pasar a
-- `agregar_linea` en vez de que ella lo busque. Eso es un cambio en la 007 y en
-- el backend, o sea que NO se hace aqui -- se deja escrito para que la decision
-- se tome cuando se monte Redis y no se descubra despues, cobrandole de mas a
-- alguien.


-- ============================================================
-- comprar_carrito
-- ============================================================
-- p_lineas es un ARREGLO de los mismos objetos que recibe agregar_linea:
--
--   [
--     {"id_oferta": 12, "cantidad": 2, "id_producto": 5,
--      "id_producto_variante": 9, "nombre_producto": "...",
--      "nombre_variante": "..."},
--     ...
--   ]
--
-- Devuelve lo mismo que comprar_pedido, mas el id del pedido que nacio.
CREATE OR REPLACE FUNCTION comprar_carrito(
    p_id_usuario              bigint,
    p_id_direccion_historial  bigint,
    p_lineas                  jsonb,
    p_metodo_pago             varchar
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_id_pedido  bigint;
    v_linea      jsonb;
    v_resultado  jsonb;
BEGIN
    -- Se comprueba ANTES de abrir el pedido. `comprar_pedido` tambien rechaza
    -- un pedido sin lineas, pero para entonces la fila ya nacio y el mensaje
    -- habla de un pedido que quien llamo nunca pidio crear. Fallar aqui dice lo
    -- que de verdad paso: vino un carrito vacio.
    IF p_lineas IS NULL OR jsonb_typeof(p_lineas) <> 'array' THEN
        RAISE EXCEPTION 'p_lineas tiene que ser un arreglo JSON de lineas'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'El carrito viene vacio: no hay nada que comprar'
            USING ERRCODE = 'check_violation';
    END IF;

    -- 1. Abre el pedido. Comprueba que la direccion sea de quien compra.
    v_id_pedido := crear_pedido(p_id_usuario, p_id_direccion_historial);

    -- 2. Las lineas, una por una y con la misma funcion de siempre.
    --
    -- Si dos elementos traen la misma oferta, `agregar_linea` les suma la
    -- cantidad en vez de escribir dos lineas: ese comportamiento se hereda y no
    -- se replica aqui.
    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_lineas)
    LOOP
        PERFORM agregar_linea(v_id_pedido, v_linea);
    END LOOP;

    -- 3. La venta. Aqui se mira el stock, se descuenta, se escribe el kardex y
    -- se registra el pago. Si algo de esto falla, los pasos 1 y 2 se deshacen
    -- con el.
    v_resultado := comprar_pedido(v_id_pedido, p_metodo_pago);

    -- El id del pedido va en la respuesta porque quien llamo no lo conocia: lo
    -- creo esta funcion. Sin el no hay forma de abrir el detalle de la compra
    -- que se acaba de hacer.
    RETURN jsonb_set(
        COALESCE(v_resultado, '{}'::jsonb),
        '{id_pedido}',
        to_jsonb(v_id_pedido),
        true
    );
END;
$fn$;

COMMENT ON FUNCTION comprar_carrito(bigint, bigint, jsonb, varchar) IS
    'Crea el pedido, agrega todas sus lineas y lo compra en una sola transaccion. Compone crear_pedido, agregar_linea y comprar_pedido sin duplicarlas';
