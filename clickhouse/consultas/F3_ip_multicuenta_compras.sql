-- F3_ip_multicuenta_compras.sql -- VARIAS CUENTAS QUE COMPRAN DESDE LA MISMA IP
--
-- QUE DEVUELVE: IPs desde las que compraron al menos `min_cuentas_por_ip`
-- cuentas distintas, con la lista de cuentas.
--
-- POR QUE IMPORTA: es la senal que el grafo no puede ver. Neo4j sabe que tres
-- cuentas se califican en circulo; no sabe que las tres compraron desde la
-- misma maquina. `cuentas` sale como lista de ids para que el backend la cruce
-- con los hallazgos del grafo: si las cuentas de un anillo aparecen aqui
-- juntas, la regla R-CASI-1 lo trata como casi confirmado.
--
-- `ips_de_confianza` saca las IPs del propio equipo: los 328 logueos reales
-- de desarrollo salen todos de 127.0.0.1 (medido, clickhouse/README.md) y sin
-- esta lista cualquier corrida de pruebas acusaria a todo el equipo. En
-- produccion ahi irian las IPs de oficinas o de un proxy conocido, nunca una
-- lista larga: cada IP que entra es un punto ciego.
--
-- La comparacion es por texto (toString(ip)) porque asi se escribe la lista a
-- mano; una IPv4 queda guardada como '::ffff:a.b.c.d'.
--
-- Parametros: lote, dias_ventana, min_cuentas_por_ip, ips_de_confianza, limite.
SELECT
    toString(ip)                           AS ip,
    uniqExact(id_usuario)                  AS cuentas_distintas,
    arraySort(groupUniqArray(id_usuario))  AS cuentas,
    uniqExact(id_pedido)                   AS pedidos,
    min(fecha)                             AS primera,
    max(fecha)                             AS ultima
FROM compra_producto FINAL
WHERE lote = {lote:String}
  AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
  AND NOT has({ips_de_confianza:Array(String)}, toString(ip))
  -- '::' es la IP VACIA, no una IP. Las compras que etl/cargar_compras.sh copio
  -- de PostgreSQL no traen IP (pedidos no la guarda) y quedan con '::'. Medido
  -- en la base real: sin esta linea salian 4 cuentas "compartiendo" la IP '::'
  -- con 33 pedidos, y eran los dos compradores y dos vendedores de la semilla.
  -- No se pone en ips_de_confianza porque no es una decision de confianza: es
  -- un dato que falta, y tiene que quedar fuera siempre.
  -- Va con toString porque en este SELECT `ip` es tambien el alias de
  -- toString(ip), y en ClickHouse el alias tapa a la columna en el WHERE: con
  -- "ip != toIPv6('::')" la comparacion era texto contra IPv6 y no corria.
  AND toString(ip) != '::'
GROUP BY ip
HAVING cuentas_distintas >= {min_cuentas_por_ip:UInt32}
ORDER BY cuentas_distintas DESC
LIMIT {limite:UInt32};
