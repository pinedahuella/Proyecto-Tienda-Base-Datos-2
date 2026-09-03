-- borrar_lote.sql
-- Borra productos GENERADOS por generar_lote.sql. El que deshace lo que aquel
-- hizo.
--
-- Se corre a mano o, mejor, con  .\arrancar.ps1 -Borrar <cuantos>, que ademas
-- limpia MongoDB, que es la mitad que se olvida siempre.
--
--     docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> \
--         -v ON_ERROR_STOP=1 \
--         -v cuantos=500 \
--         -v semilla=-1 \
--         -f /migrations/lote/borrar_lote.sql
--
--   cuantos   cuantos borrar, empezando por los MAS NUEVOS.
--             0 o menos quiere decir TODOS los generados.
--             Si se piden mas de los que hay, borra los que hay y lo DICE en
--             vez de fallar. Pedir de mas no es un error, es no saber cuantos
--             habia, que es justo lo normal.
--
--   semilla   -1 para no mirar la semilla y borrar de cualquier lote.
--             Un numero para borrar solo de ESE lote.
--
--
-- LO QUE ESTE ARCHIVO NO HACE, Y ES LA PARTE IMPORTANTE
-- ============================================================
--
-- NO BORRA LOS 102 PRODUCTOS CURADOS, los que trae migrations/datos/. Y no es
-- una precaucion timida, es que no se puede y conviene saber por que.
--
-- Medido sobre esta base: 59 de esos productos tienen ventas detras. La cadena
-- es pedido_producto -> precio_historial -> oferta -> producto, y el primer
-- eslabon es ON DELETE RESTRICT. Borrar uno de esos productos exige borrar
-- antes el pedido que lo compro, y un pedido sin sus lineas es un pedido que
-- miente sobre lo que se vendio. El esquema lo prohibe a proposito.
--
-- Ademas, `resena.id_producto_mongo` NO tiene llave foranea (no puede tenerla,
-- apunta al catalogo de MongoDB), asi que borrar un producto resenado NO falla:
-- deja la resena huerfana, apuntando a un producto que ya no existe, en
-- silencio. Eso es peor que fallar.
--
-- PARA DEJAR LA BASE COMO NUEVA, con sus 102 productos curados y nada mas, ya
-- existe el camino bueno y es otro:
--
--     .\arrancar.ps1 -Reiniciar
--
-- Ese borra los volumenes de las CUATRO bases y las vuelve a construir desde
-- los archivos del repositorio. No hay huerfanos, no hay pedidos sin lineas, y
-- las once comprobaciones de la semilla vuelven a correr y a dar en verde.
-- Vaciar el catalogo a mano dejaria una base que ninguna de esas
-- comprobaciones describe ya.
--
--
-- POR QUE BORRA LOS MAS NUEVOS PRIMERO
-- ============================================================
-- Porque "borrame 500" casi siempre significa "deshazme lo ultimo que hice".
-- Empezar por los mas viejos borraria el lote que alguien dejo montado para una
-- demostracion y conservaria el de prueba que acaba de salir mal.
--
--
-- POR QUE PIDE LA CONFIRMACION DE MONGODB APARTE
-- ============================================================
-- Este archivo solo habla con PostgreSQL. Los productos tambien viven en
-- MongoDB, y correr el ETL despues NO los quita: etl/cargar.js escribe con
-- replaceOne y upsert, o sea que agrega y actualiza pero nunca borra, y su
-- unico barrido de sobrantes es sobre `categorias` y `productos_eventos`.
-- Para `db.productos` no hay ninguno.
--
-- Por eso al final se imprime un aviso con el recordatorio. Y por eso el camino
-- recomendado es la bandera de arrancar.ps1, que hace las dos mitades sola.


BEGIN;


-- ============================================================
-- Los parametros, leidos una sola vez
-- ============================================================
-- Van a una tabla temporal por lo mismo que en generar_lote.sql: psql NO
-- sustituye sus variables dentro de un bloque delimitado por dolares, y las
-- necesitamos dentro de plpgsql. Medido: un DO $$ ... ':cuantos' ... $$ imprime
-- el texto ':cuantos' tal cual.
CREATE TEMP TABLE borrado_parametro ON COMMIT DROP AS
SELECT (:'cuantos')::bigint  AS cuantos,
       (:'semilla')::bigint  AS semilla;


-- ============================================================
-- Que se va a borrar
-- ============================================================
-- El marcador es lo unico que distingue un producto generado de uno curado y de
-- uno publicado desde el panel. La expresion regular exige el formato completo
-- (espacio, L, digitos, guion, cuatro digitos, y fin de cadena) para que un
-- producto curado que por casualidad lleve una L y un numero no caiga aqui.
--
-- LOS VENDIDOS SE SALTAN, NO PARAN EL BORRADO
--
-- Un producto generado nace sin ventas, pero nada impide comprarlo desde la
-- aplicacion entre que se genera y que se borra. Si eso paso, ese producto no
-- se puede borrar: pedido_producto -> precio_historial es ON DELETE RESTRICT, y
-- borrarlo exigiria borrar el pedido, que es lo que el esquema prohibe.
--
-- La primera version de este archivo abortaba la transaccion entera en cuanto
-- encontraba uno. Estaba mal, y por la misma razon por la que pedir mas de los
-- que hay no es un error: un solo producto vendido dejaba sin borrar los otros
-- mil novecientos noventa y nueve, y para desatascarlo habia que averiguar a
-- mano cual era y excluirlo. Quien teclea "borra todos" quiere que se borre
-- todo lo que se pueda borrar.
--
-- Asi que se EXCLUYEN aqui, y al final se dice cuantos fueron y por que. La
-- diferencia importa: el borrado no falla, informa.
--
-- Ojo con donde va el descarte: va ANTES del LIMIT. Si se descartaran despues,
-- "borrame 500" borraria menos de 500 aunque hubiera de sobra, porque los
-- vendidos habrian ocupado sitio en la cuenta sin llegar a borrarse.
CREATE TEMP TABLE borrado_vendidos ON COMMIT DROP AS
SELECT DISTINCT o.id_producto_mongo AS id_producto
FROM pedido_producto pp
JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
JOIN oferta o           ON o.id_oferta = ph.id_oferta;

CREATE TEMP TABLE borrado_ids ON COMMIT DROP AS
WITH p AS (SELECT * FROM borrado_parametro),
candidatos AS (
    SELECT pr.id_producto
    FROM productos pr, p
    WHERE pr.nombre ~ ' L[0-9]+-[0-9]{4}$'
      AND (p.semilla < 0
           OR pr.nombre ~ (' L' || p.semilla::text || '-[0-9]{4}$'))
      AND pr.id_producto NOT IN (SELECT id_producto FROM borrado_vendidos)
)
SELECT id_producto
FROM candidatos, p
ORDER BY id_producto DESC
LIMIT CASE WHEN (SELECT cuantos FROM p) > 0
           THEN (SELECT cuantos FROM p)
           ELSE NULL END;


-- ============================================================
-- Contar antes, y avisar si se pidio de mas
-- ============================================================
DO $aviso$
DECLARE
    v_cuantos   bigint;
    v_semilla   bigint;
    v_hay       bigint;
    v_a_borrar  bigint;
    v_vendidos  bigint;
BEGIN
    SELECT cuantos, semilla INTO v_cuantos, v_semilla FROM borrado_parametro;

    SELECT count(*) INTO v_hay
    FROM productos
    WHERE nombre ~ ' L[0-9]+-[0-9]{4}$'
      AND (v_semilla < 0 OR nombre ~ (' L' || v_semilla::text || '-[0-9]{4}$'));

    SELECT count(*) INTO v_a_borrar FROM borrado_ids;

    IF v_hay = 0 THEN
        IF v_semilla < 0 THEN
            RAISE EXCEPTION 'No hay ningun producto generado que borrar'
                USING HINT = 'Los productos curados de migrations/datos/ no se '
                             'borran con este archivo. Para dejar la base como '
                             'nueva:  .\arrancar.ps1 -Reiniciar';
        ELSE
            RAISE EXCEPTION 'La semilla % no genero ningun producto en esta base', v_semilla
                USING HINT = 'Mira que lotes hay:  SELECT DISTINCT substring('
                             'nombre from '' (L[0-9]+)-[0-9]{4}$'') FROM productos;';
        END IF;
    END IF;

    -- Pedir de mas NO es un error. Es no saber cuantos habia, que es lo normal.
    -- Se borra lo que hay y se dice, que es lo que alguien quiere que pase.
    IF v_cuantos > 0 AND v_cuantos > v_hay THEN
        RAISE NOTICE 'Se pidieron % y solo hay %. Se borran los %.',
                     v_cuantos, v_hay, v_hay;
    END IF;

    -- Cuantos se quedaron fuera por tener ventas. Ya estan excluidos de
    -- borrado_ids; esto es solo para poder decirlo. Se cuentan sobre los
    -- candidatos que la peticion abarcaba, no sobre la base entera, o el numero
    -- hablaria de productos que a esta corrida no le tocaban.
    SELECT count(*) INTO v_vendidos
    FROM productos pr
    WHERE pr.nombre ~ ' L[0-9]+-[0-9]{4}$'
      AND (v_semilla < 0 OR pr.nombre ~ (' L' || v_semilla::text || '-[0-9]{4}$'))
      AND pr.id_producto IN (SELECT id_producto FROM borrado_vendidos);

    IF v_vendidos > 0 THEN
        RAISE NOTICE 'Se saltan % productos que tienen ventas detras: esos no se pueden borrar.', v_vendidos;
        RAISE NOTICE 'Borrarlos exigiria borrar los pedidos que los compraron, y un pedido';
        RAISE NOTICE 'sin lineas miente sobre lo que se vendio. Se borra todo lo demas.';
    END IF;

    -- Que TODOS los candidatos esten vendidos si es un caso sin salida: no hay
    -- nada que borrar y hay que decirlo claro, no terminar en verde sin haber
    -- hecho nada.
    IF v_a_borrar = 0 THEN
        RAISE EXCEPTION 'Los % productos que se pidio borrar tienen todos ventas detras', v_hay
            USING HINT = 'Ninguno se puede borrar sin borrar antes su pedido. '
                         'Para dejar la base como nueva:  .\arrancar.ps1 -Reiniciar';
    END IF;

    RAISE NOTICE 'A borrar: % productos generados (de % que hay)', v_a_borrar, v_hay;
END
$aviso$;


-- ============================================================
-- El borrado, en el orden de las llaves foraneas
-- ============================================================
-- Todas las de este tramo son ON DELETE RESTRICT, asi que una borrada fuera de
-- orden FALLA en vez de arrastrar. Eso es bueno: obliga a que este orden sea
-- explicito y a que nadie borre de mas por descuido.
CREATE TEMP TABLE borrado_var ON COMMIT DROP AS
    SELECT id_producto_variante FROM productos_variantes
     WHERE id_producto IN (SELECT id_producto FROM borrado_ids);

CREATE TEMP TABLE borrado_of ON COMMIT DROP AS
    SELECT id_oferta FROM oferta
     WHERE id_producto_mongo IN (SELECT id_producto FROM borrado_ids);

-- La oferta y todo lo que cuelga de ella
DELETE FROM stock_movimiento WHERE id_oferta IN (SELECT id_oferta FROM borrado_of);
DELETE FROM rechazo_oferta   WHERE id_oferta IN (SELECT id_oferta FROM borrado_of);
DELETE FROM precio_historial WHERE id_oferta IN (SELECT id_oferta FROM borrado_of);
DELETE FROM oferta           WHERE id_oferta IN (SELECT id_oferta FROM borrado_of);

-- El enlace de la imagen, nunca la imagen.
--
-- generar_lote.sql NO crea filas en imagen_producto: reusa las que ya existen
-- apuntandolas desde imagen_producto_producto. Asi que aqui se borra el enlace
-- y la fotografia se queda, porque sigue siendo de su producto curado. Un
-- DELETE sobre imagen_producto aqui chocaria contra el RESTRICT o, peor, se
-- llevaria la foto de un producto que nadie pidio borrar.
DELETE FROM imagen_producto_producto
 WHERE id_producto_variante IN (SELECT id_producto_variante FROM borrado_var);

-- Las variantes
DELETE FROM producto_variante_caracteristica_variante
 WHERE id_producto_variante IN (SELECT id_producto_variante FROM borrado_var);
DELETE FROM productos_variantes_historial
 WHERE id_producto_variante IN (SELECT id_producto_variante FROM borrado_var);
DELETE FROM productos_variantes
 WHERE id_producto_variante IN (SELECT id_producto_variante FROM borrado_var);

-- El producto
DELETE FROM producto_caracteristica WHERE id_producto IN (SELECT id_producto FROM borrado_ids);
DELETE FROM productos_historial     WHERE id_producto IN (SELECT id_producto FROM borrado_ids);
DELETE FROM productos               WHERE id_producto IN (SELECT id_producto FROM borrado_ids);


-- ============================================================
-- Comprobarse a si mismo
-- ============================================================
-- Un borrado que dice haber borrado y dejo mitades es peor que uno que falla.
DO $verificar$
DECLARE
    v_mal      bigint;
    v_quedan   bigint;
    v_curados  bigint;
BEGIN
    -- 1. no quedo ningun producto de los que se pidio borrar
    SELECT count(*) INTO v_mal
    FROM productos WHERE id_producto IN (SELECT id_producto FROM borrado_ids);
    IF v_mal > 0 THEN
        RAISE EXCEPTION '% productos que se iban a borrar siguen ahi', v_mal;
    END IF;

    -- 2. no quedo ninguna variante huerfana de esos productos
    SELECT count(*) INTO v_mal
    FROM productos_variantes WHERE id_producto IN (SELECT id_producto FROM borrado_ids);
    IF v_mal > 0 THEN
        RAISE EXCEPTION '% variantes se quedaron sin su producto', v_mal;
    END IF;

    -- 3. no quedo ninguna oferta apuntando a un producto borrado
    SELECT count(*) INTO v_mal
    FROM oferta WHERE id_producto_mongo IN (SELECT id_producto FROM borrado_ids);
    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas apuntan a un producto que ya no existe', v_mal;
    END IF;

    -- 4. los 102 curados siguen enteros. Este archivo no los toca NUNCA, y esta
    --    comprobacion existe para que si alguien afloja la expresion regular del
    --    marcador, se entere aqui y no tres semanas despues.
    SELECT count(*) INTO v_curados
    FROM productos WHERE nombre !~ ' L[0-9]+-[0-9]{4}$';
    IF v_curados < 102 THEN
        RAISE EXCEPTION 'Quedan solo % productos curados: este archivo se llevo algo que no era suyo', v_curados;
    END IF;

    -- 5. ninguna resena quedo huerfana. No hay llave foranea que lo impida,
    --    asi que es la unica forma de enterarse.
    SELECT count(*) INTO v_mal
    FROM resena r
    WHERE r.id_producto_mongo IN (SELECT id_producto FROM borrado_ids);
    IF v_mal > 0 THEN
        RAISE EXCEPTION '% resenas quedaron apuntando a un producto borrado', v_mal;
    END IF;

    SELECT count(*) INTO v_quedan FROM productos;

    RAISE NOTICE 'Borrado verificado. Quedan % productos (% curados, % generados).',
                 v_quedan, v_curados, v_quedan - v_curados;
    RAISE NOTICE 'FALTA MONGODB: correr el ETL NO los quita de alla, porque cargar.js';
    RAISE NOTICE 'no tiene barrido para db.productos. Usa .\arrancar.ps1 -Borrar,';
    RAISE NOTICE 'que hace las dos mitades, o borralos a mano por su marcador.';
END
$verificar$;


COMMIT;
