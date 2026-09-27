-- ============================================================
-- 026_casos_fraude.sql
-- ============================================================
-- Los casos de fraude: el agrupador de Jose David junta los hallazgos de las
-- tres fuentes que no se hablaban (`anillo_fraude` del grafo,
-- `hallazgo_evento_fraude` de ClickHouse y `alerta_fraude` del login) cuando
-- comparten cuentas, y les pone puntaje, nivel y reglas "casi confirmado".
-- Lo llena AgrupadorFraudeWorkerService cada 15 minutos y el admin lo revisa
-- por GET y PATCH /admin/fraude/casos.
--
--
-- DE DONDE SALE
-- ============================================================
-- Del SQL de referencia del companero, en
-- `backend/elementos Generales/plan pendiente/agrupador-fraude.sql`, con su
-- diseno en `agrupador-fraude.md` de la misma carpeta. Copiado tal cual salvo
-- dos cosas, las dos de este lado:
--
--   1. Las tres llaves de `evidencia_caso_fraude` hacia las fuentes van con
--      ON DELETE CASCADE. Sin eso, borrar una alerta que ya es evidencia de
--      un caso falla por la llave, y lo hacen `pruebas/alertas_login.sh` y
--      `demo-fraude-pais.ps1 -Limpiar`. La evidencia de una fila borrada no
--      apunta a nada, asi que se va con ella.
--   2. La descripcion de R-CASI-1 ya no nombra A.4 (misma casa con calle),
--      que el companero descarto el 2026-09-26.
--
-- No lleva candado de ids como la 019, la 023 y la 025: el backend busca los
-- niveles, las reglas y el estado `confirmada` por NOMBRE, nunca por id.
--
-- Es idempotente, con IF NOT EXISTS y ON CONFLICT, porque `arrancar.ps1` la
-- vuelve a correr en cada arranque y la base del companero ya la tiene.
--
-- Reservada desde la 022 para la propuesta de casos de fraude
-- (`docs/fraude-entrega3/02-reglas-backend.md`).
-- ============================================================


BEGIN;

CREATE TABLE IF NOT EXISTS nivel_caso_fraude (
    id_nivel_caso_fraude      smallserial PRIMARY KEY,
    nivel_caso_fraude_nombre  varchar(20) NOT NULL UNIQUE
    -- informativo, revisar, prioritario, casi_confirmado
);

COMMENT ON TABLE nivel_caso_fraude IS 'Catalogo de los cuatro niveles de un caso de fraude agrupado';

CREATE TABLE IF NOT EXISTS caso_fraude (
    id_caso_fraude           bigserial PRIMARY KEY,
    id_nivel_caso_fraude     smallint NOT NULL REFERENCES nivel_caso_fraude,
    puntaje                  numeric(8,2) NOT NULL,
    id_estado_alerta_fraude  smallint NOT NULL REFERENCES estado_alerta_fraude,
    firma_al_descartar       text,
    motivo                   text,
    ultima_evidencia         timestamptz NOT NULL,
    fecha_creacion           timestamptz NOT NULL DEFAULT now(),
    fecha_actualizacion      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE caso_fraude IS 'Un caso: uno o mas hallazgos de fraude que comparten cuentas, con puntaje y nivel combinados';
COMMENT ON COLUMN caso_fraude.firma_al_descartar IS 'Que evidencia (tipos y claves) habia al momento de descartar -- si cambia, el caso se reabre';
COMMENT ON COLUMN caso_fraude.id_estado_alerta_fraude IS 'Reusa el catalogo de alerta_fraude/hallazgo_evento_fraude -- pendiente/revisada/descartada, mas confirmada (ver el INSERT de abajo)';

-- Que reglas "casi confirmado" cumplio un caso -- normalizado, NO un
-- arreglo de texto en caso_fraude (correccion del usuario, 2026-09-26):
-- catalogo + tabla puente, mismo patron que el resto del proyecto
-- (tipo_hallazgo_evento, estado_alerta_fraude). Un caso puede cumplir mas
-- de una regla a la vez (ver el caso 2 del documento original, cumple
-- R-CASI-1 y R-CASI-2 juntas), de ahi la tabla puente y no una sola
-- columna con un id.
CREATE TABLE IF NOT EXISTS regla_casi_confirmado (
    id_regla_casi_confirmado      smallserial PRIMARY KEY,
    regla_casi_confirmado_nombre  varchar(20) NOT NULL UNIQUE,
    -- R-CASI-1 .. R-CASI-5
    descripcion                   text NOT NULL
);

-- Por si la tabla ya existia de una corrida anterior sin esta columna.
ALTER TABLE regla_casi_confirmado ADD COLUMN IF NOT EXISTS descripcion text;

COMMENT ON TABLE regla_casi_confirmado IS 'Catalogo de las cinco reglas que suben un caso a casi_confirmado sin importar el puntaje';
COMMENT ON COLUMN regla_casi_confirmado.descripcion IS 'La condicion (que evidencia exige) y que quiere decir, en una sola frase -- seccion 4 de docs/fraude-entrega3/02-reglas-backend.md';

CREATE TABLE IF NOT EXISTS caso_fraude_regla (
    id_caso_fraude            bigint NOT NULL REFERENCES caso_fraude ON DELETE CASCADE,
    id_regla_casi_confirmado  smallint NOT NULL REFERENCES regla_casi_confirmado,
    PRIMARY KEY (id_caso_fraude, id_regla_casi_confirmado)
);

COMMENT ON TABLE caso_fraude_regla IS 'Que reglas R-CASI cumplio cada caso -- puede ser mas de una a la vez';

-- Las tres fuentes ya tienen exactamente UNA tabla persistida cada una
-- (verificado contra la base real, 2026-09-26): `anillo_fraude` (grafo,
-- las 10 familias A y B juntas), `hallazgo_evento_fraude` (eventos,
-- F1-F6), `alerta_fraude` (login). Por eso `evidencia_caso_fraude` usa TRES
-- llaves foraneas reales, exclusivas entre si, en vez de un `fuente`
-- de texto + una `clave` suelta que habria que mantener sincronizada a
-- mano (correccion del usuario, 2026-09-26 -- "lo mas normalizado
-- posible"). `tipo`/`clave`/`metricas` YA NO se copian aca: se consiguen
-- con un JOIN a la fila real, que ya los tiene cada una (`anillo_fraude`
-- gano su propio `detalle jsonb` para esto, ver el ALTER de abajo).
CREATE TABLE IF NOT EXISTS evidencia_caso_fraude (
    id_evidencia_caso_fraude   bigserial PRIMARY KEY,
    id_caso_fraude             bigint NOT NULL REFERENCES caso_fraude ON DELETE RESTRICT,
    id_anillo_fraude           bigint REFERENCES anillo_fraude ON DELETE CASCADE,
    id_hallazgo_evento_fraude  bigint REFERENCES hallazgo_evento_fraude ON DELETE CASCADE,
    id_alerta_fraude           bigint REFERENCES alerta_fraude ON DELETE CASCADE,
    puntos                     numeric(6,2) NOT NULL,
    ultima_evidencia           timestamptz NOT NULL,
    CHECK (num_nonnulls(id_anillo_fraude, id_hallazgo_evento_fraude, id_alerta_fraude) = 1)
);

-- La base del companero ya tiene la tabla con las tres llaves SIN cascada,
-- de antes de esta migracion. El CREATE de arriba no las cambia si la tabla
-- existe, asi que se rehacen aqui. Es idempotente: cada corrida las quita y
-- las vuelve a poner iguales.
ALTER TABLE evidencia_caso_fraude
    DROP CONSTRAINT IF EXISTS evidencia_caso_fraude_id_anillo_fraude_fkey,
    DROP CONSTRAINT IF EXISTS evidencia_caso_fraude_id_hallazgo_evento_fraude_fkey,
    DROP CONSTRAINT IF EXISTS evidencia_caso_fraude_id_alerta_fraude_fkey;
ALTER TABLE evidencia_caso_fraude
    ADD CONSTRAINT evidencia_caso_fraude_id_anillo_fraude_fkey
        FOREIGN KEY (id_anillo_fraude) REFERENCES anillo_fraude ON DELETE CASCADE,
    ADD CONSTRAINT evidencia_caso_fraude_id_hallazgo_evento_fraude_fkey
        FOREIGN KEY (id_hallazgo_evento_fraude) REFERENCES hallazgo_evento_fraude ON DELETE CASCADE,
    ADD CONSTRAINT evidencia_caso_fraude_id_alerta_fraude_fkey
        FOREIGN KEY (id_alerta_fraude) REFERENCES alerta_fraude ON DELETE CASCADE;

-- Un mismo hallazgo real (anillo/hallazgo de evento/alerta) no puede ser
-- evidencia de mas de un caso a la vez -- si no, el mismo hecho se
-- contaria dos veces en dos puntajes distintos. Un indice unico parcial
-- por columna (no puede ser un UNIQUE normal: las otras dos siempre son
-- NULL en cada fila, y NULL nunca choca con NULL).
CREATE UNIQUE INDEX IF NOT EXISTS idx_evidencia_caso_fraude_anillo
    ON evidencia_caso_fraude (id_anillo_fraude) WHERE id_anillo_fraude IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_evidencia_caso_fraude_hallazgo_evento
    ON evidencia_caso_fraude (id_hallazgo_evento_fraude) WHERE id_hallazgo_evento_fraude IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_evidencia_caso_fraude_alerta
    ON evidencia_caso_fraude (id_alerta_fraude) WHERE id_alerta_fraude IS NOT NULL;

COMMENT ON TABLE evidencia_caso_fraude IS 'Enlaza UN hallazgo real (de anillo_fraude, hallazgo_evento_fraude o alerta_fraude -- exactamente una de las tres) a su caso. NO copia tipo/clave/metricas: se leen con JOIN a la fuente real';
COMMENT ON COLUMN evidencia_caso_fraude.puntos IS 'Cuantos puntos aporta ESTE hallazgo al puntaje del caso -- esto si es un dato nuevo, calculado por las reglas de puntaje (seccion 3), no una copia de nada que ya exista';

-- `anillo_fraude` era la unica de las tres fuentes sin un campo de
-- detalle -- `hallazgo_evento_fraude.detalle` y `alerta_fraude.detalle` ya
-- existian. Se le agrega para que las metricas (horas, vueltas,
-- exclusividad) de un hallazgo de grafo tambien queden en algun lado y
-- las tres fuentes se lean igual desde `evidencia_caso_fraude`.
ALTER TABLE anillo_fraude ADD COLUMN IF NOT EXISTS detalle jsonb NOT NULL DEFAULT '{}'::jsonb;
COMMENT ON COLUMN anillo_fraude.detalle IS 'Las metricas del hallazgo (horas, vueltas, exclusividad, etc.) -- agregado 2026-09-26 para que anillo_fraude quede igual que hallazgo_evento_fraude/alerta_fraude';

CREATE TABLE IF NOT EXISTS evidencia_caso_fraude_cuenta (
    id_evidencia_caso_fraude  bigint NOT NULL REFERENCES evidencia_caso_fraude ON DELETE CASCADE,
    id_usuario                bigint NOT NULL REFERENCES usuarios ON DELETE RESTRICT,
    es_nucleo                 boolean NOT NULL,
    PRIMARY KEY (id_evidencia_caso_fraude, id_usuario)
);

COMMENT ON TABLE evidencia_caso_fraude_cuenta IS 'Que cuentas toca una evidencia dentro de ESTE caso, y si es nucleo o periferia -- NO es redundante con hallazgo_evento_fraude_cuenta: esa clasificacion es por hallazgo aislado, esta es por CASO (>=2 hallazgos del caso, o uno fuerte), se recalcula cada vez que el caso se reune';

-- NO existe `evidencia_caso_fraude_resena`: seria 100% redundante con
-- `anillo_fraude_resena`, que ya existe y ya enlaza un anillo con sus
-- resenas de evidencia. Con `evidencia_caso_fraude.id_anillo_fraude` de
-- arriba, el camino ya es directo:
--   evidencia_caso_fraude -> id_anillo_fraude -> anillo_fraude_resena -> resena
-- (encontrado revisando el esquema real, correccion del usuario, 2026-09-26).

-- El unico nivel que habilita sanciones (esconder resenas del promedio,
-- aviso inmediato). Los otros tres (pendiente/revisada/descartada) ya
-- existen, los reusan alerta_fraude/anillo_fraude/hallazgo_evento_fraude.
INSERT INTO estado_alerta_fraude (estado_alerta_fraude_nombre)
VALUES ('confirmada')
ON CONFLICT (estado_alerta_fraude_nombre) DO NOTHING;

INSERT INTO nivel_caso_fraude (nivel_caso_fraude_nombre)
VALUES ('informativo'), ('revisar'), ('prioritario'), ('casi_confirmado')
ON CONFLICT (nivel_caso_fraude_nombre) DO NOTHING;

INSERT INTO regla_casi_confirmado (regla_casi_confirmado_nombre, descripcion) VALUES
    ('R-CASI-1', 'Un ciclo, un reiterado o una granja, y ademas las cuentas del nucleo compraron desde la misma IP (F3) o nacieron desde la misma IP (F6) -- se califican entre si y son la misma persona fisica'),
    ('R-CASI-2', 'Un ciclo, un mutuo o una cadena abierta, y ademas al menos dos cuentas del nucleo recibieron resenas expres de autores con menos de 60 minutos de vida (B.7) -- nadie compra, recibe y califica en minutos, es un guion'),
    ('R-CASI-3', 'Una cuenta del nucleo califico un producto y despues lo devolvio (la resena y la devolucion comparten autor, producto y vendedor), y el caso tiene otro hallazgo de resenas -- compro para poder calificar y recupero el dinero'),
    ('R-CASI-4', 'Un ciclo con dos o mas olas (B.4) y todas sus notas altas -- el anillo se usa cada tanto, como un recurso'),
    ('R-CASI-5', 'Coordinados (B.6), y ademas las dos cuentas compraron o nacieron desde la misma IP (F3 o F6) -- dos teclados, una mano')
ON CONFLICT (regla_casi_confirmado_nombre) DO UPDATE SET descripcion = EXCLUDED.descripcion;

-- La columna pudo quedar NULLABLE si se agrego con el ALTER de arriba
-- (tabla ya existente, sin el NOT NULL del CREATE original). Ya con las
-- cinco filas pobladas por el INSERT de arriba, se puede exigir.
ALTER TABLE regla_casi_confirmado ALTER COLUMN descripcion SET NOT NULL;

COMMIT;
