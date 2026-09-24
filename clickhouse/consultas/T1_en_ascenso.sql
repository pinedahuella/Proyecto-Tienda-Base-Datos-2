-- T1_en_ascenso.sql -- LO QUE SE ESTA CALENTANDO ANTES DE VENDERSE
--
-- QUE DEVUELVE: productos cuyas vistas diarias de los ultimos `dias_recientes`
-- dias superan a las de los `dias_base` dias anteriores, ordenados por cuantas
-- veces crecieron.
--
-- Lee el RESUMEN (vistas_por_producto_dia, que la vista materializada mantiene
-- sola) y no la tabla cruda: por eso contesta en milisegundos sin importar
-- cuantas vistas haya. Los contadores se leen con countMerge / uniqMerge
-- porque la tabla guarda estados parciales, no numeros.
--
-- DOS CORRECCIONES sobre la consulta del README:
--   1. Compara PROMEDIOS DIARIOS, no totales. La del README comparaba 7 dias
--      contra "todo lo anterior", y un producto con mas historia parecia
--      siempre mas frio de lo que es.
--   2. Suaviza con +1 arriba y abajo. Sin eso un producto que paso de 0 vistas
--      a 1 "crecio infinito" y encabeza la lista; con `min_vistas` y el +1 hace
--      falta volumen de verdad para subir.
--
-- `vistas_por_persona` va al lado para que nadie celebre como tendencia lo que
-- es un producto inflado (ver F1).
--
-- Parametros: lote, dias_recientes, dias_base, min_vistas, min_crecimiento, limite.
SELECT
    id_producto,
    countMergeIf(vistas, dia > today() - {dias_recientes:UInt32})           AS vistas_recientes,
    countMergeIf(vistas, dia <= today() - {dias_recientes:UInt32})          AS vistas_base,
    uniqMergeIf(sesiones, dia > today() - {dias_recientes:UInt32})          AS personas_recientes,
    round(vistas_recientes / {dias_recientes:UInt32}, 1)                    AS por_dia_ahora,
    round(vistas_base / {dias_base:UInt32}, 1)                              AS por_dia_antes,
    round((vistas_recientes / {dias_recientes:UInt32} + 1)
        / (vistas_base / {dias_base:UInt32} + 1), 2)                        AS veces,
    round(vistas_recientes / greatest(personas_recientes, 1), 1)            AS vistas_por_persona
FROM vistas_por_producto_dia
WHERE lote = {lote:String}
  AND dia > today() - ({dias_recientes:UInt32} + {dias_base:UInt32})
GROUP BY id_producto
HAVING vistas_recientes >= {min_vistas:UInt32}
   AND veces >= {min_crecimiento:Float64}
ORDER BY veces DESC
LIMIT {limite:UInt32};
