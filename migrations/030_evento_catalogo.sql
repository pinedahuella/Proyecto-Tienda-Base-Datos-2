-- ============================================================
-- 030_evento_catalogo.sql
-- ============================================================
-- La cola de outbox que lleva a MongoDB los numeros de las ofertas. Es la
-- segunda mitad de la decision 5 (docs/PLAN-COMPRAR-SIN-MONGO.md).
--
-- Cada tarjeta del catalogo en MongoDB lleva seis numeros que salen de las
-- ofertas de PostgreSQL: precio_tienda, precio_desde, stock_tienda,
-- stock_total, total_ofertas y hay_descuento. Hasta aqui el backend los
-- recalculaba con un `await` justo despues de cada compra o cambio de oferta
-- (ProductosService.recalcularCamposCalculados). Con MongoDB caido la compra
-- no fallaba, pero la respuesta esperaba 3 s por cada producto, y si el
-- recalculo fallaba el numero quedaba viejo sin que nadie lo volviera a
-- intentar.
--
-- Ahora un trigger anota el producto en esta tabla, EN LA MISMA TRANSACCION
-- que cambia la oferta. Si la compra hace ROLLBACK, el evento tambien
-- desaparece; si hace COMMIT, el evento queda seguro aunque MongoDB este
-- caido. Un worker del backend la vacia y recalcula en MongoDB. Es el mismo
-- diseno que evento_grafo (015), que hace lo mismo con las resenas y Neo4j.
--
-- QUE CUENTA COMO CAMBIO
--
-- Lo que mueve alguno de los seis numeros de la tarjeta:
--
--   precio                el precio
--   porcentaje_descuento  el precio final y hay_descuento
--   stock                 la cantidad
--   id_estado_oferta      pausar o activar saca o mete la oferta en el precio
--                         desde, el stock total y el total de ofertas
--   una oferta nueva o borrada
--
-- La copia del catalogo de la 029 (nombre, imagen, estados del producto) NO
-- encola nada: esa va en el sentido contrario, de MongoDB a PostgreSQL, y se
-- escribe en la misma peticion que edita el producto.
--
-- LA COLA NO SE VACIA EN EL ARRANQUE, a diferencia de evento_grafo. El ETL del
-- catalogo (paso 7) solo conoce los productos que tienen fila en `productos`
-- de PostgreSQL, y los que viven solo en MongoDB tambien tienen ofertas. Marcar
-- todo como hecho despues del ETL dejaria esos sin recalcular. El worker
-- agrupa por producto, asi que miles de eventos de una semilla son unos pocos
-- miles de recalculos, una sola vez.
--
-- Es idempotente, con IF NOT EXISTS, CREATE OR REPLACE y DROP TRIGGER IF
-- EXISTS, porque arrancar.ps1 la vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

-- ============================================================
-- La cola
-- ============================================================
CREATE TABLE IF NOT EXISTS evento_catalogo (
    id_evento          bigserial PRIMARY KEY,
    id_producto_mongo  bigint NOT NULL,
    id_oferta          bigint NOT NULL,
    operacion          varchar(10) NOT NULL
                       CHECK (operacion IN ('alta', 'cambio', 'baja')),
    fecha              timestamptz NOT NULL DEFAULT now(),
    procesado_en       timestamptz,
    intentos           integer NOT NULL DEFAULT 0 CHECK (intentos >= 0),
    ultimo_error       text
);

COMMENT ON TABLE evento_catalogo IS
    'Cola de outbox: productos cuyos numeros del catalogo en MongoDB (precio, stock, total de ofertas, descuento) hay que recalcular. La escribe un trigger sobre oferta en la misma transaccion; la vacia un worker del backend';

COMMENT ON COLUMN evento_catalogo.id_evento IS
    'Serial. Su orden ES el orden de llegada -- no ordenar por fecha, que puede empatar';

-- Lo que se recalcula es el PRODUCTO entero, no la oferta: los seis numeros
-- se agregan sobre todas las ofertas del producto. El id de la oferta queda
-- para poder explicar de donde salio el evento.
COMMENT ON COLUMN evento_catalogo.id_producto_mongo IS
    'El producto a recalcular en MongoDB. El worker agrupa por esta columna y recalcula una sola vez por producto';

-- SIN llave foranea a oferta, igual que evento_grafo con resena: el trigger
-- dispara tambien AFTER DELETE y apuntaria a una oferta recien borrada.
COMMENT ON COLUMN evento_catalogo.id_oferta IS
    'La oferta que cambio. SIN FK a proposito: un evento de baja apunta a una oferta que ya no existe';

COMMENT ON COLUMN evento_catalogo.operacion IS
    'alta = oferta nueva, cambio = precio, descuento, stock o estado, baja = oferta borrada. Solo informativo: el worker recalcula igual en los tres casos';

COMMENT ON COLUMN evento_catalogo.procesado_en IS
    'NULL = pendiente. Con fecha = MongoDB ya tiene los numeros de ese momento';

COMMENT ON COLUMN evento_catalogo.intentos IS
    'Reintentos fallidos. Sirve para apartar un producto que falla siempre y no deja avanzar a los de atras';

COMMENT ON COLUMN evento_catalogo.ultimo_error IS
    'El mensaje del ultimo fallo, para poder mirar un evento apartado sin adivinar';

-- Indices PARCIALES, igual que en evento_grafo: lo procesado se acumula para
-- siempre y la cola no lo mira nunca. El primero es para leer en orden, el
-- segundo para marcar de una vez todos los eventos de un producto.
CREATE INDEX IF NOT EXISTS idx_evento_catalogo_cola
    ON evento_catalogo (id_evento)
    WHERE procesado_en IS NULL;

CREATE INDEX IF NOT EXISTS idx_evento_catalogo_producto
    ON evento_catalogo (id_producto_mongo)
    WHERE procesado_en IS NULL;


-- ============================================================
-- El trigger
-- ============================================================
CREATE OR REPLACE FUNCTION encolar_evento_catalogo()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO evento_catalogo (id_producto_mongo, id_oferta, operacion)
        VALUES (NEW.id_producto_mongo, NEW.id_oferta, 'alta');
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO evento_catalogo (id_producto_mongo, id_oferta, operacion)
        VALUES (OLD.id_producto_mongo, OLD.id_oferta, 'baja');
        RETURN OLD;
    END IF;

    INSERT INTO evento_catalogo (id_producto_mongo, id_oferta, operacion)
    VALUES (NEW.id_producto_mongo, NEW.id_oferta, 'cambio');
    RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION encolar_evento_catalogo() IS
    'Anota en evento_catalogo el producto de una oferta nueva, borrada, o con precio, descuento, stock o estado distinto (030)';

-- Son dos triggers y no uno porque el WHEN del UPDATE compara OLD con NEW, y
-- un trigger que tambien dispara en INSERT no puede nombrar OLD en su WHEN.
--
-- El WHEN hace que un UPDATE que no cambia ninguno de los cuatro (la copia del
-- catalogo de la 029, una fecha, un UPDATE sin cambios) no encole nada. Sin
-- el, `UPDATE OF stock` dispara aunque el stock quede igual.
DROP TRIGGER IF EXISTS trg_oferta_evento_catalogo_alta_baja ON oferta;
CREATE TRIGGER trg_oferta_evento_catalogo_alta_baja
    AFTER INSERT OR DELETE ON oferta
    FOR EACH ROW EXECUTE FUNCTION encolar_evento_catalogo();

DROP TRIGGER IF EXISTS trg_oferta_evento_catalogo_cambio ON oferta;
CREATE TRIGGER trg_oferta_evento_catalogo_cambio
    AFTER UPDATE OF precio, porcentaje_descuento, stock, id_estado_oferta ON oferta
    FOR EACH ROW
    WHEN (OLD.precio               IS DISTINCT FROM NEW.precio
       OR OLD.porcentaje_descuento IS DISTINCT FROM NEW.porcentaje_descuento
       OR OLD.stock                IS DISTINCT FROM NEW.stock
       OR OLD.id_estado_oferta     IS DISTINCT FROM NEW.id_estado_oferta)
    EXECUTE FUNCTION encolar_evento_catalogo();

COMMIT;
