# PENDIENTE: el outbox para el grafo

> ## OJO ANTES DE LEER: la cola YA EXISTE, y NO tiene la forma de este documento
>
> **Al 2026-09-03 por la noche.** Este documento era el diseno y decia "nada de
> esto esta implementado". Eso ya no es cierto:
>
> - La tabla y el trigger estan en **`migrations/015_outbox_grafo.sql`**, aplicados.
> - `etl/cargar_grafo.sh` vacia la cola al terminar, y tiene un modo
>   **`--cola`** que proyecta solo lo pendiente.
> - Falta el worker, la conciliacion y el aviso de "ultima sincronizacion", y
>   **los lleva Jose David** (su plan esta en
>   `backend/elementos Generales/plan pendiente/outbox-grafo.md`).
>
> **Y el esquema que se construyo NO es el de aqui abajo.** Se le quitaron dos
> columnas a proposito, asi que quien lea la seccion del esquema de este
> documento va a ver dos campos que en la base no existen:
>
> | Lo que este documento proponia | Que paso |
> |---|---|
> | `entidad varchar(30)` | **quitada.** El trigger siempre escribiria `'resena'`. Una columna con un solo valor posible no informa de nada |
> | `operacion varchar(10)` | **quitada.** El alta y la baja se INFIEREN releyendo la resena: si la fila existe es alta, si no existe es baja. Guardarla congela un "que paso" que puede contradecir a la base |
> | `id_entidad` | se llama **`id_resena`**, que es lo que de verdad guarda |
>
> **La fuente de verdad del esquema es `migrations/015_outbox_grafo.sql`**, y su
> cabecera explica cada decision. Lo de aqui abajo se conserva porque el
> RAZONAMIENTO sigue valiendo entero -- el porque de un outbox, las cinco
> trampas del worker, la conciliacion -- pero el DDL concreto ya caduco.

**No es de la Entrega 2.** No da un solo punto ahi. Da 5 en la Entrega 3, y eso
esta explicado al final.

---

## El problema que resuelve

Hoy el grafo se llena corriendo `./etl/cargar_grafo.sh` a mano (o desde
`arrancar.ps1`). Eso tiene dos costuras:

**1. El grafo se queda viejo y no lo dice.** Una resena publicada despues de la
ultima corrida no esta en Neo4j. El panel de fraude la ignora sin ninguna senal:
ensena un analisis correcto sobre datos incompletos, que es peor que fallar.

**2. El ETL relee TODO cada vez.** Es idempotente (`MERGE`), pero no incremental:
con 90 resenas tarda 14 segundos (medidos con 86, que era el numero de
entonces), y ese numero crece con el catalogo aunque no
haya cambiado nada. Medido el 2026-08-29.

---

## Que es un outbox

Una tabla de eventos pendientes que se escribe **en la misma transaccion** que el
dato, y que otro proceso vacia despues.

```
  INSERT INTO resena ...        --+  una sola transaccion:
  (trigger) INSERT evento_grafo --+  o pasan las dos o no pasa ninguna

  ... segundos despues, otro proceso:
  lee los pendientes -> los aplica en Neo4j -> los marca hechos
```

**Todo el patron esta en esas dos lineas de arriba.** Lo unico que lo hace
funcionar es que el evento se escriba dentro de la transaccion del dato.

### Por que NO puede escribirlo el backend

Es la pregunta obvia, y la respuesta es la razon de ser del patron.

Si el backend guarda la resena y **despues** encola (en Redis, en una cola, donde
sea), hay un instante entre las dos cosas. Si el proceso se cae ahi, la resena
existe y el evento no. Nadie se entera nunca -- no hay error, no hay reintento,
simplemente esa resena no llega al grafo jamas.

Con un trigger ese instante no existe: PostgreSQL escribe las dos filas o
ninguna.

### Por que la cola va en PostgreSQL y no en Redis

Por lo mismo. Redis no participa de la transaccion de PostgreSQL, asi que
encolar ahi reintroduce exactamente el hueco de arriba.

Redis sirve para el carrito y la venta limitada, donde el dato ES transitorio.
Aqui el dato es un hecho que no se puede perder.

---

## Las piezas

### 1. La tabla

Nueva migracion, `013_outbox_grafo.sql`:

```sql
CREATE TABLE evento_grafo (
    id_evento    bigserial PRIMARY KEY,
    entidad      varchar(30) NOT NULL,   -- 'resena' por ahora
    id_entidad   bigint NOT NULL,
    operacion    varchar(10) NOT NULL,   -- 'alta' | 'baja'
    fecha        timestamptz NOT NULL DEFAULT now(),
    procesado_en timestamptz,            -- NULL = pendiente
    intentos     integer NOT NULL DEFAULT 0,
    ultimo_error text
);

-- La cola: lo pendiente, lo mas viejo primero. PARCIAL, porque lo procesado
-- se acumula para siempre y la cola no lo mira nunca.
CREATE INDEX idx_evento_grafo_cola
    ON evento_grafo(id_evento)
    WHERE procesado_en IS NULL;
```

**`id_evento` es un serial y ese orden ES el orden de aplicacion.** No usar
`fecha`: dos eventos en el mismo milisegundo quedarian sin desempate, y una baja
podria aplicarse antes que su alta.

**Solo el id, no una copia del dato.** El worker relee de PostgreSQL, asi que
siempre aplica el estado ACTUAL. Es menos eficiente y mucho mas simple, y para
una proyeccion es lo correcto: si una resena cambio tres veces antes de que el
worker llegara, se aplica la ultima version y las otras dos no hacen falta.

### 2. El trigger

```sql
CREATE OR REPLACE FUNCTION encolar_evento_grafo()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    INSERT INTO evento_grafo (entidad, id_entidad, operacion)
    VALUES ('resena',
            COALESCE(NEW.id_resena, OLD.id_resena),
            CASE WHEN TG_OP = 'DELETE' THEN 'baja' ELSE 'alta' END);
    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_resena_al_grafo
    AFTER INSERT OR UPDATE OR DELETE ON resena
    FOR EACH ROW EXECUTE FUNCTION encolar_evento_grafo();
```

Ojo: en un `DELETE` la fila `NEW` no existe. El `COALESCE` de arriba funciona
porque plpgsql deja `NEW` como NULL en ese caso, pero **si algun dia hace falta
leer otra columna, hay que ramificar por `TG_OP`** -- nombrar un campo de `NEW`
en un DELETE revienta en tiempo de ejecucion. Es la misma trampa que ya esta
documentada en el trigger de `likes` de la migracion 011.

Hace falta el mismo trigger sobre `comentario` (el texto y la fecha de la resena
viven ahi) encolando `('resena', <el id de su resena>, 'alta')`.

### 3. El consumidor

**Aqui esta la decision, y conviene partirla en dos etapas.**

#### Etapa A -- sin proceso nuevo (lo barato)

`cargar_grafo.sh` deja de releer todo: vacia la cola. Sigue corriendose a mano y
desde `arrancar.ps1`, exactamente como hoy.

Se gana el 80% del beneficio (el ETL deja de crecer con el catalogo) por el 20%
del trabajo, y **no agrega ni un proceso que tenga que estar vivo**.

#### Etapa B -- el worker (lo caro)

Un bucle que corre solo cada N segundos. Es lo que hace que una resena llegue al
grafo sin que nadie haga nada.

**El costo real no es el codigo: es que tiene que estar corriendo.** Un proceso
de fondo que no vuelve solo tras reiniciar la maquina es una fuente conocida de
problemas en este equipo. Y ademas: si vive dentro de Nest es de Jose David, que
ya tiene 8 rutas pendientes.

Sugerencia: que sea un script propio en `etl/`, arrancado por `arrancar.ps1`,
para que siga siendo territorio nuestro.

---

## Las cinco trampas

Estan aqui porque son las que hacen que un outbox mal hecho sea peor que no
tenerlo.

### 1. Es "al menos una vez", nunca "exactamente una vez"

El worker puede escribir en Neo4j y caerse **antes** de marcar el evento. Al
volver, lo aplica otra vez. **Eso no se puede evitar** -- Neo4j y PostgreSQL no
comparten transaccion.

Por eso **toda escritura al grafo tiene que ser idempotente**, y ya lo es: el ETL
usa `MERGE` en todos lados. Si algun dia alguien mete un `CREATE`, este patron se
rompe en silencio y aparecen nodos duplicados.

### 2. Dos workers a la vez se pisan

Si alguien corre el ETL mientras el worker esta despachando, los dos toman los
mismos eventos. Se resuelve con:

```sql
SELECT * FROM evento_grafo
WHERE procesado_en IS NULL
ORDER BY id_evento
LIMIT 100
FOR UPDATE SKIP LOCKED;
```

**Si, es `FOR UPDATE`, y no contradice la Entrega 2.** Lo que ahi se prohibe es
usar bloqueos para la venta de inventario limitado bajo peticiones concurrentes
de usuarios. Esto es otra cosa: un trabajo de fondo repartiendose una cola. Vale
la pena tener la distincion clara, porque en la presentacion la van a preguntar.

### 3. Un evento envenenado tapa la cola

Si un evento falla siempre (un dato torcido, un producto que no existe), y la
cola se procesa en orden, **bloquea todo lo que viene detras para siempre**.

Por eso la tabla lleva `intentos` y `ultimo_error`. Regla: a los 5 intentos se
aparta -- se marca procesado con el error escrito -- y se sigue. Y algo tiene que
mirar esos apartados, o se convierte en un silencio.

### 4. La tabla crece para siempre

Lo procesado se acumula. Hay que podarlo:

```sql
DELETE FROM evento_grafo
WHERE procesado_en IS NOT NULL AND procesado_en < now() - interval '7 dias';
```

**El `procesado_en IS NOT NULL` no es opcional.** Sin el, una poda por fecha
borra pendientes viejos -- justo los que mas falta hacen, porque un pendiente
viejo es uno que ya fallo varias veces.

### 5. El dia que se enciende, lo viejo no tiene eventos

Las 90 resenas que ya existen nunca dispararon el trigger. Hay dos salidas:

- `./etl/cargar_grafo.sh --limpiar` una vez, y de ahi en adelante la cola. Es lo
  mas simple y funciona porque el grafo es una proyeccion.
- O sembrar la cola: `INSERT INTO evento_grafo (entidad, id_entidad, operacion)
  SELECT 'resena', id_resena, 'alta' FROM resena;`

**Y hay que decidirlo antes de encender el trigger**, porque en cuanto este
puesto la semilla va a generar 86 eventos cada vez que se cargue.

---

## La conciliacion: la red debajo de todo

Un outbox reduce la deriva; no la elimina. Neo4j puede haberse borrado, alguien
pudo tocarlo a mano, un evento pudo apartarse.

**Hace falta algo que compare y avise.** No que arregle: que AVISE.

```
resenas en PostgreSQL   ==  nodos :Resena en Neo4j
usuarios con resena     ==  nodos :Usuario
                            relaciones ESCRIBIO == CALIFICA_A == SOBRE == resenas
```

Si no cuadra, lo dice y sugiere `--limpiar`. Es barato (cuatro `count`) y es lo
unico que convierte "creo que el grafo esta al dia" en un hecho comprobable.

Va en el mismo sitio donde ya viven los otros candados de este proyecto: como una
comprobacion que falla fuerte, no como un comentario que pide que alguien se
acuerde.

**Esto se puede hacer HOY, sin outbox, y ya seria util.** Es la pieza mas barata
de todo el documento.

---

## Por que vale la pena aunque tarde

Porque **paga dos veces**, y la segunda vale mas que la primera.

La Entrega 3 pide, textual:

> *"Documento de estrategia de consistencia para el flujo de checkout, que
> identifique cada componente involucrado, los puntos de falla posibles, y el
> mecanismo de mitigacion adoptado -- ya sea mediante reintentos idempotentes, un
> patron de compensacion, o la aceptacion documentada de una ventana de
> consistencia eventual."*

**Son 5 puntos de puro documento.** Y el outbox es exactamente eso:

| Lo que pide la Entrega 3 | Lo que es el outbox |
|---|---|
| componentes involucrados | PostgreSQL (verdad) y Neo4j (proyeccion) |
| puntos de falla | el worker se cae, Neo4j no responde, evento envenenado |
| reintentos idempotentes | `MERGE` + `intentos` |
| ventana de consistencia eventual | los N segundos entre la resena y su nodo |

O sea que no es trabajo extra: es el entregable de la 3, adelantado, y con codigo
corriendo detras en vez de un texto que describe algo que no existe.

---

## El orden

1. **La conciliacion.** Barata, util sola, y hace visible el problema que las
   otras dos resuelven.
2. **La tabla y el trigger** (`013_outbox_grafo.sql`). Sin worker todavia.
3. **Etapa A**: `cargar_grafo.sh` vacia la cola en vez de releer todo.
4. **Etapa B**: el worker que corre solo. Aqui, y no antes, aparece el costo de
   tener un proceso vivo.
5. ~~**El documento de la Entrega 3**, escrito sobre lo que ya funciona.~~
   **ESCRITO el 2026-09-04**: `docs/CONSISTENCIA-CHECKOUT.md`.

Los pasos 1 a 3 son `migrations/` y `etl/`: territorio nuestro, sin depender de
nadie. El 4 conviene hablarlo con Jose David aunque no toque `backend/`, porque
cambia como arranca el sistema.

---

Relacionado: `neo4j/README.md` (el modelo del grafo y por que es una proyeccion),
`etl/README.md` (como carga hoy), `docs/BACKEND-PENDIENTE.md` (las rutas que
faltan).
