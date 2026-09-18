-- ============================================================
-- anillos-fraude-persistencia.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada despues de la ultima migracion real
-- existente y en migrations/README.md -- mismo workflow de siempre (ver
-- fraude-login-eventos.sql y notificacion-fraude-usuario.sql, mismo folder,
-- para el precedente).
--
-- Persiste lo que hasta ahora solo detectaba y logueaba
-- `AnillosDetectorService` (src/services/fraude/anillos-detector.service.ts):
-- los anillos `mutuo`/`ciclo`/`reiterado` (A.1/A.2) que aparecen en el grafo
-- de Neo4j. A.4 (misma direccion) sigue fuera de alcance -- ver
-- `anillos-fraude-persistencia.md` (mismo folder) para el porque de cada
-- decision de esta tabla.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS / ON CONFLICT) y reversible: un
-- `.\arrancar.ps1 -Reiniciar` reconstruye la base desde las migraciones
-- reales y borra todo esto.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. tipo_anillo_fraude: catalogo de los tipos de anillo que detecta
--    AnillosDetectorService. Mismo criterio que tipo_alerta_fraude: un
--    catalogo chico y controlado por el codigo, en tabla y no en un CHECK,
--    para seguir el mismo patron que el resto del proyecto (estado_oferta,
--    estado_producto, tipo_alerta_fraude...).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tipo_anillo_fraude (
    id_tipo_anillo_fraude      smallserial PRIMARY KEY,
    tipo_anillo_fraude_nombre  varchar(20) NOT NULL UNIQUE
);

-- El orden del INSERT fija los ids: 1 mutuo, 2 ciclo, 3 reiterado.
-- src/models/anillo-fraude.ts los fija como constantes, igual que
-- ID_TIPO_ALERTA_FRAUDE_* en models/alerta-fraude.ts.
INSERT INTO tipo_anillo_fraude (tipo_anillo_fraude_nombre) VALUES
    ('mutuo'),
    ('ciclo'),
    ('reiterado')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE tipo_anillo_fraude IS
    'Catalogo de tipos de anillo de fraude en resenas que detecta AnillosDetectorService: mutuo (2 cuentas se califican entre si), ciclo (3-4 cuentas en circulo), reiterado (mutuo ademas sobre el mismo producto -- pisa a mutuo del mismo par)';


-- ------------------------------------------------------------
-- 2. anillo_fraude: una fila por anillo detectado
-- ------------------------------------------------------------
-- La escribe AnillosDetectorService (worker de 15 min y su version acotada
-- por resena, detectarInmediato()) cuando A.1/A.2 encuentran un grupo de
-- cuentas dentro de la ventana de dias vigente (VENTANA_DIAS, hoy 60).
--
-- `clave` NO lleva el tipo -- a diferencia del `Anillo.id` que arma
-- `fraude.service.ts` para el panel en vivo (`mutuo-9-10`) -- es solo los
-- ids de cuenta ordenados ("9-10"). A proposito: un mismo par/grupo de
-- cuentas puede empezar como `mutuo` y mas tarde subir a `reiterado` (si
-- escriben otra resena sobre el mismo producto), y para efectos de
-- persistencia sigue siendo EL MISMO caso -- se actualiza la fila existente
-- (tipo + ultima_vez_confirmado_activo), no se crea una fila nueva. Mismo
-- criterio que ya usa `AnillosDetectorService.agrupar()` para fusionar
-- mutuo/reiterado del mismo par antes de loguear.
--
-- id_estado_alerta_fraude reusa el catalogo de fraude de login
-- (pendiente/revisada/descartada): es generico, sin logica propia de ningun
-- dominio, no hace falta uno nuevo para anillos.
CREATE TABLE IF NOT EXISTS anillo_fraude (
    id_anillo_fraude              bigserial PRIMARY KEY,

    id_tipo_anillo_fraude         smallint NOT NULL
                                   REFERENCES tipo_anillo_fraude(id_tipo_anillo_fraude),

    clave                         varchar(255) NOT NULL UNIQUE,

    id_estado_alerta_fraude       smallint NOT NULL
                                   REFERENCES estado_alerta_fraude(id_estado_alerta_fraude),

    fecha_creacion                timestamptz NOT NULL DEFAULT now(),

    -- Se actualiza cada vez que una corrida (worker o acotada) vuelve a
    -- encontrar este mismo anillo. Junto con fecha_creacion, responde
    -- "hace cuanto existe" y "sigue activo" sin necesitar una ventana fija
    -- como alerta_fraude.ventana_inicio -- un anillo es "esto existe en el
    -- grafo ahora mismo", no "un umbral se cruzo en un momento".
    ultima_vez_confirmado_activo  timestamptz NOT NULL DEFAULT now(),

    -- Cuando un admin cambio el estado. Distinta de la de arriba: esa es
    -- sobre deteccion, esta es sobre revision humana.
    fecha_actualizacion           timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE anillo_fraude IS
    'Un anillo de fraude en resenas (mutuo/ciclo/reiterado, A.1/A.2) detectado por AnillosDetectorService. No guarda evidencia en JSON: ver anillo_fraude_resena para las resenas exactas, y consultar Neo4j/resena con esos ids para el detalle de la relacion.';
COMMENT ON COLUMN anillo_fraude.clave IS
    'Los ids de cuenta del anillo, ordenados y unidos con "-" (ej. "9-10"). NO lleva el tipo: el mismo par/grupo de cuentas puede subir de mutuo a reiterado (o bajar, si la resena que sostenia el reiterado sale de la ventana) sin cambiar de fila.';
COMMENT ON COLUMN anillo_fraude.ultima_vez_confirmado_activo IS
    'La ultima corrida (worker de 15 min o chequeo acotado por resena) que volvio a encontrar este anillo. Si deja de avanzar, el anillo ya no aparecio en corridas recientes -- no se borra ni se marca solo, queda para que un admin lo revise.';

-- El listado de admin: los anillos que siguen activos primero.
CREATE INDEX IF NOT EXISTS idx_anillo_fraude_listado
    ON anillo_fraude (ultima_vez_confirmado_activo DESC);

-- Filtrar por estado (la cola de pendientes) sin barrer toda la tabla.
CREATE INDEX IF NOT EXISTS idx_anillo_fraude_estado
    ON anillo_fraude (id_estado_alerta_fraude);


-- ------------------------------------------------------------
-- 3. anillo_fraude_resena: pivote a la evidencia
-- ------------------------------------------------------------
-- Que resenas exactas son la evidencia de cada anillo -- una fila por
-- resena, no un array ni un jsonb. Con el id de resena el admin puede
-- consultar directo Neo4j (MATCH (r:Resena) WHERE r.id IN (...)) o
-- PostgreSQL (SELECT * FROM resena WHERE id_resena IN (...)): es el mismo
-- id en las dos bases (GrafoSyncService lo proyecta tal cual).
--
-- Sin columna de lectura -- a diferencia de notificacion_fraude, aca no hay
-- a quien notificar: las cuentas de un anillo son las SOSPECHOSAS, no
-- victimas, asi que avisarles les daria la oportunidad de evadir la
-- deteccion. El caso es 100% interno para que un admin lo revise -- ver
-- anillos-fraude-persistencia.md para el razonamiento completo.
--
-- Tampoco hay una tabla de cuentas aparte: para mutuo/ciclo/reiterado toda
-- cuenta del anillo es autor o vendedor de alguna de sus resenas, asi que
-- "quienes estan en el anillo" sale de un join contra resena.id_usuario /
-- id_usuario_vendedor con los ids de aqui -- guardarlas tambien seria
-- redundante.
CREATE TABLE IF NOT EXISTS anillo_fraude_resena (
    id_anillo_fraude  bigint NOT NULL
                      REFERENCES anillo_fraude(id_anillo_fraude)
                      ON DELETE RESTRICT,

    id_resena         bigint NOT NULL
                      REFERENCES resena(id_resena)
                      ON DELETE RESTRICT,

    PRIMARY KEY (id_anillo_fraude, id_resena)
);

COMMENT ON TABLE anillo_fraude_resena IS
    'Pivote: que resenas exactas son la evidencia de un anillo_fraude. Sin columna de lectura (las cuentas del anillo son sospechosas, no se les notifica) y sin tabla de cuentas aparte (se derivan via join con resena.id_usuario/id_usuario_vendedor).';

-- Para ir de una resena a que anillo(s) pertenece, si hiciera falta.
CREATE INDEX IF NOT EXISTS idx_anillo_fraude_resena_resena
    ON anillo_fraude_resena (id_resena);

COMMIT;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT id_tipo_anillo_fraude, tipo_anillo_fraude_nombre
FROM tipo_anillo_fraude ORDER BY id_tipo_anillo_fraude;

SELECT to_regclass('public.anillo_fraude') AS tabla_anillo_fraude;
SELECT to_regclass('public.anillo_fraude_resena') AS tabla_anillo_fraude_resena;
