# Mesh

Proyecto de Bases de Datos 2.

```
backend/            API en NestJS
frontend/           Interfaz en SvelteKit
migrations/         Scripts SQL del esquema
docs/               Documentacion
docker-compose.yml  Bases de datos
```

## Documentacion

| Archivo | Contenido |
|---|---|
| [docs/instalacion.md](docs/instalacion.md) | Que instalar, como levantar el proyecto, errores comunes |
| [docs/base-de-datos.md](docs/base-de-datos.md) | El modelo relacional y por que quedo asi |
| [docs/api.md](docs/api.md) | Estandar de respuestas y endpoints |
| [migrations/README.md](migrations/README.md) | Como se nombran y se corren las migraciones |
| [comandos.txt](comandos.txt) | Todos los comandos, con lo que hace cada uno |

## Arranque rapido

```powershell
.\arrancar.ps1                     # bases de datos y migraciones

cd backend  ; npm run start:dev    # http://localhost:3000
cd frontend ; npm run dev          # http://localhost:5173
```

pgAdmin queda en http://localhost:5050 con el servidor ya conectado.

Detalle completo en [docs/instalacion.md](docs/instalacion.md).
