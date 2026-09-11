# `ip_rotacion_cuenta` en Redis — el espejo corto que faltaba

**Fecha:** 2026-09-11, segunda ronda del día (después de
`2026-09-11_1002-toma-cuenta-patrones-lentos-elastic.md`).
**Alcance:** `backend/`. Catálogo `tipo_alerta_fraude` ampliado a 8 filas
(antes 7) + **una fila renombrada** — `.sql` de referencia aplicado en
local, la migración real la integra el compañero.

## Por qué

Al cerrar la ronda de Elasticsearch (toma de cuenta + patrones lentos), se
notó que tres de las cuatro señales retrospectivas tenían un espejo corto
en Redis ya existente y una no: `ip_rotacion_cuenta` (IPs distintas
probando una misma cuenta) nació directo en Elasticsearch, sin versión
corta. Esta ronda agrega esa versión corta a `FraudeLoginService` — el
mismo mecanismo que `multi_cuenta_ip`, con los roles invertidos.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `elementos Generales/plan pendiente/fraude-login-eventos.sql` | ampliado — `UPDATE` que renombra `ip_rotacion_cuenta` → `ip_rotacion_cuenta_lenta`, más 1 fila nueva `ip_rotacion_cuenta` (id 8). Reaplicado en local |
| `src/models/alerta-fraude.ts` | `ID_TIPO_ALERTA_FRAUDE_IP_ROTACION_CUENTA` (id 7) renombrada a `..._LENTA`; nueva `ID_TIPO_ALERTA_FRAUDE_IP_ROTACION_CUENTA` (id 8); `TipoAlertaFraude` con los 8 valores |
| `src/services/fraude-login/fraude-login-retrospectivo.service.ts` | usa el nuevo nombre de constante (`..._LENTA`) — sin cambio de comportamiento, solo el import |
| `src/services/fraude-login/fraude-login.service.ts` | + `revisarIpRotacionCuenta()`, llamada sin condición (igual que `revisarMultiCuentaIp`) desde `registrarIntento` |
| `src/dto/paginar-alertas-fraude.ts` | `TIPOS_ALERTA_FRAUDE_VALIDOS` con los 8 valores, en el orden del catálogo |

Documentación: `endpoints/endpoints-fraude.md` (tabla de señales, sección
"Qué llena cada columna", ejemplos de filtro `tipo`, prueba nueva) y
`plan pendiente/fraude-login-eventos.md` (punto 4, segunda ronda; sección
"Compañero" con el detalle del renombre).

### El catálogo: por qué el renombre y no una fila nueva con otro nombre

La alternativa más simple — dejar `ip_rotacion_cuenta` (id 7, Elasticsearch)
tal cual y llamar a la versión Redis `ip_rotacion_cuenta_rapida` o
similar — habría invertido el patrón establecido en las otras dos parejas
(`fuerza_bruta_cuenta`/`fuerza_bruta_cuenta_lenta`,
`multi_cuenta_ip`/`multi_cuenta_ip_lenta`, donde **sin sufijo = Redis** y
**`_lenta` = Elasticsearch**). Mantener esa asimetría habría sido confuso
para cualquiera que lea el catálogo más adelante. Como el módulo todavía no
tiene una migración real promovida (el compañero sigue con el `.sql` de
referencia pendiente de integrar) y las únicas filas afectadas eran datos
de prueba propios, se decidió renombrar la fila existente para mantener el
patrón consistente, en vez de acumular una excepción.

El `.sql` de referencia queda con un `UPDATE ... WHERE tipo_alerta_fraude_nombre
= 'ip_rotacion_cuenta'` **antes** del `INSERT`, idempotente (si ya se
corrió, o la tabla está vacía, no hace nada) — necesario para reconciliar
la base LOCAL que ya tenía la fila vieja. La migración real, sobre una
tabla vacía, no necesita ese paso: el `INSERT` de las 8 filas ya trae los
nombres finales.

### La detección — espejo invertido de `multi_cuenta_ip`

```ts
private async revisarIpRotacionCuenta(
  identificador: string | null,
  ip: string,
  idUsuario: string | null,
): Promise<void> {
  if (identificador == null) return;
  const clave = `mesh:fraude:ips_cuenta:${identificador}`;
  await redis.sadd(clave, ip);
  await redis.expire(clave, 300, 'NX');
  const ipsDistintas = await redis.scard(clave);
  if (ipsDistintas >= 4) { /* registrarAlerta(...) */ }
}
```

`multi_cuenta_ip` agrupa por IP y cuenta identificadores distintos;
`ip_rotacion_cuenta` agrupa por identificador y cuenta IPs distintas —
misma mecánica de Redis (`SADD` + `EXPIRE ... NX` + `SCARD`), mismos
números (300s, umbral 4, sin razón técnica para que cambien solo porque se
invirtieron los roles). Corre **sin importar si el intento falló o no**,
igual que `multi_cuenta_ip` — un acierto en medio de la rotación cuenta
igual para la señal.

## Probado en vivo — 2026-09-11

Como no se puede generar tráfico real desde varias IPs distintas en una
sola máquina, se sembraron 3 IPs previas directo en la clave de Redis (vía
`redis-cli SADD`+`EXPIRE`) y se dejó que un login real fuera la 4ª — así se
ejercitó el código real de punta a punta, solo el "historial previo" es
simulado.

| # | Caso | Resultado |
|---|---|---|
| 1 | `SADD` manual de 3 IPs (`198.18.0.1/2/3`) sobre `mesh:fraude:ips_cuenta:comprador.sur@mesh.com` + `EXPIRE 300` | `SCARD` → 3, no dispara nada (umbral 4) |
| 2 | Login real y exitoso de `comprador_sur`, desde `127.0.0.1` | `SADD` agrega la 4ª IP → `SCARD` → 4 (≥4) → alerta `ip_rotacion_cuenta` (id 24): `{"ips":["198.18.0.1","198.18.0.2","198.18.0.3","127.0.0.1"],"ips_distintas":4,"ventana_segundos":300}`, `cuenta_involucrada: {"id_usuario":"3","usuario":"comprador_sur"}` |
| 3 | `TTL` de la clave tras el login | 292 s — no se reinició a 300 (confirma `EXPIRE ... NX`: la clave ya tenía TTL puesto por el `SADD` manual del paso 1) |

`npx tsc --noEmit` y `eslint` limpios sobre todos los archivos tocados.

**Limpieza:** `DELETE FROM alerta_fraude WHERE id_alerta_fraude = 24` +
`redis-cli DEL mesh:fraude:ips_cuenta:comprador.sur@mesh.com`.

## Lo que no se hizo en esta ronda (y por qué)

- **Espejo lento de `fuerza_bruta_ip`.** Ahora es la única señal sin par —
  no se pidió agregarla en esta ronda. Sería el mismo molde que
  `fuerza_bruta_cuenta_lenta` cambiando el campo de agrupación a `ip.keyword`.
- **`PATCH` para marcar una alerta revisada/descartada.** Sigue sin
  construirse — no se pidió, se deja para cuando el frontend tenga la
  pantalla de triage.
- **Bloqueo o frenado del login.** Decisión explícita del usuario, vigente
  desde la primera ronda: el sistema solo alerta.

## Le toca al compañero (fuera de `backend/`)

Migración real con las 8 filas del catálogo en el orden final (sin
necesitar el `UPDATE` de renombre, que es solo para reconciliar la base
local). Ver la sección "Compañero" del plan.
