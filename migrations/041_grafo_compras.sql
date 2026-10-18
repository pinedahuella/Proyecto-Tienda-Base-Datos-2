-- ============================================================
-- 041_grafo_compras.sql
-- ============================================================
-- Las compras al grafo de Neo4j, de Jose David (25f0fe0, 2026-10-16). Es su
-- grafo-compras.sql hecho migracion; el plan esta en
-- backend/elementos Generales/plan pendiente/grafo-compras.md.
--
--   (:Usuario)-[:HIZO]->(:Compra)-[:DE]->(:Producto)
--   (:Compra)-[:A_VENDEDOR]->(:Usuario)
--
-- Un nodo :Compra por linea de pedido, como :Resena. Cuenta como compra un
-- pedido comprado, enviado o entregado. "Para ti" (GET /productos/para-ti) y
-- "tambien compraron" (GET /productos/:id/tambien-compraron) se leen en vivo
-- del grafo.
--
-- Mismo outbox que evento_grafo (resenas): el pedido commitea sin esperar a
-- Neo4j y GrafoComprasSyncService proyecta segundos despues. La cola va POR
-- CUENTA: el worker relee todas las compras de la cuenta y deja sus :Compra
-- iguales a eso.
--
-- Lo unico distinto de su SQL es la siembra del final. La suya encolaba todas
-- las cuentas con pedidos en cada corrida, y arrancar.ps1 corre el esquema en
-- cada arranque: el worker volvia a proyectar a todo el mundo cada vez. Aqui
-- siembra solo con la cola vacia, o sea la primera vez. En una base nueva no
-- hay pedidos todavia y los encolan los triggers al cargar migrations/datos/.
-- etl/cargar_grafo.sh --limpiar vuelve a encolar a todos al terminar, porque
-- borra las :Compra.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS evento_grafo_compra (
    id_evento      bigserial PRIMARY KEY,
    id_usuario     bigint NOT NULL,
    fecha          timestamptz NOT NULL DEFAULT now(),
    procesado_en   timestamptz,
    intentos       integer NOT NULL DEFAULT 0 CHECK (intentos >= 0),
    ultimo_error   text
);

COMMENT ON TABLE evento_grafo_compra IS
    'Cola de outbox: cuentas cuyas compras hay que volver a proyectar al grafo de Neo4j (nodos Compra). La llenan triggers de pedido y pedido_producto en la misma transaccion; la vacia GrafoComprasSyncService. Una sola fila pendiente por cuenta';
COMMENT ON COLUMN evento_grafo_compra.id_usuario IS
    'La cuenta que compro. SIN FK a proposito, igual que evento_grafo: la cola no debe impedir nada';
COMMENT ON COLUMN evento_grafo_compra.fecha IS
    'Ultimo cambio visto mientras esta pendiente';
COMMENT ON COLUMN evento_grafo_compra.procesado_en IS
    'NULL = pendiente. Con fecha = las compras de la cuenta ya estan en el grafo';
COMMENT ON COLUMN evento_grafo_compra.intentos IS
    'Reintentos fallidos, para apartar una cuenta que falla siempre y no deja avanzar a las demas';
COMMENT ON COLUMN evento_grafo_compra.ultimo_error IS
    'El mensaje del ultimo fallo';

CREATE UNIQUE INDEX IF NOT EXISTS uq_evento_grafo_compra_pendiente
    ON evento_grafo_compra (id_usuario)
    WHERE procesado_en IS NULL;

CREATE OR REPLACE FUNCTION encolar_evento_grafo_compra(p_id_usuario bigint)
RETURNS void
LANGUAGE sql
AS $fn$
    INSERT INTO evento_grafo_compra (id_usuario)
    VALUES (p_id_usuario)
    ON CONFLICT (id_usuario) WHERE procesado_en IS NULL
    -- intentos = 0: un cambio nuevo reactiva una cuenta apartada.
    DO UPDATE SET fecha = clock_timestamp(), intentos = 0;
$fn$;

-- Un pedido nace, cambia de estado (comprado, cancelado...) o se borra.
CREATE OR REPLACE FUNCTION encolar_evento_grafo_compra_de_pedido()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    -- En un DELETE la fila NEW no esta asignada.
    IF TG_OP = 'DELETE' THEN
        PERFORM encolar_evento_grafo_compra(OLD.id_usuario);
    ELSE
        PERFORM encolar_evento_grafo_compra(NEW.id_usuario);
        IF TG_OP = 'UPDATE' AND NEW.id_usuario <> OLD.id_usuario THEN
            PERFORM encolar_evento_grafo_compra(OLD.id_usuario);
        END IF;
    END IF;
    RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_pedido_al_grafo ON pedido;
CREATE TRIGGER trg_pedido_al_grafo
    AFTER INSERT OR DELETE OR UPDATE OF id_estado_pedido, id_usuario ON pedido
    FOR EACH ROW EXECUTE FUNCTION encolar_evento_grafo_compra_de_pedido();

-- Una linea entra o sale de un pedido (o cambia de producto o cantidad).
CREATE OR REPLACE FUNCTION encolar_evento_grafo_compra_de_linea()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_pedido bigint;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_pedido := OLD.id_pedido;
    ELSE
        v_pedido := NEW.id_pedido;
    END IF;
    PERFORM encolar_evento_grafo_compra(p.id_usuario)
       FROM pedido p
      WHERE p.id_pedido = v_pedido;
    RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_pedido_producto_al_grafo ON pedido_producto;
CREATE TRIGGER trg_pedido_producto_al_grafo
    AFTER INSERT OR DELETE OR UPDATE OF id_producto_mongo, cantidad, id_pedido
    ON pedido_producto
    FOR EACH ROW EXECUTE FUNCTION encolar_evento_grafo_compra_de_linea();

-- Siembra: cada cuenta que ya tiene pedidos, UNA vez (con la cola vacia).
-- Con esto el worker llena el grafo solo, sin ETL. Despues de un
-- `etl/cargar_grafo.sh --limpiar` la vuelve a correr el propio ETL.
INSERT INTO evento_grafo_compra (id_usuario)
SELECT DISTINCT id_usuario FROM pedido
 WHERE NOT EXISTS (SELECT 1 FROM evento_grafo_compra)
ON CONFLICT (id_usuario) WHERE procesado_en IS NULL DO NOTHING;

COMMIT;
