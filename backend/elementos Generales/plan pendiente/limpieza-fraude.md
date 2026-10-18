# Limpieza del sistema de fraude (2026-10-17)

Revisión de las señales de fraude y del agrupador de casos. El SQL de
referencia está en `limpieza-fraude.sql` (aplicado en la base local,
idempotente). Decidido con el usuario.

## Qué cambió

### 1. Las señales de login ya no unen casos, tampoco al guardar

El agrupador ya no unía por login: una IP compartida es un indicio, no una
prueba. Pero la persistencia sí unía. Una señal solo podía ser evidencia de
UN caso (índice único sobre `id_senal_fraude`). Al guardar un segundo grupo
que tenía la misma señal de login, la persistencia lo fusionaba con el
primero. Es el item C1 de `docs/BACKEND-PENDIENTE.md`.

Así estaba la base: `multi_cuenta_ip` de `127.0.0.1` juntó en un solo caso
los 4 anillos de prueba, que no comparten cuentas. Además metió como núcleo a
cuentas reales (3, 7, 52), porque el núcleo contaba las señales de login y
la misma IP aparece dos veces (`multi_cuenta_ip` y `multi_cuenta_ip_lenta`).

Ahora:

- La evidencia es única por **(caso, señal)**. Una señal de login puede
  estar en varios casos, y en cada uno solo con las cuentas de ESE caso.
- La búsqueda de "¿en qué caso está esto?" no mira las señales de login.
- Las señales de login no meten cuentas al caso ni hacen núcleo a nadie.
- La evidencia de un caso queda **igual** a los hallazgos de su grupo: lo
  que ya no es vigente (descartado por el admin) o es de otro grupo se borra.
  Así se parte un caso que una versión vieja juntó de más. El primer grupo
  que lo toca se queda con el caso y su estado; los demás abren uno nuevo,
  `pendiente`.
- La firma de "caso descartado" se arma con las cuentas que se guardan, igual
  que el `PATCH`. Si no, un descartado con evidencia de login se reabriría
  solo en cada corrida.

Código: `agrupador-fraude.service.ts`, `persistencia-caso-fraude.service.ts`.

### 2. Fuera `cadena_abierta` (B.1)

En una cadena A→B→C, la nota de A ayuda a B y la de B ayuda a C: la
reputación no se concentra en nadie. Para inflar a un vendedor, las cuentas
lo califican a él (eso es `satelites`). En los datos, las 8 cadenas eran
pedazos de anillos que ya salían como `ciclo`, `mutuo` o `satelites`. Se
quitaron la consulta, el tipo, su peso (15) y su bono, y la rama de R-CASI-2
que la aceptaba.

### 3. `favor_devuelto` (B.5) fusionado en `mutuo`

Siempre salían los dos sobre el mismo par. Ahora la consulta de ciclos trae
la fecha de cada reseña, y un par mutuo guarda en su `detalle` las **horas**
entre la ida y la vuelta (la más corta). El puntaje de favor devuelto pasó a
ser un bono de `mutuo` y de `reiterado`: +20 en menos de 1 h, +12 en menos de
24 h, +8 en menos de 72 h. Diferencia con B.5: no exige notas altas.
Calificarse de vuelta en minutos es sospechoso con cualquier nota.

### 4. Fuera `carrito_acaparador` (F4)

Su premisa ("aparta unidades hasta que el carrito vence, 24 h") quedó vieja
con el carrito en PostgreSQL. Una oferta normal no reserva nada, y una
venta relámpago reserva 15 min con PostgreSQL impidiendo vender de más.

### 5. La granja de registros (F6) pasa a Elasticsearch

En ClickHouse nunca podía dispararse: `evento_registro` está vacía, porque el
ETL la llenaba desde `log_registro` y el backend dejó de escribirla el
2026-09-10. Los registros están en `mesh_eventos_autenticacion`.

`FraudeLoginRetrospectivoService.evaluarGranjaDeRegistros()` (cada 15 min)
usa los mismos números que la F6: 5 o más cuentas desde la misma IP en 60
min, en los últimos 30 días, sin las IP de la propia máquina. Elastic agrupa
por IP y trae sus registros; la peor ventana se calcula en el backend
(`peorVentana`). Se guarda igual que antes: hallazgo de eventos, cuentas
`autor`, sin aviso, IP en su pivote. `ultima_deteccion` es el último registro
de la ventana; antes era "hoy" y una granja vieja contaba siempre como
reciente.

En el catálogo cambia su fuente a `elastic`. El adaptador trata la familia
`compras_navegacion` siempre como evidencia `eventos`, venga de la base que
venga, para que no se confunda con el texto de reseñas (R-CASI-3). Esta
señal **sí une** cuentas en un caso: nacer juntas desde una IP no es
compartir el wifi.

### 6. Reglas R-CASI

- Se quitó la rama "comparten casa con calle" de R-CASI-1: A.4 se descartó y
  nunca hubo detector.
- Se quitó R-CASI-4 ("ciclo con dos olas"): las olas de B.4 no se guardan en
  ninguna señal, así que nunca se podía cumplir.
- Se actualizaron las descripciones de R-CASI-1, 2 y 5.

## Cómo quedó la base local

5 casos: uno por anillo de prueba (113-116, 117-120, 121-124, 125-128), los
cuatro `casi_confirmado` por R-CASI-2, y uno `revisar` con 7-8. Las cuentas
reales ya no son núcleo de nada.

## Pruebas hechas

- Persistencia (28 casos, en una transacción que se deshace): partir el caso
  mezclado y conservar su estado; login en varios casos sin fusionar;
  idempotencia; fusión legítima con herencia de estado; señal descartada que
  sale de la evidencia; descartado que no se reabre solo y sí con evidencia
  nueva; login solo que no forma caso.
- Pasos 2 a 5 (40 casos): horas de `mutuo` iguales a las de los
  `favor_devuelto` borrados (4 s y 2 s); bonos por tramo; detectores sin los
  tipos quitados; `peorVentana`; granja sembrada en Elastic y sus límites (4
  en una hora no alcanza; 5 repartidas en 80 min no; hace 40 días no;
  localhost en sus tres formas no); que no avisa; que une dos anillos y
  dispara R-CASI-1 y R-CASI-5.
- `pruebas/casos_fraude_fusion.cjs` 0 FALLA (su C1 ya no une),
  `pruebas/casos_fraude_granja.cjs` 6/6.
- Rutas de admin por HTTP: casos, `alertas-resenas` y `alertas-eventos`; los
  tipos quitados dan 400.

## Le toca a otros (fuera de `backend/`)

- **Migración real** con el contenido de `limpieza-fraude.sql`, después de la
  039. **Va antes de desplegar el código**: con el índice viejo, el
  `ON CONFLICT (id_caso_fraude, id_senal_fraude)` falla y el agrupador no
  guarda ningún caso (pasó en local: una corrida "0/5").
- `neo4j/consultas/B1_cadena_abierta.cypher` y `B5_favor_devuelto.cypher`
  (borrar o marcar como fuera de uso), `neo4j/pruebas/comparar.py`.
- `clickhouse/consultas/F4_carrito_acaparador.sql`, `F6_granja_de_registros.sql`
  y sus parámetros en `parametros.txt`; `clickhouse/pruebas/comprobar.py`. El
  ETL de `evento_registro` ya no lo necesita nadie.
- `pruebas/anillos_familia_b.sh` (espera cadena y favor devuelto).
- `docs/`: `BACKEND-PENDIENTE.md` (C1 queda resuelto), `base-de-datos.md`,
  `TRASPASO.md` y `fraude-entrega3/01`, `02` y `03`.
