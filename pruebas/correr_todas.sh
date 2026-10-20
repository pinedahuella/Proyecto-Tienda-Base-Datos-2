#!/usr/bin/env bash
# pruebas/correr_todas.sh -- corre todas las pruebas del repo de a una, cada
# una con su log, y deja un resumen de una linea por prueba.
#
#   bash pruebas/correr_todas.sh                       todas
#   bash pruebas/correr_todas.sh pruebas/carrito.sh    solo esas
#   SALIDA=/c/algun/lado bash pruebas/correr_todas.sh  logs y resumen ahi
#
# Por omision deja todo en $TMP/mesh-pruebas: RESUMEN.txt y un .log por prueba.
# El resumen se borra al empezar, asi un FIN viejo no engana a quien espera.
# Necesita las bases y el backend arriba (.\arrancar.ps1 y npm run start:dev),
# o el modo remoto (source remoto/activar.sh), que corre las mismas pruebas
# contra las bases de otra PC. Tarda unos 25 minutos.
cd "$(dirname "$0")/.." || exit 1
DIR="${SALIDA:-${TMPDIR:-/tmp}/mesh-pruebas}"
# Que no le llegue a las pruebas: pruebas/eventos.sh usa SALIDA como el archivo
# donde guarda lo que dice el ETL, y con una carpeta ahi se cae entera.
unset SALIDA
mkdir -p "$DIR"
RES="$DIR/RESUMEN.txt"
rm -f "$RES"

if [ $# -gt 0 ]; then
    LISTA=("$@")
else
    LISTA=(
        pruebas/etl_compras.sh
        pruebas/grafo_compras.sh
        pruebas/recomendaciones.sh
        pruebas/carrito.sh
        pruebas/carrito_vencimiento.sh
        pruebas/oferta_limitada.sh
        pruebas/descuentos.sh
        pruebas/reglas_descuento.sh
        pruebas/reglas_periodo.sh
        pruebas/ofertas_paginadas.sh
        pruebas/ofertas_y_seguimientos.sh
        pruebas/busquedas_sin_resultados.sh
        pruebas/busqueda.sh
        pruebas/alertas_login.sh
        pruebas/anillos.sh
        pruebas/anillos_familia_b.sh
        pruebas/eventos.sh
        pruebas/tendencias.sh
        pruebas/tendencias_avanzadas.sh
        pruebas/etl_mongo.sh
        pruebas/resenas.sh
        pruebas/notas.sh
        pruebas/casos_fraude_fusion.cjs
        pruebas/casos_fraude_granja.cjs
        pruebas/correr_detectores_resenas.cjs
        pruebas/correr_detectores_fraude.cjs
        pruebas/vectores_worker.cjs
        pruebas/clasificador_en_postgres.mjs
        pruebas/recomendacion_semantica.py
        elastic/pruebas/facetas.py
        redis/prueba_acceso.sh
        redis/prueba_carrito.sh
        redis/prueba_restaurar.sh
        redis/prueba_concurrencia.sh
        redis/mas_vendidos.sh
        neo4j/correr_patrones.sh
        clickhouse/correr_consultas.sh
        pruebas/caidas.mjs
        pruebas/falla_checkout.sh
    )
fi

for p in "${LISTA[@]}"; do
    log="$DIR/$(echo "$p" | tr '/' '_').log"
    rm -f "$log"
    ini=$(date +%s)
    case "$p" in
        *.sh)        timeout 1500 bash "$p"   > "$log" 2>&1 ;;
        *.cjs|*.mjs) timeout 1500 node "$p"   > "$log" 2>&1 ;;
        *.py)        timeout 1500 python "$p" > "$log" 2>&1 ;;
    esac
    c=$?
    seg=$(( $(date +%s) - ini ))
    resumen=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E "[0-9]+ OK|OK, [0-9]+ FALLA|[0-9]+ FALLA|SIN MEDIR|Todo bien" | tail -1 | tr -s ' ')
    printf '%-42s exit %-3s %4ss  %s\n' "$p" "$c" "$seg" "$resumen" | tee -a "$RES"
done
echo "FIN" >> "$RES"
echo "Resumen en $RES"
