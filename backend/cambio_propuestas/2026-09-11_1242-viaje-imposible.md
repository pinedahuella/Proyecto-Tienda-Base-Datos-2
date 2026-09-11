# Viaje imposible — geolocalización con `geoip-lite` en el camino del login

**Fecha:** 2026-09-11, tercera ronda del día (después de
`2026-09-11_1002-toma-cuenta-patrones-lentos-elastic.md` y
`2026-09-11_1045-ip-rotacion-cuenta-redis.md`).
**Alcance:** `backend/`. Catálogo `tipo_alerta_fraude` ampliado a 9 filas
(antes 8). Mapping de Elasticsearch aplicado directo al índice local —
la versión oficial (carpeta `elastic/`, fuera de `backend/`) queda para el
compañero.

## Decisiones tomadas en esta ronda (confirmadas por el usuario antes de codear)

1. **`geoip-lite` como fuente definitiva de geolocalización** (punto 2 del
   plan) — ya se había validado en una sesión anterior contra IPs públicas
   reales (incluida la IP de prueba oficial de MaxMind, para confirmar
   precisión, y la IP real del usuario). Cierra la decisión pendiente.
2. **Se geolocaliza en el propio camino del login, no en un worker
   aparte.** `geoip-lite` es una búsqueda 100% en memoria (la base viene
   empaquetada con la librería, sin llamada de red), del orden de
   microsegundos — no vale la pena la complejidad de diferirlo. Decisión
   explícita: "un par de ms más en el login no me parece tan mal".
3. **Umbral: 800 km/h** (no 900) — más rápido que un vuelo comercial, con
   margen.
4. **Dispara en cada login exitoso**, comparando contra el login exitoso
   inmediatamente anterior — no en el worker de 15 min.
5. **Un tipo de alerta nuevo**, no reutiliza ninguno existente.
6. **La limitación de falsos positivos por VPN se acepta explícitamente** —
   y además es la única forma práctica de demostrar el patrón en la demo
   sin depender de gente real en países distintos.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `elementos Generales/plan pendiente/fraude-login-eventos.sql` | ampliado — 1 fila nueva `viaje_imposible` (id 9). Reaplicado en local |
| `src/models/alerta-fraude.ts` | + `ID_TIPO_ALERTA_FRAUDE_VIAJE_IMPOSIBLE` (id 9), `TipoAlertaFraude` con 9 valores |
| `src/dto/paginar-alertas-fraude.ts` | `TIPOS_ALERTA_FRAUDE_VALIDOS` con los 9 valores |
| `src/helpers/contexto-peticion.ts` | + `GeoUbicacion`, + `geolocalizarIp()` (usa `geoip-lite`), `ContextoPeticion.geo` nuevo, calculado en cada petición |
| `src/models/evento-autenticacion.ts` | + `GeoEvento`, campo `geo` en `EventoAutenticacion` |
| `src/services/log.service.ts` | guarda `contexto.geo` en el documento de Mongo |
| `src/services/eventos-autenticacion/documento-elastic.ts` | traduce `geo` (Mongo) a `geo_punto`/`geo_pais`/`geo_ciudad` (Elasticsearch) — ver el bug real, abajo |
| `src/services/fraude-login/viaje-imposible.service.ts` | **nuevo** — `ViajeImposibleService` |
| `src/controllers/usuario.controller.ts` | llama `viajeImposibleService.revisarLogin(...)` sin `await`, junto a `tomaCuentaService`, solo en éxito |
| `src/app.module.ts` | registra `ViajeImposibleService` |

Instalado en una sesión anterior: `geoip-lite@1.4.10` + `@types/geoip-lite`
(ya en `package.json`). Documentación: `endpoints/endpoints-fraude.md`
(tabla de señales, sección de geolocalización, prueba nueva) y
`plan pendiente/fraude-login-eventos.md` (puntos 2 y 3 marcados HECHO,
sección "Compañero" con el mapping correcto).

### Bug real encontrado y corregido: `geo_point` no acepta campos extra

El primer intento guardaba `geo: { lat, lon, pais, ciudad }` como un solo
objeto, mapeado en Elasticsearch como `geo_point`. **Un campo `geo_point`
de Elasticsearch SOLO acepta `lat`/`lon`** (o la forma GeoJSON
`type`/`coordinates`) — nada más. El primer documento de prueba con ese
campo falló al indexar con
`document_parsing_exception: field [pais] not supported: must be one of:
lon, lat, z, type, coordinates`, y el worker de sync
(`EventosAutenticacionSyncService`) se quedó reintentando en silencio cada
5 s sin lograrlo nunca — el diseño de "nunca tumba nada" funcionó
exactamente como debía, pero eso mismo escondió el problema hasta que se
revisaron los logs a mano.

**Corrección:** aplanar el dato en tres campos sueltos en el índice --
`geo_punto` (el `geo_point` real, solo `lat`/`lon`), `geo_pais`,
`geo_ciudad` (texto plano, mapping dinámico, sin declarar explícito). En
MongoDB no hace falta el mismo aplanamiento — Mongo no tiene esa
restricción, así que `evento-autenticacion.ts` sigue guardando `geo`
como un objeto natural (`{lat, lon, pais, ciudad}`); el aplanamiento pasa
solo en la traducción hacia Elasticsearch (`documento-elastic.ts`), que ya
es el punto exacto del código responsable de esa traducción.

El campo `geo` (el mapping viejo, `geo_point`, sin datos nunca) quedó
abandonado en el índice — Elasticsearch no permite borrar un campo de un
mapping. Inofensivo, pero si alguien ve `geo` en el mapping sin datos, es
por esto; el campo real y vivo es `geo_punto`.

### El mapping explícito, aplicado directo al índice local

```
PUT mesh_eventos_autenticacion/_mapping
{ "properties": { "geo_punto": { "type": "geo_point" } } }
```

Mismo patrón que el `.sql` de referencia sobre Postgres: se aplica directo
para poder desarrollar y probar en local; la versión oficial le toca al
compañero, en la carpeta `elastic/` (fuera de `backend/`), integrada junto
con el resto del mapping explícito que ya estaba pendiente (`keyword` para
los campos de texto, `date` para `fecha`).

### La detección — comparación puntual, no una ventana

```ts
async revisarLogin(datos: { idUsuario, identificador, geo, fecha }) {
  if (datos.geo == null || datos.identificador == null) return;

  // ultimo login exitoso de la cuenta CON geo conocida
  const anterior = await elasticClient.search({
    query: { bool: { filter: [
      { term: { 'id_usuario.keyword': datos.idUsuario } },
      { term: { 'tipo.keyword': 'login' } },
      { term: { 'resultado.keyword': 'exito' } },
      { exists: { field: 'geo_punto' } },
    ]}},
    sort: [{ fecha: 'desc' }], size: 1,
  });
  if (!anterior) return; // primer login con geo de esta cuenta

  const horas = (datos.fecha - fechaAnterior) / 3_600_000;
  const km = haversine(anterior.geo, datos.geo);
  const kmh = km / horas;
  if (kmh >= 800) { /* registrarAlertaFraude(...) */ }
}
```

`toma_cuenta` y `viaje_imposible` comparten la forma (ambos disparan en
login exitoso, ambos consultan el historial en vez de contar contra un
umbral en una ventana), pero preguntan cosas distintas: `toma_cuenta`
pregunta "¿esta IP apareció ALGUNA VEZ en el historial?" (un `terms` sobre
todo el pasado); `viaje_imposible` pregunta "¿el login INMEDIATAMENTE
ANTERIOR implica una velocidad imposible?" (un `sort desc size 1`, sin
agregación). Por eso `viaje_imposible` es un servicio aparte, no un método
más de `TomaCuentaService`.

## Probado en vivo — 2026-09-11

Desde esta máquina solo hay IPs privadas disponibles (nunca geolocalizan),
así que ni un login real propio sirve para ejercitar el lado "login
actual" del patrón. Se probó `ViajeImposibleService` **directo, con
`ts-node`, sin pasar por HTTP** — es una clase sin dependencias de
inyección de Nest (`elasticClient`/`pool` se importan directo, no vía
constructor), así que `new ViajeImposibleService().revisarLogin(...)`
ejercita el código real (consulta real a Elasticsearch, UPSERT real en
Postgres), solo sin la capa HTTP encima. Script en el scratchpad, no en el
repo.

El "login anterior" se sembró en Mongo con geolocalización real (Londres,
la misma IP de prueba de MaxMind ya validada en la sesión de `geoip-lite`)
y se esperó su indexado real por `EventosAutenticacionSyncService`.

| # | Caso | Resultado |
|---|---|---|
| 1 | Login "anterior" sembrado: Londres, hace 5 min (antes de la corrección del bug) | falló al indexar, `document_parsing_exception` — confirmó el bug |
| 2 | Mismo documento, tras aplanar `geo_punto`/`geo_pais`/`geo_ciudad` | indexado correcto: `geo_punto: {"lat":51.753,"lon":-0.3256}`, `geo_pais:"GB"`, `geo_ciudad:"St Albans"` |
| 3 | `revisarLogin()` real: cuenta `comprador_sur`, geo actual = Guatemala City (coordenadas reales), `fecha` = ahora | alerta `viaje_imposible` (id 25): `distancia_km: 8748`, `horas_transcurridas: 0.14`, `velocidad_kmh: 63158` — coincide exacto con la distancia Guatemala↔Londres ya calculada en la prueba de viabilidad de `geoip-lite` |
| 4 | Mismo par de coordenadas, `fecha` 20h después (un vuelo real) | **no** nace una segunda alerta — `437 km/h` implícitos, bajo el umbral de 800 |
| 5 | `GET /admin/fraude/alertas-login?tipo=viaje_imposible` (sesión admin real) | `200`, exactamente la alerta del caso 3, con las dos ubicaciones completas en `detalle` |

`npx tsc --noEmit` y `eslint` limpios sobre todos los archivos tocados.

**Limpieza:** `DELETE FROM alerta_fraude` de la fila de prueba (id 25) +
el documento sintético de `eventos_autenticacion` (Mongo, por
`ip: 81.2.69.142`) y su réplica en Elasticsearch (`_delete_by_query`).

## Lo que no se hizo en esta ronda (y por qué)

- **Panel de exploración manual** (punto 3 del plan) — no se pidió.
- **`PATCH` para marcar una alerta revisada/descartada** — sigue sin
  construirse, se deja para cuando el frontend tenga la pantalla de
  triage.
- **Bloqueo o frenado del login** — decisión explícita del usuario, vigente
  desde la primera ronda: el sistema solo alerta.
- **Mapping explícito del lado oficial (`elastic/`)** — se aplicó directo
  al índice local para poder desarrollar; la integración formal le toca al
  compañero.

## Le toca al compañero (fuera de `backend/`)

Migración real con la 9ª fila del catálogo, y el mapping explícito de
`mesh_eventos_autenticacion` (incluyendo `geo_punto` como `geo_point`,
**sin** anidar `geo_pais`/`geo_ciudad` dentro de ese mismo campo). Ver la
sección "Compañero" del plan, con el detalle exacto de la forma que evita
repetir el bug de esta ronda.
