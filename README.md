# Mesh

Proyecto de Bases de Datos 2.

```
backend/            API en NestJS
frontend/           Interfaz en SvelteKit
migrations/         Esquema SQL, y el generador del conjunto de datos
etl/                Migracion del catalogo a MongoDB
mongo/              Colecciones e indices
docs/               Documentacion
docker-compose.yml  Bases de datos
```

## El modelo, en una frase

El catalogo es **compartido**: un producto describe una cosa del mundo y no es de
nadie. Quien lo vende, a que precio y con cuantas unidades es una fila de
`oferta`. La cuenta de la tienda (`tienda@mesh.com`) tiene oferta de todo, y su
precio es el que se ensena en la pagina.

El detalle esta en [docs/base-de-datos.md](docs/base-de-datos.md).

## El conjunto de datos

**102 productos** en 17 categorias hoja (ninguna con menos de 5, para que
filtrar por categoria signifique algo), 202 variantes, **552 ofertas** y 8
cuentas. Todos los productos tienen imagen, verificada una por una.

No se edita a mano: lo escribe `node migrations/datos/generador.js`, con semilla
fija, y el archivo se comprueba a si mismo al cargar.

Esos son los numeros **recien cargado**. Una base sobre la que ya se compro o se
publico algo tiene mas, y no pasa nada: los productos que se crean desde el
panel viven solo en MongoDB (la migracion del catalogo esta terminada, ver
[docs/base-de-datos.md](docs/base-de-datos.md)), asi que es normal que PostgreSQL
y MongoDB no cuenten lo mismo. Para volver al conjunto exacto:
`.\arrancar.ps1 -Reiniciar`.

## Que se puede hacer hoy

Buscar en el catalogo (por nombre, categoria, precio, disponibilidad y
caracteristicas, con las dos formas de paginar), abrir la ficha y ver las
ofertas de cada vendedor, agregar al carrito, elegir a donde se entrega, pagar
con la tarjeta simulada, y ver el historial de pedidos con el detalle de cada
uno -- incluido **como se veia el producto el dia en que se compro**.

Y despues de pagar se aterriza en una pantalla de agradecimiento con el detalle
del pedido, cuyo boton de volver recarga el catalogo: asi el descuento de
existencias se VE, que antes pasaba en la base y no en la pantalla.

Del lado del vendedor: publicar ofertas, y cambiar su precio, su estado y sus
existencias, con un buscador sobre las propias. **Una oferta suya ya no sale a la
venta sola**: nace `pendiente` y espera a que la tienda la apruebe o la rechace
con un motivo. Si se la rechazan, corregirle el precio la manda de vuelta a la
cola. Y ademas puede **proponer productos** nuevos para el catalogo compartido,
que nacen `en_revision` y siguen el mismo camino.

Del lado de la tienda y del administrador -- que el backend trata igual -- se
entra por el PRODUCTO en vez de por una lista de 202 ofertas: el catalogo
paginado de 20 en 20, con filtro por nombre y por categoria, y las ofertas de un
producto se piden al abrirlo. Ademas administran el catalogo compartido (alta,
edicion e historial por fecha), tambien paginado y con su buscador, y tienen las
dos colas de revision: la de ofertas pendientes y la de productos propuestos.

Las direcciones llegan hasta la puerta: ademas de pais, departamento, ciudad y
codigo postal llevan la **calle**, que es obligatoria al crear una direccion
nueva -- sin ella no se puede entregar un pedido.

> **Ojo con el frontend.** El backend de todo lo anterior esta hecho y probado, y
> el esquema tambien; las pantallas todavia no. En concreto, el formulario de
> direcciones tiene que mandar `direccion_exacta` o el alta responde 400, y las
> dos colas de revision no tienen pantalla todavia.

## Documentacion

| Archivo | Contenido |
|---|---|
| [docs/instalacion.md](docs/instalacion.md) | Que instalar, como levantar el proyecto, errores comunes |
| [docs/base-de-datos.md](docs/base-de-datos.md) | El modelo relacional y por que quedo asi |
| [docs/api.md](docs/api.md) | Estandar de respuestas y endpoints |
| [docs/frontend.md](docs/frontend.md) | Paginas, paleta y tema claro/oscuro |
| [migrations/README.md](migrations/README.md) | Como se nombran y se corren las migraciones |
| [etl/README.md](etl/README.md) | Como se migra el catalogo de PostgreSQL a MongoDB |
| [comandos.txt](comandos.txt) | Todos los comandos, con lo que hace cada uno |
| [backend/elementos Generales/cambios-multivendedor.md](backend/elementos%20Generales/cambios-multivendedor.md) | Que cambia en el backend con el modelo multi-vendedor |

## Arranque rapido

```powershell
.\arrancar.ps1                     # bases de datos y migraciones

cd backend  ; npm run start:dev    # http://localhost:3000
cd frontend ; npm run dev          # http://localhost:5173
```

pgAdmin queda en http://localhost:5050 con el servidor ya conectado, y DbGate
en http://localhost:3001 para MongoDB.

Detalle completo en [docs/instalacion.md](docs/instalacion.md).
