# demo-fraude-login.ps1
# Demuestra, con ventanas de navegador de verdad escribiendo solas, las
# senales de fraude de login que NO necesitan una IP distinta:
#
#   fuerza_bruta_cuenta   varios fallos seguidos contra -Cuenta
#   fuerza_bruta_ip       los mismos fallos, contados por IP (misma maquina)
#   multi_cuenta_ip       -Cuenta y -OtrasCuentas, probadas una tras otra
#                         (SOLO si se pasa -OtrasCuentas -- ver el param())
#
#   .\demo-fraude-login.ps1 -Cuenta ventas.norte@mesh.com
#   .\demo-fraude-login.ps1 -Cuenta ventas.norte@mesh.com `
#     -OtrasCuentas compradora.norte@mesh.com,comprador.sur@mesh.com,admin@mesh.com
#
# LO QUE ESTO NO CUBRE, A PROPOSITO
# ------------------------------------------------------------
# viaje_imposible e ip_rotacion_cuenta (con su version _lenta) piden que el
# intento venga de una IP DISTINTA a la anterior -- son literalmente "el
# origen cambio", y desde una sola maquina el origen es siempre el mismo.
# Para esas dos ya existe .\demo-fraude-pais.ps1, que las simula de verdad con
# Tor saliendo de otro pais. toma_cuenta tampoco: pregunta si la IP es NUEVA
# para la cuenta, y en esta maquina todas las cuentas de prueba ya tienen
# 127.0.0.1 en su historial desde que se sembraron.
#
# fuerza_bruta_cuenta_lenta y multi_cuenta_ip_lenta (Elasticsearch, umbral 15
# y 8) tampoco se disparan con los numeros de aqui a proposito: son el
# respaldo retrospectivo de las de Redis, y demostrar las dos con los mismos
# clics seria repetir la misma escena dos veces. Si hace falta verlas, subir
# -IntentosFuerzaBruta a 16 o -OtrasCuentas a ocho correos las alcanza.
#
#
# COMO ESCRIBE SOLO EN LA VENTANA
# ------------------------------------------------------------
# No hay Selenium ni Playwright instalados en este proyecto, y meter uno solo
# para esto era mas peso del que vale. En vez de eso se abre Chrome o Edge de
# verdad y se le mandan pulsaciones de teclado reales (SendKeys) -- exactamente
# lo que verias si alguien lo estuviera escribiendo a mano, rapido.
#
# Por eso el campo de correo de /entrar ahora lleva `autofocus`
# (frontend/src/routes/entrar/+page.svelte): sin eso, cada intento nuevo
# habria que contar cuantos Tab hacen falta para llegar al campo, y ese numero
# se rompe en cuanto alguien agregue un enlace a la cabecera. Con autofocus el
# cursor siempre esta en "Correo o usuario" apenas carga la pagina, y entre un
# intento y el siguiente la ventana se manda a /entrar OTRA VEZ con Ctrl+L (el
# atajo que enfoca la barra de direcciones en cualquier navegador) en vez de
# intentar limpiar los campos a mano.
#
# SendKeys manda las teclas a la ventana que este AL FRENTE en ese instante,
# sin importar cual sea -- no hay forma de apuntarlo a una ventana en
# particular. Por eso, antes de cada rafaga, el script comprueba con
# GetForegroundWindow() que la ventana al frente sigue siendo la que abrio.
# Windows le puede robar el foco solo (un aviso de Chrome, una notificacion
# del sistema) sin que nadie haya tocado nada, asi que primero se INTENTA
# recuperarlo con SetForegroundWindow otra vez -- solo si eso tambien falla
# se detiene, en vez de escribir a ciegas en lo que sea que haya quedado
# abierto. Aun asi: NO toques el mouse ni el teclado mientras corre.
#
# Chrome tiene un detalle que rompe la forma obvia de encontrar la ventana:
# si ya esta abierto, `chrome.exe url` no crea un proceso nuevo -- le pasa la
# URL a la instancia que ya corre y el proceso que lanzo este script SALE
# enseguida, asi que su Id o su MainWindowHandle no sirven de nada. Por eso
# se busca por TITULO de ventana ("Mesh"), comparando un antes y un despues:
# la que aparece nueva es la que se acaba de abrir.

param(
    [Parameter(Mandatory = $true)]
    [string]$Cuenta,

    # VACIA por defecto a proposito: este script SOLO ataca las cuentas que
    # se le mandan, nunca una lista escondida. multi_cuenta_ip necesita 4
    # identificadores DISTINTOS probados desde la misma IP en 5 minutos, asi
    # que sin -OtrasCuentas esa parte se salta sola (avisando por que) y
    # solo corre la fuerza bruta contra -Cuenta.
    #
    #   .\demo-fraude-login.ps1 -Cuenta ventas.norte@mesh.com `
    #     -OtrasCuentas compradora.norte@mesh.com,comprador.sur@mesh.com,admin@mesh.com
    [string[]]$OtrasCuentas = @(),

    [string]$Frontend = 'http://localhost:5173',

    # fuerza_bruta_cuenta pide 5 en 60s; fuerza_bruta_ip pide 8 en 60s. Con 8
    # se disparan las DOS a la vez, en la misma ventana.
    [int]$IntentosFuerzaBruta = 8
)

function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

# ------------------------------------------------------------
# Comprobaciones antes de tocar nada
# ------------------------------------------------------------
Paso "Revisando que Mesh este arriba"
docker ps *> $null
if ($LASTEXITCODE -ne 0) { Mal "Docker no responde. Abre Docker Desktop y corre .\arrancar.ps1"; exit 1 }
if (-not (docker ps --format '{{.Names}}' | Select-String -Quiet 'mesh-postgres')) {
    Mal "Los contenedores de Mesh no estan arriba. Corre primero: .\arrancar.ps1"; exit 1
}
try { Invoke-RestMethod -Uri "$Frontend/entrar" -TimeoutSec 5 -UseBasicParsing *> $null }
catch { Mal "El frontend no contesta en $Frontend. Corre: cd frontend ; npm run dev"; exit 1 }
Ok "Docker, los contenedores y el frontend estan arriba"

# ------------------------------------------------------------
# El navegador: Chrome primero, Edge si no esta
# ------------------------------------------------------------
$candidatos = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
)
$navegador = $candidatos | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $navegador) {
    Mal "No encontre Chrome ni Edge instalados en las rutas de siempre."
    exit 1
}
Ok "Navegador: $navegador"

# Modo privado (incognito en Chrome, InPrivate en Edge) -- no es por
# discrecion, es lo que arreglo el corte real que paso dos veces seguidas: en
# una ventana normal, despues de varios intentos de login Chrome ofrece
# "Quieres que Chrome guarde tu contrasena?" con un globito que le puede
# robar el foco a media rafaga, y SendKeys termina escribiendo ahi. En modo
# privado Chrome NUNCA ofrece guardar contrasenas, asi que ese globito no
# existe. De paso evita el otro problema ya visto (el autocompletado
# guardado sustituyendo lo que se acaba de escribir por una sugerencia
# vieja): en modo privado no hay sugerencias guardadas que ofrecer.
$modoPrivado = if ($navegador -match 'msedge') { '--inprivate' } else { '--incognito' }

# ------------------------------------------------------------
# Win32: encontrar ventanas por titulo y ponerlas al frente
# ------------------------------------------------------------
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class VentanaMesh {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc enumProc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

    public static Dictionary<IntPtr, string> Listar() {
        var mapa = new Dictionary<IntPtr, string>();
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            if (sb.Length > 0) mapa[hWnd] = sb.ToString();
            return true;
        }, IntPtr.Zero);
        return mapa;
    }
}
"@

# Abre una ventana NUEVA (--new-window) con esa URL y devuelve su handle, o
# $null si no la encontro en 8 segundos. "Nueva" se decide comparando con lo
# que ya habia ANTES de lanzar el navegador, por el motivo de Chrome del
# encabezado.
function Abrir-VentanaNueva([string]$url) {
    $antes = [VentanaMesh]::Listar().Keys
    Start-Process -FilePath $navegador -ArgumentList "--new-window", $modoPrivado, "`"$url`""
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 200
        $ahora = [VentanaMesh]::Listar()
        $nueva = $ahora.Keys | Where-Object { $_ -notin $antes -and $ahora[$_] -match 'Mesh' }
        if ($nueva) { return $nueva | Select-Object -First 1 }
    }
    return $null
}

# Pone esa ventana al frente y comprueba que de verdad quedo al frente --
# SetForegroundWindow puede fallar en silencio si Windows decide que este
# proceso no tiene "foco" para robarlo (pasa si la ventana de PowerShell tiene
# el foco cuando se pide el cambio).
function Enfocar([IntPtr]$handle) {
    [VentanaMesh]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 400
    return ([VentanaMesh]::GetForegroundWindow() -eq $handle)
}

# El candado de seguridad: si la ventana al frente cambio entre que se enfoco
# y que le toca escribir, SendKeys mandaria las teclas a lo que sea que la
# persona tenga abierto ahora. Antes de darse por vencido, REINTENTA
# ponerla al frente una vez -- un aviso de Chrome o una notificacion de
# Windows le pueden robar el foco solos, sin que nadie haya tocado nada, y
# alli SetForegroundWindow otra vez basta para recuperarlo. Solo si el
# reintento tambien falla se detiene el script entero: mejor parar que
# arriesgarse a escribir un correo y una contrasena en la ventana equivocada.
function Confirmar-O-Abortar([IntPtr]$handle, [string]$fase) {
    if ([VentanaMesh]::GetForegroundWindow() -eq $handle) { return }
    if (Enfocar $handle) { return }
    Mal "La ventana de '$fase' ya no esta al frente y no la pude recuperar. Me detengo aqui para no escribir en la ventana equivocada."
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms

# SendKeys trata +^%~(){} como teclas especiales. Los correos y contrasenas de
# esta demo no los llevan, pero si algun dia -OtrasCuentas trae uno con punto
# y coma o parentesis, esto evita que rompa la secuencia en vez de escribirlo.
function Escapar-SendKeys([string]$texto) {
    -join ($texto.ToCharArray() | ForEach-Object {
        if ('+^%~(){}' -match [regex]::Escape($_)) { "{$_}" } else { $_ }
    })
}

# Un intento de login completo: recarga /entrar con Ctrl+L (no hace falta
# limpiar campos a mano), escribe el identificador (ya con foco por el
# autofocus del campo), Tab al campo de contrasena, y Enter para mandar el
# formulario.
function Enviar-Intento([IntPtr]$handle, [string]$fase, [string]$identificador, [string]$contrasena) {
    Confirmar-O-Abortar $handle $fase
    $sk = [System.Windows.Forms.SendKeys]
    $sk::SendWait('^l')
    Start-Sleep -Milliseconds 150
    $sk::SendWait((Escapar-SendKeys "$Frontend/entrar"))
    $sk::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 1400
    Confirmar-O-Abortar $handle $fase
    $sk::SendWait((Escapar-SendKeys $identificador))
    $sk::SendWait('{TAB}')
    $sk::SendWait((Escapar-SendKeys $contrasena))
    $sk::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 1200
}

Write-Host ""
Write-Host "=============================================================="
Write-Host " Van a abrirse ventanas de Chrome/Edge que escriben SOLAS." -ForegroundColor Yellow
Write-Host " No toques el mouse ni el teclado hasta que termine." -ForegroundColor Yellow
Write-Host "=============================================================="
Start-Sleep -Seconds 3

# ------------------------------------------------------------
# Parte 1: fuerza bruta contra -Cuenta (dispara fuerza_bruta_cuenta Y
# fuerza_bruta_ip a la vez: los $IntentosFuerzaBruta fallos cuentan para las
# dos, porque salen de la misma cuenta Y de la misma IP).
# ------------------------------------------------------------
Paso "Fuerza bruta contra $Cuenta ($IntentosFuerzaBruta intentos)"
$vFuerzaBruta = Abrir-VentanaNueva "$Frontend/entrar"
if (-not $vFuerzaBruta) { Mal "No pude abrir la ventana. Prueba a mano: $Frontend/entrar"; exit 1 }
if (-not (Enfocar $vFuerzaBruta)) { Mal "No pude poner la ventana al frente."; exit 1 }
Start-Sleep -Milliseconds 800
for ($i = 1; $i -le $IntentosFuerzaBruta; $i++) {
    Enviar-Intento $vFuerzaBruta "fuerza bruta" $Cuenta "clave-mala-$i"
    Write-Host "   intento $i de $IntentosFuerzaBruta" -ForegroundColor DarkGray
}
Ok "Listo: $IntentosFuerzaBruta fallos contra $Cuenta desde esta maquina"

# ------------------------------------------------------------
# Parte 2: multi_cuenta_ip -- $Cuenta y -OtrasCuentas, una detras de otra,
# desde la MISMA IP (necesita 4 identificadores distintos en 300s).
# ------------------------------------------------------------
$identificadores = @($Cuenta) + $OtrasCuentas | Select-Object -Unique
if ($identificadores.Count -lt 4) {
    Mal "multi_cuenta_ip pide 4 cuentas distintas y solo hay $($identificadores.Count) (revisa -OtrasCuentas). Se salta esta parte."
} else {
    Paso "Probando $($identificadores.Count) cuentas distintas desde esta IP"
    $vMultiCuenta = Abrir-VentanaNueva "$Frontend/entrar"
    if (-not $vMultiCuenta) { Mal "No pude abrir la ventana. Prueba a mano: $Frontend/entrar"; exit 1 }
    if (-not (Enfocar $vMultiCuenta)) { Mal "No pude poner la ventana al frente."; exit 1 }
    Start-Sleep -Milliseconds 800
    foreach ($id in $identificadores) {
        Enviar-Intento $vMultiCuenta "multi-cuenta" $id "clave-mala"
        Write-Host "   probado: $id" -ForegroundColor DarkGray
    }
    Ok "Listo: $($identificadores.Count) cuentas distintas probadas desde la misma IP"
}

# ------------------------------------------------------------
# El resultado, en una tercera ventana
# ------------------------------------------------------------
Paso "Abriendo el panel de fraude"
Start-Process -FilePath $navegador -ArgumentList "--new-window", $modoPrivado, "`"$Frontend/panel?s=fraude`""

Write-Host ""
Write-Host "=============================================================="
Write-Host " LISTO. Entra como admin@mesh.com / Admin123 y mira 'Fraude'." -ForegroundColor Green
Write-Host " Deberian aparecer fuerza_bruta_cuenta, fuerza_bruta_ip y" -ForegroundColor Green
Write-Host " multi_cuenta_ip. Con la cuenta $Cuenta veras las mismas" -ForegroundColor Green
Write-Host " alertas en la campanita de la cabecera." -ForegroundColor Green
Write-Host "=============================================================="
