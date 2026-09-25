# API

> **El contrato completo de las 119 rutas NO esta aqui.** Vive en
> `backend/elementos Generales/endpoints/`, que es donde lo mantiene quien
> escribe el backend y por tanto la fuente de verdad. Los enlaces de antes
> apuntaban a la carpeta de arriba, de donde los archivos se mudaron:
>
> | Archivo | Que cubre |
> |---|---|
> | [endpoints.md](../backend/elementos%20Generales/endpoints/endpoints.md) | usuario, perfil, direcciones, admin |
> | [endpoints-productos.md](../backend/elementos%20Generales/endpoints/endpoints-productos.md) | el catalogo publico, los historiales por fecha y las recomendaciones R1 a R3 |
> | [endpoints-vendedores.md](../backend/elementos%20Generales/endpoints/endpoints-vendedores.md) | `/vendedor/*`, descuentos, ventas relampago y las dos clases de reglas, con la tabla de que rol entra a cada ruta |
> | [endpoints-compradores.md](../backend/elementos%20Generales/endpoints/endpoints-compradores.md) | pedidos del comprador |
> | [endpoints-carrito.md](../backend/elementos%20Generales/endpoints/endpoints-carrito.md) | carrito en Redis y checkout |
> | [endpoints-eventos.md](../backend/elementos%20Generales/endpoints/endpoints-eventos.md) | eventos a ClickHouse, los seis rankings y las tendencias T1 a T3 |
> | [endpoints-fraude.md](../backend/elementos%20Generales/endpoints/endpoints-fraude.md) | alertas de login y anillos de resenas, con los tipos B |
> | [endpoints-buscador.md](../backend/elementos%20Generales/endpoints/endpoints-buscador.md), [endpoints-resenas.md](../backend/elementos%20Generales/endpoints/endpoints-resenas.md), [endpoints-reportes.md](../backend/elementos%20Generales/endpoints/endpoints-reportes.md) | el buscador, las resenas y los reportes |
>
> Este archivo se queda con lo que NO cambia con cada ruta: el formato de
> respuesta, como se manejan los errores y como esta organizado el codigo.
> Duplicar alli la lista de rutas solo garantiza que una de las dos caduque.

## Lo que llego el 2026-09-24 y 25, y donde lo usa el portal

Solo el indice, para saber que pantalla mira cada ruta nueva. El contrato
esta en los archivos de arriba.

| Ruta | Que es | Donde se ve |
|---|---|---|
| `POST /vendedor/ofertas/:id/descuento` con `duracion_segundos` | descuento que se quita solo. Crea `mesh:oferta:<id>:descuento` en Redis, con vencimiento o sin el | panel, Ofertas, "Hasta cuando" |
| `POST, GET, GET paginado, PATCH /vendedor/reglas-descuento-periodos` | descuento por fecha (tabla de la 022) | panel, Reglas, "Descuentos por fecha" |
| 409 de exclusion en las cuatro formas de descuento | una oferta tiene un solo descuento activo a la vez | los tres formularios lo explican con `textoConflictoDescuento` |
| `GET /admin/fraude/alertas-resenas?tipo=` con los tipos B | los seis patrones B guardados (tabla de la 023) | panel, Fraude, y la campana del admin |
| `GET /admin/eventos/tendencias`, `/embudo`, `/busquedas-sin-respuesta` | T1, T2 y T3, solo admin | panel, Tendencias, "Señales" |
| `GET /productos/vistos-recientemente` | R1, publica, con `sesion` | portada, "Viste hace poco" |
| `GET /productos/:id/tambien-vieron` | R2, publica, lee Redis | ficha del producto |
| `GET /productos/para-ti` | R3, con sesion, lee Redis | portada, "Para ti" |

Los arneses que las miden por HTTP: `pruebas/descuentos.sh`,
`pruebas/reglas_descuento.sh`, `pruebas/reglas_periodo.sh`,
`pruebas/anillos_familia_b.sh`, `pruebas/tendencias_avanzadas.sh` y
`pruebas/recomendaciones.sh`.

## Estandar de respuestas

Todos los endpoints responden con la misma estructura.

```json
{
  "ok": true,
  "mensaje": "texto corto",
  "payload": {}
}
```

| Campo | Tipo | Que es |
|---|---|---|
| `ok` | boolean | Si la operacion salio bien |
| `mensaje` | string | Explicacion corta, legible para una persona |
| `payload` | cualquiera | Los datos utiles para el frontend |

### Reglas

Los tres campos van siempre. Aunque falle, `payload` viaja como `null` y nunca se
omite. Asi el frontend siempre lee la misma estructura.

`payload` es solo datos. Nada de banderas ni mensajes adentro.

`mensaje` se le puede ensenar al usuario. Los detalles tecnicos van al log del
servidor, no a la respuesta.

El frontend revisa `ok` antes de usar `payload`:

```js
const r = await fetch('/db').then(r => r.json());

if (!r.ok) {
  mostrarError(r.mensaje);
  return;
}

usarDatos(r.payload);
```

### Codigos HTTP

El codigo y `ok` siempre concuerdan.

| Codigo | Cuando | ok |
|---|---|---|
| 200 | Todo bien | true |
| 201 | Se creo algo | true |
| 400 | El cliente mando datos invalidos | false |
| 401 | No hay sesion, o el token vencio | false |
| 402 | La tarjeta fue rechazada | false |
| 404 | No existe lo que se pidio | false |
| 409 | Conflicto, por ejemplo stock insuficiente | false |
| 503 | Una base de datos no responde | false |
| 500 | Error inesperado | false |

Se usan los dos porque el codigo lo leen las herramientas (Docker, monitoreo,
logs) y `ok` lo lee el frontend.

### Como se arma en el codigo

Los constructores estan en `backend/src/helpers/respuesta.ts`:

```ts
import { exito, fallo } from '../helpers/respuesta';

exito({ base: 'mesh' }, 'Conexion establecida');
// { ok: true, mensaje: 'Conexion establecida', payload: { base: 'mesh' } }

fallo('No se pudo conectar con PostgreSQL');
// { ok: false, mensaje: 'No se pudo conectar con PostgreSQL', payload: null }
```

No armar el objeto a mano. Si el estandar cambia, se cambia en un solo archivo.

---

## Endpoints

### GET /

Ruta de prueba. Dice que la API esta viva. HTTP 200:

```json
{
  "ok": true,
  "mensaje": "Hello World",
  "payload": {
    "servicio": "Mesh API",
    "estado": "en linea"
  }
}
```

No toca la base de datos. Si responde, el backend arranco bien.

### GET /db

Comprueba si el backend puede hablar con PostgreSQL. Le manda una consulta minima
que no toca ninguna tabla: solo interesa saber si responde.

Conectado, HTTP 200:

```json
{
  "ok": true,
  "mensaje": "Conexion establecida con PostgreSQL",
  "payload": {
    "base": "mesh",
    "hora": "2026-08-16T02:38:08.288Z",
    "version": "PostgreSQL 18.6"
  }
}
```

Sin conexion, HTTP 503:

```json
{
  "ok": false,
  "mensaje": "No se pudo conectar con PostgreSQL",
  "payload": null
}
```

Probado apagando y encendiendo el contenedor:

```bash
docker stop mesh-postgres
curl http://localhost:3000/db
docker start mesh-postgres
```

---

## Como esta organizado el backend

```
src/
  controllers/   reciben la peticion y devuelven la respuesta
  services/      la logica y las consultas
  models/        la forma de cada tabla y de cada respuesta
  helpers/       utilidades compartidas
  middlewares/   codigo que corre antes de llegar al controlador
  database/      la conexion
```

Las carpetas usan los nombres estandar del framework. Todo lo que escribimos
nosotros (archivos, clases y funciones) esta en espanol.

### Cuantas piezas hay, y donde esta la lista

Al 2026-09-25 (99891a8) el backend son **36 controladores, 51 servicios
(contando los workers), 32 modelos, 65 DTO y 38 helpers**, y monta **119
rutas**. Contado asi, y hay que volver a contarlo antes de creerle a este
numero:

```bash
cd backend/src
find controllers -name "*.controller.ts" | wc -l
grep -rhoE "@(Get|Post|Patch|Put|Delete)\(" --include=*.controller.ts . | wc -l
```

**La lista archivo por archivo no se copia aqui a proposito.** `backend/` lo
escribe y lo mantiene otra persona, asi que un inventario en este documento
caduca el dia siguiente y nadie se entera: es exactamente el problema que ya
tuvo este archivo, que llego a enumerar cuatro controladores cuando ya habia
catorce. La lista viva esta en los cuatro `endpoints-*.md` de
`backend/elementos Generales/`, que son la fuente de verdad.

Lo que si vale la pena fijar aqui, porque es la convencion y no cambia, es
**como se llaman las cosas**: un modelo por cada tabla que el backend LEE, con
el mismo nombre en singular y en kebab-case (`models/estado-oferta.ts` para
`estado_oferta`). No hay uno por cada tabla de la base -- eran 20 modelos contra
39 tablas cuando se escribio esto, y la proporcion sigue -- porque los catalogos y las tablas que solo toca el SQL no necesitan
tipo en TypeScript. Ademas, un
DTO por cuerpo de peticion o de respuesta, y las carpetas con los nombres
estandar del framework. Todo lo que escribimos nosotros -- archivos, clases y
funciones -- esta en espanol.

Los `id` de las tablas grandes van tipados como `string` y no como `number`.
Son `bigserial`, y el driver `pg` entrega los `bigint` como texto para no perder
precision. Si se declaran `number`, una comparacion como `id === 1` falla en
silencio porque lo que llega es `"1"`. Los catalogos si van como `number`
porque son `smallserial`.

### El recorrido de una peticion

```
navegador  ->  GET /db
  ->  BaseDatosController   recibe la peticion
  ->  BaseDatosService      hace la consulta
  ->  pool                  toma una conexion del grupo
  ->  PostgreSQL            responde
  <-  regresa como JSON
```

El controlador no tiene logica: recibe, llama al servicio y devuelve. Toda la
logica vive en el servicio. Por eso el controlador siempre es corto.

### Que es el pool

`database/postgres.ts` crea un pool de conexiones: un grupo de conexiones ya
abiertas que se reutilizan. Abrir una conexion nueva en cada consulta seria
lento, asi que el pool las mantiene listas y las va prestando.

Ese archivo tambien escucha el evento `error` del pool. No es opcional: cuando
PostgreSQL se apaga, el pool avisa que perdio una conexion en reposo, y en Node
un evento `error` que nadie escucha mata el proceso. Sin ese listener, apagar la
base tumbaba el backend completo.

Probado apagando el contenedor con el backend corriendo: `GET /db` responde 503
y `GET /` sigue respondiendo 200. Al encender la base otra vez, `GET /db` vuelve
a 200 solo, sin reiniciar nada.
