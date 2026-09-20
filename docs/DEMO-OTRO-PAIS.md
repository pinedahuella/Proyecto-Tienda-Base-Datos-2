# Demostrar el fraude del login con una IP de otro pais

Sirve para ensenar que los detectores de `FraudeLoginService` funcionan con IPs
reales, no solo con `127.0.0.1`. Todo lo hace `demo-fraude-pais.ps1`, en la raiz.

## Como se corre

Con Docker arriba y el sistema levantado (`.\arrancar.ps1`, backend en 3000 y
frontend en 5173):

```powershell
.\demo-fraude-pais.ps1 -Pais sg
```

Paises: sg (Singapur), de (Alemania), jp (Japon), us (EE.UU.), nl (Holanda),
fr (Francia), gb (Reino Unido), ca (Canada).

Al terminar imprime un link. Se abre y se entra como `admin@mesh.com` /
`Admin123`, pestana **Fraude**, seccion **Intentos de entrada sospechosos**.
Ahi sale la alerta con la IP del pais elegido:

```
http://localhost:5173/panel?s=fraude
```

Manda 8 intentos fallidos con 4 correos distintos, asi que aparecen dos
alertas de esa IP: "muchos intentos desde una IP" y "muchos correos desde una
IP".

## Precalentar, para que en clase no tarde

Lo lento no se ve y se puede hacer antes:

```powershell
.\demo-fraude-pais.ps1 -Precalentar -Pais sg
```

Comprueba que el tunel pueda salir, construye UNA vez la imagen de Tor
(`mesh-tor-demo:local`, unos 60 MB; antes cada corrida instalaba `tor` y `curl`
en un alpine pelado, delante de todos), compila la copia del backend y deja Tor
corriendo con salida en el pais, comprobada. No para el backend ni pausa
ClickHouse y Neo4j: eso sigue siendo de la demo. Tor caliente pesa unos 50 MB y se
suelta con `docker rm -f mesh-tor-demo`.

La demo lo detecta sola: si hay un Tor corriendo con la etiqueta del mismo pais lo
reutiliza, y si es de otro pais lo rehace. Sin precalentar sigue funcionando igual,
solo que mas lento. Desde el panel de comandos es el boton "Precalentar la demo de
otro pais".

Medido el 2026-09-20 en esta maquina: precalentado completo en frio, con Tor
fallando una vez sin causa conocida (a mano arranca en 16 s); con la imagen y la
copia ya hechas, 7 s. La demo entera con Tor caliente tardo 226 s, y ahora cada paso
imprime a los cuantos segundos empezo, para ver donde se va lo que queda. Lo que
queda es sobre todo arrancar la copia en el 3100, abrir el tunel y volver a levantar
el backend normal: eso no se puede precalentar, porque la copia y el backend normal no
pueden correr a la vez (duplicarian los `@Interval`).

## La red de la U bloquea el tunel

`cloudflared` sale siempre por el puerto 7844 y el firewall de la U lo bloquea por
puerto (el sintoma es "El tunel no levanto"). La salida es la misma que en LEDKID:
WARP, el cliente de Cloudflare, en modo MASQUE, que lo mete dentro de HTTPS.

`demo-fraude-pais.ps1` y `tunel-celular.ps1` llaman ahora a `Asegurar-SalidaTunel`
(en `copia-backend.ps1`). Prueba el 7844 y solo si esta cerrado usa WARP: si no esta
conectado corre `warp-cli tunnel protocol set MASQUE` y `warp-cli connect`. Si WARP
YA esta conectado no lo toca, porque el tunel de LEDKID cuelga de el. Sin WARP
instalado avisa y sigue, y el tunel dira si subio.

Probado: con el 7844 libre (WARP conectado, en esta maquina) no cambia nada, y el
camino de "puerto cerrado" devuelve falso. **NO probado desde la red de la U**: el
camino que conecta WARP no se ha ejecutado de verdad.

## Que hace por dentro, en cuatro pasos

1. Levanta **Tor** en un contenedor con salida en el pais elegido, y pide
   circuitos hasta que la IP de verdad geolocaliza ahi. El pais se pregunta
   desde la PC y no por Tor, porque ipinfo contesta 403 a los nodos de Tor.
2. Hace una **copia de `backend/` fuera del repo** con una sola linea cambiada
   (`new FastifyAdapter({ trustProxy: 'loopback' })`) y la corre en el puerto
   3100. El repo NO se toca. La copia la arma `copia-backend.ps1`, el mismo que
   usa `tunel-celular.ps1`.
3. Abre un **tunel rapido de Cloudflare** a esa copia.
4. Manda los intentos desde el pais por el tunel y **comprueba en las bases**
   que quedaron: lee de Mongo con que IP los registro el backend y busca sus
   alertas en `alerta_fraude`. Si no estan, lo dice y sale con error. Despues
   cierra el tunel y la copia y vuelve a levantar el backend normal en 3000.

La IP que se ensena al final es la que registro el backend, y puede no ser la
que dio ipify: un nodo de Tor sale a veces por varias IPs. El 2026-09-15 ipify
vio `192.210.214.13` y el backend registro `204.8.96.78`, las dos de EE. UU.

**Hasta el 2026-09-15 el script no funcionaba** y decia que si. PowerShell 5.1
le quita las comillas dobles a los argumentos de `docker`, asi que el JSON del
login llegaba como `{identificador:demo.sg1@mesh.test,...}`, el backend
contestaba 400 y ningun intento contaba. Ahora el cuerpo viaja en base64, y
la comprobacion del paso 4 es la que lo habria delatado.

La alerta se queda en el panel para ensenarla. Cuando ya no haga falta:

```powershell
.\demo-fraude-pais.ps1 -Limpiar
```

Borra las alertas de esas IPs en Postgres y los eventos en Mongo y en
Elasticsearch. Encuentra todo por el user-agent `mesh-demo-pais`, que la demo
pone en cada intento.

La copia del backend queda en `%TEMP%\mesh-demo` y se reutiliza. Si `backend/`
cambio despues (un pull de Jose David), el script la rehace solo.

## Por que `trustProxy`, y por que `'loopback'`

Sin `trustProxy`, detras de un tunel o un proxy TODO llega como la IP de la
maquina (`127.0.0.1`), porque el tunel se conecta desde el mismo equipo. Con la
copia se ve el caso real; el backend del repo sigue sin esa linea hasta que
Jose David la ponga. Esta pedida en `docs/BACKEND-PENDIENTE.md`, arriba del
todo, y es lo unico que le falta al backend.

`'loopback'` y no `true`: con `true` el backend se queda con la IP que el
cliente escriba en `X-Forwarded-For`, aunque entre por el tunel, porque
Cloudflare no borra esa cabecera sino que le agrega la IP real al final. Con
`'loopback'` solo se cree lo que llega de esta maquina. Esta medido en
`BACKEND-PENDIENTE.md`.

Para que una persona entre desde su celular (con VPN o sin ella) y su login
salga con su IP ya no falta nada de nuestro lado: ver
`docs/ENTRAR-DESDE-EL-CELULAR.md`.

## Si algo falla

- **"Docker no responde"**: abre Docker Desktop y espera a que arranque.
- **"Los contenedores de Mesh no estan arriba"**: corre `.\arrancar.ps1`.
- **"No consegui una salida en X"**: ese pais tiene pocos nodos de salida en
  Tor ese dia. Prueba con otro (de y nl casi siempre andan).
- El tunel rapido de Cloudflare tarda unos segundos en responder; el script ya
  espera por el.
