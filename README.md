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
