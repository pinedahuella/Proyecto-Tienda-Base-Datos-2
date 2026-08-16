# Instalacion y ambiente

Como dejar Mesh corriendo en una PC nueva.

## Programas que hay que instalar

| Programa | Version | Donde |
|---|---|---|
| Node.js | 24 LTS | https://nodejs.org |
| Docker Desktop | ultima | https://www.docker.com/products/docker-desktop |
| Git | ultima | https://git-scm.com/downloads |

Nada mas. PostgreSQL y pgAdmin no se instalan: estan en el `docker-compose.yml`
y Docker los baja solo.

Si la PC ya tiene PostgreSQL instalado, hay que detener su servicio. Usa el
puerto 5432 y choca con el contenedor.

## Pasos

```bash
git clone https://github.com/pinedahuella/Proyecto-Tienda-Base-Datos-2.git
cd Proyecto-Tienda-Base-Datos-2
```

Las contrasenas no vienen en el repositorio. Hay que crear dos archivos `.env`
a partir de sus plantillas y llenarlos con los valores que use el equipo:

```powershell
copy .env.example .env
copy backend\.env.example backend\.env
```

Los dos archivos deben tener el mismo usuario y la misma contrasena, porque el
de la raiz es el que crea la base y el de `backend` es con el que la API se
conecta a ella.

Despues:

```bash
cd backend && npm install
cd ../frontend && npm install
```

## Levantar el proyecto

En Windows, un solo comando deja las bases listas:

```powershell
.\arrancar.ps1
```

El script arranca Docker si esta apagado, levanta los contenedores, espera a que
PostgreSQL responda y corre las migraciones pendientes. Se puede correr las veces
que quieras: si una migracion ya estaba aplicada lo avisa y sigue.

```powershell
.\arrancar.ps1 -Reiniciar     # borra los datos y empieza de cero
```

Despues, en dos terminales mas:

```bash
cd backend && npm run start:dev   # http://localhost:3000
cd frontend && npm run dev        # http://localhost:5173
```

A mano, sin el script:

```bash
docker compose up -d
docker exec mesh-postgres psql -U $DB_USER -d $DB_NAME -f /migrations/001_usuarios.sql
```

## Contenedores

| Servicio | Contenedor | Imagen | Puerto |
|---|---|---|---|
| PostgreSQL | mesh-postgres | pgvector/pgvector:pg18 | 5432 |
| pgAdmin | mesh-pgadmin | dpage/pgadmin4 | 5050 |

Apagar todo:

```bash
docker compose down
```

Con `-v` ademas borra los datos de la base.

La carpeta `migrations/` esta montada dentro del contenedor de PostgreSQL en
`/migrations`, para poder correr los scripts sin copiarlos a mano.

## Accesos de desarrollo

| Servicio | Usuario | Contrasena |
|---|---|---|
| PostgreSQL | `DB_USER` del .env | `DB_PASSWORD` del .env |
| pgAdmin | `PGADMIN_EMAIL` del .env | `PGADMIN_PASSWORD` del .env |

**Ninguna contrasena esta escrita en el repositorio.** Todas viven en el archivo
`.env`, que git ignora. Por eso el primer paso de la instalacion es copiar
`.env.example` y llenarlo.

pgAdmin entra directo en http://localhost:5050 y el servidor `Mesh` ya viene
registrado y conectado. Los dos archivos que lo logran, `servers.json` y
`pgpass`, los genera `arrancar.ps1` a partir del `.env` cada vez que corre; por
eso tampoco estan en el repositorio.

Si algun dia hay que conectarlo a mano, el host es `postgres`, no `localhost`.
pgAdmin corre dentro de Docker y para el `localhost` es el mismo pgAdmin.

## Que hay instalado en el backend

```
NestJS 11                  framework
@nestjs/platform-fastify   servidor
TypeScript 5.7
pg 8.23                    driver de PostgreSQL
```

El driver `pg` se usa con SQL directo. No hay ORM.

## Que hay instalado en el frontend

```
SvelteKit 2.63
Svelte 5.56
Vite 8
TypeScript
```

## Comandos del backend

| Comando | Que hace |
|---|---|
| `npm run start:dev` | arranca y se reinicia solo al guardar |
| `npm run start:prod` | corre el compilado de `dist/` |
| `npm run build` | compila TypeScript a `dist/` |
| `npm run lint` | revisa el codigo |
| `npm run format` | formatea el codigo |

Los scripts con nombre propio siempre llevan `run`. `npm start:dev` no existe.

## Errores comunes

**npm no corre en PowerShell**

```
npm : File C:\Program Files\nodejs\npm.ps1 cannot be loaded because
running scripts is disabled on this system.
```

Solucion:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
```

Comprobar con `Get-ExecutionPolicy -Scope CurrentUser`, debe decir
`RemoteSigned`.

**El puerto 3000 esta ocupado**

```
Error: listen EADDRINUSE: address already in use 0.0.0.0:3000
```

Solucion:

```powershell
Get-NetTCPConnection -LocalPort 3000 -State Listen |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
```

**El contenedor de PostgreSQL se reinicia en bucle**

```
Counter to that, there appears to be PostgreSQL data in:
/var/lib/postgresql/data (unused mount/volume)
```

PostgreSQL 18 cambio la ruta de los datos. El volumen va montado en
`/var/lib/postgresql`, no en `/var/lib/postgresql/data`. Ya esta corregido en el
`docker-compose.yml`; no revertirlo.

**pgAdmin no conecta**

Se puso `localhost` como host. Va `postgres`.
