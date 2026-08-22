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

Si la PC ya tiene PostgreSQL instalado, hay que detener su servicio antes de
empezar. Usa el puerto 5432 y se pelea con el contenedor. En PowerShell como
administrador:

```powershell
Get-Service postgresql* | Stop-Service -Force
Get-Service postgresql* | Set-Service -StartupType Manual
```

Lo segundo es para que no vuelva solo al reiniciar la PC. Si hace falta para otra
clase, se levanta a mano con `Start-Service postgresql*`.

Esto no da un error claro y cuesta encontrarlo. Esta explicado abajo, en
"El backend dice que la contrasena esta mal".

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
| MongoDB | mesh-mongo | mongo:8 | 27018 |
| DbGate | mesh-dbgate | dbgate/dbgate:latest | 3001 |

Apagar todo:

```bash
docker compose down
```

Con `-v` ademas borra los datos de la base.

La carpeta `migrations/` esta montada dentro del contenedor de PostgreSQL en
`/migrations`, para poder correr los scripts sin copiarlos a mano.

Lo mismo con `mongo/`, montada en el contenedor de MongoDB en `/mongo`. Ahi van
los scripts que crean las colecciones.

## Accesos de desarrollo

| Servicio | Usuario | Contrasena |
|---|---|---|
| PostgreSQL | `DB_USER` del .env | `DB_PASSWORD` del .env |
| pgAdmin | `PGADMIN_EMAIL` del .env | `PGADMIN_PASSWORD` del .env |
| MongoDB | `MONGO_USER` del .env | `MONGO_PASSWORD` del .env |
| DbGate | entra directo, sin usuario | |

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

**Compass o el backend ven una base de Mongo vacia y sin contrasena**

Windows puede tener un MongoDB instalado como servicio, y ese ya ocupa el
27017. Los dos pueden escuchar a la vez sin dar ningun error, pero el que
contesta en `localhost` es el de Windows: Compass conecta, no pide contrasena, y
ensena una base que no es la del proyecto.

Por eso el contenedor publica el **27018**, no el 27017. La cadena de conexion
del proyecto es:

```
mongodb://<MONGO_USER>:<MONGO_PASSWORD>@localhost:27018/mesh?authSource=admin
```

Para saber con cual estas hablando, mira la version y si te pide contrasena:

```bash
docker exec mesh-mongo mongosh --quiet --eval "db.adminCommand({buildInfo:1}).version"
```

Si una conexion no pide contrasena, no es la del proyecto.

Dentro de la red de Docker no cambia nada: DbGate y cualquier otro contenedor
siguen usando `mongo:27017`.


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

**El backend dice que la contrasena esta mal**

```
ERROR [BaseDatosService] 28P01: la autentificacion password fallo para el usuario "meme"
```

Casi siempre es una de estas tres, en este orden.

*Hay otro PostgreSQL escuchando en el 5432.* Es la mas dificil de ver, porque
todo lo demas funciona: el contenedor arranca, las migraciones corren y
`docker exec ... psql` entra sin problema. Pasa que el PostgreSQL instalado en
Windows se ata a `127.0.0.1` y el contenedor a `0.0.0.0`; cuando el backend pide
`localhost`, Windows le da el mas especifico, o sea el nativo. El backend nunca
llega al contenedor. Se ve asi:

```powershell
Get-NetTCPConnection -LocalPort 5432 -State Listen |
  ForEach-Object { Get-Process -Id $_.OwningProcess } |
  Select-Object -Unique Id, ProcessName
```

Si ademas de `com.docker.backend` aparece `postgres`, es eso. Se detiene el
servicio con los comandos del inicio de este archivo.

Para confirmarlo, este comando sale al 5432 del host igual que el backend:

```powershell
$p = (Get-Content backend\.env | Select-String '^DB_PASSWORD=').ToString().Split('=')[1]
docker exec -e PGPASSWORD=$p mesh-postgres psql -h host.docker.internal -p 5432 -U meme -d mesh -c "select current_database();"
```

Tiene que responder `mesh`. Si da 28P01, esta llegando a otro servidor.

Ojo con el mensaje: PostgreSQL responde "password fallo" **tambien cuando el
usuario no existe**, a proposito, para no delatar que usuarios tiene. Asi que
28P01 no significa que la contrasena este mal; significa que ese servidor no te
deja entrar.

*Los dos .env no dicen lo mismo.* Son dos archivos: el de la raiz crea la base y
`backend/.env` es con el que la API se conecta. Se comprueba sin ensenar la
contrasena:

```powershell
$a = (Get-Content .env         | Select-String '^DB_PASSWORD=').ToString()
$b = (Get-Content backend\.env | Select-String '^DB_PASSWORD=').ToString()
if ($a -eq $b) { "COINCIDEN" } else { "NO COINCIDEN" }
```

*El backend quedo con el valor viejo en memoria.* `npm run start:dev` se
reinicia al guardar un `.ts`, pero no al cambiar el `.env`. Despues de editarlo
hay que cortar con Ctrl+C y volver a levantarlo.

**En pgAdmin no aparece ningun servidor**

pgAdmin lee `servers.json` una sola vez, cuando crea su base de configuracion en
el volumen `pgadmin-data`. Si el volumen ya existe, `arrancar.ps1` regenera el
archivo pero pgAdmin ni lo mira. Para que un cambio surta efecto hay que recrear
ese volumen:

```powershell
docker compose rm -sf pgadmin
docker volume rm proyecto-tienda-base-datos-2_pgadmin-data
docker compose up -d pgadmin
```

Primero `.\arrancar.ps1`, que regenera el `servers.json`, y despues el borrado.
Al reves no sirve. Esto no toca la base de datos: el volumen de pgAdmin solo
guarda sus preferencias.

Para ver si lo cargo bien:

```powershell
docker logs mesh-pgadmin | Select-String "Loading servers", "servers.json"
```

**En pgAdmin no se ven las tablas**

Estan en la base `mesh`, en `Databases > mesh > Schemas > public > Tables`. La
base `postgres`, que es la que pgAdmin abre por defecto, esta vacia de verdad.

**pgAdmin no conecta**

Se puso `localhost` como host. Va `postgres`.
