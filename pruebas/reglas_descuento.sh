#!/usr/bin/env bash
# pruebas/reglas_descuento.sh -- las reglas de descuento automatico, A TRAVES
# DEL BACKEND. Es el CRUD de /vendedor/reglas-descuento (commit 56ce5f8) contra
# la tabla de la migracion 021.
#
#   bash pruebas/reglas_descuento.sh
#   VENDEDOR=ventas.oriente@mesh.com OTRO=ventas.poniente@mesh.com bash pruebas/reglas_descuento.sh
#
# Prueba la CONFIGURACION y la exclusion con el descuento manual. El disparo
# (DisparadorReglasAutomaticoService, desde el 2026-09-25) mira ClickHouse cada
# minuto, y probarlo pide sembrar ventas en compra_producto, que no tiene
# transacciones ni se deshace: no se mide aqui. Por lo mismo la regla de
# prueba pide 12 unidades en 45 minutos y pasa casi toda la prueba pausada,
# para que ninguna venta real la dispare a la mitad.
#
# QUE COMPRUEBA
# ============================================================
#   1. La migracion 021. La tabla existe con UNIQUE(id_oferta), FK con
#      ON DELETE CASCADE, los CHECK y el trigger de fecha_actualizacion.
#   2. Quien puede. Sin sesion 401, un comprador 403.
#   3. Las validaciones del backend. umbral 0, ventana 0, duracion 0 (aqui no
#      vale como en la venta limitada), 95%, 0.5%, un numero como texto y un
#      campo que falta dan 400.
#   4. Crear da 201, activa true, y la fila de PostgreSQL tiene lo mismo que se
#      mando. Una segunda regla sobre la misma oferta da 409. Una oferta ajena
#      da 404.
#   5. Listar y paginar. La nueva sale en GET, y el paginado cuadra con el
#      COUNT de PostgreSQL.
#   6. Editar. Pausar con { activa: false } da 200 y el trigger mueve
#      fecha_actualizacion. Cambiar dos numeros deja el resto igual. {} da 400
#      y un id que no existe 404.
#   7. Aislamiento. Otro vendedor no la ve en su lista y su PATCH da 404.
#   8. Exclusion con el descuento manual (2026-09-24). Con la regla pausada el
#      descuento manual entra (201). Con el descuento puesto, reactivar la
#      regla da 409 y la regla sigue pausada. Quitado el descuento, reactivar
#      da 200, y con la regla activa el descuento manual da 409. Al final la
#      regla queda pausada otra vez.
#
# LO QUE DEJA COMO ESTABA, aunque falle a la mitad (hay un trap): quita por la
# API el descuento manual si quedo puesto, y borra la regla que creo. Es la UNICA escritura directa a PostgreSQL de esta prueba y
# es a proposito: el backend no tiene ruta para borrar una regla, solo para
# pausarla. Tambien lo hizo asi el companero al probarla (ver
# endpoints-vendedores.md, "Teardown").

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
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

# Deja el codigo en CODIGO y el cuerpo en CUERPO, igual que pruebas/descuentos.sh.
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

ID_REGLA=""
DESCUENTO_PUESTO=0
limpiar() {
    if [ "$DESCUENTO_PUESTO" = "1" ]; then
        pedir DELETE "/vendedor/ofertas/$OFERTA/descuento" "$C_VEND"
        echo; echo "Limpieza: descuento manual de la oferta $OFERTA quitado (HTTP $CODIGO)."
    fi
    if [ -n "$ID_REGLA" ]; then
        sql "DELETE FROM regla_descuento_automatico WHERE id_regla_descuento_automatico = $ID_REGLA" >/dev/null
        echo; echo "Limpieza: regla $ID_REGLA borrada."
    fi
}
trap limpiar EXIT
# Con la senal atrapada, un Ctrl+C o un timeout tambien pasan por limpiar
# (ver pruebas/descuentos.sh: en el bash de Git el trap de EXIT solo no basta).
trap 'exit 130' INT TERM HUP
OFERTA=""; C_VEND=""

# ------------------------------------------------------------------ 1
titulo "1. La migracion 021"
igual "la tabla existe" "$(sql "SELECT to_regclass('regla_descuento_automatico') IS NOT NULL")" "t"
igual "UNIQUE(id_oferta)" "$(sql "SELECT count(*) FROM pg_constraint WHERE conrelid='regla_descuento_automatico'::regclass AND contype='u'")" "1"
igual "FK a oferta con ON DELETE CASCADE" "$(sql "SELECT confdeltype FROM pg_constraint WHERE conrelid='regla_descuento_automatico'::regclass AND contype='f' AND confrelid='oferta'::regclass")" "c"
igual "cuatro CHECK" "$(sql "SELECT count(*) FROM pg_constraint WHERE conrelid='regla_descuento_automatico'::regclass AND contype='c'")" "4"
igual "trigger de fecha_actualizacion" "$(sql "SELECT count(*) FROM pg_trigger WHERE tgrelid='regla_descuento_automatico'::regclass AND NOT tgisinternal AND tgfoid='oferta_tocar_fecha'::regproc")" "1"

# ------------------------------------------------------------------ elegir
C_VEND=$(entrar "$VENDEDOR" "$CLAVE_VENDEDOR")
C_OTRO=$(entrar "$OTRO" "$CLAVE_VENDEDOR")
C_COMP=$(entrar "$COMPRADOR" "$CLAVE_COMPRADOR")
if [ -z "$C_VEND" ] || [ -z "$C_OTRO" ] || [ -z "$C_COMP" ]; then
    echo "No pude iniciar sesion con alguna cuenta. Esta el backend en $API?" >&2
    exit 1
fi

# Una oferta que pueda recibir regla Y descuento manual: activa y aprobada
# (el descuento manual lo pide), sin descuento, sin venta relampago y sin
# ninguna regla, de las dos clases. Cualquiera de esas cosas daria 409 por la
# exclusion y la prueba mediria otra cosa.
OFERTA=$(sql "SELECT o.id_oferta FROM oferta o JOIN usuarios u USING(id_usuario)
               JOIN estado_oferta eo USING(id_estado_oferta)
               WHERE u.correo_electronico = '$VENDEDOR'
                 AND eo.estado_oferta_nombre = 'activa'
                 AND o.fecha_aprobacion IS NOT NULL
                 AND o.porcentaje_descuento IS NULL
                 AND NOT o.es_inventario_limitado
                 AND NOT EXISTS (SELECT 1 FROM regla_descuento_automatico r WHERE r.id_oferta = o.id_oferta)
                 AND NOT EXISTS (SELECT 1 FROM regla_descuento_periodo rp WHERE rp.id_oferta = o.id_oferta AND rp.activa)
               ORDER BY o.id_oferta LIMIT 1")
AJENA=$(sql "SELECT o.id_oferta FROM oferta o JOIN usuarios u USING(id_usuario)
              WHERE u.correo_electronico = '$OTRO' ORDER BY o.id_oferta LIMIT 1")
if [ -z "$OFERTA" ] || [ -z "$AJENA" ]; then
    echo "No encontre una oferta de $VENDEDOR sin regla, o una de $OTRO." >&2
    exit 1
fi
echo; echo "Oferta propia $OFERTA ($VENDEDOR), ajena $AJENA ($OTRO)"

cuerpo() {  # OFERTA UMBRAL VENTANA RELAMPAGO DURACION PORCENTAJE
    printf '{"id_oferta":%s,"umbral_unidades":%s,"ventana_minutos":%s,"es_venta_relampago":%s,"duracion_segundos":%s,"porcentaje_descuento":%s}' "$@"
}

# ------------------------------------------------------------------ 2
titulo "2. Quien puede"
pedir GET /vendedor/reglas-descuento ""
igual "sin sesion" "$CODIGO" "401"
pedir POST /vendedor/reglas-descuento "$C_COMP" "$(cuerpo "$OFERTA" 10 60 false 3600 20)"
igual "un comprador" "$CODIGO" "403"

# ------------------------------------------------------------------ 3
titulo "3. Validaciones"
pedir POST /vendedor/reglas-descuento "$C_VEND" "$(cuerpo "$OFERTA" 0 60 false 3600 20)";  igual "umbral 0" "$CODIGO" "400"
pedir POST /vendedor/reglas-descuento "$C_VEND" "$(cuerpo "$OFERTA" 10 0 false 3600 20)";  igual "ventana 0" "$CODIGO" "400"
pedir POST /vendedor/reglas-descuento "$C_VEND" "$(cuerpo "$OFERTA" 10 60 false 0 20)";    igual "duracion 0" "$CODIGO" "400"
pedir POST /vendedor/reglas-descuento "$C_VEND" "$(cuerpo "$OFERTA" 10 60 false 3600 95)"; igual "porcentaje 95" "$CODIGO" "400"
pedir POST /vendedor/reglas-descuento "$C_VEND" "$(cuerpo "$OFERTA" 10 60 false 3600 0.5)"; igual "porcentaje 0.5" "$CODIGO" "400"
pedir POST /vendedor/reglas-descuento "$C_VEND" "$(cuerpo "$OFERTA" '"10"' 60 false 3600 20)"; igual "umbral como texto" "$CODIGO" "400"
pedir POST /vendedor/reglas-descuento "$C_VEND" "{\"id_oferta\":$OFERTA,\"umbral_unidades\":10}"; igual "faltan campos" "$CODIGO" "400"
igual "ninguna de esas dejo fila" "$(sql "SELECT count(*) FROM regla_descuento_automatico WHERE id_oferta=$OFERTA")" "0"

# ------------------------------------------------------------------ 4
titulo "4. Crear"
pedir POST /vendedor/reglas-descuento "$C_VEND" "$(cuerpo "$OFERTA" 12 45 true 5400 17.5)"
igual "crear da 201" "$CODIGO" "201"
ID_REGLA=$(de_cuerpo payload.id_regla_descuento_automatico)
igual "sale activa" "$(de_cuerpo payload.activa)" "true"
FILA=$(sql "SELECT umbral_unidades||'|'||ventana_minutos||'|'||es_venta_relampago||'|'||duracion_segundos||'|'||porcentaje_descuento||'|'||activa
             FROM regla_descuento_automatico WHERE id_regla_descuento_automatico = ${ID_REGLA:-0}")
igual "PostgreSQL guardo lo mismo que se mando" "$FILA" "12|45|true|5400|17.50|true"
pedir POST /vendedor/reglas-descuento "$C_VEND" "$(cuerpo "$OFERTA" 5 10 false 60 10)"
igual "segunda regla sobre la misma oferta" "$CODIGO" "409"
pedir POST /vendedor/reglas-descuento "$C_VEND" "$(cuerpo "$AJENA" 5 10 false 60 10)"
igual "oferta ajena" "$CODIGO" "404"

# ------------------------------------------------------------------ 5
titulo "5. Listar y paginar"
pedir GET /vendedor/reglas-descuento "$C_VEND"
EN_LISTA=$(printf '%s' "$CUERPO" | python -c "
import sys,json; d=json.load(sys.stdin)['payload']
print('si' if any(r['id_regla_descuento_automatico']=='$ID_REGLA' for r in d) else 'no')")
igual "la nueva sale en GET" "$EN_LISTA" "si"
TOTAL_PG=$(sql "SELECT count(*) FROM regla_descuento_automatico r JOIN oferta o USING(id_oferta)
                 JOIN usuarios u ON u.id_usuario=o.id_usuario WHERE u.correo_electronico='$VENDEDOR'")
pedir GET "/vendedor/reglas-descuento/paginado?pagina=1&limite=1" "$C_VEND"
igual "total_reglas cuadra con PostgreSQL" "$(de_cuerpo payload.total_reglas)" "$TOTAL_PG"
igual "total_paginas con limite 1" "$(de_cuerpo payload.total_paginas)" "$TOTAL_PG"

# ------------------------------------------------------------------ 6
titulo "6. Editar"
ANTES=$(sql "SELECT fecha_actualizacion FROM regla_descuento_automatico WHERE id_regla_descuento_automatico=$ID_REGLA")
sleep 1
pedir PATCH "/vendedor/reglas-descuento/$ID_REGLA" "$C_VEND" '{"activa":false}'
igual "pausar da 200" "$CODIGO" "200"
igual "queda pausada" "$(de_cuerpo payload.activa)" "false"
DESPUES=$(sql "SELECT fecha_actualizacion FROM regla_descuento_automatico WHERE id_regla_descuento_automatico=$ID_REGLA")
if [ "$ANTES" != "$DESPUES" ]; then OK "el trigger movio fecha_actualizacion"; else FALLA "fecha_actualizacion no cambio"; fi
pedir PATCH "/vendedor/reglas-descuento/$ID_REGLA" "$C_VEND" '{"umbral_unidades":30,"porcentaje_descuento":25}'
igual "cambiar dos numeros da 200" "$CODIGO" "200"
FILA=$(sql "SELECT umbral_unidades||'|'||ventana_minutos||'|'||es_venta_relampago||'|'||duracion_segundos||'|'||porcentaje_descuento||'|'||activa
             FROM regla_descuento_automatico WHERE id_regla_descuento_automatico = $ID_REGLA")
igual "cambian esos dos y el resto sigue" "$FILA" "30|45|true|5400|25.00|false"
pedir PATCH "/vendedor/reglas-descuento/$ID_REGLA" "$C_VEND" '{}'
igual "PATCH vacio" "$CODIGO" "400"
pedir PATCH "/vendedor/reglas-descuento/$ID_REGLA" "$C_VEND" '{"porcentaje_descuento":91}'
igual "PATCH con 91%" "$CODIGO" "400"
pedir PATCH /vendedor/reglas-descuento/999999999 "$C_VEND" '{"activa":true}'
igual "regla que no existe" "$CODIGO" "404"

# ------------------------------------------------------------------ 7
titulo "7. Aislamiento entre vendedores"
pedir GET /vendedor/reglas-descuento "$C_OTRO"
LA_VE=$(printf '%s' "$CUERPO" | python -c "
import sys,json; d=json.load(sys.stdin)['payload']
print('si' if any(r['id_regla_descuento_automatico']=='$ID_REGLA' for r in d) else 'no')")
igual "el otro vendedor no la ve" "$LA_VE" "no"
pedir PATCH "/vendedor/reglas-descuento/$ID_REGLA" "$C_OTRO" '{"activa":true}'
igual "el otro vendedor no la puede editar" "$CODIGO" "404"
igual "y sigue pausada" "$(sql "SELECT activa FROM regla_descuento_automatico WHERE id_regla_descuento_automatico=$ID_REGLA")" "f"

# ------------------------------------------------------------------ 8
titulo "8. Exclusion con el descuento manual"
pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$C_VEND" '{"porcentaje_descuento":15}'
igual "con la regla pausada, el descuento manual entra" "$CODIGO" "201"
[ "$CODIGO" = "201" ] && DESCUENTO_PUESTO=1

pedir PATCH "/vendedor/reglas-descuento/$ID_REGLA" "$C_VEND" '{"activa":true}'
igual "reactivar la regla con el descuento puesto" "$CODIGO" "409"
case "$(de_cuerpo mensaje)" in
    *excluyentes*) OK "el 409 es el de la exclusion" ;;
    *)             FALLA "el 409 dice otra cosa: $(de_cuerpo mensaje)" ;;
esac
igual "la regla sigue pausada" "$(sql "SELECT activa FROM regla_descuento_automatico WHERE id_regla_descuento_automatico=$ID_REGLA")" "f"

pedir DELETE "/vendedor/ofertas/$OFERTA/descuento" "$C_VEND"
igual "quitar el descuento manual" "$CODIGO" "200"
[ "$CODIGO" = "200" ] && DESCUENTO_PUESTO=0

pedir PATCH "/vendedor/reglas-descuento/$ID_REGLA" "$C_VEND" '{"activa":true}'
igual "sin descuento, reactivar la regla" "$CODIGO" "200"

pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$C_VEND" '{"porcentaje_descuento":15}'
igual "con la regla activa, el descuento manual" "$CODIGO" "409"
[ "$CODIGO" = "201" ] && DESCUENTO_PUESTO=1
case "$(de_cuerpo mensaje)" in
    *"descuento automatico"*) OK "el 409 nombra la regla automatica" ;;
    *)                        FALLA "el 409 dice otra cosa: $(de_cuerpo mensaje)" ;;
esac
igual "y la oferta sigue sin descuento" "$(sql "SELECT COALESCE(porcentaje_descuento::text,'null') FROM oferta WHERE id_oferta=$OFERTA")" "null"

pedir PATCH "/vendedor/reglas-descuento/$ID_REGLA" "$C_VEND" '{"activa":false}'
igual "la regla vuelve a quedar pausada" "$CODIGO" "200"

echo
echo "=============================================================="
echo "Resultado: $ok OK, $fallo FALLA"
[ "$fallo" -eq 0 ]
