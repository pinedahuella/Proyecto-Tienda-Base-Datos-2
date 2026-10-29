# Guía de estudio — Decisiones técnicas multi-base en Mesh

Este documento reconstruye, a partir del código real del backend (no de un resumen), las decisiones técnicas detrás de las piezas que cruzan más de una base de datos en el proyecto: el carrito y las ventas relámpago sobre Redis, qué vive exactamente en cada base para ese dominio, cómo se ponen de acuerdo los workers que sincronizan datos entre bases, el grafo de fraude en Neo4j (consultas Cypher y scripts `.sh`), el fraude de login repartido entre Redis y Elasticsearch, y los últimos cambios sobre ClickHouse (la base columnar). La idea es poder contestar "por qué se decidió así" hasta el nivel de la línea de código concreta, no solo el "qué hace".

## Índice

1. El carrito de compra sobre Redis
2. Ventas relámpago / inventario limitado en Redis
3. Qué vive en cada base, campo por campo
4. El mapa completo de workers de sincronización
5. Neo4j: el grafo de fraude en reseñas
6. Fraude de login: Redis + Elasticsearch
7. ClickHouse: la base columnar y los últimos cambios
8. El catálogo copiado a PostgreSQL y la cola de productos por recalcular (2026-10-01)

---

## Parte 1 — El carrito de compra sobre Redis

### Por qué se movió de PostgreSQL a Redis

El carrito viejo era literalmente una fila de `pedido` en estado `pendiente`: se creaba con `crear_pedido()`, se le agregaban líneas con `agregar_linea()` y el `id_pedido` viajaba en `localStorage` del navegador. Ese diseño tenía dos fallas frente al enunciado de la Entrega 2:

1. **No caducaba nunca por inactividad.** El JWT de sesión dura 2 horas, pero eso es un plazo *fijo* desde el login, no una expiración por *inactividad*. Alguien podía dejar un pedido `pendiente` abierto indefinidamente y nunca se limpiaba solo. Un TTL de Redis que se renueva en cada toque (`EXPIRE` tras cada operación) sí es exactamente "expira por inactividad".
2. **Exigía tener cuenta.** Sin usuario no había fila de `pedido` que abrir.

La decisión fue: el carrito deja de ser una entidad de negocio persistente y pasa a ser pura *intención de compra* en memoria, que se resuelve contra las fuentes de verdad (PostgreSQL para precio/stock, MongoDB para nombre/imagen) recién cuando hace falta pintarlo o pagarlo.

### El diseño de claves

Una sola clave por cuenta, un HASH (`backend/src/services/carrito/carrito.service.ts:88`, documentado en el docstring de la clase):

```
mesh:carrito:<id_usuario>   HASH   { <id_oferta>: cantidad, ... }
```

```ts
private clave(idUsuario: string): string {
  return `mesh:carrito:${idUsuario}`;
}
```

El carrito es literalmente un `Map<id_oferta, cantidad>` — la intención, nada más. Nombre, precio, stock e imagen **no se guardan en Redis**: viven en `oferta` (PostgreSQL) y en `productos` (MongoDB), cambian todo el tiempo, y una copia en Redis se desactualizaría en segundos. Se resuelven al vuelo en `GET /carrito` (`verCarrito()`) con exactamente **dos consultas en lote**, sin importar cuántas líneas tenga el carrito: una a `oferta` (`consultarOfertas`) y una a `productos` de Mongo (`consultarProductos`), ambas con `$in`/`ANY($1::bigint[])`.

No hay ruta para "crear" un carrito. El primer `HSET` sobre una clave que no existe la crea sola; el carrito muere solo por TTL de 24h de inactividad, por `DEL` tras el checkout, o por `DELETE /carrito` manual. Un HASH sin campos deja de existir por sí mismo en Redis, así que "vaciar la última línea" y "borrar el carrito" son la misma operación físicamente.

```ts
static readonly TTL_SEGUNDOS = 60 * 60 * 24; // carrito.service.ts:133
```

El TTL se renueva (`redis.expire(clave, TTL_SEGUNDOS)`) en **cada** mutación: `definirCantidad`, `quitarLinea`, y en la propia lectura `verCarrito` (mirar el carrito cuenta como actividad, vía `renovarTtl()`).

El `id_usuario` sale del token de sesión, nunca de un id de carrito guardado aparte — dos dispositivos de la misma cuenta comparten carrito automáticamente sin ningún mecanismo adicional.

### Los archivos reales

- **Modelo/tipos**: `backend/src/models/carrito.ts` — define `CarritoLinea`, `MotivoNoDisponible` (`oferta_no_disponible`, `variante_no_disponible`, `agotado`, `stock_insuficiente`, `oferta_no_existe`, `reserva_vencida`), `Carrito`, `ResumenCarrito`.
- **Controller**: `backend/src/controllers/carrito/carrito.controller.ts` — `@Controller('carrito')` con `@UseGuards(SesionGuard, PermisoGuard)` y `@Permiso('carrito.usar')` a nivel de clase (los tres roles tienen ese permiso en `rol_permiso`: cualquiera con sesión tiene carrito). Cinco rutas:

```
GET    /carrito                    -> ver()          -> verCarrito()
PUT    /carrito/lineas/:idOferta   -> definirCantidad() (cantidad ABSOLUTA, no +1/-1)
DELETE /carrito/lineas/:idOferta   -> quitarLinea()
DELETE /carrito                    -> vaciar(idUsuario, true)
POST   /carrito/comprar            -> comprarCarrito()
```

- **Service**: `backend/src/services/carrito/carrito.service.ts` (1081 líneas) — toda la lógica.

### Qué toca cada operación

`PUT`/`DELETE /carrito/lineas/:idOferta` son Redis puro (`HSET`/`HDEL` + `EXPIRE`), **sin una sola consulta a PostgreSQL** — devuelven un `ResumenCarrito` calculado solo con el hash. `GET /carrito` sí toca las otras dos bases, pero en lote, no por línea.

### La trampa del precio congelado — y cómo se resolvió

La función `agregar_linea()` de `migrations/007_flujo_pedido.sql` congela el precio: guarda el `id_precio_historial` vigente en el momento en que se ejecuta, para que si el vendedor sube el precio después, el pedido conserve el que se le mostró a la persona. Esto describe el diseño de 007, de cuando "el carrito" literalmente era una fila de `pedido` — en ese modelo, llamar a `agregar_linea()` SÍ coincidía con el momento de agregar algo al carrito.

**Ojo con leer esto como el comportamiento actual del carrito en Redis: no lo es.** `agregar_linea()` nunca se llama cuando alguien agrega algo al carrito hoy — `PUT /carrito/lineas/:idOferta` es Redis puro (`HSET`/`EXPIRE`, cero consultas a Postgres, ver `carrito.service.ts:283-364`). La función solo se ejecuta **dentro de `comprar_carrito()`** (`migrations/012_comprar_carrito.sql`), es decir, recién al pagar — que puede ser hasta 24h después de que la oferta entró al carrito. Esa brecha entre "cuándo se llama a la función" y "cuándo la persona vio el precio" es exactamente la trampa que el resto de esta sección explica.

Ese diseño asumía que entre "agregar al carrito" y "pagar" podían pasar días (el carrito viejo era una fila de `pedido`). Con el carrito en Redis, `POST /carrito/comprar` llama a `comprar_carrito()` (`migrations/012_comprar_carrito.sql`), que **crea el pedido, agrega todas las líneas y paga en la misma llamada** — agregar y comprar pasan casi en el mismo instante. Si no se hacía nada, el precio que se "congelaría" sería el vigente al pagar, no el que la persona vio en el catálogo mientras el carrito esperaba hasta 24h en Redis. Sería un cobro incorrecto silencioso.

La solución quedó repartida en dos migraciones y el backend:

**`migrations/013_precio_del_carrito.sql`** reescribe `agregar_linea()` (misma firma `(bigint, jsonb)`, `CREATE OR REPLACE`) para que acepte un `id_precio_historial` **dentro** de `p_linea`:

```sql
v_id_precio_pedido := (p_linea->>'id_precio_historial')::bigint;

IF v_id_precio_pedido IS NULL THEN
    -- Sin el campo: el vigente, igual que la 007 (retrocompatible).
    v_id_precio  := v_id_precio_hoy;
    v_precio_usado := v_precio_actual;
ELSE
    -- Con el campo: tiene que ser una fila de ESTA oferta.
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
```

El filtro `AND ph.id_oferta = v_id_oferta` es la comprobación de seguridad: sin él, cualquiera podría mandar el `id_precio_historial` de **otra** oferta (más barata) y pagar lo que quisiera. Si el precio congelado que trae el cliente ya no es el vigente, la función **no bloquea la compra**: cobra el congelado y lo informa devolviendo `precio_cambio`, `precio_congelado`, `precio_actual` en el jsonb de retorno — la decisión de si eso es aceptable la toma quien llama, no la base de datos.

Del lado del backend, `CarritoService.comprarCarrito()` implementa esa mitad: cada línea del carrito lleva su `precio` "visto" en el último `GET /carrito`, y el cliente lo reenvía en `lineas_precio_visto` al pagar. `detectarAvisosPrecio()` (`carrito.service.ts:894`) compara texto contra texto (los dos `numeric(12,2)` formateados igual por PostgreSQL, evitando el redondeo binario de comparar como `number` de JS):

```ts
private detectarAvisosPrecio(
  lineas: CarritoLinea[],
  lineasVisto: ComprarCarritoPeticion['lineas_precio_visto'],
): AvisoPrecioCarrito[] {
  ...
  for (const linea of lineas) {
    const precioVisto = precioVistoPorOferta.get(linea.id_oferta);
    if (precioVisto != null && precioVisto !== linea.precio) {
      avisos.push({ id_oferta: linea.id_oferta, ..., precio_visto: precioVisto, precio_actual: linea.precio });
    }
  }
  return avisos;
}
```

Si hay avisos y el cliente no mandó `confirmar_cambios: true`, `ejecutarCompraCarrito()` devuelve `{ comprado: false, avisos }` sin tocar nada — el mismo contrato que ya usa `POST /comprador/pedidos/:id/comprar`. Reenviando con `confirmar_cambios: true` deja pasar la compra al precio de hoy.

### El candado de doble-submit del checkout

Clave `mesh:checkout:<id_usuario>`, `SET EX 30 NX` (`carrito.service.ts:642-673`, método `conCandadoCheckout`):

```ts
private async conCandadoCheckout<T>(idUsuario: string, fn: () => Promise<T>): Promise<T> {
  const clave = `mesh:checkout:${idUsuario}`;
  let obtenido: string | null = null;
  try {
    obtenido = await redis.set(clave, '1', 'EX', 30, 'NX');
  } catch (error) { manejarErrorRedis(this.logger, error); }

  if (obtenido == null) {
    throw new ErrorConflicto('Ya tienes una compra en curso, espera un momento antes de reintentar');
  }

  try {
    return await fn();
  } finally {
    try { await redis.del(clave); }
    catch (error) { this.logger.warn(...); }
  }
}
```

`comprarCarrito()` es literalmente `return this.conCandadoCheckout(idUsuario, () => this.ejecutarCompraCarrito(idUsuario, datos, ip))`. El problema que resuelve: dos `POST /carrito/comprar` idénticos y concurrentes (doble clic, doble submit de red) leían **los dos** el carrito lleno antes de que ninguno lo vaciara, y cada uno creaba su propio pedido — cobrando dos veces. `SET ... NX` es atómico porque Redis atiende un comando a la vez, así que de dos peticiones simultáneas solo una obtiene el candado; la otra ni siquiera llega a leer el carrito. El `EX 30` es puramente defensivo (si el proceso muere a mitad del checkout, el candado igual expira solo); el camino normal lo libera el `finally` con `DEL`.

### Qué pasa cuando falla el pago a mitad de camino

`ejecutarCompraCarrito()` (`carrito.service.ts:487-619`) sigue este orden:

1. `verCarrito()` — carrito vacío → 409.
2. Si hay líneas no disponibles (oferta pausada, variante desactivada, sin stock, id inventado) → 409 con la lista, siempre. Según el flag `QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR` (`helpers/constantes.ts`), esas líneas además se quitan del carrito de Redis antes de responder.
3. Chequeo de `lineas_precio_visto` (arriba).
4. Resuelve `id_direccion_historial`, valida/cobra tarjeta (mock) si aplica.
5. `SELECT comprar_carrito($1,$2,$3::jsonb,$4)` — si esto lanza una excepción de negocio (código `23503`/`23504`, la oferta se pausó o agotó entre `verCarrito()` y este punto), se capturan las reservas de inventario limitado que se habían tomado y se **devuelven** vía `devolverReservas()` antes de relanzar el 409. El pago no se concretó, así que esas unidades no pueden quedar retenidas.
6. Si `comprar_carrito()` tuvo éxito: `confirmarReservas()` (best-effort, la venta ya cerró en PostgreSQL — un fallo de Redis aquí no deshace la compra), `vaciar(idUsuario)` (sin soltar reservas, porque ya se confirmaron), evento fire-and-forget a ClickHouse, y recálculo de campos calculados de Mongo.

### `comprar_carrito()` — por qué es atómica sin escribir un `BEGIN`

`migrations/012_comprar_carrito.sql` compone las tres funciones de la 007 (`crear_pedido`, `agregar_linea`, `comprar_pedido`) **sin copiarlas**:

```sql
CREATE OR REPLACE FUNCTION comprar_carrito(
    p_id_usuario bigint, p_id_direccion_historial bigint,
    p_lineas jsonb, p_metodo_pago varchar
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_id_pedido bigint; v_linea jsonb; v_resultado jsonb;
BEGIN
    IF p_lineas IS NULL OR jsonb_typeof(p_lineas) <> 'array' THEN
        RAISE EXCEPTION 'p_lineas tiene que ser un arreglo JSON de lineas' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'El carrito viene vacio: no hay nada que comprar' USING ERRCODE = 'check_violation';
    END IF;

    v_id_pedido := crear_pedido(p_id_usuario, p_id_direccion_historial);

    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_lineas)
    LOOP
        PERFORM agregar_linea(v_id_pedido, v_linea);
    END LOOP;

    v_resultado := comprar_pedido(v_id_pedido, p_metodo_pago);

    RETURN jsonb_set(COALESCE(v_resultado, '{}'::jsonb), '{id_pedido}', to_jsonb(v_id_pedido), true);
END; $fn$;
```

El cuerpo de una función `plpgsql` corre dentro de una sola transacción implícita — no hace falta un `BEGIN`/`COMMIT` explícito. Si `comprar_pedido` levanta una excepción en la última línea (por ejemplo, sin stock), se deshacen también el `INSERT` del pedido y **todas** sus líneas: no queda un pedido huérfano en `pendiente` para siempre, que era exactamente el riesgo del flujo viejo de tres viajes separados desde la aplicación. La migración lo verificó con conexiones separadas: 27 pedidos antes de una compra fallida por falta de stock, 27 después — cero rastro.

### Deliberadamente NO copiar las reglas de negocio

El comentario de cabecera de la 012 es explícito sobre esto: reescribir el contenido de `agregar_linea`/`comprar_pedido` dentro de `comprar_carrito` significaría que el día que alguien corrija un caso lo corrija en un solo lado y el otro se quede mintiendo — "es el mismo fallo que ya costó caro antes: un arreglo tiene gemelo en el otro camino." Por eso `comprar_carrito` solo **orquesta** llamadas a las tres funciones de la 007/013, nunca duplica su SQL.

---

## Parte 2 — Ventas relámpago / inventario limitado en Redis

### Por qué Lua y no `SELECT ... FOR UPDATE`

El flujo normal de compra (`comprar_pedido()`, `migrations/007_flujo_pedido.sql:469-474`) bloquea la fila de la oferta:

```sql
-- FOR UPDATE: bloquea la fila hasta que termine la transaccion, asi
-- que otra compra de la MISMA oferta espera y luego lee el saldo ya
-- descontado. Sin esto las dos leen "queda 1" y las dos venden.
SELECT * INTO v_oferta
FROM oferta WHERE id_oferta = v_linea.id_oferta
FOR UPDATE;
```

Esto es correcto para el flujo normal — es la razón por la que las ofertas se quedan en PostgreSQL en primer lugar: el descuento tiene que ser atómico, medido en Entrega 1 con cero sobreventas sobre 555 ofertas. Pero el enunciado del profesor para Entrega 2 pide explícitamente *"operaciones atómicas del almacén clave-valor, con evidencia de que el mecanismo se sostiene bajo solicitudes concurrentes simuladas y **sin recurrir a bloqueos a nivel de aplicación**"*. `FOR UPDATE` es exactamente ese bloqueo prohibido — funciona, pero bajo una venta relámpago (miles de personas peleando por cien unidades en el mismo segundo) la fila se vuelve el cuello de botella: cada solicitud espera a que la anterior confirme su transacción entera. No es que se venda de más, es que se atiende de a uno — el problema no es de corrección, es de que el enunciado prohíbe ese mecanismo por nombre.

`redis/inventario_limitado.lua:1-6` lo dice en su propia cabecera:

```
Este archivo es la respuesta al punto de la Entrega 2 que pide "operaciones
atomicas del almacen clave-valor, sin bloqueos a nivel de aplicacion". Todo lo
demas de esta carpeta se apoya en el.
```

### Por qué Redis-de-un-solo-hilo NO alcanza por sí solo

El archivo argumenta esto explícitamente porque es la confusión más común: Redis atiende un comando a la vez, lo que hace atómico cada comando *suelto*, pero **no hace atómica una decisión que necesita dos comandos**. La forma ingenua:

```
GET  oferta:12:stock      -> "1"     (el cliente ve que queda una)
DECRBY oferta:12:stock 1  -> 0       (y la toma)
```

Entre esas dos líneas caben otros cincuenta clientes leyendo el mismo "1". Los cincuenta descuentan y el contador termina en -49. La segunda forma ingenua ("descuento primero, compenso si quedó negativo") es peor porque el contador queda visiblemente negativo en el hueco intermedio, y si el proceso compensador muere, la unidad se pierde para siempre. La tercera — un candado (`SET NX PX` + operar + `DEL`) — funciona pero **está explícitamente prohibida** por el enunciado ("sin bloqueos a nivel de aplicación"), y además reimplementa mal un gestor de transacciones: quien toma el candado y muere deja a todos esperando el `PX`.

Un **script Lua** corre entero como si fuera un solo comando de Redis: nadie se mete en el medio entre "comprobar" y "descontar". Por eso todas las ramas de rechazo del script van **antes** de la primera escritura — Redis no deshace lo que un script ya escribió, así que un `return` después de tocar el stock dejaría unidades fantasma.

### La forma de los datos — dos claves, no cinco

```
KEYS[1]  mesh:oferta:<id_oferta>            HASH
             stock      unidades que todavia se pueden tomar
             reservado  unidades tomadas y sin confirmar
             vendidas   unidades confirmadas (el pago paso en PostgreSQL)
             rechazos   intentos que se fueron con las manos vacias
             ticket     ultimo numero de ticket entregado
             r:<ticket> cantidad de esa reserva
             u:<ticket> quien la tiene

KEYS[2]  mesh:oferta:<id_oferta>:reservas   ZSET
             miembro = ticket, puntaje = milisegundo en que vence
```

Solo dos claves y no una por reserva, porque un script Lua solo puede tocar claves declaradas en `KEYS` (necesario el día que esto corra en Redis Cluster), y no se pueden declarar N claves desconocidas de antemano. Meter cada reserva como campos `r:<ticket>`/`u:<ticket>` del mismo hash resuelve eso.

El ZSET existe (en vez de una clave por reserva con su propio `EXPIRE`) porque cuando una reserva vence hay que **devolver** la unidad al contador de `stock`, y el `EXPIRE` de Redis borra la clave sin avisar a nadie — se podría escuchar el evento de expiración, pero esos avisos se pierden si nadie está suscrito en ese momento. Con el ZSET, el vencimiento se "cosecha" dentro del mismo paso atómico de la reserva siguiente (función `cosechar()`, líneas 175-206), sin proceso de fondo ni suscripción a eventos.

### Las operaciones, una por una

**`sembrar`** (`op == 'sembrar'`, líneas 220-256) — el vendedor abre la venta. Es **destructivo a propósito**: `DEL CLAVE RESERVAS` antes de escribir el contador nuevo, para que un doble clic del vendedor no duplique el stock puesto a la venta. Un bug real documentado en el propio archivo (líneas 237-254): el `EXPIRE` del ZSET no se podía poner aquí porque el `DEL` de la línea anterior acababa de borrar la clave, y `EXPIRE` sobre una clave inexistente devuelve `0` sin efecto — el ZSET quedaba inmortal, y con `maxmemory-policy noeviction` (exigido por el README) esas claves nunca se desalojaban, arriesgando llenar la memoria y tumbar hasta el carrito. Se corrigió moviendo el `EXPIRE` del ZSET a `reservar`, que es donde la clave existe de verdad.

**`reservar`** (líneas 269-344) — el paso único, comprobar y descontar:

```lua
elseif op == 'reservar' then
    local id_usuario = ARGV[2]
    local cantidad   = tonumber(ARGV[3])
    local ttl_res    = tonumber(ARGV[4])

    local ahora = ahora_ms()
    cosechar(ahora)

    local stock = campo('stock')
    if not stock then
        return {'SIN_OFERTA', 0, 0}
    end

    if cantidad > stock then
        redis.call('HINCRBY', CLAVE, 'rechazos', 1)
        return {'AGOTADO', 0, stock}
    end

    local ticket   = redis.call('HINCRBY', CLAVE, 'ticket', 1)
    local restante = redis.call('HINCRBY', CLAVE, 'stock', -cantidad)
    redis.call('HINCRBY', CLAVE, 'reservado', cantidad)
    redis.call('HSET', CLAVE, 'r:' .. ticket, cantidad, 'u:' .. ticket, id_usuario)
    ...
    return {'VENDIDO', ticket, restante}
```

La comparación es `cantidad > stock`, no `stock > 0` — con 2 unidades y un pedido de 3, `stock > 0` pasaría la comprobación y dejaría el contador en -1; esa es la razón de que `prueba_concurrencia.sh` corra explícitamente una ronda con `cantidad=3` sobre 100 unidades (33 reservas y 1 sobra, un número que ese bug no puede producir). El reloj (`ahora_ms()`) sale de `redis.call('TIME')` y nunca de un `ARGV`: si el cliente pudiera mandar "ahora", una sola llamada maliciosa con un valor futuro enorme podría vencer las reservas de todos los demás y robarles las unidades.

**`confirmar`** (líneas 382-408) y **`devolver`** (líneas 423-442) — comparten la comprobación de dueño (`u:<ticket>`), que es el bloque de seguridad más importante del archivo. El comentario documenta un bug real reproducido: antes de esta comprobación, cualquiera podía llamar `devolver <ticket>` sin haber reservado nada y soltar la reserva de otra persona, porque los tickets son enteros consecutivos (`HINCRBY`) y por tanto adivinables por conteo — no son secretos. Con tres compradores y tres tickets, un cuarto llamador podía devolver los tres seguidos y vaciar la venta entera. Peor: si a la víctima le liberaban la reserva y su `comprar_carrito()` igual salía bien después, su `confirmar` fallaba con `SIN_TICKET` — pagó y se quedó sin unidad, sin que nadie lo notara automáticamente. La comprobación:

```lua
local dueno = redis.call('HGET', CLAVE, 'u:' .. ticket)
if dueno ~= id_usuario then
    return {'TICKET_AJENO', 0}
end
```

`confirmar` **no toca `stock`** — ya se descontó al reservar; solo mueve unidades de `reservado` a `vendidas`. `devolver` mueve de `reservado` de vuelta a `stock`.

**`redimensionar`** (líneas 486-569) — la operación que usa `PUT /carrito/lineas/:idOferta` cuando la persona cambia la cantidad de una línea que ya tenía ticket. Existe porque ese endpoint fija la cantidad **absoluta** ("quiero 5"), no un +1/-1, y para una oferta de inventario limitado eso significa cambiar cuántas unidades están apartadas. El comentario del archivo explica por qué **dos llamadas separadas no sirven**, con las dos formas rotas documentadas:

- `devolver` y luego `reservar`: entre las dos llamadas, cualquier otro comprador puede llevarse las unidades que se acababan de soltar. Quien solo quería bajar de 3 a 2 puede terminar con 0.
- `reservar` y luego `devolver`: exige que existan tantas unidades libres **ajenas** como la cantidad nueva completa, cuando en realidad solo hace falta la diferencia.

`redimensionar` calcula el **stock efectivo** = `stock + cantidad_vieja` (lo que hay libre más lo que esta misma reserva va a soltar), compara la cantidad nueva contra eso, y solo si alcanza libera la reserva vieja y crea una nueva — todo en un solo paso atómico. El ticket **siempre** es nuevo, incluso si la cantidad no cambió (más barato que decidir cuándo reusarlo).

**`estado`** (líneas 582-592) — de solo lectura, no cosecha ni renueva nada a propósito: una pantalla que se refresca sola no debería mover reservas de nadie. Devuelve además `pendientes` (el `ZCARD` del ZSET) como comprobación *independiente* del contador `reservado`, porque los dos se escriben en lugares distintos del script — si alguna vez no coinciden, hay un bug real.

### El archivo `redimensionar-reserva.lua` — nota sobre su ubicación real

A diferencia de lo que sugiere el nombre, en el estado actual del código la operación `redimensionar` **ya vive dentro de `redis/inventario_limitado.lua`** (líneas 486-569, arriba). El archivo standalone `backend/elementos Generales/plan pendiente/redimensionar-reserva.lua` sigue existiendo como versión **provisional**, y `InventarioLimitadoService` (`inventario-limitado.service.ts:56-64`) todavía carga los dos por separado con dos `redis.defineCommand()`:

```ts
const RUTA_SCRIPT_REDIMENSIONAR = join(
  __dirname,
  '../../../elementos Generales/plan pendiente/redimensionar-reserva.lua',
);
redis.defineCommand('redimensionarReserva', {
  numberOfKeys: 2,
  lua: readFileSync(RUTA_SCRIPT_REDIMENSIONAR, 'utf8'),
});
```

El propio comentario del servicio deja anotado que ese archivo provisional (escrito para desarrollar en paralelo mientras el compañero dueño del `.lua` real lo integraba) se borra el día que el compañero sume esa operación a `inventario_limitado.lua` oficialmente.

### La evidencia — `redis/prueba_concurrencia.sh`

La rúbrica paga la **evidencia**, no el código: "el código puede estar bien escrito y sobrevender igual: lo único que lo demuestra es lanzarle más gente de la que cabe y contar" (cabecera del script).

**Cómo se simula concurrencia real**: `redis-benchmark` (viene con el contenedor `mesh-redis`, nada que instalar) abre `-c 50` conexiones de verdad y sostiene una petición en vuelo en cada una — no un `for` de bash, que jamás tendría dos peticiones en el aire a la vez. Config por defecto: `SOLICITUDES=1000`, `CLIENTES=50`, `UNIDADES=100` (diez veces más gente que unidades), `RONDAS=2`.

**Cómo verifica que la carga fue concurrente de verdad** (no solo asumida): mide `total_connections_received` de `INFO stats` antes y después de la carga — la resta son los sockets reales que abrió esa carga. El script documenta que esta comprobación se agregó **después** de descubrir que la anterior (afirmar por escrito "hubo concurrencia" sin medirla) daba 20 OK, 0 FALLA incluso corriendo con `CLIENTES=1` — cero concurrencia real por construcción, y el resultado se veía idéntico.

**El conteo se hace DENTRO del script Lua, no contando respuestas HTTP desde afuera** — `redis-benchmark` solo informa velocidad, no qué contestó cada solicitud. Los contadores `ticket`/`rechazos` se escriben en el mismo paso atómico que decide, y se verifican contra tres fuentes independientes: `ZCARD` del ZSET (lo llena `ZADD`), el campo `reservado` (lo llena `HINCRBY`), y el descenso exacto de `stock`.

**La ronda de control**: la misma carga corre contra un contador ingenuo (`DECRBY` pelado sobre una clave sin ninguna comprobación), y termina en -900. El punto no es "esto demuestra que hubo concurrencia" (el script corrige explícitamente una afirmación anterior incorrecta en ese sentido: `DECRBY` sobrevende igual aunque corra en fila india, medido con `-c 1`) sino que un comando atómico de Redis **sin la comprobación dentro del mismo paso no alcanza** — que es justamente el argumento de por qué hace falta Lua.

**Otras rondas del arnés**: vencimiento de reservas abandonadas (se cosechan solas al llegar la siguiente reserva, sin proceso de fondo); confirmar/devolver como puente con PostgreSQL; el ticket es de su dueño (reproduce el bug de robo de reservas y confirma que ya no existe); las dos claves (hash y ZSET) vencen juntas.

Resultado esperado: **cero sobreventa** — el stock nunca queda negativo, con 1000 solicitudes y 50 clientes simultáneos sobre 100 unidades, sin candados, sin reintentos, sin compensar.

### El flujo completo: reservar → confirmar/devolver

1. **Agregar al carrito** (`CarritoService.definirCantidad()`, `carrito.service.ts:283-364`): primero comprueba con `existeVentaLimitada()` (un `EXISTS` en Redis, sin tocar Postgres) si la oferta está en modo relámpago. Si lo está, llama a `redimensionar()` — esta es la **única excepción** a "agregar al carrito nunca reserva nada": para una oferta normal, `PUT /carrito/lineas/:idOferta` es Redis puro sin reservar; para una de inventario limitado, si no alcanza el stock, el 409 llega **de inmediato**, antes de tocar el carrito (a diferencia de una oferta normal, que se deja agregar siempre y avisa recién en `GET /carrito`). El ticket devuelto se guarda como campo compañero del mismo hash del carrito: `t:<id_oferta>`.
2. **Al pagar** (`ejecutarCompraCarrito`): `leerLineasConReserva()` lee los tickets vivos **antes** de llamar a `comprar_carrito()`, porque el `vaciar()` final borra el hash del carrito y con él los tickets.
3. Si `comprar_carrito()` falla (la oferta se pausó/agotó entre `verCarrito` y la llamada): `devolverReservas()` — las unidades vuelven al contador de Redis en el acto, en vez de esperar el TTL completo de cada reserva.
4. Si tiene éxito: `confirmarReservas()` — cada ticket pasa de "reservado" a "vendido" en Redis. Es **best-effort**: si esto falla (Redis caído, ticket ya vencido), la compra **no se deshace** — ya cerró en PostgreSQL, que es el libro contable real con su `FOR UPDATE`. Queda un desajuste chico y acotado entre los dos contadores, no una sobreventa.

### Las rutas del vendedor

`POST`/`DELETE /vendedor/ofertas/:id/venta-limitada` — `backend/src/controllers/vendedores/ventas-limitadas.controller.ts` + `backend/src/services/vendedores/ventas-limitadas.service.ts`, deliberadamente **separados** de `OfertasVendedorController`/`Service`: comparten prefijo y guards pero el mecanismo (Redis) no tiene nada que ver con el CRUD de ofertas (PostgreSQL puro).

`abrir()` valida la duración (tope `MAX_DURACION_SEGUNDOS = 7 * 24 * 60 * 60`, 7 días — "más que eso ya no es relámpago"), comprueba que la oferta sea del vendedor (`exigirOfertaPropia`, con el mismo patrón que el resto del panel: un admin actúa como la cuenta de la tienda resuelta por `CORREO_TIENDA`, nunca por id fijo; ajena o inexistente da el mismo 404 genérico), y delega en `InventarioLimitadoService.activar()`, que:

```ts
async activar(idOferta: number, ttlSegundos = 0) {
  const fila = await this.obtenerFila(idOferta);
  if (fila.estado_oferta_nombre !== 'activa') { throw new ErrorConflicto(...); }
  if (fila.es_inventario_limitado) { throw new ErrorConflicto(...); } // sembrar es destructivo

  await pool.query('UPDATE oferta SET es_inventario_limitado = true WHERE id_oferta = $1', [idOferta]);
  try {
    const resultado = await redisExtendido.inventarioLimitado(clave, claveReservas, 'sembrar', fila.stock, ttlSegundos);
    return { stock_sembrado: Number(resultado[1]) };
  } catch (error) {
    // Compensación manual: si Redis falla tras el UPDATE, se revierte la columna
    await pool.query('UPDATE oferta SET es_inventario_limitado = false WHERE id_oferta = $1', [idOferta]);
    manejarErrorRedis(this.logger, error);
  }
}
```

Nótese la compensación manual entre las dos bases: como no hay una transacción distribuida entre PostgreSQL y Redis, si el `UPDATE` en Postgres ya se comprometió pero el `sembrar` en Redis falla, el código deshace el `UPDATE` a mano para no dejar la oferta marcada como "limitada" sin nada sembrado en Redis (lo que la dejaría incomprable por cualquier camino).

### El worker `revisarVencidas()`

`InventarioLimitadoService.revisarVencidas()` (`@Interval`, cada 60000ms, mismo patrón que `GrafoSyncService` del outbox del grafo):

```ts
@Interval('inventario-limitado-vencidas', InventarioLimitadoService.INTERVALO_REVISION_VENCIDAS_MS)
async revisarVencidas(): Promise<void> {
  if (this.revisandoVencidas) return; // no se solapan corridas
  this.revisandoVencidas = true;
  try {
    const { rows } = await pool.query(
      'SELECT id_oferta FROM oferta WHERE es_inventario_limitado = true');
    for (const idOferta of ids) {
      const sigueViva = await this.existeVentaLimitada(idOferta); // EXISTS puro
      if (sigueViva) continue;
      await pool.query(
        'UPDATE oferta SET es_inventario_limitado = false WHERE id_oferta = $1 AND es_inventario_limitado = true',
        [idOferta]);
    }
  } finally { this.revisandoVencidas = false; }
}
```

El problema que resuelve: cuando una venta relámpago tiene `duracion_segundos`, Redis le pone `EXPIRE` a `mesh:oferta:<id>` y el ZSET de reservas sincroniza su propio TTL — al vencer, las claves desaparecen **solas**, sin avisar a nadie. Pero `oferta.es_inventario_limitado` en PostgreSQL solo se apagaba antes mediante un `DELETE` manual (`revertir()`), así que una venta que vencía por su cuenta dejaba esa columna en `true` para siempre — el panel del vendedor seguía anunciando "en venta relámpago" de algo que ya volvió a ser normal. Al comprador no le afecta (Redis ya no tiene nada que reservar), solo miente el panel. El worker cierra ese hueco reusando `existeVentaLimitada()` (un `EXISTS`, sin gasto extra) por cada oferta marcada.

### La columna `oferta.es_inventario_limitado` y su índice parcial

`migrations/014_inventario_limitado.sql`:

```sql
ALTER TABLE oferta
    ADD COLUMN IF NOT EXISTS es_inventario_limitado boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_oferta_inventario_limitado
    ON oferta(id_oferta)
    WHERE es_inventario_limitado;
```

Es columna y no una tabla aparte porque es un atributo booleano de la oferta, no una entidad — una tabla `venta_limitada(id_oferta, ...)` sería una fila por oferta sin columnas propias, la misma columna con un `JOIN` de más. El índice es **parcial** (`WHERE es_inventario_limitado`) porque las únicas consultas que necesitan esta columna preguntan "cuáles son las ofertas relámpago" — nunca "cuáles no lo son", que sería casi el catálogo entero. Un índice normal sobre un booleano donde el ~99% de las filas vale `false` no sirve de nada (el planificador lo descarta); el parcial solo guarda las filas `true`, tan chico como ofertas relámpago haya.

Importante: esta columna **no garantiza** que haya una venta viva ahora mismo, solo que esa oferta *opera bajo* el mecanismo — la venta viva, con sus unidades y su plazo, existe solo en Redis. El backend consulta Redis para "¿hay stock ahora?" y nunca le pregunta eso a PostgreSQL.

### El 409 en `PATCH /vendedor/ofertas/:id`

`backend/src/services/vendedores/ofertas.service.ts` (método `editar()`), líneas 427-461:

```ts
const ajusteStock =
  datos.ajuste_stock != null ? validarAjusteStock(datos.ajuste_stock) : null;

const filaActual = await this.obtenerFilaPropia(idOferta, idUsuario);

// Con la venta relampago abierta, el stock real lo lleva Redis (las
// unidades reservadas se descuentan ahi, no en `oferta.stock`); dejar
// que `ajuste_stock` toque la columna de PostgreSQL mientras tanto
// desincroniza las dos y Redis puede terminar prometiendo unidades que
// PostgreSQL ya no tiene. precio y estado no se ven afectados.
if (ajusteStock != null && filaActual.es_inventario_limitado) {
  throw new ErrorConflicto(
    'La oferta esta en una venta relampago: cierra la venta relampago antes de ajustar su existencia',
  );
}
```

La condición corta **solo** cuando `ajuste_stock` viene junto con la oferta en modo relámpago — no importa si en el mismo `PATCH` vienen también `precio`/`estado`: el chequeo va antes de la transacción, así que si `ajuste_stock` está presente y la oferta está en venta relámpago, el 409 corta los tres campos juntos y no se aplica nada, para no dejar un precio nuevo escrito mientras el ajuste que vino en el mismo request falló. `precio` y `estado` **solos** (sin `ajuste_stock`) siguen editables sin ninguna restricción, porque esos dos no leen ni escriben `oferta.stock` — el motivo de fondo es que si Redis sigue prometiendo unidades que PostgreSQL ya rebajó por otra vía, el checkout terminaría con un error que no explica nada al comprador.

---

## Parte 3 — Qué vive en cada base, campo por campo

Este dominio (carrito, ofertas, ventas relámpago, catálogo, fraude) toca las seis bases del proyecto. Ninguna es un espejo de otra: cada una guarda exactamente lo que necesita para la pregunta que solo ella puede contestar rápido, y todo lo demás se resuelve por referencia (`id_producto_mongo`, `id_oferta`, etc.), nunca por copia completa.

| Base | Qué guarda de este dominio | Por qué ahí y no en otro lado |
|---|---|---|
| **PostgreSQL** | `oferta` (precio, stock, estado, `es_inventario_limitado`), `precio_historial` (snapshot de cada precio que tuvo una oferta), `stock_movimiento` (kardex aditivo de reposición/venta/devolución/ajuste), `pedido`/`pedido_producto`, `alerta_fraude`, `notificacion_fraude`, `anillo_fraude`/`anillo_fraude_resena`, `evento_grafo` (outbox hacia Neo4j), `usuarios`, `direcciones` | Es el libro contable: todo lo que exige atomicidad transaccional fuerte (`FOR UPDATE`, `ON DELETE RESTRICT` en la cadena de pedido→precio→oferta) y no puede perderse ni desincronizarse nunca. |
| **MongoDB** | `productos` (catálogo, con los campos calculados `precio_tienda`, `precio_desde`, `stock_tienda`, `stock_total`, `total_ofertas`, `resenas_promedio`, `resenas_total`, y la bandera `pendiente_busqueda`), `eventos_autenticacion` (con la bandera `pendiente_elastic`) | El catálogo es documental por naturaleza (variantes embebidas, sin JOIN); las banderas de sincronización viven en el mismo documento que ya se escribe, atómico gratis sin outbox. |
| **Redis** | `mesh:carrito:<id_usuario>` (HASH, intención de compra), `mesh:checkout:<id_usuario>` (candado de doble-submit), `mesh:oferta:<id_oferta>` + `mesh:oferta:<id_oferta>:reservas` (HASH+ZSET del inventario limitado), `mesh:productos:mas_vendidos` (ZSET), contadores `mesh:fraude:*` (fuerza bruta / multi-cuenta) | Todo lo que necesita expiración automática por TTL, atomicidad de un solo paso (Lua) o un ranking leído por rango — ninguna de las tres cosas es el punto fuerte de un relacional ni de un documental. |
| **Elasticsearch** | `mesh_productos` (índice de búsqueda difusa del catálogo), `mesh_eventos_autenticacion` (intentos de login, con `ip` tipo `ip` para rangos y `geo_punto`/`geo_pais`/`geo_ciudad` aplanados) | Búsqueda de texto libre con tolerancia a errores y agregaciones (`terms`, `cardinality`, `date_histogram`) sobre historial completo — lo que ni Postgres ni Mongo hacen bien a este volumen. |
| **Neo4j** | `:Usuario`, `:Resena`, `:Producto`, `:Direccion` y las relaciones `ESCRIBIO`/`CALIFICA_A`/`SOBRE`/`VIVE_EN` — proyección de solo lectura de `resena`/`usuarios`/`direcciones` de Postgres | Preguntas de "quién está conectado con quién, por qué camino, de qué largo" (anillos de fraude) son nativas de un grafo y artificiales en SQL (`WITH RECURSIVE` con guardas manuales contra ciclos infinitos y nodos repetidos). |
| **ClickHouse** | `vista_producto`, `carrito_producto`, `compra_producto`, `devolucion_producto`, `busqueda_realizada`, `busqueda_clic`, `evento_login`, `evento_registro`, `vistas_por_producto_dia` — todas con columna `lote` (`real` / `generado-<semilla>`) | Volumen alto de eventos de navegación con agregación por tiempo (tendencias, más vendidos) — el `ORDER BY` como orden físico en disco hace que ese tipo de consulta escanee un tramo contiguo en vez de saltar por toda la tabla. |

Ninguna oferta, precio ni stock vive duplicado en MongoDB — se eliminó a propósito la coleccion `ofertas` que existía en una versión anterior del modelo (ver la Parte 3 no repite eso: la ficha de un producto pide sus ofertas reales directo a PostgreSQL, `WHERE id_producto_mongo = ... ORDER BY precio`). Los cuatro campos calculados de Mongo (`precio_tienda`, `stock_tienda`, `stock_total`, `total_ofertas`, más `precio_desde`) son **copias** derivadas de `oferta`, y por eso cualquier escritura que toque una oferta (crear, editar precio/estado, reponer stock) tiene que terminar llamando a `recalcularCamposCalculados()` — si no, la tarjeta del catálogo dice un precio y la ficha del producto otro.

---

## Parte 4 — El mapa completo de workers de sincronización

Todo servicio con `@Interval(...)` en `backend/src` que mueve o deriva datos de una base a otra (confirmado con `grep -r "@Interval(" backend/src`, siete resultados, ninguno fuera de esta lista):

| Servicio | Base origen | Base destino | Campo/bandera que dispara | Intervalo | Patrón | Disparo inmediato |
|---|---|---|---|---|---|---|
| `BuscadorSyncService` | MongoDB (`productos`) | Elasticsearch (`mesh_productos`) | `pendiente_busqueda: true` en el propio documento | 10 s (`INTERVALO_MS = 10000`), hasta 200/corrida | Bandera en el mismo documento | No (siempre espera el reloj de 10s) |
| `EventosAutenticacionSyncService` | MongoDB (`eventos_autenticacion`) | Elasticsearch (`mesh_eventos_autenticacion`) | `pendiente_elastic` en el propio documento | 5 s (`INTERVALO_MS = 5000`), hasta 500/corrida | Bandera en el mismo documento | **Sí** — `sincronizarAhora()`, llamada por `UsuarioController` justo tras cada login |
| `GrafoSyncService` | PostgreSQL (`resena`) | Neo4j (`:Resena`, `:Usuario`, `:Producto`) | fila en tabla outbox `evento_grafo` (trigger `trg_resena_al_grafo`) | 10 s (`INTERVALO_MS = 10000`), tope 500/corrida, `FOR UPDATE SKIP LOCKED` | Outbox con tabla + trigger | **Sí** — `procesarAhora()`, llamada por `ResenasService.crear()` justo tras insertar |
| `EventoProductoSyncService` | PostgreSQL (`oferta`, `resena`) | MongoDB (campos calculados de `productos`: precio, stock, ofertas, descuento, nota) | fila en tabla outbox `evento_producto` (triggers `trg_oferta_al_producto` y `trg_resena_al_producto`), UNA fila pendiente por producto | 5 s (`INTERVALO_MS = 5000`), hasta 200/corrida | Outbox con tabla + trigger, deduplicado por producto | no |
| `AnillosDetectorService` | Neo4j (consultas Cypher A.1/A.2) | PostgreSQL (`anillo_fraude`, `anillo_fraude_resena`) | ninguna bandera — re-evalúa toda la ventana en cada corrida | 15 min (`INTERVALO_MS = 15 * 60 * 1000`), ventana de 60 días | Ninguno — recomputación completa por ventana temporal | **Sí** — `detectarInmediato(idResena)`, llamada por `ResenasService.crear()` encadenada tras `procesarAhora()` |
| `FraudeLoginRetrospectivoService` | Elasticsearch (`mesh_eventos_autenticacion`, agregaciones) | PostgreSQL (`alerta_fraude`) | ninguna bandera — re-evalúa últimas 24h completas en cada corrida | 15 min (`INTERVALO_MS = 15 * 60 * 1000`) | Ninguno — recomputación completa por ventana temporal | **Sí** — `evaluarInmediato()`, llamada por `UsuarioController` justo tras cada login |
| `MasVendidosSyncService` | ClickHouse (`compra_producto`) | Redis (ZSET `mesh:productos:mas_vendidos`) | ninguna bandera — recalcula agregando la ventana de 24h/7d en cada corrida | 10 min (`INTERVALO_MS = 10 * 60 * 1000`) | ZSET con reemplazo atómico vía `RENAME` | No |
| `InventarioLimitadoService.revisarVencidas` | Redis (existencia de `mesh:oferta:<id>`) | PostgreSQL (`oferta.es_inventario_limitado`) | ausencia de la clave en Redis (`EXISTS`) tras un `EXPIRE` vencido | 60 s (`INTERVALO_REVISION_VENCIDAS_MS = 60000`) | Ninguno — polling de `EXISTS` sobre todas las ofertas marcadas | No |

Todos comparten el mismo molde defensivo, verificado en cada archivo: un flag booleano de instancia (`procesando`/`revisandoVencidas`) que hace que la corrida se salte por completo si la anterior sigue en curso (nunca se encolan corridas), y ningún worker relanza una excepción hacia NestJS — un fallo de conexión se loguea con `logger.warn` y se reintenta solo en la próxima corrida, sin tumbar el proceso.

**El criterio de fondo que decide el patrón** (verificado contra el comentario explícito de cada servicio, no inferido):

**Bandera en el mismo documento** (Mongo → Elasticsearch, los dos casos `*SyncService` que parten de Mongo) es posible porque la marca de "pendiente de sincronizar" vive en el **mismo documento** que ya se está escribiendo por la operación de negocio (crear/editar un producto, registrar un login) — es atómico gratis, no hace falta ninguna infraestructura extra: el `UPDATE`/`INSERT` normal de Mongo ya deja la bandera puesta en la misma operación. Esto es posible en Mongo standalone porque no depende de ninguna capacidad transaccional entre documentos: la bandera y el dato que describe viven juntos.

**Outbox con tabla + trigger** (`GrafoSyncService`, origen PostgreSQL) es el patrón *necesario* — no elegido por preferencia — específicamente cuando el origen es PostgreSQL y el destino es otra base: Mongo standalone (sin replica set) no tiene Change Streams ni transacciones multi-documento, así que ese truco de "bandera en el mismo documento" no aplicaría igual del lado Postgres → algo. Pero además Postgres sí tiene lo que Mongo no tiene fácil: un **trigger de base de datos** que puede insertar una fila en una tabla aparte (`evento_grafo`) de forma atómica con el `INSERT`/`UPDATE` original, sin que la aplicación tenga que acordarse de hacerlo. El outbox es entonces la combinación de "el origen puede garantizar la escritura atómica de la cola vía trigger" — algo que Postgres ofrece y Mongo standalone no.

**ZSET con reemplazo por `RENAME`** (`MasVendidosSyncService`) se usa cuando el destino no es una bandera de "pendiente" sino directamente un **ranking ordenado que se lee por rango** (`ZREVRANGE`). Aquí no hay "documentos pendientes" que procesar uno por uno — cada corrida recomputa el ranking completo desde cero agregando ClickHouse, y la única garantía que hace falta es que el consumidor nunca vea un ranking a medio reconstruir, que es exactamente lo que da la atomicidad de `RENAME` sobre una clave temporal.

**Ninguno — solo `@Interval` sin bandera, recomputación completa de una ventana** (`AnillosDetectorService`, `FraudeLoginRetrospectivoService`, `InventarioLimitadoService.revisarVencidas`) aplica cuando la pregunta no es "qué cambió desde la última corrida" sino "qué patrón existe ahora mismo en una ventana de tiempo" — un patrón de fraude (ciclo de calificaciones, ataque lento) depende de la **acumulación** de eventos en una ventana, no de un evento aislado nuevo, así que no tiene sentido una bandera por evento: hay que volver a mirar toda la ventana en cada corrida. `revisarVencidas` es un caso distinto dentro del mismo grupo: no agrega nada, solo hace `EXISTS` puntual por cada oferta marcada — es mantenimiento cosmético de una bandera que puede quedar obsoleta cuando Redis expira una clave por su cuenta, sin que nadie avise.

---

## Parte 5 — Neo4j: el grafo de fraude en reseñas

### El modelo: tres nodos y por qué no hay `:Vendedor`

El esquema vive en `neo4j/001_esquema.cypher` (aplicado por `etl/cargar_grafo.sh` en cada corrida, con `CREATE CONSTRAINT ... IF NOT EXISTS`):

```
(:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(:Usuario)
                        (:Resena)-[:SOBRE]->(:Producto)
```

**No hay etiqueta `:Vendedor`.** En Mesh comprar no exige rol — un vendedor también compra — así que si el modelo partiera `:Usuario` en `:Usuario` y `:Vendedor`, la misma cuenta física quedaría representada por **dos nodos distintos** según actuara como comprador o como vendedor en cada arista. La consulta de anillo (`A.1`, más abajo) necesita que el camino cierre sobre el mismo nodo: `A-como-vendedor` tendría que ser idénticamente `A-como-comprador` para que `MATCH (inicio)-[...]->(inicio)` funcione. Con dos etiquetas, el ciclo `A→B→C→A` nunca cerraría porque el `A` de llegada (vendedor) y el `A` de partida (comprador) serían nodos distintos con relaciones distintas. Es el mismo argumento que decidió no partir productos por vendedor en Mongo (memoria `arquitectura-productos-mongo`): lo que tiene que ser el mismo nodo, tiene que ser el mismo nodo.

**La reseña es un nodo, no una relación.** Una relación de Neo4j conecta exactamente dos entidades; una reseña conecta tres (autor, vendedor, producto). Reificarla como nodo es lo que permite expresar "sobre el MISMO producto" (consulta A.2) — con una relación directa `(a)-[:CALIFICA]->(b)` esa condición no se podría escribir porque no hay tercer extremo donde anclar el producto.

Restricciones de unicidad (`CREATE CONSTRAINT usuario_id ... REQUIRE u.id IS UNIQUE`, y análogas para `:Resena`/`:Producto`) no son adorno: el ETL carga con `MERGE`, que hace `MATCH` y solo crea si no encuentra. Sin índice de unicidad ese `MATCH` es un barrido de etiqueta, y dos corridas simultáneas podrían no encontrarse mutuamente y crear dos nodos con el mismo id — la restricción resuelve la búsqueda y toma el candado de la carrera en una sola instrucción.

**`:Direccion` es el cuarto nodo que se apartó del modelo original de tres tipos**, y su identidad es el **texto normalizado** (`clave`), no `id_direccion` de Postgres — porque dos filas de `direcciones` (una por cuenta) que apuntan a la misma casa física tienen que colapsar en **un solo nodo** para que `(a)-[:VIVE_EN]->(d)<-[:VIVE_EN]-(b)` sea un camino de dos saltos y no una comparación de texto todo-contra-todo. La normalización (minúsculas, sin tildes vía `translate()`, espacios colapsados) vive en `etl/extraer_grafo.sql` y se **copia verbatim** en `SQL_DIRECCIONES` de `grafo-sync.service.ts` (líneas 763-789) para que el worker incremental produzca exactamente la misma clave que el ETL completo — si divergieran, la misma casa caería en dos nodos según quién la haya cargado.

### El campo `tiene_calle` — la trampa real que se detectó y corrigió

13 de las 16 filas de `direcciones` no tienen `direccion_exacta` (la calle). Sin distinguirlo, la clave de un domicilio sin calle queda `guatemala|sacatepequez|antigua guatemala|` — y **cualquier par de cuentas que solo declaró su ciudad** cae en ese mismo nodo `:Direccion`. Esto no fue teórico: el README documenta que, antes de la corrección, la consulta A.4 "encontraba" dos pares reales (`comprador.sur`+`compradora.norte` en Antigua, y `tienda@mesh.com`+un usuario cualquiera en San José Pinula) que solo compartían **ciudad**, no casa — y `A.5` les sumaba un punto de señal por eso. La corrección: cada nodo `:Direccion` lleva `tiene_calle: boolean`, y las consultas A.4/A.5 exigen `d.tiene_calle = true` para contar como señal. Los pares que solo comparten ciudad se siguen listando (en `A.4b`), pero **rotulados explícitamente como "NO ES SEÑAL"**.

### Las cinco consultas Cypher de `neo4j/consultas/`

**A.1 — el anillo (la consulta de varios saltos, vale los 3 puntos de la entrega):**

```cypher
MATCH anillo = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)
WITH nodes(anillo) AS paso
WITH [n IN paso WHERE n:Usuario] AS cuentas,
     [n IN paso WHERE n:Resena]  AS resenas
WITH cuentas[0..-1] AS ciclo, resenas
WHERE ALL (c IN ciclo WHERE ciclo[0].id <= c.id)
  AND size(ciclo) = size(reduce(vistas = [], c IN ciclo |
        CASE WHEN c.id IN vistas THEN vistas ELSE vistas + c.id END))
UNWIND resenas AS r
WITH [c IN ciclo | c.correo]  AS anillo_de_cuentas,
     count(DISTINCT r)        AS resenas_del_anillo,
     avg(r.calificacion)      AS nota_media,
     min(r.fecha).epochSeconds AS primera,
     max(r.fecha).epochSeconds AS ultima
RETURN anillo_de_cuentas, size(anillo_de_cuentas) AS cuantas_cuentas,
       resenas_del_anillo, round(nota_media, 2) AS nota_media,
       (ultima - primera) / 86400 AS dias_en_cerrarse
ORDER BY dias_en_cerrarse ASC, nota_media DESC;
```

`*4..8` son **saltos**, no cuentas: el camino alterna obligatoriamente `Usuario→Resena→Usuario`, así que 4 saltos = 2 cuentas (par mutuo), 6 = triángulo, 8 = cuadrado. Se corta en 8 porque más allá el número de caminos crece muy rápido y un "anillo" de 7+ cuentas ya describe gente que se conoce, no una máquina de estrellas.

Dos trampas reales que costaron reescrituras, documentadas en el propio archivo:

1. **Anillos duplicados por rotación**: el mismo triángulo se encuentra una vez por cada cuenta desde la que se arranca la caminata (3 rotaciones para un triángulo). El filtro `WHERE ALL (c IN ciclo WHERE ciclo[0].id <= c.id)` ancla cada anillo en su cuenta de id más chico, dejándolo aparecer una sola vez.
2. **Anillos inventados por nodo repetido**: un camino de largo variable en Cypher garantiza que no se repita una *relación*, pero no un *nodo*. Dos cuentas que se califican dos veces en cada sentido generan 4 relaciones distintas, de modo que además del camino correcto de 4 saltos (A→B→A) existe uno de 8 (A→B→A→B→A) con relaciones todas distintas pero solo dos cuentas reales. Medido: ese par salía dos veces — una vez como anillo de 2 cuentas (verdad) y otra como anillo de 4 cuentas con los dos correos repetidos (mentira). El `reduce()` que arma la lista de ids sin repetir, comparado con `size(ciclo)`, detecta y descarta el segundo caso. Se usa `reduce` y no `apoc.coll.toSet` **a propósito**: esta consulta vale los 3 puntos de la entrega y no puede depender de que APOC esté instalado.

**A.2 — par mutuo sobre el MISMO producto** (la frase literal del enunciado del profesor):

```cypher
MATCH (a:Usuario)-[:ESCRIBIO]->(ra:Resena)-[:CALIFICA_A]->(b:Usuario),
      (b)-[:ESCRIBIO]->(rb:Resena)-[:CALIFICA_A]->(a),
      (ra)-[:SOBRE]->(p:Producto)<-[:SOBRE]-(rb)
WHERE a.id < b.id
RETURN a.correo AS cuenta_a, b.correo AS cuenta_b, p.nombre AS producto_compartido,
       ra.calificacion AS nota_de_a_a_b, rb.calificacion AS nota_de_b_a_a,
       abs(ra.fecha.epochSeconds - rb.fecha.epochSeconds) / 3600 AS horas_entre_las_dos
ORDER BY horas_entre_las_dos ASC;
```

Esta consulta es la que justifica que la reseña sea un nodo: la condición "mismo producto" exige que `ra` y `rb` (las dos reseñas del par) se encuentren en el mismo `:Producto`, algo que una relación directa cuenta→cuenta no podría expresar.

**A.3 — ráfaga de notas en pocos días**, con una regresión real documentada en el propio archivo. La versión vieja comparaba el lapso entre la **primera y la última** reseña de todo el historial del par:

```cypher
-- VERSIÓN VIEJA, con el bug
WITH a, b, count(r) AS cuantas, min(r.fecha).epochSeconds AS primera, max(r.fecha).epochSeconds AS ultima
WHERE cuantas >= 3 AND (ultima - primera) <= 3 * 86400
```

Eso no es una ventana móvil, es un rango — y tiene la propiedad invertida de la que hace falta: **agregar más evidencia apaga la alerta**. Medido: una ráfaga real (tres notas de 5 en 20 minutos) más una cuarta reseña legítima cinco meses después daba **cero filas**; borrando solo esa cuarta reseña, la misma consulta sí la encontraba. Peor: en los datos reales, los pares establecidos tienen 8-11 reseñas repartidas en 70-140 días, así que la consulta vieja **nunca podía** devolver una fila para ningún par con historia — su "0 filas" no significaba "no hay ráfagas", significaba "ningún par tiene TODA su historia dentro de 72 horas".

La versión corregida usa una ventana deslizante real:

```cypher
MATCH (a:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(b:Usuario)
WITH a, b, r ORDER BY r.fecha
WITH a, b, collect(r) AS historial
WHERE size(historial) >= 3
UNWIND range(0, size(historial) - 3) AS i
WITH a, b, historial, i
WHERE historial[i + 2].fecha.epochSeconds - historial[i].fecha.epochSeconds <= 3 * 86400
WITH a, b,
     [x IN historial
      WHERE x.fecha.epochSeconds >= historial[i].fecha.epochSeconds
        AND x.fecha.epochSeconds - historial[i].fecha.epochSeconds <= 3 * 86400] AS rafaga
ORDER BY size(rafaga) DESC
WITH a, b, collect(rafaga)[0] AS rafaga
RETURN a.correo AS califica, b.correo AS al_vendedor, size(rafaga) AS cuantas, ...
```

`range(0, size(historial) - 3)` recorre cada posición que **podría** ser el arranque de una ráfaga de 3, comparando contra la posición dos lugares después (i, i+1, i+2 = tres reseñas). Si esa distancia cabe en 72h, hay ráfaga sin importar qué haya antes o después — la ventana es local, no global.

**A.4 — cuentas que comparten domicilio (con calle)**:

```cypher
MATCH (a:Usuario)-[:VIVE_EN]->(d:Direccion)<-[:VIVE_EN]-(b:Usuario)
WHERE a.id < b.id AND d.tiene_calle
RETURN d.ciudad, d.departamento, d.exacta AS direccion_exacta,
       collect(a.correo + ' + ' + b.correo) AS cuentas_que_la_comparten
ORDER BY ciudad;
```

**A.5 — el puntaje compuesto**, la que se lee primero porque convierte cuatro listas sueltas en un ranking por sospecha:

```cypher
MATCH (x:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(y:Usuario)
WITH DISTINCT CASE WHEN x.id < y.id THEN x ELSE y END AS a,
              CASE WHEN x.id < y.id THEN y ELSE x END AS b
OPTIONAL MATCH (a)-[:ESCRIBIO]->(ra:Resena)-[:CALIFICA_A]->(b)
WITH a, b, collect(ra) AS de_a_hacia_b
OPTIONAL MATCH (b)-[:ESCRIBIO]->(rb:Resena)-[:CALIFICA_A]->(a)
WITH a, b, de_a_hacia_b, collect(rb) AS de_b_hacia_a
OPTIONAL MATCH (ra2:Resena)-[:SOBRE]->(:Producto)<-[:SOBRE]-(rb2:Resena)
WHERE ra2 IN de_a_hacia_b AND rb2 IN de_b_hacia_a
WITH a, b, de_a_hacia_b, de_b_hacia_a, count(ra2) AS coincidencias_de_producto
OPTIONAL MATCH (a)-[:VIVE_EN]->(d:Direccion)<-[:VIVE_EN]-(b)
WHERE d.tiene_calle
WITH a, b, de_a_hacia_b, de_b_hacia_a, coincidencias_de_producto,
     count(d) AS direcciones_compartidas, de_a_hacia_b + de_b_hacia_a AS todas
WITH a, b, todas,
     size(de_a_hacia_b) > 0 AND size(de_b_hacia_a) > 0 AS se_califican_mutuamente,
     coincidencias_de_producto > 0     AS sobre_el_mismo_producto,
     ALL (r IN todas WHERE r.calificacion >= 4) AS solo_notas_altas,
     direcciones_compartidas > 0       AS comparten_direccion
RETURN a.correo AS cuenta_a, b.correo AS cuenta_b, size(todas) AS resenas_entre_los_dos,
       se_califican_mutuamente, sobre_el_mismo_producto, solo_notas_altas, comparten_direccion,
       (CASE WHEN se_califican_mutuamente THEN 1 ELSE 0 END) +
       (CASE WHEN sobre_el_mismo_producto THEN 1 ELSE 0 END) +
       (CASE WHEN solo_notas_altas        THEN 1 ELSE 0 END) +
       (CASE WHEN comparten_direccion     THEN 1 ELSE 0 END) AS senales
ORDER BY senales DESC, resenas_entre_los_dos DESC
LIMIT 20;
```

Trampa documentada en el propio archivo: el filtro `a.id < b.id` en A.2/A.4 es seguro porque el patrón ahí es **simétrico** (los dos sentidos tienen que existir para que el `MATCH` encuentre algo). En A.5 el patrón de entrada (`x`→`y`) es **dirigido** — solo uno de los dos escribió, todavía no se sabe si el otro también — así que aplicar el mismo `WHERE a.id < b.id` sobre `x`/`y` **no ordenaría, borraría**: todo par cuyo autor tuviera id mayor que el vendedor desaparecería del ranking en silencio. La primera versión de esta consulta tenía exactamente ese bug y listaba solo 4 de los 8 pares reales — se descubrió contando a mano en PostgreSQL, no leyendo el Cypher. La corrección normaliza el par **dentro** de la consulta con el `CASE WHEN x.id < y.id` antes de cualquier filtro, y usa `OPTIONAL MATCH` (nunca `MATCH` puro) en los dos sentidos porque, tras normalizar, ya no se sabe cuál de los dos escribió primero.

El puntaje es **una suma de banderas, no un modelo** — decisión deliberada: cualquiera que lea el resultado puede reconstruir de dónde salió el número, lo cual importa más que la precisión cuando lo que sigue es que una persona revise cuentas ajenas.

### El arnés `neo4j/correr_fraude.sh` — por qué es un `.sh` y no un `.cypher` con dos partes

Antes las dos mitades de la demostración (correr contra el grafo real, y correr contra un grafo con un anillo sembrado) vivían en un solo `.cypher`, con la "parte B" como una **copia pegada** de la parte A. Se midió el fallo real: cambiando `*4..8` por `*40..80` **únicamente en la copia de arriba** — rompiendo a propósito la consulta que vale los 3 puntos — la salida del archivo completo quedaba idéntica, porque la demostración corría la copia de abajo, intacta. Mientras existan dos textos, el de abajo no prueba nada sobre el de arriba. Cypher no tiene forma de incluir un archivo dentro de otro, así que el único lugar donde se puede correr el **mismo texto** dos veces contra dos estados del grafo es afuera, en shell:

```bash
ARCHIVOS="A1_anillo A2_par_mutuo A3_rafaga A4_misma_casa A5_puntaje"
correr_las_cinco() {
    local sufijo="$1" archivo salida
    for archivo in $ARCHIVOS; do
        salida=$(cypher < "$CONSULTAS/$archivo.cypher" 2>&1)
        ...
        printf '%s\n' "$salida" > "$TMP/$archivo.$sufijo"
    done
}
```

`correr_las_cinco real` corre contra el grafo tal cual está; luego se siembra `siembra.cypher` (seis cuentas y cuatro productos con **ids negativos** — `usuarios.id_usuario` es `bigserial` y nunca produce negativos, así que no chocan nunca, y como el ETL hace `MERGE` por id, la siguiente corrida no los toca) etiquetados `:Prueba`; y `correr_las_cinco sembrado` vuelve a correr **los mismos cinco archivos**, sin copiarlos. Las comprobaciones (`tiene_fila`/`no_tiene_fila`) hacen `grep` literal sobre la salida capturada — nunca vuelven a preguntarle al grafo con una consulta parecida, porque eso reintroduciría el mismo problema de "dos textos".

El script está probado contra 5 sabotajes distintos y cada uno lo detecta (tabla completa en `neo4j/README.md`): revertir A.3 a `max-min`, quitar el filtro de rotación de A.1, quitar `d.tiene_calle` de A.4, y sembrar sin la relación `ESCRIBIO` (que antes hacía que el script saliera con código 0 sin imprimir un solo mensaje, porque `cypher-shell` devuelve 1 solo si el Cypher **no compila**, nunca si simplemente no encuentra nada — de ahí que el arnés necesitara aserciones explícitas con `grep`, no confiar en el código de salida).

El anillo real (no sembrado) vive en **PostgreSQL** desde el 2026-08-30: tres cuentas `anillo.*@mesh.com` que se compran entre sí (obligatorio, porque el backend exige compra pagada para reseñar) y luego se califican 5 estrellas en círculo, desde la misma casa. El anillo de `siembra.cypher` es un **segundo** anillo, de mentira, que demuestra que las consultas no solo encuentran lo que ya hay sembrado en la fuente de verdad sino que de verdad detectan el patrón.

### El outbox: `GrafoSyncService` (`backend/src/services/grafo/grafo-sync.service.ts`)

El grafo es una proyección, no la fuente de verdad. `POST /resenas` no le habla a Neo4j directamente — inserta en Postgres, un trigger (`trg_resena_al_grafo`, en el `.sql` de referencia de `outbox-grafo.md`) encola una fila en `evento_grafo`, y este servicio la despacha, de forma asíncrona.

**El worker** (`@Interval('grafo-outbox', 10000)`, línea 85) llama `procesarPendientes(true)`, protegido por un flag booleano `procesando` para que dos corridas del `@Interval` no se solapen. `procesarUnEvento` toma **un evento a la vez**, en su propia transacción corta:

```sql
SELECT id_evento, id_resena
  FROM evento_grafo
 WHERE procesado_en IS NULL AND intentos < $1
 ORDER BY id_evento
 LIMIT 1
 FOR UPDATE SKIP LOCKED
```

`FOR UPDATE SKIP LOCKED` es lo que permite que el worker del `@Interval` y una llamada de `procesarAhora()` (ver abajo) corran **al mismo tiempo** sin pisarse: cada una toma la fila más vieja que la otra no tenga ya bloqueada, en vez de bloquearse esperando.

Distinción real entre dos clases de fallo (líneas 214-236): si `proyectarResena` falla por un problema de **dato** (Cypher inválido, valor torcido), se suma un intento a esa fila puntual y se sigue con el resto de la cola — a los 5 intentos (`MAX_INTENTOS`) el evento queda "apartado" y lo reporta la conciliación. Si falla por **conexión** (Neo4j o Postgres caídos, detectado por `esFalloDeConexionGrafo`, que reconoce prefijos `Neo.ClientError.Statement.*` como error de dato pero `Neo.TransientError.*`/`ServiceUnavailable`/códigos `08`/`53`/`57P0*` de Postgres como conexión), se corta la corrida entera **sin gastar un intento** — se reintenta completa en la siguiente.

**`procesarAhora()`** (línea 116) es el disparo inmediato: lo llama `ResenasService.crear()` justo después de insertar una reseña, para no esperar el tick de 10s. **Deliberadamente no comparte el flag `procesando`** del `@Interval` — el comentario del código documenta el bug real que esto evita: bajo varias reseñas casi simultáneas, compartir el mutex dejaría a la mayoría de las llamadas sin hacer nada. Es seguro sin mutex porque (a) `FOR UPDATE SKIP LOCKED` ya reparte la cola entre corridas superpuestas sin pisarse, y (b) la proyección es `MERGE` — idempotente — así que ni siquiera hace falta que el reparto sea perfecto. Este mismo patrón (evitar el mutex compartido en la versión "ahora") se repite textual en `EventosAutenticacionSyncService.sincronizarAhora()` y en `AnillosDetectorService.detectarInmediato()`, con la misma justificación citada explícitamente en los tres archivos.

**`proyectarResena`** relee el estado ACTUAL de la reseña desde Postgres (el evento solo trae el id) y aplica un único Cypher con `MERGE` en cascada:

```cypher
MERGE (a:Usuario {id: $autor_id})
  SET a.correo = $autor_correo, a.usuario = $autor_usuario, ...
MERGE (v:Usuario {id: $vendedor_id}) SET ...
MERGE (p:Producto {id: $producto_id}) SET p.nombre = $producto_nombre
MERGE (r:Resena {id: $id_resena}) SET r.calificacion = $calificacion, ...
MERGE (a)-[:ESCRIBIO]->(r)
MERGE (r)-[:CALIFICA_A]->(v)
MERGE (r)-[:SOBRE]->(p)
WITH r
UNWIND $direcciones AS d
  MERGE (dir:Direccion {clave: d.clave}) SET ...
  WITH dir, d
  MATCH (u:Usuario {id: d.id_usuario})
  MERGE (u)-[:VIVE_EN]->(dir)
```

Nodos antes que relaciones — no es estético, `MERGE (a)-[:ESCRIBIO]->(r)` necesita que `a` y `r` ya existan. Si la reseña ya no existe en Postgres (fue borrada), en vez del `MERGE` se ejecuta `MATCH (r:Resena {id: $id}) DETACH DELETE r`.

**`neo4j.int()` es obligatorio** para todo id que se pasa como parámetro (`neo4j.int(idResena)`, `neo4j.int(f.autor_id)`, etc. — `database/neo4j.ts` lo documenta explícitamente): un `number` crudo de JavaScript se guarda como `Float` en Neo4j, y `MERGE {id: 5}` (Float) **no encuentra** un nodo con `{id: 5}` (Integer) — crea un segundo nodo duplicado que ninguna consulta subsiguiente encuentra, porque todas comparan contra el tipo Integer.

**La conciliación** (`conciliar()`, para `GET /admin/grafo/conciliacion`) compara conteos de Postgres contra Neo4j y **avisa, no repara** — la reparación es `etl/cargar_grafo.sh --limpiar`. Corre las dos consultas con un límite de tiempo (`conLimiteDeTiempo`, 15s) para que una base caída no cuelgue la petición. `estadoCola()` consulta `evento_grafo` y devuelve `null` (no lanza) si la tabla todavía no existe (código de error `42P01` de Postgres) — la conciliación sigue siendo útil sin la cola.

### `AnillosDetectorService`: de A.1/A.2 puntuales a un worker con ventana de tiempo y persistencia

Este es el reemplazo del panel en vivo eliminado. Corre las **mismas** consultas A.1 (ciclos) y A.2 (mismo producto) que `neo4j/consultas/`, pero con dos diferencias: agrega una condición de ventana de 60 días (`AnillosDetectorService.VENTANA_DIAS`), y en vez de devolver el payload completo para un endpoint, solo devuelve ids — es de detección, no de presentación.

```cypher
-- CYPHER_CICLICOS_VENTANA
MATCH camino = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)
WITH nodes(camino) AS nodos
WITH [n IN nodos WHERE n:Usuario] AS usuariosCamino,
     [n IN nodos WHERE n:Resena]  AS resenasCamino
WITH usuariosCamino[0..-1] AS ciclo, resenasCamino
WHERE ALL (c IN ciclo WHERE ciclo[0].id <= c.id)
  AND size(ciclo) = size(reduce(vistas = [], c IN ciclo |
        CASE WHEN c.id IN vistas THEN vistas ELSE vistas + c.id END))
  AND ALL (r IN resenasCamino WHERE r.fecha >= datetime() - duration({days: $dias}))
RETURN [c IN ciclo | c.id] AS cuentas, [r IN resenasCamino | r.id] AS resenas
```

Un ciclo con una sola reseña vieja fuera de la ventana ya no cuenta como activo — la condición `ALL (r IN resenasCamino WHERE ...)` exige que **todas** las reseñas del camino sean recientes.

**Dos entradas**: `detectar()` (`@Interval` cada 15 min) recorre todo el grafo; `detectarInmediato(idResena)` (llamada por `ResenasService.crear()` justo después de que `GrafoSyncService.procesarAhora()` termina de proyectar la reseña nueva) usa una versión acotada de la misma consulta, con una condición extra `AND $idResena IN [r IN resenasCamino | r.id]` — exige que el camino incluya específicamente la reseña recién creada, porque es la única arista nueva del grafo; un ciclo viejo entre las mismas cuentas ya lo habría visto una corrida anterior.

**`agrupar()`** junta el resultado de las dos consultas por conjunto de cuentas (clave = ids ordenados y unidos con `-`): si un par sale tanto en A.1 (`ciclo`/`mutuo`, según tenga 2 o ≥3 cuentas) como en A.2 (`reiterado`), gana el tipo `reiterado` porque es la señal más fuerte — el código lo resuelve con un flag `ganaElTipo` en la función `registrar()` interna.

**La persistencia**, en `registrarAnilloFraude` (`helpers/registrar-anillo-fraude.ts`):

```sql
INSERT INTO anillo_fraude (id_tipo_anillo_fraude, clave, id_estado_alerta_fraude)
VALUES ($1, $2, $3)
ON CONFLICT (clave)
DO UPDATE SET
  id_tipo_anillo_fraude = $1,
  ultima_vez_confirmado_activo = now()
RETURNING id_anillo_fraude
```

`clave` es **solo los ids de cuenta ordenados**, sin el tipo — así, si un par sube de `mutuo` a `reiterado` entre corridas (aparecieron más reseñas que activan A.2), el `UPSERT` **actualiza la misma fila** en vez de crear una nueva, porque el conflicto se evalúa sobre `clave` únicamente y el `DO UPDATE` sobreescribe el tipo con el ganador de la corrida actual. Esto también resuelve la condición de carrera entre `detectar()` (worker de 15 min) y `detectarInmediato()` (disparo por reseña) corriendo casi simultáneamente sobre el mismo anillo: si los dos intentan insertar la misma `clave` a la vez, uno de los dos `INSERT` gana la fila y el otro cae en la rama `ON CONFLICT`, sin duplicar ni bloquear — la unicidad la garantiza la restricción `UNIQUE(clave)` de Postgres, no un lock de aplicación.

Los ids de reseña se insertan **siempre** (también cuando el anillo ya existía), porque la evidencia puede crecer entre corridas — `ON CONFLICT (id_anillo_fraude, id_resena) DO NOTHING` hace que reinsertar un id ya guardado no cueste nada.

**El `UPSERT` nunca pisa `id_estado_alerta_fraude`** en el `DO UPDATE` — si un admin ya marcó el anillo `revisada`/`descartada`, que el worker lo vuelva a encontrar activo no debe reabrirlo solo.

**Sin notificación a las cuentas del anillo**, a diferencia del fraude de login: el comentario del propio helper lo explica — "acá las cuentas del anillo son las SOSPECHOSAS, no víctimas". Notificarle a una cuenta que forma parte de un anillo detectado le daría la oportunidad de dejar de calificar en círculo y evadir la próxima corrida del detector, mientras que en fraude de login la cuenta notificada es la que sufrió el ataque (alguien probó su contraseña), no quien lo ejecutó.

### `GET`/`PATCH /admin/fraude/alertas-resenas` y `.../:id/detalle-grafo`

`AdminFraudeAnillosController` + `FraudeAnillosPersistidosService`. El listado paginado hace `JOIN` de `anillo_fraude` contra dos subconsultas correlacionadas: `SQL_CUENTAS_DE_ANILLO` (deriva las cuentas del anillo por `UNION` de `id_usuario`/`id_usuario_vendedor` de sus reseñas — **no existe tabla `anillo_fraude_cuenta`**, porque toda cuenta de un anillo mutuo/ciclo/reiterado es necesariamente autor o vendedor de alguna de sus reseñas) y `SQL_RESENAS_DE_ANILLO` (los ids de evidencia).

`marcarAnillo()` distingue 404 de 409 con dos consultas separadas (`explicarPorQueNoActualizo`): si el `UPDATE ... WHERE id_anillo_fraude = $1 AND id_estado_alerta_fraude = $3` (solo transiciona desde `pendiente`) afecta cero filas, primero se comprueba si el id existe en absoluto (404 si no) y si existe pero ya no está `pendiente` (409).

**`obtenerDetalleGrafo()` no vuelve a correr A.1/A.2.** Ya se sabe cuáles son las reseñas exactas de este anillo (`anillo_fraude_resena`), así que solo pide su detalle puntual:

```cypher
MATCH (r:Resena) WHERE r.id IN $ids
OPTIONAL MATCH (a:Usuario)-[:ESCRIBIO]->(r)
OPTIONAL MATCH (r)-[:CALIFICA_A]->(v:Usuario)
OPTIONAL MATCH (r)-[:SOBRE]->(p:Producto)
RETURN r.id AS id_resena, a.usuario AS autor, a.correo AS correo_autor,
       v.usuario AS vendedor, v.correo AS correo_vendedor,
       p.nombre AS producto, r.calificacion AS calificacion, toString(r.fecha) AS fecha
```

Esta es una consulta de **detalle puntual** (`MATCH (r:Resena) WHERE r.id IN $ids`), no de patrón — a diferencia de A.1/A.2, que recorren todo el grafo buscando una estructura, esta ya sabe exactamente qué nodos quiere y solo trae sus vecinos inmediatos con `OPTIONAL MATCH`.

---

## Parte 6 — Fraude de login: Redis + Elasticsearch

### Por qué dos capas y no una sola

Redis ve el instante pero olvida en minutos (TTL de la ventana); Elasticsearch ve todo el historial de una cuenta y su geolocalización, pero no es tan instantáneo como un `INCR`. Un atacante que reparte su ataque en horas para no cruzar un umbral de 60 segundos es invisible para Redis mientras haya sucedido; Elasticsearch sí lo ve porque re-agrega sobre 24h completas. Al revés: Elasticsearch tarda en sincronizarse (aunque el disparo inmediato lo acorta a segundos), así que Redis sigue siendo la primera línea para lo que hay que detectar en el propio milisegundo del intento.

### Capa Redis — `FraudeLoginService`, cuatro señales inmediatas

`registrarIntento()` la llama `UsuarioController` **sin `await`** (fire-and-forget, igual que `LogService`) en cada intento de login, éxito o fallo. Cuatro contadores, cada uno con el mismo patrón `INCR`/`SADD` + `EXPIRE ... NX`:

```
mesh:fraude:fallos_ip:<ip>         INCR, umbral 8 fallos en 60s     -> fuerza_bruta_ip
mesh:fraude:fallos_cuenta:<id>     INCR, umbral 5 fallos en 60s     -> fuerza_bruta_cuenta
mesh:fraude:cuentas_ip:<ip>        SADD identificador, SCARD >= 4 en 300s -> multi_cuenta_ip
mesh:fraude:ips_cuenta:<id>        SADD ip, SCARD >= 4 en 300s      -> ip_rotacion_cuenta
```

`EXPIRE clave segundos NX` (el flag `NX`, disponible desde Redis 7 — `redis:8-alpine` del compose ya lo trae) pone el TTL **una sola vez**, al crear la clave: si ya tenía TTL, no lo reinicia. Sin `NX`, cada intento nuevo alargaría la ventana indefinidamente y una ventana de 60s podría terminar acumulando fallos de horas.

`ip_rotacion_cuenta` es el espejo invertido de `multi_cuenta_ip`: en vez de agrupar por IP y contar cuentas distintas probadas, agrupa por cuenta y cuenta IPs distintas desde las que se probó — evade un bloqueo por IP.

**Decisión explícita del usuario (2026-09-10, documentada en el propio comentario de clase): esto solo alerta, nunca frena el login.** Cruzar un umbral deja una fila en `alerta_fraude`; ninguna cuenta ni IP se bloquea automáticamente. Este es el criterio con el que hay que contestarle al profesor si pregunta "¿por qué no bloquean directamente?": el sistema prioriza no bloquear a un usuario legítimo por un falso positivo (contraseña olvidada, varios miembros de una familia en la misma IP) — el humano revisa antes de actuar.

### Capa Elasticsearch — lo que Redis no puede ver

**`TomaCuentaService`** (`toma-cuenta.service.ts`): compara la IP del login exitoso actual contra **todo** el historial de logins exitosos de esa cuenta, vía una agregación `terms` sobre el índice `mesh_eventos_autenticacion`:

```ts
aggs: {
  ips_conocidas: { terms: { field: 'ip.keyword', size: 1000 } },
  huellas_conocidas: { terms: { field: 'huella_cliente.keyword', size: 1000 } },
}
```

Exige `logins_exitosos_previos >= 3` (`MINIMO_HISTORIAL`) antes de evaluar nada — sin ese piso, el primer login de una cuenta nueva siempre tendría "IP nueva" (nunca tuvo ninguna) y se marcaría sospechoso sin serlo. Corre solo en login **exitoso** — un fallo no revela nada sobre quién es el dueño real.

**`ViajeImposibleService`**: compara el login actual contra el login exitoso **inmediatamente anterior** de la misma cuenta (no todo el historial — solo el más reciente), con fórmula haversine real:

```ts
function distanciaHaversineKm(a: GeoUbicacion, b: GeoUbicacion): number {
  const toRad = (grados: number) => (grados * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const senoMitad = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  const angulo = 2 * Math.atan2(Math.sqrt(senoMitad), Math.sqrt(1 - senoMitad));
  return RADIO_TIERRA_KM * angulo;
}
```

Si `km / horas_transcurridas >= 800` km/h (más rápido que un vuelo comercial, con margen), se registra `viaje_imposible`. Limitación **aceptada, no bug**: un usuario con VPN da un falso positivo legítimo — documentado como la única forma práctica de demostrar este patrón en una demo sin depender de gente conectándose desde países distintos de verdad.

**`FraudeLoginRetrospectivoService`**: worker `@Interval` cada 15 minutos, re-evalúa las **últimas 24h completas** (no solo eventos nuevos — el patrón depende de acumulación, no de un evento aislado) con tres agregaciones. La de `multi_cuenta_ip_lenta` usa `cardinality` + `bucket_selector` para que Elasticsearch filtre del lado del servidor, sin traer buckets que no cruzan el umbral:

```ts
aggs: {
  por_ip: {
    terms: { field: 'ip.keyword', min_doc_count: 8, size: 1000 },
    aggs: {
      cardinalidad: { cardinality: { field: 'identificador_intentado.keyword' } },
      muestra: { terms: { field: 'identificador_intentado.keyword', size: 20 } },
      filtro_umbral: {
        bucket_selector: {
          buckets_path: { cuentas: 'cardinalidad' },
          script: `params.cuentas >= 8`,
        },
      },
    },
  },
}
```

`min_doc_count: 8` filtra por volumen de documentos en el `terms` (barato); `bucket_selector` filtra después por la `cardinality` real (cuántos identificadores *distintos*, no solo cuántos documentos) — necesario porque una IP con 8 documentos podría ser 8 intentos a la misma cuenta, no 8 cuentas distintas.

`ventana_inicio` se trunca a la **hora** (no al minuto, como Redis): con un intervalo de 15 min, truncar al minuto crearía una fila nueva casi en cada corrida mientras el patrón siga activo; truncar a la hora da una alerta persistente por hora sin perder la reaparición si el ataque sigue horas después.

**Disparo inmediato**: además del worker de 15 min, `evaluarInmediato()` corre versiones acotadas de las tres mismas señales, filtradas a la cuenta/IP de un solo login — la llama `UsuarioController` justo después de cada login, encadenada tras `sincronizarAhora()`:

```ts
private dispararSincronizacionPosLogin(logPromesa, identificador, ip, idUsuario) {
  void logPromesa
    .then(() => this.eventosAutenticacionSyncService.sincronizarAhora())
    .then(() => this.fraudeLoginRetrospectivoService.evaluarInmediato({ identificador, ip, idUsuario }))
    .catch(() => { /* best-effort */ });
}
```

Nota el orden encadenado: primero se sincroniza el evento a Elasticsearch (`sincronizarAhora`, con `refresh: 'wait_for'` para que sea inmediatamente buscable), y **solo después** corre `evaluarInmediato` — si se evaluara antes de sincronizar, Elasticsearch no vería todavía el evento recién ocurrido.

### `EventosAutenticacionSyncService` — el worker Mongo→Elasticsearch, y el bug real de mutex compartido

Copia eventos desde la colección `eventos_autenticacion` de MongoDB (donde `LogService` los escribe primero) hacia el índice de Elasticsearch, vía la bandera `pendiente_elastic`. `sincronizar()` (`@Interval` cada 5s) y `sincronizarAhora()` (llamada tras cada login) comparten la misma lógica (`procesarPendientes`) pero **deliberadamente no comparten el flag `procesando`**:

> "bajo una ráfaga de logins casi simultáneos (el caso que más importa acertar rápido), si esta llamada se bloqueara cada vez que otra ya está corriendo, la mayoría de los intentos quedarían sin sincronizar su propio evento [...] — se probó en vivo y era justo lo que pasaba."

Es decir: el bug real (documentado explícitamente en el comentario del código) era que la primera versión de `sincronizarAhora()` sí compartía el mutex del `@Interval`, y bajo ráfagas de logins casi simultáneos la mayoría de las llamadas se encontraban el mutex tomado y no hacían nada — sus eventos quedaban sin sincronizar hasta el próximo tick de 5s, y el chequeo de fraude inmediato corría contra datos incompletos. Se corrigió quitando el mutex de `sincronizarAhora()`: es seguro porque `procesarPendientes` reindexar dos veces el mismo documento (el `_id` de Mongo se reutiliza como `_id` en Elastic) no es un error, y un `$unset` sobre un campo que ya no está tampoco lo es — varias corridas superpuestas pueden reprocesar el mismo documento, nunca de forma incorrecta.

`sincronizarAhora()` indexa con `refresh: 'wait_for'` (Elasticsearch es "near real-time" — sin esto, el documento recién escrito podría no ser buscable todavía cuando `evaluarInmediato` lo consultara un instante después); el `@Interval` normal no lo necesita porque no hay nada esperando ese refresco en el acto.

**Por qué `geo` va aplanado en tres campos y no anidado** (`documento-elastic.ts`, bug real encontrado el 2026-09-11): un campo mapeado como `geo_point` en Elasticsearch **solo** acepta `lat`/`lon` (o el formato GeoJSON); si se le manda un objeto con `pais`/`ciudad` adentro, Elasticsearch rechaza el documento **entero** con `document_parsing_exception`. Por eso `geo_punto: {lat, lon}` va aparte, y `geo_pais`/`geo_ciudad` son campos de texto plano sueltos, sin mapping especial.

### Notificación al usuario afectado — `notificacion_fraude`

`registrarAlertaFraude` es el `UPSERT` compartido por los cuatro servicios que escriben alertas (`FraudeLoginService`, `TomaCuentaService`, `ViajeImposibleService`, `FraudeLoginRetrospectivoService`). La llave de conflicto de `alerta_fraude` es `(tipo, clave, ventana_inicio)`: varios cruces del umbral dentro de la misma ventana **suman** `contador` en una sola fila; si el patrón sigue en la ventana siguiente, nace una fila nueva a propósito.

Las notificaciones solo se crean cuando la alerta **nace** (no en cada suma del contador dentro de la misma ventana), distinguido con el truco `(xmax = 0) AS fue_insertada` de Postgres — `xmax` vale 0 en una fila recién insertada, y distinto de 0 en una fila tocada por el `DO UPDATE` del `ON CONFLICT`.

Por qué **tabla** `notificacion_fraude` y no una columna `fecha_lectura` en `alerta_fraude`: `multi_cuenta_ip` puede afectar a varias cuentas a la vez (todas las que esa IP probó), así que hace falta una fila por (alerta, cuenta afectada), cada una con su propio "ya la vi". La resolución de a quién notificar es genérica por la **forma** de los datos, no por el tipo de alerta:

```ts
async function resolverCuentasDestino(cliente, idUsuario, detalle) {
  if (idUsuario != null) return [idUsuario];
  const identificadores = detalle.identificadores;
  if (!Array.isArray(identificadores) || identificadores.length === 0) return [];
  const textos = identificadores.filter((v): v is string => typeof v === 'string');
  const { rows } = await cliente.query(
    `SELECT DISTINCT id_usuario FROM usuarios WHERE usuario = ANY($1) OR correo_electronico = ANY($1)`,
    [textos],
  );
  return rows.map((f) => f.id_usuario);
}
```

Si `idUsuario` viene resuelto (fuerza_bruta_cuenta, viaje_imposible, toma_cuenta, ip_rotacion_cuenta y sus `_lenta`), esa una cuenta. Si es `null` pero `detalle` trae un array `identificadores` (multi_cuenta_ip y su `_lenta`), se resuelve cada texto contra `usuarios` y notifica a todas las cuentas reales que aparezcan — los identificadores que correspondan a correos inventados simplemente no generan fila. Si ninguna de las dos formas aplica (`fuerza_bruta_ip`: fallos repetidos desde una IP sin lista de cuentas objetivo), nadie se notifica — la alerta queda solo para el panel de admin. Es deliberadamente genérico por forma y no por `switch` sobre el tipo de alerta, para que una señal futura con la misma forma quede cubierta sin tocar este archivo.

`GET`/`PATCH /perfil/alertas-fraude` (`PerfilController`, vive en `FraudeLoginService` del lado de lectura porque ya es dueño de `alerta_fraude`): el usuario ve sus propias alertas (`JOIN notificacion_fraude` filtrado por su `id_usuario`, nunca recibe un id de cuenta por parámetro) y las marca leídas con `SET fecha_lectura = COALESCE(fecha_lectura, now())` — idempotente, no pisa la fecha de la primera lectura. `detalleParaUsuario()` le oculta al usuario la lista completa de `identificadores` en `multi_cuenta_ip`/`multi_cuenta_ip_lenta` (quiénes más fueron blanco del mismo ataque) pero conserva el conteo `cuentas_distintas` — sabe que no fue el único blanco, sin enterarse de quiénes fueron los demás (decisión explícita del usuario, 2026-09-15).

---

## Parte 7 — ClickHouse: la base columnar y los últimos cambios

### Por qué columnar, y por qué NO es la respuesta al requisito "grafos O columnar" de la rúbrica

`docs/DECISION-GRAFOS-VS-COLUMNAR.md` (ADR-3, 2026-09-03) es el documento que hay que poder defender palabra por palabra si el profesor pregunta "por qué esta decisión". La Entrega 2 plantea **dos análisis distintos** que el propio enunciado advierte que "no necesariamente ameritan la misma solución técnica":

| | Análisis A | Análisis B |
|---|---|---|
| Qué pide | cuentas que se califican entre sí de forma reiterada (anillos de fraude) | actividad de ventas por intervalos, demanda en ascenso |
| Familia que sugiere el enunciado | grafos | columnar |
| La pregunta en una línea | quién está conectado con quién, por qué camino | cuánto se vendió de qué, entre qué fechas |

El equipo **midió antes de decidir**, no asumió. Escribió el análisis A entero en SQL puro (`WITH RECURSIVE` sobre `resena`, recorriendo aristas de calificación hasta cerrar un ciclo) y lo corrió contra la base viva junto a la versión en Cypher:

```sql
WITH RECURSIVE arista AS (
    SELECT DISTINCT id_usuario AS de, id_usuario_vendedor AS a
      FROM resena WHERE id_usuario <> id_usuario_vendedor),
camino AS (
    SELECT a.de AS inicio, a.a AS actual, 1 AS saltos,
           ARRAY[a.de, a.a] AS visitados
      FROM arista a
    UNION ALL
    SELECT c.inicio, a.a, c.saltos + 1, c.visitados || a.a
      FROM camino c JOIN arista a ON a.de = c.actual
     WHERE c.saltos < 4
       AND (a.a = c.inicio OR NOT (a.a = ANY (c.visitados))))
SELECT saltos AS cuentas_en_el_anillo, count(*) AS cuantos
  FROM camino
 WHERE actual = inicio AND saltos >= 2
   AND inicio = (SELECT min(v)
                   FROM unnest(visitados[1:array_length(visitados,1)-1]) AS v)
 GROUP BY saltos ORDER BY saltos;
```

Resultado medido: **28.7 ms**, mismos anillos exactos que Cypher. A este volumen (90 reseñas, 14 aristas), **ninguna de las dos familias hace falta por rendimiento** — decirlo así, de frente, es parte de lo que el ADR exige. La decisión se tomó por otro criterio: el análisis A es de **largo variable** (un anillo puede ser de 2, 3 o 4 cuentas, no se sabe de antemano), y en SQL eso exige un `WITH RECURSIVE` con dos obligaciones manuales — cortar la recursión (`saltos < 4`) e impedir que un camino repita una cuenta (el array `visitados` comparado con `= ANY` en cada paso). Se comprobó qué pasa si se quita esa segunda guardia: **2 anillos reales se convierten en 7** (el de 2 cuentas se cuenta 2 veces, el de 3 se cuenta 3 veces, y aparecen "anillos de 4" que no existen — son el mismo anillo recorrido dos vueltas). En Cypher esa garantía es una palabra del lenguaje (`*4..8` con nodos no repetidos), no cuatro sitios donde equivocarse.

**Para el análisis B (tendencias) se midió lo mismo y se llegó a la conclusión contraria**: la consulta agregada por mes/producto sobre `pedido_producto` corre en **16.379 ms** (`EXPLAIN ANALYZE`) usando los índices que ya existían, sin `Seq Scan`. Meter Cassandra para esto habría significado una tabla nueva por cada forma de pregunta (el modelo en Cassandra se diseña por consulta, no por entidad), un cuarto ETL, renunciar a los `JOIN` contra `precio_historial`/`estado_pedido`, y un octavo contenedor — todo para bajar de 16 ms a un número que nadie notaría sobre 32 pedidos.

**Decisión final del ADR: se implementa Neo4j para el análisis A (grafos), NO se incorpora Cassandra, y el análisis B se queda en PostgreSQL.** La rúbrica exige implementar solo UNA de las dos familias y documentar la comparativa con la alternativa descartada — eso es exactamente lo que es este documento, y cierra con una sección 6 explícita de "cuándo SÍ se justificaría columnar" (cuando la consulta de tendencias pase de 1000 ms, cuando el volumen de eventos crezca dos órdenes de magnitud — de ~16/mes a ~100 000 líneas de pedido —, cuando haya que retener series de años, cuando la escritura compita con las transacciones de compra, o cuando haya más de un nodo físico).

**Entonces, ¿por qué existe ClickHouse en el proyecto si el ADR decidió no usar columnar?** Porque este ADR resuelve un requisito de la *rúbrica* (Entrega 2, sección 5.2, "grafos o columnar" para dos análisis puntuales). ClickHouse entró después, el 2026-09-06, por una **directiva verbal separada del profesor**: quería tendencias de navegación (qué se está "calentando" antes de venderse) y fraude por IP a partir de eventos de *navegación*, no de compra — una fuente de datos que en el momento del ADR (32 pedidos, sin eventos de clic) ni siquiera existía. El propio ADR deja escrita la condición 6.2 (volumen de eventos de navegación) como el gatillo que cambiaría el análisis, y es exactamente lo que pasó: cambió la premisa, no la conclusión del ADR sobre el análisis A/B original.

### Conceptos de modelado obligatorios para defender ante el profesor

**`MergeTree` vs `AggregatingMergeTree`.** `MergeTree` es el motor base: guarda cada fila cruda, ordenada físicamente según `ORDER BY`, y permite cualquier consulta ad hoc sobre esos datos crudos (usado en `vista_producto`, `carrito_producto`, `busqueda_realizada`, `busqueda_clic`). `AggregatingMergeTree` guarda **estados parciales de una agregación** (`AggregateFunction(count, UInt64)`, `AggregateFunction(uniq, String)`) en vez de filas crudas, y esos estados se van *fusionando* solos en segundo plano a medida que ClickHouse compacta partes de la tabla — leer de ahí exige `countMerge()`/`uniqMerge()` para colapsar los estados en un número final. Se usa en `vistas_por_producto_dia`, alimentada por una `MATERIALIZED VIEW` que se dispara automáticamente en cada `INSERT` a `vista_producto`:

```sql
CREATE TABLE IF NOT EXISTS vistas_por_producto_dia
(
    dia          Date,
    id_producto  UInt64,
    lote         LowCardinality(String),
    vistas       AggregateFunction(count, UInt64),
    sesiones     AggregateFunction(uniq, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (dia, id_producto, lote);

CREATE MATERIALIZED VIEW IF NOT EXISTS vistas_por_producto_dia_mv
TO vistas_por_producto_dia
AS
SELECT toDate(fecha) AS dia, id_producto, lote,
       countState()      AS vistas,
       uniqState(sesion)  AS sesiones
FROM vista_producto
GROUP BY dia, id_producto, lote;
```

No hay ETL, no hay worker, no hay cola: la vista materializada mantiene el resumen sola en el mismo instante que entra cada fila cruda. Y la tabla cruda sigue existiendo aparte — la vista materializada no la reemplaza, solo abarata la pregunta que ya se sabe que se hace todos los días.

**`ORDER BY` como orden FÍSICO en disco, no un índice secundario.** Esto es lo que más se confunde viniendo de un motor relacional. En ClickHouse, `ORDER BY` decide en qué secuencia quedan escritos los bloques de datos en disco — no es una estructura aparte que se consulta, es el layout físico de la tabla. Por eso cada tabla del esquema (`clickhouse/001_esquema.sql`) elige su `ORDER BY` según la pregunta que más se le va a hacer: `vista_producto` y `carrito_producto` van por `(id_producto, fecha)` porque la pregunta dominante es "qué le pasó a ESTE producto en el tiempo" — así una consulta filtrada por `id_producto` lee un tramo contiguo del disco en vez de saltar por toda la tabla. `evento_login`/`evento_registro` van por `(ip, fecha, ...)` porque su pregunta es "cuántas cuentas distintas salen de esta IP", la señal de fraude que el grafo no puede ver (Neo4j sabe que dos cuentas se califican entre sí, no que entran desde la misma IP a la misma hora). `busqueda_realizada`/`busqueda_clic` van por `(termino, fecha)` porque ahí la pregunta es por término, no por producto.

**`ReplacingMergeTree` en las tablas de compra/devolución.** `compra_producto` y `devolucion_producto` usan este motor (no `MergeTree` a secas) porque, aunque hoy no se reintenta el `INSERT`, la tabla ya viene preparada para que un reintento futuro no duplique la venta: dos filas con la misma clave de `ORDER BY` se colapsan en una sola durante el merge en background. **Bug real encontrado y corregido el 2026-09-18**: el `ORDER BY` original de `compra_producto` no incluía `id_oferta`, solo `(id_producto, fecha, id_pedido)`. Cuando un pedido tenía dos líneas del **mismo producto** compradas a **dos vendedores distintos** (dos ofertas), ambas filas compartían la misma clave (la fecha es idéntica, viene del mismo `INSERT`) y `ReplacingMergeTree` se quedaba con una sola — perdiendo unidades. Medido: el pedido 121 tenía 3 líneas reales en PostgreSQL (ofertas 5, 46 y 51, las dos últimas del mismo producto) y en ClickHouse quedaban 2. Se corrigió agregando `id_oferta` al `ORDER BY`: `ORDER BY (id_producto, fecha, id_pedido, id_oferta)`.

### La columna `lote`

Presente en **todas** las tablas de eventos (`vista_producto`, `carrito_producto`, `compra_producto`, `devolucion_producto`, `busqueda_realizada`, `busqueda_clic`, `evento_login`, `evento_registro`, y propagada hasta `vistas_por_producto_dia`). Vale `'real'` (lo mandó el portal de verdad) o `'generado-<semilla>'` (lo sembró un script de `clickhouse/lote`). Existe porque, sin ella, un panel de fraude o de tendencias no puede distinguir un patrón medido de un patrón que dibujó un generador — y eso es grave en un panel de fraude: **acusaría a una cuenta de la semilla por un comportamiento que un script inventó**, no por algo que la cuenta hizo. Es el mismo marcador que ya usan `migrations/lote` (Postgres) y `mongo/lote`, replicado aquí. Todas las consultas de ranking (`AdminTendenciasService`, `MasVendidosSyncService`) filtran `lote = 'real'` **sin ningún parámetro para pedir lo contrario** — decisión explícita, no un descuido: "las métricas en todo lugar... son sobre solo los reales, simple".

En `vistas_por_producto_dia` el `lote` va dentro del `ORDER BY` mismo (`(dia, id_producto, lote)`), no solo como columna: si se agregara sin estar en la clave, lo generado y lo real quedarían sumados en la misma celda del `AggregateFunction` y ya no habría forma de separarlos después — la única pregunta que de verdad importa ("esto es medido o inventado") se perdería para siempre en cuanto se fusionaran los estados.

### El esquema real (`clickhouse/001_esquema.sql`)

```sql
CREATE TABLE IF NOT EXISTS vista_producto
(
    fecha        DateTime64(3),
    id_producto  UInt64,
    id_usuario   Nullable(UInt64),   -- publico, sin cuenta obligatoria
    sesion       String,             -- distingue anonimos entre si
    ip           IPv6,               -- IPv4 cabe dentro sin perder nada
    origen       LowCardinality(String),  -- catalogo | buscador | directo
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = MergeTree
ORDER BY (id_producto, fecha)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;
```

`vista_producto` es la **única tabla que nace en ClickHouse** (las demás de fraude de login son copias de Postgres). Sin ella no hay forma de saber qué se está calentando *antes* de venderse — el sistema, sin esto, solo guardaba el final de la historia (la compra). El `TTL` borra solas las filas de más de 12 meses, sin que nadie tenga que correr una limpieza — una capacidad nativa del motor que no existe igual en un relacional.

```sql
CREATE TABLE IF NOT EXISTS carrito_producto
(
    fecha        DateTime64(3),
    id_producto  UInt64,
    id_oferta    UInt64,
    id_usuario   UInt64,      -- nunca null: el carrito siempre exige sesion
    cantidad     UInt32,
    ip           IPv6,
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = MergeTree
ORDER BY (id_producto, fecha)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;
```

Sin `sesion` ni `origen` (a diferencia de `vista_producto`): no hay carrito de invitado en este proyecto, así que no hay visitante anónimo que distinguir. `id_oferta` viaja sin normalizar junto a `id_producto` porque el carrito real opera por oferta (vendedor+variante) pero la pregunta analítica dominante es de producto.

```sql
CREATE TABLE IF NOT EXISTS compra_producto
(
    fecha        DateTime64(3),
    id_producto  UInt64,
    id_oferta    UInt64,
    id_usuario   UInt64,
    cantidad     UInt32,
    id_pedido    UInt64,
    ip           IPv6,
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = ReplacingMergeTree
ORDER BY (id_producto, fecha, id_pedido, id_oferta)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;

-- devolucion_producto: columnas IDENTICAS, mismo motor, mismo ORDER BY.
-- Se evaluó agregar un campo `motivo` y se descartó: aquí solo hay un
-- valor relevante (devolución genérica), una columna con un solo valor
-- posible no aporta nada.
```

`compra_producto` es una **copia analítica**, no la fuente de verdad de ingresos — eso sigue siendo PostgreSQL (`GET /admin/reportes/ventas`), transaccional y exacto. Esta tabla mide *tasa de conversión* (vista → carrito → compra), nunca calcula un monto de facturación.

### `POST /eventos/vista`, `/carrito`, `/busqueda-clic` — el controlador real

`backend/src/controllers/eventos.controller.ts`. Las tres rutas responden **202 Accepted sin esperar el INSERT** (`@HttpCode(HttpStatus.ACCEPTED)` + `void this.eventosService.registrar...(...)` sin `await`):

```ts
@Post('vista')
@HttpCode(HttpStatus.ACCEPTED)
async vista(@Body() cuerpo: RegistrarVistaPeticion, @Req() request: FastifyRequest) {
  // ...validaciones...
  void this.eventosService.registrarVista({
    idProducto,
    idUsuario: await idUsuarioDeCookieOpcional(request),
    sesion,
    ip: request.ip,
    origen,
  });
  return exito(null, 'Vista registrada');
}
```

`POST /eventos/vista` es **pública** (sin `SesionGuard`): la ficha de producto se puede ver sin cuenta, y exigir sesión dejaría fuera justo la mitad del tráfico interesante. `id_usuario` sale de `idUsuarioDeCookieOpcional(request)` (helper compartido, `helpers/sesion-opcional.ts`) — si hay cookie válida la usa, si no manda `null`.

`POST /eventos/carrito` **sí exige sesión** (`@UseGuards(SesionGuard)`), porque el carrito de este proyecto siempre requiere cuenta — `id_usuario` sale de `@UsuarioActual()`, nunca de cookie opcional.

`POST /eventos/busqueda-clic` es pública igual que `vista`, y es la única de las dos rutas de búsqueda que necesita un `POST` propio: `busqueda_realizada` el backend la puede registrar solo (ya corrió la búsqueda), pero un *clic* es una interacción de interfaz pura que el backend no puede inferir sin que el navegador avise.

En `EventosService` (`backend/src/services/eventos/eventos.service.ts`), cada método está envuelto en `try/catch` que **nunca relanza** — solo `logger.warn`. Es el mismo criterio que `LogService.guardar()` y `FraudeLoginService.registrarIntento()`: registrar un evento es un efecto secundario de algo que ya pasó, no algo de lo que dependa la respuesta HTTP.

### El bug de `formatoFechaClickHouse`

```ts
function formatoFechaClickHouse(fecha: Date): string {
  const partes = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Guatemala',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).formatToParts(fecha);
  const obtener = (tipo: string): string =>
    partes.find((p) => p.type === tipo)?.value ?? '00';
  const milisegundos = String(fecha.getMilliseconds()).padStart(3, '0');
  return `${obtener('year')}-${obtener('month')}-${obtener('day')} ${obtener('hour')}:${obtener('minute')}:${obtener('second')}.${milisegundos}`;
}
```

`DateTime64(3)` por HTTP/JSONEachRow (el protocolo que usa el cliente Node) **exige un STRING** `AAAA-MM-DD HH:MM:SS.mmm`, no un timestamp numérico — un `INSERT` de prueba directo confirmó que un número (segundos o milisegundos desde época) o se rechaza, o **peor: se interpreta mal sin dar ningún error**. El string se arma explícitamente en la zona horaria del *servidor* de ClickHouse (`America/Guatemala`, fijada en `clickhouse/docker-compose.yml`), sin importar en qué zona corra el proceso de Node — porque un string sin offset lo interpreta ClickHouse en la zona del propio servidor, y si se armara con la hora local del backend (que podría correr en otra zona) el dato quedaría corrido. Es el mismo tipo de bug que ya había mordido una vez con el `now()` del contenedor.

### `compra_producto`/`devolucion_producto` — sin ruta HTTP, enganchadas directo en el flujo de negocio

```ts
/**
 * Compra confirmada -- llamada DIRECTO desde CarritoService.ejecutarCompraCarrito
 * (fire-and-forget, sin await), justo despues de que comprar_carrito() de
 * PostgreSQL confirma el pedido.
 */
async registrarCompra(datos: {
  idUsuario: string; idPedido: number; ip: string;
  lineas: { idProducto: number; idOferta: number; cantidad: number }[];
}): Promise<void> {
  if (datos.lineas.length === 0) return;
  try {
    const fecha = formatoFechaClickHouse(new Date());
    await clickhouse.insert({
      table: 'compra_producto',
      values: datos.lineas.map((linea) => ({
        fecha, id_producto: linea.idProducto, id_oferta: linea.idOferta,
        id_usuario: datos.idUsuario, cantidad: linea.cantidad,
        id_pedido: datos.idPedido, ip: datos.ip, lote: 'real',
      })),
      format: 'JSONEachRow',
    });
  } catch (error) {
    this.logger.warn(`No se pudo registrar la compra en ClickHouse: ${error}`);
  }
}
```

`registrarCompra()` se llama desde `CarritoService.ejecutarCompraCarrito()`, y `registrarDevolucion()` desde `PedidosCompradorService.cancelarPedido()` — **ninguna de las dos tiene ruta HTTP propia**, ni pasa por un worker con outbox. Es una **decisión explícita, discutida y descartada**: a diferencia de reseñas→Neo4j (outbox con tabla `evento_grafo`+trigger) o logueos→Elasticsearch (bandera `pendiente_elastic`+worker), perder un evento de analítica aquí no arriesga nada — la venta *ya quedó segura* en PostgreSQL de forma completamente independiente de este `INSERT`. Se probó en vivo con ClickHouse REALMENTE caído a mitad de una compra real: la operación de negocio se completó normal (~0.1 s), el evento de analítica se perdió de verdad, sin cola ni reintento — a propósito, no un bug. Cada `registrarCompra`/`registrarDevolucion` manda **una fila por línea del pedido en un solo `INSERT`** (ClickHouse prefiere lotes a filas sueltas), nunca una llamada por línea.

### `busqueda_realizada` — enganchada en la ruta pública de búsqueda, no en una ruta propia

Se registra desde dentro de `BuscadorProductosController.buscar()` (la ruta **pública**, `GET /buscador/productos`, nunca `/admin`): el backend ya corrió la búsqueda y sabe el término y cuántos resultados dio, así que no hace falta que el frontend avise nada aparte — mismo razonamiento que `registrarCompra`, opuesto al de `registrarVista`. `sesion` viaja como **query param opcional** de ese mismo `GET`; si no viene, el evento se salta en silencio (`registrarBusqueda` igual nunca lanza), sin bloquear ni degradar la búsqueda de nadie.

### `GET /admin/eventos/*` — el ranking de tendencias, controller y service reales

`AdminTendenciasController` (`backend/src/controllers/admin/admin-tendencias.controller.ts`), protegido con `SesionGuard` + `PermisoGuard` y `@Permiso('tendencias.ver')` a nivel de clase, un permiso que en `rol_permiso` solo tiene el admin — nunca la tienda, mismo criterio que el resto de paneles de admin. Seis rutas (`vista`, `carrito`, `compra`, `devolucion`, `busqueda`, `busqueda-clic`), mismos tres query params en las seis:

```
dias        cuantos dias hacia atras (defecto 7, tope 365)
limite      cuantos resultados del ranking -- "M" (defecto 20, tope 200)
direccion   "positivo" (defecto, top M) | "negativo" (bottom M)
```

`AdminTendenciasService` decide la métrica por tabla — **decisión explícita del usuario, según qué tan fácil es repetir la acción sin inflar el número**:

```ts
async rankingVistas(query)  { return this.rankingPorProducto('vista_producto', 'count(DISTINCT sesion)', query); }
async rankingCarrito(query) { return this.rankingPorProducto('carrito_producto', 'count(DISTINCT id_usuario)', query); }
async rankingCompras(query) { return this.rankingPorProducto('compra_producto', 'sum(cantidad)', query); }
async rankingDevoluciones(query) { return this.rankingPorProducto('devolucion_producto', 'sum(cantidad)', query); }
async rankingBusquedas(query)     { return this.rankingPorTermino('busqueda_realizada', query); }  // count(DISTINCT sesion)
async rankingClicsBusqueda(query) { return this.rankingPorTermino('busqueda_clic', query); }        // count(DISTINCT sesion)
```

- **`vista`/`carrito`** cuentan **personas distintas**, no eventos totales: mirar una ficha o agregar al carrito es de bajo esfuerzo y "casi cualquiera puede repetirlo", así que lo que importa es a cuánta gente distinta le interesó — no el volumen bruto que una sola persona podría inflar. `vista_producto` tiene columna `sesion` (sirve incluso sin cuenta); `carrito_producto` no la tiene (el carrito siempre exige sesión), así que ahí la distinción es por `id_usuario`.
- **`compra`/`devolucion`** usan `sum(cantidad)`, conteo normal: completar una compra no es trivial ni repetible sin fricción, cada unidad cuenta por lo que es.
- **`busqueda`/`busqueda-clic`** cuentan sesión distinta pero **agrupando por `termino`**, no por producto: la pregunta es qué tan buscado/cliqueado está un término.

La consulta compartida real (`consultarRanking`):

```sql
SELECT ${columnaAgrupar} AS clave, ${metrica} AS total
  FROM ${tabla}
 WHERE fecha >= now() - INTERVAL {dias:UInt32} DAY
   AND lote = 'real'
 GROUP BY ${columnaAgrupar}
 ORDER BY total ${direccion}
 LIMIT {limite:UInt32}
```

`tabla` y `metrica` nunca salen del cliente — son constantes fijadas por cada método público (`rankingVistas`, `rankingCompras`, etc.), así que interpolarlas directamente en el SQL es seguro (no hay inyección posible porque no hay input de usuario en esas dos posiciones); `dias`/`limite` sí vienen del query string y van como `query_params` parametrizados, nunca interpolados. Las cuatro rutas que agrupan por `id_producto` hacen una **segunda consulta a MongoDB** con `$in` para traer nombre/precio — **sin filtrar por estado** (a diferencia del catálogo público o de `mas-vendidos`): un admin explorando tendencias necesita ver también un producto inactivo o ya borrado. `total` llega de ClickHouse como **string** (`count`/`sum` se promueven a `UInt64`, que el driver serializa como texto para no perder precisión en JS) y se convierte a `number` recién en el método público, no en la consulta genérica.

### `GET /productos/mas-vendidos` + `MasVendidosSyncService` — el worker ClickHouse → Redis

`backend/src/services/productos/mas-vendidos-sync.service.ts`. Worker `@Interval('mas-vendidos-sync', 10 * 60 * 1000)` — **cada 10 minutos**, con guardia `procesando` para que una corrida lenta no se pise con la siguiente:

```ts
async recalcular(): Promise<void> {
  if (this.procesando) return;
  this.procesando = true;
  try {
    let filas = await this.consultarVentana(24, 'HOUR');
    if (filas.length === 0) {
      filas = await this.consultarVentana(7, 'DAY');
    }
    if (filas.length === 0) {
      this.logger.log('sin compras en 24h ni en 7 dias -- se deja el ranking anterior tal cual');
      return;
    }
    await this.reemplazarRanking(filas);
  } catch (error) {
    this.logger.warn(`corrida interrumpida -- ${mensajeCorto(error)}`);
  } finally {
    this.procesando = false;
  }
}
```

Agrega `compra_producto` de las últimas 24h; si esa ventana viene vacía (un bache normal, no un error), cae a 7 días para no dejar el ranking en blanco por algo tan corto; si **también** 7 días viene vacío, el worker **no toca Redis en absoluto** — deja el último cálculo válido aunque esté viejo, porque mostrar algo desactualizado es mejor que vaciar la vitrina. Publica hasta 20 ids (`TOPE_ALMACENADO`, más de los 8 que la ruta pública muestra — así un cambio futuro en cuántos se pintan no toca este worker).

**El reemplazo es atómico vía `RENAME`, no sobreescritura clave por clave**:

```ts
private async reemplazarRanking(filas: FilaRankingClickHouse[]): Promise<void> {
  const paresScoreMiembro: (string | number)[] = [];
  for (const fila of filas) {
    paresScoreMiembro.push(Number(fila.total), fila.id_producto);
  }
  await redis.del(MasVendidosSyncService.CLAVE_TEMPORAL);
  await redis.zadd(MasVendidosSyncService.CLAVE_TEMPORAL, ...paresScoreMiembro);
  await redis.rename(MasVendidosSyncService.CLAVE_TEMPORAL, MasVendidosSyncService.CLAVE_RANKING);
}
```

El ZSET nuevo se arma completo en una clave temporal (`mesh:productos:mas_vendidos:tmp`) y solo al final se publica con `RENAME` sobre la clave real (`mesh:productos:mas_vendidos`). `RENAME` en Redis es una operación atómica de un solo paso: nadie que esté leyendo el ranking en ese instante puede ver un ZSET a medio reconstruir (algunos productos del ranking nuevo, otros del viejo) — si en vez de `RENAME` se hicieran `ZADD`/`ZREM` incrementales sobre la clave real, existiría una ventana donde una lectura concurrente vería un estado mixto inconsistente.

La ruta pública (`MasVendidosService.obtener()`, `backend/src/services/productos/mas-vendidos.service.ts`) lee los primeros 8 con `ZREVRANGE 0 7` (sin scores, los miembros ya vienen en orden de más a menos vendido) y trae el detalle real con `$in` a Mongo, **filtrando `estado: activo`** — a diferencia de `AdminTendenciasService`, aquí sí importa: un producto que se desactivó después de venderse mucho no debe seguir apareciendo en el catálogo público.

`lote = 'real'` **fijo**, sin parámetro, en la consulta `consultarVentana` — mismo criterio que `AdminTendenciasService`: mezclar compras sembradas por un script en un ranking de "más vendidos" sería mostrar un número que nadie compró de verdad.

### `trustProxy: 'loopback'` — el hallazgo que afectaba TODA la IP registrada del sistema

`backend/src/main.ts`, línea de creación de la app:

```ts
const app = await NestFactory.create<NestFastifyApplication>(
  AppModule,
  new FastifyAdapter({ trustProxy: 'loopback' }),
);
```

Fastify tiene tres modos relevantes para `request.ip` cuando hay un proxy delante (el proxy `/api` de Vite en desarrollo, o un túnel de Cloudflare para entrar desde el celular):

- **`trustProxy: false`** (default): `request.ip` es siempre el socket directo — con proxy en medio, siempre `127.0.0.1`.
- **`trustProxy: true`**: Fastify confía en el header `X-Forwarded-For` completo y toma la IP **más a la izquierda** — pero esa cabecera **la puede escribir el cliente**. Medido con un nodo de Tor mandando `X-Forwarded-For: 1.2.3.4` de forma maliciosa detrás de un túnel real: `trustProxy: true` da `request.ip = 1.2.3.4` (la IP inventada por el atacante), no la real.
- **`trustProxy: 'loopback'`**: Fastify solo confía en el `X-Forwarded-For` cuando la conexión directa (el socket) viene de `127.0.0.0/8` o `::1` — es decir, cuando quien habla con el backend es un proceso de la propia máquina (Vite, el túnel). A partir de ahí, se detiene en la **primera IP de fuera** del rango de loopback. Mismo escenario de arriba: `request.ip = 192.42.116.59` (la real). Y si alguien intenta pegarle directo al puerto 3000 desde otra máquina sin pasar por el proxy, su conexión no viene de loopback, así que su cabecera `X-Forwarded-For` **no se lee en absoluto** — no puede inventarse ninguna IP.

Este era un hallazgo real, no cosmético: sin la línea, `request.ip` daba `127.0.0.1` para **todo el mundo** que entrara por el túnel del celular — y eso corrompía silenciosamente el campo `ip` de `vista_producto`, `carrito_producto`, `compra_producto`, `devolucion_producto` **y** los contadores de fraude por IP (`fuerza_bruta_ip`, `multi_cuenta_ip` de Redis, y las agregaciones por IP de Elasticsearch): cuatro personas entrando desde sus celulares por el mismo túnel ya disparaban una alerta `multi_cuenta_ip` falsa, porque todas contaban como la misma IP `127.0.0.1`.

---

## Parte 8 — El catálogo copiado a PostgreSQL y la cola de productos por recalcular (2026-10-01)

Esta parte explica por qué el carrito y el checkout dejaron de depender de MongoDB, y cómo se mantiene todo en pie. Plan y estado: `plan pendiente/catalogo-en-postgres.md` y `plan pendiente/evento-producto.md`.

### El problema que había

El checkout no escribía en Mongo, pero lo **leía** antes de cobrar (nombre del producto, nombre y estado de la variante) y lo **escribía** después de cobrar (`recalcularCamposCalculados`, con `await`). Con Mongo caído la compra daba 503, y aunque la compra ya estuviera cobrada, la respuesta esperaba unos 3 s por producto (`serverSelectionTimeoutMS`), en serie. Era la fila 11 de `docs/CONSISTENCIA-CHECKOUT.md`: una dependencia de **disponibilidad**, no de consistencia.

### Decisión 1: la copia va normalizada, en dos tablas, no como columnas de `oferta`

`producto_catalogo (id_producto_mongo, nombre)` y `variante_catalogo (id_producto_mongo, id_producto_variante_mongo, nombre_variante, estado, imagen)`. El nombre depende de la **variante**, no de la oferta: una variante puede tener muchas ofertas (modelo multi-vendedor), y como columna de `oferta` el nombre se repetiría N veces y un renombre tocaría N filas. El par de ids identifica la variante (en Mongo dos productos pueden repetir el id de variante). `imagen` guarda una sola imagen, la portada, porque es lo único que necesita la línea del carrito. La FK de `oferta` a `variante_catalogo` está prevista como etapa 2 y NO se aplicó: crear una oferta sobre un producto recién creado la rechazaría si la copia aún no existe.

### Decisión 2: Mongo y PostgreSQL no comparten transacción, así que el orden es lo que protege

`escribirConCatalogoPostgres` (`helpers/catalogo-postgres.ts`) hace: `BEGIN` en PostgreSQL, `UPSERT` de la copia (sin commit todavía), escritura en Mongo, `COMMIT`. Si falla antes del `COMMIT`: `ROLLBACK` y se deshace Mongo. Si falla el `COMMIT`: se deshace Mongo. PostgreSQL va primero porque su `COMMIT` es lo último que puede fallar, y es mucho más raro que falle que una escritura de Mongo. Ventana que queda, declarada: el proceso muere entre la escritura de Mongo y el `COMMIT`, o falla la propia compensación. No es una transacción distribuida (no hay commit en dos fases entre estas dos bases); es una aproximación con ventana de milisegundos.

### Decisión 3: el recálculo de Mongo sale de la petición, vía outbox deduplicado

Mismo patrón que `evento_grafo` (Parte 4), con una diferencia deliberada: `evento_producto` guarda **una fila pendiente por producto**, no una por cambio (índice único parcial + `UPSERT` en el trigger). Recalcular siempre parte del estado actual, así que 50 cambios seguidos se resuelven con un solo recálculo. Dos triggers (`oferta`, solo las columnas que entran en los campos calculados; `resena`) escriben en la misma transacción del cambio, por lo que no se puede olvidar un sitio. El worker (`EventoProductoSyncService`) marca `procesado_en` solo si `fecha` sigue siendo la que leyó; si el producto cambió mientras se recalculaba, la fila queda pendiente y se repite. Un producto que falla 5 veces se aparta; un cambio nuevo lo reactiva (el trigger pone `intentos = 0`). Si Mongo está caído, el worker corta la corrida sin contar intentos.

Se descartó dejar la llamada directa sin `await` (fire-and-forget): sigue metiendo a Mongo en la ruta de compra, no reintenta y duplica lo que ya hace el worker.

### Lo que se acepta

- La tarjeta del catálogo (precio, stock, nota) puede ir hasta unos segundos atrás. La ficha y el cobro siguen en vivo contra PostgreSQL, así que nada se vende de más.
- Los cambios al catálogo hechos fuera del backend (ETL, scripts) no pasan por `escribirConCatalogoPostgres`: hay que sembrar con `plan pendiente/catalogo-en-postgres-sembrar.cjs`.
- Sin las migraciones reales (`029` catálogo, `030` cola y triggers) el worker falla en cada pasada; en local ya están aplicadas a mano.
