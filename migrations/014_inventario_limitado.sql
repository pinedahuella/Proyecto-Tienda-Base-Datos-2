-- ============================================================
-- 014_inventario_limitado.sql
-- ============================================================
-- Marca que ofertas se venden con el mecanismo de venta relampago de Redis en
-- vez de con el flujo normal de stock de PostgreSQL.
--
-- Es una sola columna, pero la decision que representa es grande y conviene
-- dejarla escrita aqui, que es donde alguien la va a buscar.
--
--
-- QUE PROBLEMA RESUELVE, Y POR QUE NO LO RESUELVE PostgreSQL
-- ============================================================
-- El flujo normal de una compra descuenta stock dentro de una transaccion, con
-- un SELECT ... FOR UPDATE sobre la fila de `oferta`. Eso es correcto y es la
-- razon escrita del ADR-2: las ofertas se quedan en el relacional justamente
-- porque el descuento tiene que ser atomico y no vender dos veces la ultima
-- unidad. Medido en la Entrega 1: cero sobreventas sobre 555 ofertas.
--
-- Lo que ese flujo NO aguanta bien es la forma de una venta relampago: miles de
-- personas peleandose por cien unidades en el mismo segundo. El FOR UPDATE las
-- pone en fila de una en una sobre la MISMA fila, y la fila se vuelve el cuello
-- de botella: cada quien espera a que el anterior confirme su transaccion
-- entera. No es que se venda de mas, es que se atiende de a uno.
--
-- Redis resuelve esa forma concreta porque ejecuta el script Lua ENTERO de
-- forma atomica y en memoria, sin transacciones que esperar. El arnes
-- `redis/prueba_concurrencia.sh` lo mide: 1000 solicitudes con 50 clientes a la
-- vez sobre 100 unidades, cero sobreventa, y el control ingenuo del mismo arnes
-- SI sobrevende, o sea que la carga llega de verdad.
--
--
-- POR QUE ES UNA COLUMNA Y NO UNA TABLA APARTE
-- ============================================================
-- Es un atributo de la oferta, no una entidad. Una oferta no tiene "ventas
-- relampago" en plural: o esta operando bajo ese mecanismo o no lo esta, y es
-- un solo booleano. Una tabla `venta_limitada(id_oferta, ...)` seria una tabla
-- con una fila por oferta y ninguna columna propia, o sea la misma columna con
-- un JOIN de mas.
--
-- El dia que haga falta guardar CUANDO abrio la venta, cuantas unidades se
-- pusieron o quien la abrio, eso SI es una entidad y toca su propia tabla. Hoy
-- esos tres datos viven en Redis mientras la venta esta abierta, y no hay
-- ningun requisito de conservarlos despues.
--
--
-- POR QUE NO SE MARCA SOLA
-- ============================================================
-- La pone el vendedor al abrir la venta, a proposito. Que el sistema decidiera
-- solo "esta oferta tiene mucha demanda, la paso a relampago" cambiaria las
-- reglas de una compra en curso sin que nadie lo pidiera: quien tenia el
-- producto en el carrito pasaria de "nada reservado" a "unidades reservadas con
-- un plazo", o al reves, en medio de su compra.
--
-- Por eso el DEFAULT es false y por eso NO hay trigger que la toque.
--
--
-- LO QUE ESTA COLUMNA NO GARANTIZA
-- ============================================================
-- Que valga true NO quiere decir que haya una venta abierta en Redis ahora
-- mismo. Quiere decir que esa oferta opera bajo ese mecanismo. La venta viva,
-- con sus unidades y su plazo, existe solo en Redis y se va cuando expira su
-- TTL o cuando el vendedor la cierra.
--
-- O sea que hay dos preguntas distintas y esta columna solo contesta la
-- primera:
--
--   esta oferta se vende con el mecanismo relampago?   -> esta columna
--   hay unidades disponibles ahora mismo?              -> Redis, y solo Redis
--
-- Confundirlas es el error caro: leer esta columna y suponer que hay stock
-- reservable lleva a ensenar "quedan pocas" de una venta que ya cerro. El
-- backend consulta Redis para lo segundo y no pregunta a PostgreSQL.
--
--
-- POR QUE NO HAY CHECK CONTRA `stock`
-- ============================================================
-- Se penso poner algo como "si es_inventario_limitado entonces stock > 0" y se
-- descarto. Mientras la venta relampago esta abierta, el stock de verdad vive
-- en Redis, y la columna `stock` de esta tabla no lo refleja: puede quedarse en
-- el numero con que se abrio la venta hasta que se confirme. Un CHECK que
-- comparara las dos cosas estaria comparando dos verdades de momentos
-- distintos, y fallaria sobre datos correctos.
-- ============================================================


ALTER TABLE oferta
    ADD COLUMN IF NOT EXISTS es_inventario_limitado boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN oferta.es_inventario_limitado IS
    'true si esta oferta opera bajo el mecanismo de venta relampago de Redis '
    '(redis/inventario_limitado.lua) en vez del flujo normal de stock con '
    'FOR UPDATE. La pone el vendedor al abrir la venta; no se marca sola. '
    'NO significa que haya una venta abierta ahora: eso solo lo sabe Redis.';


-- ------------------------------------------------------------
-- El indice, y por que es PARCIAL
-- ------------------------------------------------------------
-- Las consultas que necesitan esta columna preguntan siempre lo mismo: cuales
-- son las ofertas relampago. Nunca preguntan cuales NO lo son, porque esas son
-- casi todas y la respuesta seria el catalogo entero.
--
-- Un indice normal sobre un booleano donde el 99 por ciento de las filas vale
-- false ocupa una entrada por cada oferta y no sirve para nada: el planificador
-- lo descarta y prefiere recorrer la tabla. El parcial solo guarda las filas
-- que valen true, asi que ocupa tantas entradas como ofertas relampago haya, y
-- para la unica pregunta que se hace es exactamente el indice que hace falta.
--
-- Es la misma leccion que ya tiene escrita mongo/001_productos.js: un indice se
-- gana el puesto por la consulta que sirve, no por la columna que cubre.
CREATE INDEX IF NOT EXISTS idx_oferta_inventario_limitado
    ON oferta(id_oferta)
    WHERE es_inventario_limitado;


-- ------------------------------------------------------------
-- Comprobarse a si misma
-- ------------------------------------------------------------
-- La migracion tiene que dejar la columna EXACTAMENTE como el backend la
-- espera, porque el backend ya la esta leyendo. Si el DEFAULT o el NOT NULL
-- salieran distintos, no fallaria nada aqui: fallaria alla, mucho despues, con
-- un null donde el codigo espera un booleano.
DO $verificar$
DECLARE
    v_tipo     text;
    v_nulos    text;
    v_default  text;
    v_indice   integer;
BEGIN
    SELECT data_type, is_nullable, coalesce(column_default, '')
      INTO v_tipo, v_nulos, v_default
      FROM information_schema.columns
     WHERE table_name = 'oferta' AND column_name = 'es_inventario_limitado';

    IF v_tipo IS NULL THEN
        RAISE EXCEPTION 'La columna es_inventario_limitado no quedo creada';
    END IF;

    IF v_tipo <> 'boolean' THEN
        RAISE EXCEPTION 'es_inventario_limitado quedo como % y tiene que ser boolean', v_tipo;
    END IF;

    IF v_nulos <> 'NO' THEN
        RAISE EXCEPTION 'es_inventario_limitado acepta NULL y no debe: el backend la lee como booleano';
    END IF;

    IF v_default NOT LIKE '%false%' THEN
        RAISE EXCEPTION 'es_inventario_limitado no tiene DEFAULT false (tiene: %)', v_default;
    END IF;

    SELECT count(*) INTO v_indice
      FROM pg_indexes
     WHERE tablename = 'oferta' AND indexname = 'idx_oferta_inventario_limitado';

    IF v_indice <> 1 THEN
        RAISE EXCEPTION 'Falta el indice parcial idx_oferta_inventario_limitado';
    END IF;

    -- Ninguna oferta existente se marca sola. Esta comprobacion existe porque
    -- la columna se aplico a mano en alguna maquina antes de que esta migracion
    -- existiera, y una fila marcada a mano ahi cambiaria como se comporta el
    -- carrito sin que nadie lo hubiera pedido.
    RAISE NOTICE 'es_inventario_limitado lista. Ofertas marcadas: %',
                 (SELECT count(*) FROM oferta WHERE es_inventario_limitado);
END
$verificar$;
