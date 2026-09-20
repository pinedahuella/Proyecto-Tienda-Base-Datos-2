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

Manda 8 intentos fallidos con 4 correos distintos, asi que aparecen alertas de esa
IP: "muchos intentos desde una IP" y "muchos correos desde una IP". Un nodo de Tor a
veces sale por dos IPs distintas y los 8 intentos se reparten; entonces puede salir
solo la de correos (paso el 2026-09-20 en una corrida, y la siguiente dio las dos).

**Mesh sigue en pie todo el rato.** La demo no para el backend, ni ClickHouse, ni Neo4j.
El tunel va directo al backend real en el 3000, y por eso ese backend tiene que estar
arriba antes de empezar (en el panel de comandos, "Reiniciar el backend").

## Entrar tu mismo desde otro pais, con el frontend de verdad

`demo-fraude-pais.ps1` manda intentos con curl. Para iniciar sesion TU MISMO desde
otro pais, con la tienda real y su formulario, esta `demo-entrar-otro-pais.ps1`. En
el panel de comandos son tres botones de "Demos de fraude": Entrar a Mesh desde otro
pais, Ver desde donde salgo y Cerrar la ventana de otro pais.

```powershell
.\demo-entrar-otro-pais.ps1 -Pais sg     # abre una ventana de Chrome que sale por Singapur
.\demo-entrar-otro-pais.ps1 -Estado      # desde donde sales, y que sigue abierto
.\demo-entrar-otro-pais.ps1 -Cerrar      # cierra la ventana, el tunel y Tor
```

Como funciona: Tor en Docker con salida en el pais (`mesh-tor-demo`, con su SOCKS
publicado solo en `127.0.0.1:9051`), un tunel de Cloudflare a la tienda (el 5173, que
le pasa `/api` al backend con la IP de quien llego) y un Chrome con perfil aparte y
limpio que usa ese Tor como proxy SOCKS5. Para la tienda esa ventana esta en otro
pais; tus otras ventanas no cambian. Chrome manda los nombres de host al proxy, asi
que el DNS tambien sale por Tor.

Como se ve que es real, en Docker:

```powershell
docker ps --filter name=mesh-tor-demo
docker exec mesh-tor-demo curl -s --socks5-hostname 127.0.0.1:9050 https://api.ipify.org
```

**Para la alerta de viaje imposible** hacen falta DOS logins exitosos de la MISMA
cuenta, desde paises distintos y con poco tiempo en medio (mas de 800 km/h implicitos).
Un login desde tu casa no cuenta: `127.0.0.1` no tiene pais. Entra con la cuenta en la
ventana de un pais, corre el comando otra vez con otro pais (cierra la ventana anterior
y abre otra, con la sesion limpia) y entra con la misma cuenta.

Probado el 2026-09-20 con `desarrollador2@mesh.com`: login desde Singapur, luego desde
Alemania y luego otra vez desde Singapur, todo con el formulario real a traves de Tor y
del tunel. El backend registro cada login con la IP y el pais de la salida
(`geo_pais` SG y DE) y salto `viaje_imposible` (9943 km, 0.19 h, 52 550 km/h,
Brandenburg a Singapur) y `toma_cuenta` (IP nueva para la cuenta). La alerta de viaje
imposible NO saltaba antes de este cambio: ver `elastic/README.md`, "Los `.keyword` de
la version 2". Las alertas de esa cuenta se quedan para ensenarlas; no las borra
`-Limpiar` (ese borra por el user-agent de la demo de curl).

Limites: la salida de Tor cambia de IP dentro del pais (mismo pais, otra IP), y un login
desde Tor puede ir lento. Cada pais es un Tor: para cambiar de pais se rehace el
contenedor, unos 50 segundos con el tunel ya abierto.

## El link con el nombre del pais, para abrirlo en cualquier navegador

`https://mesh-singapur.ledkid.com`, `mesh-alemania`, `mesh-japon`, `mesh-eeuu`,
`mesh-holanda`, `mesh-francia`, `mesh-reinounido` y `mesh-canada`, todos en
`.ledkid.com`. Es la tienda real, pero cualquier persona que abra el link de un pais
aparece para el backend en ESE pais, sin instalar nada y desde el navegador o el celular
que quiera. Lo dan los dos botones: **Login desde otro pais** (al final de la demo con
curl) y **Entrar a Mesh desde otro pais**. Se cierra con **Cerrar la ventana de otro pais**
o `.\demo-entrar-otro-pais.ps1 -Cerrar`.

Como funciona: `panel-comandos/pais-proxy.mjs` recibe lo que llega a ese nombre y lo
reenvia a `https://mesh.ledkid.com` SALIENDO POR TOR del pais (SOCKS5 en
`127.0.0.1:9051`, el Tor de Docker). Para el backend, la IP es la de la salida de Tor y su
pais sale de geoip. No reenvia quien es el visitante (`X-Forwarded-For`, `CF-*`), porque
si lo hiciera el backend veria la IP real de quien abre el link. Solo reenvia a
`mesh.ledkid.com`, solo contesta al nombre de SU pais y solo escucha en `127.0.0.1`;
llega hasta el por el tunel `mesh`.

Probado el 2026-09-20 con un Chrome normal, sin proxy y con la IP real de esta maquina:
login por el link de Singapur y luego por el de Alemania, con la misma cuenta. El backend
registro `SG` y despues `DE`, y salto `viaje_imposible` (9933 km en 0.02 h) y
`toma_cuenta`. La IP real del visitante no aparece en ningun registro.

Lo que hay que saber:
- **Es mas lento** que la tienda normal, porque cada conexion nueva pasa por Tor.
- **Necesita la direccion publica abierta** (`mesh.ledkid.com`): el proxy le habla a ella.
  Si esta cerrada, el link la abre. Publicar Mesh es publicarlo con sus cuentas de prueba.
- **Uno a la vez**: hay un solo Tor, asi que solo esta abierto el link del ultimo pais que
  se pidio. Los otros nombres contestan 502 mientras no esten abiertos.
- **Se prepara UNA vez** por cuenta de Cloudflare: `.\mesh-publico.ps1 -Accion paises`
  agrega un registro DNS nuevo por pais en `ledkid.com` (solo altas, no cambia ninguno
  existente) y los nombres al ingress del tunel `mesh`. El tunel de LEDKID no se toca.
- Los nombres son de un solo nivel (`mesh-singapur.ledkid.com`, no
  `singapur.mesh.ledkid.com`): el certificado gratuito de Cloudflare cubre `*.ledkid.com`
  y no los de dos niveles.

## Precalentar, para que en clase no tarde

Lo lento no se ve y se puede hacer antes:

```powershell
.\demo-fraude-pais.ps1 -Precalentar -Pais sg
```

Comprueba que el tunel pueda salir, construye UNA vez la imagen de Tor
(`mesh-tor-demo:local`, unos 60 MB; antes cada corrida instalaba `tor` y `curl`
en un alpine pelado, delante de todos) y deja Tor corriendo con salida en el pais,
comprobada. Tor caliente pesa unos 50 MB y se suelta con
`docker rm -f mesh-tor-demo`.

La demo lo detecta sola: si hay un Tor corriendo con la etiqueta del mismo pais lo
reutiliza, y si es de otro pais lo rehace. Sin precalentar sigue funcionando igual,
solo que mas lento. Desde el panel de comandos es el boton "Precalentar la demo de
otro pais".

Medido el 2026-09-20 en esta maquina, con cada paso cronometrado (la demo imprime a
los cuantos segundos empieza cada paso):

| Version | Total | Mesh |
|---|---|---|
| Con copia del backend en el 3100, Tor caliente | 226 s | backend, ClickHouse y Neo4j caidos casi todo el rato |
| Tunel al backend real, Tor sin precalentar (con la imagen ya construida) | 90 s | siempre en pie, 44 de 44 muestras con 200 |
| Lo mismo, con Tor precalentado (el precalentado tarda 23 s) | 72 s | siempre en pie, 35 de 35 muestras con 200 |

En la version con copia, 96 s se iban en arrancar la copia (60 s hasta el primer log
de Node y 35 s conectando a los servicios), y despues venia devolver el backend
normal, que no se midio por separado. Ese era el costo de tener dos backends, y ya no
existe. En la corrida de 90 s, Tor tardo 25 s en arrancar y dar una salida en el
pais; con Tor caliente ese paso tarda 4 s. Lo que queda en los 72 s es abrir el tunel
(unos 33 s) y mandar los 8 intentos por Tor (unos 30 s), y eso no se precalienta.

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
2. Comprueba que el **backend real** conteste en el 3000. No lo para ni lo copia.
3. Abre un **tunel rapido de Cloudflare** a ese backend.
4. Manda los intentos desde el pais por el tunel y **comprueba en las bases**
   que quedaron: lee de Mongo con que IP los registro el backend y busca sus
   alertas en `alerta_fraude`. Si no estan, lo dice y sale con error. Si la IP
   registrada es `127.0.0.1`, dice que el backend que corre es de antes del
   `trustProxy` y que hay que reiniciarlo. Despues cierra el tunel y Tor.

`-ConCopia` deja el camino viejo (una copia del backend en el 3100 con `trustProxy`,
pausando ClickHouse y Neo4j y parando el backend real un rato), por si algun dia
corre un backend sin esa linea.

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

Con `-ConCopia`, la copia del backend queda en `%TEMP%\mesh-demo` y se reutiliza. Si
`backend/` cambio despues (un pull de Jose David), el script la rehace solo.

## Por que `trustProxy`, y por que `'loopback'`

Sin `trustProxy`, detras de un tunel o un proxy TODO llega como la IP de la
maquina (`127.0.0.1`), porque el tunel se conecta desde el mismo equipo. Jose David
lo agrego a `backend/src/main.ts` el 2026-09-18, y por eso la demo ya no necesita
una copia. Antes hacia falta: `docs/BACKEND-PENDIENTE.md` lo pedia arriba del todo.
Un backend que se compilo antes de ese cambio sigue registrando `127.0.0.1`, y la
demo lo avisa.

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
