#!/usr/bin/env bash
# pruebas/reglas_periodo.sh -- las reglas de descuento por PERIODO, A TRAVES DEL
# BACKEND. Es el CRUD de /vendedor/reglas-descuento-periodos contra la tabla de
# la migracion 022, con sus dos 409: el solape entre reglas de la misma oferta y
# la exclusion con los otros descuentos.
#
#   bash pruebas/reglas_periodo.sh
#   VENDEDOR=ventas.oriente@mesh.com OTRO=ventas.poniente@mesh.com bash pruebas/reglas_periodo.sh
#
# Mismo molde que pruebas/reglas_descuento.sh.
#
# Todas las reglas de esta prueba son de los anios 2098 y 2099, a proposito:
# DisparadorReglasPeriodoService corre cada 15 minutos y aplica la regla que
# cubra HOY. Una regla de la prueba que cubriera hoy le pondria un descuento de
# verdad a la oferta a mitad de la corrida. Por lo mismo el descuento manual de
# la seccion 7 usa un % que ninguna regla tiene: el disparador quita un
# descuento que "reconoce" como de una regla de la oferta, aunque este pausada.
#
# QUE COMPRUEBA
# ============================================================
#   1. La migracion 022. La tabla, la FK con ON DELETE CASCADE, los ocho CHECK,
#      los dos indices y el trigger de fecha_actualizacion.
#   2. Quien puede. Sin sesion 401, un comprador 403.
#   3. Las validaciones. Dia 0 y 32, mes 13, un mes sin el otro, anio sin mes,
#      anio 1999, 95 %, un numero como texto y un campo que falta dan 400.
#   4. Crear y el solape. A (1 al 5 de enero de 2099) da 201. B (3 al 10, se
#      pisa con A) da 409. C (10 al 15) da 201, conviven. Editar C para que
#      empiece el 4 da 409 y la fila no cambia. D, igual que A pero de 2098,
#      da 201: anios distintos no se pisan. Una oferta ajena da 404.
#   5. Listar y paginar. Las nuevas salen en GET, el paginado cuadra con
#      PostgreSQL.
#   6. Editar. Pausar da 200 y el trigger mueve fecha_actualizacion. {} da 400,
#      91 % da 400 y un id que no existe 404.
#   7. Exclusion. Con reglas activas, el descuento manual y la regla automatica
#      dan 409. Con todas pausadas el manual entra; con el puesto, crear o
#      reactivar una regla por periodo da 409.
#   8. Aislamiento. Otro vendedor no las ve y su PATCH da 404.
#
# LO QUE DEJA COMO ESTABA, aunque falle a la mitad (hay un trap): quita por la
# API el descuento manual si quedo puesto, y borra las reglas que creo con un
# DELETE directo a PostgreSQL. Es la unica escritura a mano y es a proposito:
# el backend no tiene ruta para borrar una regla, igual que la automatica.

set -u

API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
VENDEDOR="${VENDEDOR:-ventas.norte@mesh.com}"
OTRO="${OTRO:-ventas.sur@mesh.com}"
CLAVE_VENDEDOR="${CLAVE_VENDEDOR:-Vendedor123}"
COMPRADOR="${COMPRADOR:-compradora.norte@mesh.com}"
CLAVE_COMPRADOR="${CLAVE_COMPRADOR:-Comprador123}"

export MSYS_NO_PATHCONV=1
export PYTHONUTF8=1

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
igual() { if [ "$2" = "$3" ]; then OK "$1"; else FALLA "$1 (esperaba '$3', llego '$2')"; fi; }
contiene() { case "$2" in *"$3"*) OK "$1" ;; *) FALLA "$1 (el mensaje fue '$2')" ;; esac; }

sql() { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" 2>/dev/null | tr -d '\r'; }
campo() { python -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
for k in sys.argv[1].split('.'):
    if d is None: break
    if isinstance(d,list):
        d = d[int(k)] if k.isdigit() and int(k) < len(d) else None
    else:
        d = d.get(k) if isinstance(d,dict) else None
print('' if d is None else (str(d).lower() if isinstance(d,bool) else d))" "$1"; }

entrar() {
    curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
        -d "{\"identificador\":\"$1\",\"contrasena\":\"$2\"}" \
      | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1
}

CODIGO=""; CUERPO=""
pedir() {   # METODO RUTA COOKIE [CUERPO_JSON]
    local _args=(-s -m 60 -w $'\n@@@%{http_code}' -X "$1" "$API$2")
    [ -n "$3" ] && _args+=(-H "Cookie: $3")
    [ -n "${4:-}" ] && _args+=(-H "Content-Type: application/json" -d "$4")
    local _todo
    _todo=$(curl "${_args[@]}" 2>/dev/null)
    CODIGO="${_todo##*@@@}"
    CUERPO="${_todo%$'\n'@@@*}"
    [ -z "$CODIGO" ] && CODIGO="000"
    [ "$CUERPO" = "$_todo" ] && CUERPO=""
}
de_cuerpo() { printf '%s' "$CUERPO" | campo "$1"; }

RUTA=/vendedor/reglas-descuento-periodos
IDS=""              # las reglas creadas, separadas por coma
ID_AUTO=""          # por si la regla automatica de la seccion 7 entro sin querer
DESCUENTO_PUESTO=0
OFERTA=""; C_VEND=""
limpiar() {
    if [ "$DESCUENTO_PUESTO" = "1" ]; then
        pedir DELETE "/vendedor/ofertas/$OFERTA/descuento" "$C_VEND"
        echo; echo "Limpieza: descuento manual de la oferta $OFERTA quitado (HTTP $CODIGO)."
    fi
    if [ -n "$ID_AUTO" ]; then
        sql "DELETE FROM regla_descuento_automatico WHERE id_regla_descuento_automatico = $ID_AUTO" >/dev/null
        echo "Limpieza: regla automatica $ID_AUTO borrada."
    fi
    if [ -n "$IDS" ]; then
        sql "DELETE FROM regla_descuento_periodo WHERE id_regla_descuento_periodo IN (${IDS#,})" >/dev/null
        echo "Limpieza: reglas por periodo ${IDS#,} borradas."
    fi
}
trap limpiar EXIT
trap 'exit 130' INT TERM HUP

cuerpo() {  # OFERTA DIA_INI DIA_FIN MES_INI MES_FIN ANIO RELAMPAGO PORCENTAJE (vacio = no se manda)
    python -c "
import json,sys
o,di,df,mi,mf,an,rel,pc = sys.argv[1:9]
d={'id_oferta':int(o),'dia_inicio':int(di),'dia_fin':int(df)}
if mi: d['mes_inicio']=int(mi)
if mf: d['mes_fin']=int(mf)
if an: d['anio']=int(an)
d['es_venta_relampago'] = rel == 'true'
d['porcentaje_descuento'] = float(pc)
print(json.dumps(d))" "$@"
}
anotar() { [ -n "$1" ] && IDS="$IDS,$1"; }
fila() { sql "SELECT dia_inicio||'|'||dia_fin||'|'||COALESCE(mes_inicio::text,'-')||'|'||COALESCE(mes_fin::text,'-')||'|'||COALESCE(anio::text,'-')||'|'||es_venta_relampago||'|'||porcentaje_descuento||'|'||activa
              FROM regla_descuento_periodo WHERE id_regla_descuento_periodo = ${1:-0}"; }

# ------------------------------------------------------------------ 1
titulo "1. La migracion 022"
igual "la tabla existe" "$(sql "SELECT to_regclass('regla_descuento_periodo') IS NOT NULL")" "t"
igual "FK a oferta con ON DELETE CASCADE" "$(sql "SELECT confdeltype FROM pg_constraint WHERE conrelid='regla_descuento_periodo'::regclass AND contype='f' AND confrelid='oferta'::regclass")" "c"
igual "ocho CHECK" "$(sql "SELECT count(*) FROM pg_constraint WHERE conrelid='regla_descuento_periodo'::regclass AND contype='c'")" "8"
igual "los dos indices" "$(sql "SELECT count(*) FROM pg_indexes WHERE tablename='regla_descuento_periodo' AND indexname IN ('idx_regla_descuento_periodo_oferta','idx_regla_descuento_periodo_activa')")" "2"
igual "trigger de fecha_actualizacion" "$(sql "SELECT count(*) FROM pg_trigger WHERE tgrelid='regla_descuento_periodo'::regclass AND NOT tgisinternal AND tgfoid='oferta_tocar_fecha'::regproc")" "1"

# ------------------------------------------------------------------ elegir
C_VEND=$(entrar "$VENDEDOR" "$CLAVE_VENDEDOR")
C_OTRO=$(entrar "$OTRO" "$CLAVE_VENDEDOR")
C_COMP=$(entrar "$COMPRADOR" "$CLAVE_COMPRADOR")
if [ -z "$C_VEND" ] || [ -z "$C_OTRO" ] || [ -z "$C_COMP" ]; then
    echo "No pude iniciar sesion con alguna cuenta. Esta el backend en $API?" >&2
    exit 1
fi

# Activa y aprobada (el descuento manual de la seccion 7 lo pide), sin
# descuento, sin venta relampago y sin reglas de ninguna clase.
OFERTA=$(sql "SELECT o.id_oferta FROM oferta o JOIN usuarios u USING(id_usuario)
               JOIN estado_oferta eo USING(id_estado_oferta)
               WHERE u.correo_electronico = '$VENDEDOR'
                 AND eo.estado_oferta_nombre = 'activa'
                 AND o.fecha_aprobacion IS NOT NULL
                 AND o.porcentaje_descuento IS NULL
                 AND NOT o.es_inventario_limitado
                 AND NOT EXISTS (SELECT 1 FROM regla_descuento_automatico r WHERE r.id_oferta = o.id_oferta)
                 AND NOT EXISTS (SELECT 1 FROM regla_descuento_periodo rp WHERE rp.id_oferta = o.id_oferta)
               ORDER BY o.id_oferta LIMIT 1")
AJENA=$(sql "SELECT o.id_oferta FROM oferta o JOIN usuarios u USING(id_usuario)
              WHERE u.correo_electronico = '$OTRO' ORDER BY o.id_oferta LIMIT 1")
if [ -z "$OFERTA" ] || [ -z "$AJENA" ]; then
    echo "No encontre una oferta libre de $VENDEDOR, o una de $OTRO." >&2
    exit 1
fi
echo; echo "Oferta propia $OFERTA ($VENDEDOR), ajena $AJENA ($OTRO)"

# ------------------------------------------------------------------ 2
titulo "2. Quien puede"
pedir GET "$RUTA" ""
igual "sin sesion" "$CODIGO" "401"
pedir POST "$RUTA" "$C_COMP" "$(cuerpo "$OFERTA" 1 5 1 1 2099 false 20)"
igual "un comprador" "$CODIGO" "403"

# ------------------------------------------------------------------ 3
titulo "3. Validaciones"
pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 0 5 1 1 2099 false 20)";   igual "dia 0" "$CODIGO" "400"
pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 1 32 1 1 2099 false 20)";  igual "dia 32" "$CODIGO" "400"
pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 1 5 13 13 2099 false 20)"; igual "mes 13" "$CODIGO" "400"
pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 1 5 1 '' 2099 false 20)";  igual "mes de inicio sin mes de fin" "$CODIGO" "400"
pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 1 5 '' '' 2099 false 20)"; igual "anio sin mes" "$CODIGO" "400"
pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 1 5 1 1 1999 false 20)";   igual "anio 1999" "$CODIGO" "400"
pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 1 5 1 1 2099 false 95)";   igual "porcentaje 95" "$CODIGO" "400"
pedir POST "$RUTA" "$C_VEND" "{\"id_oferta\":$OFERTA,\"dia_inicio\":\"1\",\"dia_fin\":5,\"mes_inicio\":1,\"mes_fin\":1,\"anio\":2099,\"es_venta_relampago\":false,\"porcentaje_descuento\":20}"
igual "dia como texto" "$CODIGO" "400"
pedir POST "$RUTA" "$C_VEND" "{\"id_oferta\":$OFERTA,\"dia_inicio\":1,\"dia_fin\":5,\"porcentaje_descuento\":20}"
igual "falta es_venta_relampago" "$CODIGO" "400"
igual "ninguna de esas dejo fila" "$(sql "SELECT count(*) FROM regla_descuento_periodo WHERE id_oferta=$OFERTA")" "0"

# ------------------------------------------------------------------ 4
titulo "4. Crear y el solape"
pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 1 5 1 1 2099 false 20)"
igual "A, 1 al 5 de enero de 2099" "$CODIGO" "201"
ID_A=$(de_cuerpo payload.id_regla_descuento_periodo); anotar "$ID_A"
igual "sale activa" "$(de_cuerpo payload.activa)" "true"
igual "PostgreSQL guardo lo mismo" "$(fila "$ID_A")" "1|5|1|1|2099|false|20.00|true"

pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 3 10 1 1 2099 false 25)"
igual "B, 3 al 10, se pisa con A" "$CODIGO" "409"
anotar "$(de_cuerpo payload.id_regla_descuento_periodo)"
contiene "el 409 habla del solape" "$(de_cuerpo mensaje)" "solapa"

pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 10 15 1 1 2099 true 25)"
igual "C, 10 al 15, convive con A" "$CODIGO" "201"
ID_C=$(de_cuerpo payload.id_regla_descuento_periodo); anotar "$ID_C"

pedir PATCH "$RUTA/${ID_C:-0}" "$C_VEND" '{"dia_inicio":4}'
igual "C empezando el 4 se pisaria con A" "$CODIGO" "409"
igual "y la fila de C no cambio" "$(fila "$ID_C")" "10|15|1|1|2099|true|25.00|true"

pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 1 5 1 1 2098 false 20)"
igual "D, igual que A pero de 2098" "$CODIGO" "201"
ID_D=$(de_cuerpo payload.id_regla_descuento_periodo); anotar "$ID_D"

pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$AJENA" 1 5 1 1 2099 false 20)"
igual "oferta ajena" "$CODIGO" "404"
anotar "$(de_cuerpo payload.id_regla_descuento_periodo)"

# ------------------------------------------------------------------ 5
titulo "5. Listar y paginar"
pedir GET "$RUTA" "$C_VEND"
EN_LISTA=$(printf '%s' "$CUERPO" | python -c "
import sys,json; d=json.load(sys.stdin)['payload']
ids={r['id_regla_descuento_periodo'] for r in d}
print('si' if {'$ID_A','$ID_C','$ID_D'} <= ids else 'no')")
igual "A, C y D salen en GET" "$EN_LISTA" "si"
TOTAL_PG=$(sql "SELECT count(*) FROM regla_descuento_periodo r JOIN oferta o USING(id_oferta)
                 JOIN usuarios u ON u.id_usuario=o.id_usuario WHERE u.correo_electronico='$VENDEDOR'")
pedir GET "$RUTA/paginado?pagina=1&limite=1" "$C_VEND"
igual "total_reglas cuadra con PostgreSQL" "$(de_cuerpo payload.total_reglas)" "$TOTAL_PG"
igual "total_paginas con limite 1" "$(de_cuerpo payload.total_paginas)" "$TOTAL_PG"

# ------------------------------------------------------------------ 6
titulo "6. Editar"
ANTES=$(sql "SELECT fecha_actualizacion FROM regla_descuento_periodo WHERE id_regla_descuento_periodo=$ID_A")
sleep 1
pedir PATCH "$RUTA/$ID_A" "$C_VEND" '{"activa":false}'
igual "pausar A" "$CODIGO" "200"
igual "queda pausada" "$(de_cuerpo payload.activa)" "false"
DESPUES=$(sql "SELECT fecha_actualizacion FROM regla_descuento_periodo WHERE id_regla_descuento_periodo=$ID_A")
if [ "$ANTES" != "$DESPUES" ]; then OK "el trigger movio fecha_actualizacion"; else FALLA "fecha_actualizacion no cambio"; fi
pedir PATCH "$RUTA/$ID_A" "$C_VEND" '{"porcentaje_descuento":22}'
igual "cambiar el %" "$CODIGO" "200"
igual "cambia eso y el resto sigue" "$(fila "$ID_A")" "1|5|1|1|2099|false|22.00|false"
pedir PATCH "$RUTA/$ID_A" "$C_VEND" '{}'
igual "PATCH vacio" "$CODIGO" "400"
pedir PATCH "$RUTA/$ID_A" "$C_VEND" '{"porcentaje_descuento":91}'
igual "PATCH con 91%" "$CODIGO" "400"
pedir PATCH "$RUTA/999999999" "$C_VEND" '{"activa":true}'
igual "regla que no existe" "$CODIGO" "404"

# ------------------------------------------------------------------ 7
titulo "7. Exclusion con los otros descuentos"
# C y D siguen activas.
pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$C_VEND" '{"porcentaje_descuento":11}'
igual "descuento manual con reglas por periodo activas" "$CODIGO" "409"
[ "$CODIGO" = "201" ] && DESCUENTO_PUESTO=1
contiene "el 409 nombra la regla por periodo" "$(de_cuerpo mensaje)" "periodo"

pedir POST /vendedor/reglas-descuento "$C_VEND" "{\"id_oferta\":$OFERTA,\"umbral_unidades\":500,\"ventana_minutos\":10,\"es_venta_relampago\":false,\"duracion_segundos\":3600,\"porcentaje_descuento\":10}"
igual "regla automatica con reglas por periodo activas" "$CODIGO" "409"
[ "$CODIGO" = "201" ] && ID_AUTO=$(de_cuerpo payload.id_regla_descuento_automatico)

pedir PATCH "$RUTA/$ID_C" "$C_VEND" '{"activa":false}'; igual "pausar C" "$CODIGO" "200"
pedir PATCH "$RUTA/$ID_D" "$C_VEND" '{"activa":false}'; igual "pausar D" "$CODIGO" "200"

pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$C_VEND" '{"porcentaje_descuento":11}'
igual "con todas pausadas, el descuento manual entra" "$CODIGO" "201"
[ "$CODIGO" = "201" ] && DESCUENTO_PUESTO=1

pedir PATCH "$RUTA/$ID_A" "$C_VEND" '{"activa":true}'
igual "reactivar A con el descuento manual puesto" "$CODIGO" "409"
contiene "el 409 es el de la exclusion" "$(de_cuerpo mensaje)" "excluyentes"
igual "A sigue pausada" "$(sql "SELECT activa FROM regla_descuento_periodo WHERE id_regla_descuento_periodo=$ID_A")" "f"

pedir POST "$RUTA" "$C_VEND" "$(cuerpo "$OFERTA" 20 25 2 2 2099 false 20)"
igual "crear otra regla con el descuento manual puesto" "$CODIGO" "409"
anotar "$(de_cuerpo payload.id_regla_descuento_periodo)"

pedir DELETE "/vendedor/ofertas/$OFERTA/descuento" "$C_VEND"
igual "quitar el descuento manual" "$CODIGO" "200"
[ "$CODIGO" = "200" ] && DESCUENTO_PUESTO=0

pedir PATCH "$RUTA/$ID_A" "$C_VEND" '{"activa":true}'
igual "sin descuento, A se reactiva" "$CODIGO" "200"
pedir PATCH "$RUTA/$ID_A" "$C_VEND" '{"activa":false}'
igual "y se vuelve a pausar" "$CODIGO" "200"

# ------------------------------------------------------------------ 8
titulo "8. Aislamiento entre vendedores"
pedir GET "$RUTA" "$C_OTRO"
LA_VE=$(printf '%s' "$CUERPO" | python -c "
import sys,json; d=json.load(sys.stdin)['payload']
print('si' if any(r['id_regla_descuento_periodo'] in ('$ID_A','$ID_C','$ID_D') for r in d) else 'no')")
igual "el otro vendedor no las ve" "$LA_VE" "no"
pedir PATCH "$RUTA/$ID_A" "$C_OTRO" '{"activa":true}'
igual "el otro vendedor no la puede editar" "$CODIGO" "404"
igual "y sigue pausada" "$(sql "SELECT activa FROM regla_descuento_periodo WHERE id_regla_descuento_periodo=$ID_A")" "f"

echo
echo "=============================================================="
echo "Resultado: $ok OK, $fallo FALLA"
[ "$fallo" -eq 0 ]
