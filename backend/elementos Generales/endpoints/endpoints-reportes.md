# Endpoints de reportes del panel de admin

Dos reportes básicos para el panel de administración de la Entrega 2. **Solo
lectura** sobre PostgreSQL (`pedido`, `pedido_producto`, `pago` y sus
catálogos de estado) — ningún reporte escribe nada.

> **Estado (2026-08-30): las dos rutas están hechas y probadas.**
> `GET /admin/reportes/reservaciones` y `GET /admin/reportes/ventas`.
> Verificado contra la base real (auth 401/403/200; números cuadrados contra
> `psql`) y contra un escenario con pedido pendiente + venta cancelada con
> reembolso, en una transacción con `ROLLBACK`. Ver "Pruebas".

Código: `src/controllers/admin/admin-reportes.controller.ts` +
`src/services/admin/admin-reportes.service.ts`. Tipos:
`src/models/reporte.ts`. Todavía **no hay pantalla** que los consuma — el
`PanelAdmin.svelte` actual solo gestiona cuentas.

---

## El dinero viaja como texto

Todos los montos salen como **string con dos decimales** (`"13346.00"`), no
como número: son `numeric(12,2)` de Postgres y pasarlos por el `float` de
JavaScript mete el redondeo binario. El frontend los muestra tal cual o los
convierte bajo su responsabilidad.

## El total de un pedido no está guardado

`pedido` **no lleva columna `total`** (a propósito: sería un dato deducible
que se puede escribir mal). El total se **suma** de
`precio_historial.precio * cantidad` de cada línea — el precio **congelado**
de cada una, que es también el que se cobró.

`pago.monto` sí es una columna, y **no siempre coincide** con esa suma: al
cancelar un pedido `comprado`, sus líneas quedan intactas (la suma no
cambia) pero el pago pasa a `reembolsado` conservando su monto. Por eso:

- **`ingresos`** se lee de `pago.monto` con el pago en `pagado`.
- **`monto` por estado de pedido** se suma de las líneas.

---

## GET /admin/reportes/reservaciones

**Solo admin.** Los pedidos en estado **`pendiente`**: se abrieron y todavía
no se pagaron. En este sistema no hay un concepto de "reserva" aparte —
una reservación **es** un pedido pendiente.

> **Un pedido pendiente NO aparta stock.** Nunca descuenta ni reserva
> unidades (`migrations/007_flujo_pedido.sql` lo dice explícito). Lo que sí
> quedó fijo es el **precio** de cada línea, congelado al agregarla, así que
> `total` es firme.

**Desde el 2026-10-17 cada pedido `pendiente` es el carrito abierto de una
cuenta** (ver `plan pendiente/carrito-postgres-verdad.md`): nace con el primer
producto que se agrega y deja de estar aquí al comprarlo, al vaciarlo o a las
24 h sin tocarlo. Así que este reporte es, en la práctica, "los carritos
abiertos". Un carrito todavía no tiene dirección (se elige al pagar): sale con
`ciudad` y `departamento` en `null`. El `total` es al precio que vio cada
persona; la venta relámpago sí aparta unidades, pero eso vive en
`reserva_venta_relampago`, no en este reporte.

```
GET /admin/reportes/reservaciones
```

### 200

```json
{
  "ok": true,
  "mensaje": "Reporte de reservaciones generado",
  "payload": {
    "generado": "2026-08-30T14:06:47.840Z",
    "resumen": { "cantidad": 1, "unidades": 3, "total": "18789.00" },
    "reservaciones": [
      {
        "id_pedido": 4,
        "fecha_creacion": "2026-08-30T13:55:00.000Z",
        "cliente": {
          "id_usuario": 7,
          "usuario": "compradora_norte",
          "correo_electronico": "compradora.norte@mesh.com",
          "nombre": "Ana Lopez"
        },
        "cantidad_lineas": 1,
        "unidades": 3,
        "total": "18789.00",
        "ciudad": "Antigua Guatemala",
        "departamento": "Sacatepequez"
      }
    ]
  }
}
```

- `generado` — cuándo se generó el reporte (ISO 8601).
- `resumen.total` — la suma de los `total` de todas las reservaciones.
- `cliente.nombre` — nombre y apellido juntos; solo el nombre si no hay
  apellido.
- Un pedido pendiente sin líneas todavía sale con `cantidad_lineas: 0` y
  `total: "0.00"` — sigue siendo una reservación válida.
- Orden: de la más nueva a la más vieja.

Lista vacía → `reservaciones: []` y `resumen` en ceros, **no** un 404.

### 401 / 403

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

`403` para una sesión válida que no es admin (comprador, vendedor, o la
tienda).

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo generar el reporte de reservaciones", "payload": null }
```

---

## GET /admin/reportes/ventas

**Solo admin.** El resumen de lo vendido, cobrado y devuelto en todo el
sistema.

```
GET /admin/reportes/ventas
```

### 200

```json
{
  "ok": true,
  "mensaje": "Reporte de ventas generado",
  "payload": {
    "generado": "2026-08-30T14:06:47.570Z",
    "pedidos_por_estado": [
      { "estado": "pendiente",  "cantidad": 0, "monto": "0.00" },
      { "estado": "comprado",   "cantidad": 2, "monto": "13346.00" },
      { "estado": "enviado",    "cantidad": 0, "monto": "0.00" },
      { "estado": "entregado",  "cantidad": 0, "monto": "0.00" },
      { "estado": "cancelado",  "cantidad": 0, "monto": "0.00" }
    ],
    "pagos_por_estado": [
      { "estado": "pendiente",   "cantidad": 0, "monto": "0.00" },
      { "estado": "pagado",      "cantidad": 2, "monto": "13346.00" },
      { "estado": "reembolsado", "cantidad": 0, "monto": "0.00" },
      { "estado": "fallido",     "cantidad": 0, "monto": "0.00" }
    ],
    "pagos_por_metodo": [
      { "metodo": "tarjeta",                 "cantidad": 1, "monto": "11906.00" },
      { "metodo": "transferencia",           "cantidad": 0, "monto": "0.00" },
      { "metodo": "efectivo contra entrega", "cantidad": 1, "monto": "1440.00" }
    ],
    "totales": {
      "pedidos": 2,
      "unidades_vendidas": 4,
      "ingresos": "13346.00",
      "reembolsado": "0.00",
      "ticket_promedio": "6673.00"
    }
  }
}
```

- **`pedidos_por_estado`** — las **5 filas** del catálogo `estado_pedido`
  siempre, aunque alguna valga 0. `monto` = suma de las líneas de los
  pedidos en ese estado.
- **`pagos_por_estado`** — las **4 filas** de `estado_pago`. Hoy todos los
  pagos nacen `pagado` (`comprar_pedido` no distingue método — decisión del
  equipo, simplificación de la Entrega 1), así que `pendiente` y `fallido`
  quedan en 0; `reembolsado` sube solo al cancelar un pedido ya `comprado`.
- **`pagos_por_metodo`** — las **3 filas** de `metodo_pago`.
- **`totales.unidades_vendidas`** — unidades de pedidos en `comprado` /
  `enviado` / `entregado` (una venta cancelada ya no cuenta).
- **`totales.ingresos`** — suma de `pago.monto` con el pago en `pagado`. Un
  reembolso **no** resta de acá; sale en `reembolsado` aparte.
- **`totales.ticket_promedio`** — `ingresos` entre el número de pagos
  `pagado`; `"0.00"` si no hay ninguno.

> **Sobre "ganancia":** el sistema no cobra comisión (salió del alcance del
> curso), así que no hay una ganancia de plataforma que calcular.
> `ingresos` es todo el dinero cobrado. Un desglose "cuánto vendió la
> tienda vs. los demás vendedores" se podría agregar cruzando
> `precio_historial.id_oferta → oferta.id_usuario`, pero se dejó fuera de
> esta versión básica.

### 401 / 403 / 503 / 500

Iguales que `GET /admin/reportes/reservaciones`, con el mensaje de 500
`"No se pudo generar el reporte de ventas"`.

---

## Lo que NO se hizo (versión básica, a propósito)

- **Filtros por fecha / rango.** Los dos reportes son "ahora mismo, todo".
  Un `?desde=&hasta=` sería el siguiente paso.
- **Desglose por vendedor / por producto.** Se puede sacar de
  `pedido_producto` + `precio_historial` + `oferta`, pero no entra en un
  reporte "básico".
- **Exportar a CSV.** Solo JSON.
- **Paginación de `reservaciones`.** Se devuelven todas; hoy son poquísimas.

---

## Pruebas — 2026-08-30

### Autorización

| Sesión | `GET /admin/reportes/ventas` |
|---|---|
| Sin sesión | `401` |
| `compradora_norte` (comprador) | `403` |
| `admin_mesh` (admin) | `200` |

### Números (contra los datos sembrados)

`GET /admin/reportes/ventas` → `comprado: 2` / `pagado: 2` /
`ingresos: "13346.00"` / `unidades_vendidas: 4` /
`ticket_promedio: "6673.00"`; `tarjeta: 11906.00` + `efectivo: 1440.00` =
`13346.00`. Cuadrado contra `psql`:
`SUM(ph.precio*pp.cantidad) = 13346.00`, `SUM(pago.monto WHERE pagado) = 13346.00`.

`GET /admin/reportes/reservaciones` → `[]` (no hay pedidos `pendiente` en la
semilla).

### Escenario con pendiente + cancelado + reembolso

En una transacción con `ROLLBACK` (para no ensuciar la base) se creó un
pedido `pendiente` (compradora_norte, 3 unidades) y una venta que luego se
canceló (`comprar_pedido` + `cancelar_pedido`). Corriendo las consultas del
servicio dentro de esa transacción:

- reservaciones → 1 pedido, 3 unidades, `total 18789.00` (3 × 6263.00).
- `pedidos_por_estado` → `pendiente 1 / 18789.00`, `comprado 2 / 13346.00`,
  `cancelado 1 / 5643.00`.
- `pagos_por_estado` → `pagado 2 / 13346.00`, `reembolsado 1 / 5643.00`.
- `totales` → `unidades_vendidas 4` (la cancelada ya no cuenta),
  `ingresos 13346.00` (el reembolso no resta), `reembolsado 5643.00`.

Tras el `ROLLBACK`, la base vuelve a sus 2 pedidos reales.

Los scripts viven en el scratchpad, no en el repo.
