# Entrar a Mesh desde un celular, con VPN o sin ella

Sirve para abrir la tienda desde fuera de esta PC (un celular, otra red, alguien
con una VPN) y que su login salga en el panel del admin con **su** IP, no con
`127.0.0.1`. Todo lo hace `tunel-celular.ps1`, en la raiz.

## Como se corre

Con Docker arriba y las bases levantadas (`.\arrancar.ps1`):

```powershell
.\tunel-celular.ps1 -ConCopia     # hoy: la IP del celular sale en el panel
.\tunel-celular.ps1               # cuando Jose David ponga trustProxy
.\tunel-celular.ps1 -Cerrar       # cierra todo y deja el backend normal
```

Al terminar imprime un link `https://....trycloudflare.com`. Se abre en el
celular, se entra con cualquier cuenta y los intentos salen en el panel del
admin, pestana **Fraude**, seccion **Intentos de entrada sospechosos**. El link
cambia cada vez que se abre el tunel. Nada abre ventanas: el frontend, la copia
y el tunel corren ocultos hasta el `-Cerrar`.

La diferencia entre las dos formas es solo el backend:

| | Backend | IP que queda en Mongo, Elastic y `alerta_fraude` |
|---|---|---|
| `-ConCopia` | una copia de `backend/` fuera del repo, en el 3100, con `trustProxy: 'loopback'` | la del celular |
| sin nada | el `backend/` del repo, en el 3000 | `127.0.0.1` para todos, hasta que el backend lleve la linea |

Mientras corre la copia, el backend normal esta parado (los dos a la vez
duplicarian los `@Interval`). `-Cerrar` lo vuelve a levantar.

## Como funciona: un solo tunel, al frontend

```
celular --> Cloudflare --> cloudflared --> vite preview :5173 --> backend
                                             |  /api/... se pasa al backend
                                             |  lo demas es la pagina
```

- `frontend/src/lib/api.ts` ya no llama a `http://localhost:3000`. En el
  navegador pide a `/api` del mismo sitio que sirvio la pagina.
- `frontend/vite.config.ts` tiene el proxy: `/api/...` va al backend sin el
  `/api`. Sirve igual con `npm run dev` y con `vite preview`. El destino es el
  3000, o lo que diga la variable `MESH_BACKEND` (el script la pone en el 3100
  con `-ConCopia`).
- Como pagina y API salen de la misma direccion, **no hace falta CORS ni tocar
  la cookie de sesion**. Con dos tuneles (uno al frontend y otro al backend)
  harian falta las dos cosas en `backend/`, y la cookie tendria que pasar a
  `sameSite: 'none'` y `secure`.
- `allowedHosts: ['.trycloudflare.com']` en el mismo archivo. Sin eso vite
  contesta "Blocked request" a todo lo que llega por el tunel.

En esta PC todo sigue igual: `http://localhost:5173`, `npm run dev`, los
arneses de `pruebas/` (esos le hablan directo al 3000 y no pasan por el proxy).

## Lo que se midio el 2026-09-15

Con `-ConCopia`, desde un contenedor de Tor que hacia de celular en Holanda
(`192.42.116.59`), por el link del tunel:

- Un login fallido que ademas mandaba `X-Forwarded-For: 1.2.3.4` quedo en Mongo
  con `192.42.116.59`. La IP inventada no se la creyo nadie.
- 8 fallos con 4 correos distintos dejaron `fuerza_bruta_ip` y `multi_cuenta_ip`,
  las dos con clave `192.42.116.59`.
- Un login bueno como admin, y despues `/usuario/yo` con la cookie, contesto
  "Sesion activa".
- Un Chrome con pantalla de celular (390x844) entro por el formulario, llego a
  `/panel` y abrio la pestana Fraude. `document.cookie` salio vacio porque la
  cookie es `httpOnly`, y aun asi `/usuario/yo`, `/perfil`, `/carrito` y
  `/admin/fraude/alertas-login` dieron 200. `/admin/fraude/anillos` dio 503
  porque Neo4j estaba parado a proposito, para ahorrar memoria.

Sin `-ConCopia`, el mismo login por el tunel quedo como `127.0.0.1`.

## Si algo falla

- **"Docker no responde"** o **"Los contenedores de Mesh no estan arriba"**:
  Docker Desktop y despues `.\arrancar.ps1`.
- **El link no abre en la red de la U**: esa red bloquea los tuneles. Con la VPN
  del celular encendida, o con datos moviles, si entra.
- **"El frontend no compilo"**: el log esta en `%TEMP%\mesh-demo\front-build.log`.
  Los demas logs (`front.err`, `backend.err`, `tunel-celular.err`) estan en la
  misma carpeta.
- **Habia algo corriendo en el 5173** (un `npm run dev`): el script lo cierra,
  porque el frontend que va por el tunel tiene que ser el compilado. Despues
  del `-Cerrar` se vuelve a abrir a mano.
- **Con Tor, la IP que da ipify no es la que queda en el panel.** Un nodo de Tor
  puede salir por varias IPs. Paso dos veces el mismo dia (`203.55.81.1` contra
  `203.55.81.2`). La que vale es la que registro el backend.

Lo que le toca al backend para no depender de la copia esta en
`docs/BACKEND-PENDIENTE.md`, arriba de todo.
