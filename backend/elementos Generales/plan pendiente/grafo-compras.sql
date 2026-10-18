-- ============================================================
-- grafo-compras.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de la ultima real (hoy la 039) y de
-- vectores-pgvector.sql. El plan completo esta en grafo-compras.md.
--
-- Las compras pasan al grafo de Neo4j, como ya pasan las resenas:
--   (:Usuario)-[:HIZO]->(:Compra)-[:A_VENDEDOR]->(:Usuario)
--                       (:Compra)-[:DE]->(:Producto)
-- Un nodo :Compra por linea de pedido (la variante va como propiedad), con la
-- misma forma que :Resena. En neo4j/001_esquema.cypher hace falta:
--   CREATE CONSTRAINT compra_id IF NOT EXISTS
--   FOR (k:Compra) REQUIRE k.id IS UNIQUE;
-- Cuenta como compra un pedido
-- `comprado`, `enviado` o `entregado`: `pendiente` todavia no lo es y
-- `cancelado` ya no.
--
-- Mismo outbox que `evento_grafo` (resenas), con la misma directiva del
-- profesor: la compra commitea en PostgreSQL sin esperar a Neo4j, un worker
-- (`GrafoComprasSyncService`) la lleva al grafo segundos despues, y la
-- conciliacion (`GET /admin/grafo/conciliacion`) compara las dos bases.
--
-- La cola va POR CUENTA, no por pedido: el worker relee TODAS las compras de
-- la cuenta y deja sus `:Compra` iguales a eso (agrega las que faltan, borra
-- las que sobran). Asi un pedido cancelado, uno nuevo o uno borrado a mano se
-- resuelven igual, sin guardar "alta" o "baja" en el evento. Una sola fila
-- pendiente por cuenta, como evento_comentario: varios cambios seguidos se
-- resuelven con una sola proyeccion.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente y reversible: un `.\arrancar.ps1 -Reiniciar` reconstruye la
-- base desde las migraciones reales y borra esto.
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

-- Siembra: cada cuenta que ya tiene pedidos, una vez. Con esto el worker
-- llena el grafo solo, sin ETL. Si el grafo se reconstruye con
-- `etl/cargar_grafo.sh --limpiar` (que hoy no carga compras), se vuelve a
-- correr esta misma sentencia.
INSERT INTO evento_grafo_compra (id_usuario)
SELECT DISTINCT id_usuario FROM pedido
ON CONFLICT (id_usuario) WHERE procesado_en IS NULL DO NOTHING;

COMMIT;
