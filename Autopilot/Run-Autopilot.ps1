<#
    Run-Autopilot.ps1
    Recoge el hardware hash del equipo y lo registra en Windows Autopilot (Intune).

    Disenado para ejecutarse desde el OOBE (SHIFT+F10 -> cmd) con Windows PowerShell 5.1.
    La recogida del hash funciona OFFLINE: el script oficial y los modulos de Graph
    viajan en el USB, asi que no hace falta PSGallery ni el proveedor NuGet.
    Solo la subida a Intune necesita internet.

    El CSV se guarda SIEMPRE en el USB antes de intentar cualquier subida, en los
    tres modos. Si la subida falla, el hash no se pierde.

    MODOS DE SUBIDA:
      -Device       (por defecto) Device code hecho a mano. Abre Edge en el propio
                    equipo con el codigo ya metido en la URL. Sin Edge, muestra URL
                    y codigo para el movil.
      -Interactive  Ventana de login clasica (WAM). En el OOBE suele quedar detras
                    de PowerShell -> ALT+TAB. Si falla, cae a device code.
      -Online       Delega en Get-WindowsAutopilotInfo.ps1 -Online, el camino oficial
                    de Microsoft tal cual. Usa su propio Connect-MgGraph interactivo.

    NOTA: todos los mensajes van sin acentos a proposito. La consola del OOBE usa
    una codepage antigua y los acentos saldrian como basura.
#>

[CmdletBinding()]
param(
    # Group Tag de Autopilot (opcional). Ej: 'Portatiles-ES'
    [string] $GroupTag = '',

    # UPN del usuario asignado (opcional). Ej: 'juan@contoso.com'
    [string] $AssignedUser = '',

    # Device code + apertura automatica del login en Edge. Es el modo por defecto.
    [switch] $Device,

    # Ventana de login clasica en lugar de device code.
    [switch] $Interactive,

    # Delegar en el -Online del script oficial de Microsoft.
    [switch] $Online,

    # Solo con -Online: grupo de Entra al que anadir el equipo. Lo implementa el
    # script oficial, no este.
    [string] $AddToGroup = '',

    # Con -Device: no abrir navegador. Solo imprime URL y codigo (para el movil).
    [switch] $NoBrowser,

    # Tenant concreto si 'organizations' no vale en tu caso. Ej: 'contoso.onmicrosoft.com'
    [string] $TenantId = 'organizations',

    # No preguntar nada: recoge hash, guarda CSV e intenta subir a Intune.
    [switch] $Unattended,

    # Recoge hash y guarda CSV, pero no intenta subir nada.
    [switch] $CsvOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Client id publico de "Microsoft Graph Command Line Tools" (el que usa el SDK).
$GraphClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
$GraphScope    = 'https://graph.microsoft.com/DeviceManagementServiceConfig.ReadWrite.All offline_access openid profile'

# ---------------------------------------------------------------- helpers ----

function Write-Step { param([string]$Text) Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    OK   $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "    AVISO $Text" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Text) Write-Host "    ERROR $Text" -ForegroundColor Red }

function Pause-Fin {
    if ($Unattended) { return }
    Write-Host ''
    Write-Host 'Pulsa ENTER para cerrar...' -ForegroundColor DarkGray
    [void](Read-Host)
}

# Quita caracteres que no valen en un nombre de fichero.
function Get-SafeName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'DESCONOCIDO' }
    $bad = [System.IO.Path]::GetInvalidFileNameChars()
    $out = $Value.Trim()
    foreach ($c in $bad) { $out = $out.Replace($c, '_') }
    return ($out -replace '\s+', '_')
}

# Localiza msedge.exe. En el OOBE no hay asociacion de navegador por defecto,
# asi que hay que llamar al ejecutable directamente.
function Find-Edge {
    $candidates = @()
    try {
        $reg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction Stop).'(default)'
        if ($reg) { $candidates += $reg.Trim('"') }
    } catch { }
    $candidates += @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Open-LoginWindow {
    param([string]$Url)

    $edge = Find-Edge
    if ($edge) {
        # user-data-dir propio: en el OOBE se ejecuta como SYSTEM y el perfil normal
        # de Edge puede no ser escribible. Se pasa como UNA sola cadena para que
        # CreateProcess la reciba tal cual y las comillas queden solo en la ruta.
        $profileDir = Join-Path $env:TEMP 'ap-edge-profile'
        $argLine = '--no-first-run --no-default-browser-check --new-window ' +
                   "--user-data-dir=`"$profileDir`" `"$Url`""
        try {
            Start-Process -FilePath $edge -ArgumentList $argLine -ErrorAction Stop | Out-Null
            Write-Ok "Edge abierto: $edge"
            return $true
        } catch {
            Write-Warn "No he podido abrir Edge: $($_.Exception.Message)"
        }
    } else {
        Write-Warn 'No encuentro msedge.exe en este equipo.'
    }

    # Ultimo intento: asociacion del sistema.
    try {
        Start-Process $Url -ErrorAction Stop | Out-Null
        Write-Ok 'Abierto con el navegador por defecto'
        return $true
    } catch {
        return $false
    }
}

function Copy-ToClipboard {
    param([string]$Text)
    try { $Text | clip.exe; return $true } catch { }
    try { Set-Clipboard -Value $Text -ErrorAction Stop; return $true } catch { }
    return $false
}

<#
    El -Online del script oficial hace 'Find-PackageProvider NuGet -ForceBootstrap'
    si el proveedor no esta presente, y eso tira a internet (y en el OOBE puede
    colgarse). Llevamos el DLL en el USB y lo dejamos donde PowerShell 5.1 lo busca.
    Todo best-effort: si falla, seguimos igual.
#>
function Install-NuGetProviderOffline {
    param([string]$ProvidersDir)

    try {
        if (Get-PackageProvider NuGet -ErrorAction Ignore) {
            Write-Ok 'Proveedor NuGet ya presente'
            return
        }
    } catch { }

    if (-not (Test-Path $ProvidersDir)) {
        Write-Warn 'No hay proveedor NuGet en el USB. Si hace falta, intentara descargarlo.'
        return
    }

    try {
        $target = Join-Path $env:ProgramFiles 'PackageManagement\ProviderAssemblies'
        foreach ($verDir in Get-ChildItem (Join-Path $ProvidersDir 'nuget') -Directory) {
            $dest = Join-Path $target "nuget\$($verDir.Name)"
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Copy-Item (Join-Path $verDir.FullName '*.dll') $dest -Force
        }
        Import-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Out-Null
        Write-Ok "Proveedor NuGet instalado desde el USB en $target"
    } catch {
        Write-Warn "No he podido instalar el proveedor NuGet offline: $($_.Exception.Message)"
    }
}

# Extrae el JSON de error de una respuesta HTTP 400 (PS 5.1).
function Get-HttpErrorJson {
    param($ErrorRecord)
    $raw = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $raw = $ErrorRecord.ErrorDetails.Message
    } elseif ($ErrorRecord.Exception.Response) {
        try {
            $sr  = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
            $raw = $sr.ReadToEnd()
            $sr.Close()
        } catch { }
    }
    if (-not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

<#
    Device code flow hecho a mano, en vez de Connect-MgGraph -UseDeviceCode.
    Razon: el SDK solo imprime el mensaje y no devuelve el codigo, asi que no se
    puede prefijar en la URL ni abrir el navegador solo. Aqui controlamos el codigo,
    lo copiamos al portapapeles y abrimos Edge en la pagina con el codigo ya puesto.
    Devuelve el access token, o $null si falla.
#>
function Get-TokenByDeviceCode {
    param(
        [string] $Tenant,
        [string] $ClientId,
        [string] $Scope,
        [switch] $SkipBrowser
    )

    $authBase = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0"

    try {
        $dc = Invoke-RestMethod -Method POST -Uri "$authBase/devicecode" -Body @{
            client_id = $ClientId
            scope     = $Scope
        } -ErrorAction Stop
    } catch {
        Write-Bad "No he podido pedir el device code: $($_.Exception.Message)"
        return $null
    }

    $code = $dc.user_code
    $uri  = $dc.verification_uri

    # El endpoint v2 no devuelve verification_uri_complete, pero la pagina de device
    # auth acepta ?otc=<codigo> y lo deja rellenado. Si no lo aceptara, la pagina
    # carga igual y solo hay que teclear el codigo.
    $uriWithCode = "$uri" + "?otc=$code"

    Write-Host ''
    Write-Host '    +---------------------------------------------------+' -ForegroundColor White
    Write-Host '    |  CODIGO DE INICIO DE SESION                       |' -ForegroundColor White
    Write-Host ('    |            {0,-39}|' -f $code)                      -ForegroundColor Yellow
    Write-Host '    +---------------------------------------------------+' -ForegroundColor White
    Write-Host "    URL: $uri" -ForegroundColor White
    Write-Host ''

    if (Copy-ToClipboard $code) { Write-Ok 'Codigo copiado al portapapeles (CTRL+V en la pagina)' }

    if ($SkipBrowser) {
        Write-Host '    Abre la URL desde el MOVIL u otro PC y mete el codigo.' -ForegroundColor Yellow
    } else {
        Write-Step 'Abriendo la ventana de login'
        if (-not (Open-LoginWindow $uriWithCode)) {
            Write-Warn 'Sin navegador. Abre la URL de arriba desde el movil u otro PC.'
        } else {
            Write-Host '    Si la ventana no aparece, prueba ALT+TAB.' -ForegroundColor DarkGray
        }
    }

    Write-Step 'Esperando el inicio de sesion'
    Write-Host "    Caduca en $([int]($dc.expires_in / 60)) minutos. CTRL+C para abortar." -ForegroundColor DarkGray

    $interval = [int]$dc.interval; if ($interval -lt 1) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    $dots     = 0

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method POST -Uri "$authBase/token" -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $ClientId
                device_code = $dc.device_code
            } -ErrorAction Stop

            Write-Host ''
            Write-Ok 'Sesion iniciada'
            return $tok.access_token

        } catch {
            $j = Get-HttpErrorJson $_
            $e = if ($j) { $j.error } else { 'unknown' }

            switch ($e) {
                'authorization_pending' {
                    $dots++
                    Write-Host -NoNewline '.'
                    if ($dots % 30 -eq 0) { Write-Host '' }
                }
                'slow_down'              { $interval += 5 }
                'authorization_declined' { Write-Host ''; Write-Bad 'Login cancelado por el usuario.'; return $null }
                'expired_token'          { Write-Host ''; Write-Bad 'El codigo ha caducado. Vuelve a lanzar el script.'; return $null }
                'bad_verification_code'  { Write-Host ''; Write-Bad 'Codigo invalido.'; return $null }
                default {
                    Write-Host ''
                    $desc = if ($j) { $j.error_description } else { $_.Exception.Message }
                    Write-Bad "Error de autenticacion ($e): $desc"
                    return $null
                }
            }
        }
    }

    Write-Host ''
    Write-Bad 'Se agoto el tiempo esperando el login.'
    return $null
}

# ------------------------------------------------------------------ inicio ----

$Root         = $PSScriptRoot
$ScriptFile   = Join-Path $Root 'Get-WindowsAutopilotInfo.ps1'
$ModulesDir   = Join-Path $Root 'Modules'
$HashesDir    = Join-Path $Root 'Hashes'
$ProvidersDir = Join-Path $Root 'Providers'

# -Device es el modo por defecto. -Interactive lo sustituye. -Online manda sobre todo.
$AuthMode = 'Device'
if ($Interactive) { $AuthMode = 'Interactive' }
if ($Online)      { $AuthMode = 'Online' }

$flags = @()
if ($Device)      { $flags += '-Device' }
if ($Interactive) { $flags += '-Interactive' }
if ($Online)      { $flags += '-Online' }
if ($flags.Count -gt 1) {
    Write-Host "AVISO: modos incompatibles ($($flags -join ' ')). Uso $AuthMode." -ForegroundColor Yellow
}
if ($AddToGroup -and $AuthMode -ne 'Online') {
    Write-Host 'AVISO: -AddToGroup solo funciona con -Online. Se ignora.' -ForegroundColor Yellow
}

Clear-Host
Write-Host '===========================================================' -ForegroundColor White
Write-Host '  AUTOPILOT - Registro de hardware hash en Intune' -ForegroundColor White
Write-Host '===========================================================' -ForegroundColor White

# --- 1. Comprobaciones previas -----------------------------------------------

Write-Step 'Comprobando entorno'

if (-not (Test-Path $ScriptFile)) {
    Write-Bad "No encuentro $ScriptFile"
    Write-Bad 'El USB esta incompleto. Vuelve a prepararlo.'
    Pause-Fin; exit 1
}
Write-Ok "Script oficial encontrado ($ScriptFile)"

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Bad 'Esta ventana NO tiene permisos de administrador.'
    Write-Bad 'En el OOBE abre cmd con SHIFT+F10 (ya va como SYSTEM).'
    Write-Bad 'En Windows normal: clic derecho en ap.cmd -> Ejecutar como administrador.'
    Pause-Fin; exit 1
}
Write-Ok 'Permisos de administrador'

# TLS 1.2 - imprescindible en .NET Framework 4.x, si no la conexion a Graph falla.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
    Write-Ok 'TLS 1.2 activado'
} catch {
    Write-Warn "No he podido forzar TLS 1.2: $($_.Exception.Message)"
}

# Modulos del USB por delante de todo, para que Import-Module NO intente descargar.
if (Test-Path $ModulesDir) {
    $env:PSModulePath = "$ModulesDir;$env:PSModulePath"
    $mods = @(Get-ChildItem $ModulesDir -Directory | Select-Object -ExpandProperty Name)
    Write-Ok "Modulos offline listos: $($mods -join ', ')"
} else {
    Write-Warn 'No hay carpeta Modules en el USB. Si subes online hara falta internet + PSGallery.'
}

Write-Ok "Modo de subida: $AuthMode"

# --- 2. Datos del equipo -----------------------------------------------------

Write-Step 'Datos del equipo'

$bios = Get-CimInstance -ClassName Win32_BIOS
$cs   = Get-CimInstance -ClassName Win32_ComputerSystem
$Serial = "$($bios.SerialNumber)".Trim()

Write-Host "    Numero de serie : $Serial"
Write-Host "    Fabricante      : $($cs.Manufacturer)"
Write-Host "    Modelo          : $($cs.Model)"

# --- 3. Recoger hash y guardar CSV en el USB --------------------------------
# Se guarda SIEMPRE, antes de intentar subir, en los tres modos.
# En modo -Online esto es una pasada extra a proposito: el script oficial conecta
# a Graph ANTES de escribir el CSV, asi que si el login falla no dejaria nada.

Write-Step 'Recogiendo hardware hash'

$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$fileBase = "$(Get-SafeName $Serial)_$stamp.csv"

# Si el USB va en solo lectura, caemos a la carpeta temporal.
$OutDir = $HashesDir
try {
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $probe = Join-Path $OutDir '.probe'
    Set-Content -Path $probe -Value 'x' -ErrorAction Stop
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
} catch {
    Write-Warn "No puedo escribir en $OutDir (USB protegido?). Uso $env:TEMP"
    $OutDir = $env:TEMP
}

$CsvPath = Join-Path $OutDir $fileBase
$AllCsv  = Join-Path $OutDir '_TODOS.csv'

$apArgs = @{ OutputFile = $CsvPath }
if ($GroupTag)     { $apArgs['GroupTag']     = $GroupTag }
if ($AssignedUser) { $apArgs['AssignedUser'] = $AssignedUser }

& $ScriptFile @apArgs

if (-not (Test-Path $CsvPath)) {
    Write-Bad 'El script no ha generado el CSV. Hash no obtenido.'
    Pause-Fin; exit 1
}

$row  = Import-Csv $CsvPath | Select-Object -First 1
$Hash = $row.'Hardware Hash'
if ([string]::IsNullOrWhiteSpace($Hash)) {
    Write-Bad 'El CSV existe pero el hash viene vacio. Equipo no compatible o WMI bloqueado.'
    Pause-Fin; exit 1
}

Write-Ok "CSV guardado: $CsvPath"
Write-Ok "Hash de $($Hash.Length) caracteres"

# Acumulado de todos los equipos pasados por este USB: se puede importar de golpe.
try {
    if (Test-Path $AllCsv) { $row | Export-Csv -Path $AllCsv -NoTypeInformation -Append }
    else                   { $row | Export-Csv -Path $AllCsv -NoTypeInformation }
    Write-Ok "Anadido al acumulado: $AllCsv"
} catch {
    Write-Warn "No he podido actualizar el acumulado: $($_.Exception.Message)"
}

if ($CsvOnly) {
    Write-Step 'Hecho (modo solo CSV)'
    Write-Host "    Importa $CsvPath en Intune: Devices > Windows enrollment > Devices > Import"
    Pause-Fin; exit 0
}

# --- 4. Confirmar subida -----------------------------------------------------

$doUpload = $true
if (-not $Unattended) {
    Write-Host ''
    $answer = Read-Host 'Subir ahora a Intune? Necesita internet y cuenta admin [S/n]'
    if ($answer -and $answer.Trim().ToLower() -like 'n*') { $doUpload = $false }
}

if (-not $doUpload) {
    Write-Step 'Saltando subida'
    Write-Host "    CSV listo en: $CsvPath"
    Write-Host '    Importalo desde intune.microsoft.com > Devices > Windows enrollment > Devices > Import'
    Pause-Fin; exit 0
}

# --- 5. Modo -Online: delegar en el script oficial ---------------------------

if ($AuthMode -eq 'Online') {
    Write-Step 'Subida por el camino oficial (Get-WindowsAutopilotInfo -Online)'
    Write-Host '    OJO: este modo usa el Connect-MgGraph interactivo del script de' -ForegroundColor Yellow
    Write-Host '    Microsoft. La ventana de login puede quedar DETRAS de PowerShell.' -ForegroundColor Yellow
    Write-Host '    Si parece colgado, pulsa ALT+TAB o minimiza esta ventana.' -ForegroundColor Yellow

    Install-NuGetProviderOffline -ProvidersDir $ProvidersDir

    # Fichero aparte: el CSV bueno del USB ya esta escrito y no se toca.
    $onlineCsv = Join-Path $env:TEMP "autopilot-online-$stamp.csv"

    $onArgs = @{ Online = $true; OutputFile = $onlineCsv }
    if ($GroupTag)     { $onArgs['GroupTag']     = $GroupTag }
    if ($AssignedUser) { $onArgs['AssignedUser'] = $AssignedUser }
    if ($AddToGroup)   { $onArgs['AddToGroup']   = $AddToGroup }

    try {
        & $ScriptFile @onArgs
        Write-Host ''
        Write-Ok 'El script oficial ha terminado. Revisa su salida de arriba.'
    } catch {
        Write-Bad "El script oficial ha fallado: $($_.Exception.Message)"
        Write-Warn "El CSV esta a salvo en $CsvPath - importalo a mano en Intune."
        Pause-Fin; exit 1
    }

    Write-Host ''
    Write-Host '-----------------------------------------------------------' -ForegroundColor White
    Write-Host " Serie   : $Serial"
    Write-Host " CSV     : $CsvPath"
    Write-Host " Verifica: intune.microsoft.com > Devices > Windows enrollment > Devices"
    Write-Host '-----------------------------------------------------------' -ForegroundColor White
    Pause-Fin
    exit 0
}

# --- 6. Modos -Device / -Interactive: subida propia --------------------------

Write-Step 'Cargando modulo de Graph'

try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Write-Ok "Microsoft.Graph.Authentication $((Get-Module Microsoft.Graph.Authentication).Version)"
} catch {
    Write-Bad "No puedo cargar Microsoft.Graph.Authentication: $($_.Exception.Message)"
    Write-Warn "El CSV esta a salvo en $CsvPath - importalo a mano."
    Pause-Fin; exit 1
}

# --- 6a. Autenticacion -------------------------------------------------------

$connected = $false

if ($AuthMode -eq 'Interactive') {
    Write-Step 'Abriendo ventana de login (modo interactivo)'
    Write-Host '    OJO: en el OOBE la ventana de login suele quedar DETRAS de' -ForegroundColor Yellow
    Write-Host '    PowerShell. Si parece colgado, pulsa ALT+TAB o minimiza esta' -ForegroundColor Yellow
    Write-Host '    ventana para encontrarla.' -ForegroundColor Yellow
    try {
        Connect-MgGraph -Scopes 'DeviceManagementServiceConfig.ReadWrite.All' -NoWelcome -ErrorAction Stop
        $connected = $true
    } catch {
        Write-Bad "Fallo el login interactivo: $($_.Exception.Message)"
        Write-Warn 'Reintento con device code...'
    }
}

if (-not $connected) {
    Write-Step 'Autenticacion por device code'
    $token = Get-TokenByDeviceCode -Tenant $TenantId -ClientId $GraphClientId `
                                   -Scope $GraphScope -SkipBrowser:$NoBrowser
    if ($token) {
        try {
            $sec = ConvertTo-SecureString $token -AsPlainText -Force
            Connect-MgGraph -AccessToken $sec -NoWelcome -ErrorAction Stop
            $connected = $true
        } catch {
            Write-Bad "El token no ha sido aceptado por Connect-MgGraph: $($_.Exception.Message)"
        }
    }

    # Ultima red: el device code del propio SDK (sin navegador automatico).
    if (-not $connected) {
        Write-Warn 'Reintento con el device code del SDK de Graph...'
        try {
            Connect-MgGraph -UseDeviceCode -Scopes 'DeviceManagementServiceConfig.ReadWrite.All' `
                            -NoWelcome -ErrorAction Stop
            $connected = $true
        } catch {
            Write-Bad "Tambien ha fallado: $($_.Exception.Message)"
        }
    }
}

if (-not $connected) {
    Write-Bad 'No he conseguido autenticar.'
    Write-Warn "El CSV esta a salvo en $CsvPath - importalo a mano en Intune."
    Pause-Fin; exit 1
}

$ctx = Get-MgContext
Write-Ok "Conectado. Tenant: $($ctx.TenantId)  Cuenta: $($ctx.Account)"

# --- 6b. Ya registrado? ------------------------------------------------------

Write-Step 'Comprobando si el equipo ya esta en Autopilot'
$already = $null
try {
    $q = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$Serial')"
    $r = Invoke-MgGraphRequest -Method GET -Uri $q -ErrorAction Stop
    if ($r.value -and $r.value.Count -gt 0) { $already = $r.value[0] }
} catch {
    Write-Warn "No he podido consultar (sigo igualmente): $($_.Exception.Message)"
}

if ($already) {
    Write-Ok "YA ESTABA REGISTRADO. Serie $($already.serialNumber), grupo '$($already.groupTag)', estado $($already.enrollmentState)"
    Write-Host '    No hace falta volver a importarlo. Puedes cerrar y seguir con el OOBE.' -ForegroundColor Green
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    Pause-Fin; exit 0
}
Write-Ok 'No estaba registrado. Procedo a importarlo.'

# --- 6c. Importar ------------------------------------------------------------

Write-Step 'Importando dispositivo en Intune'

$body = @{
    '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
    serialNumber       = $Serial
    hardwareIdentifier = $Hash          # base64, Graph lo acepta como Binary
    groupTag           = $GroupTag
    productKey         = ''
}
if ($AssignedUser) { $body['assignedUserPrincipalName'] = $AssignedUser }

$importUri = 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities'

try {
    $created = Invoke-MgGraphRequest -Method POST -Uri $importUri `
        -Body ($body | ConvertTo-Json -Depth 5) -ContentType 'application/json' -ErrorAction Stop
    Write-Ok "Importacion aceptada. Id: $($created.id)"
} catch {
    Write-Bad "Fallo la importacion: $($_.Exception.Message)"
    Write-Warn "El CSV esta a salvo en $CsvPath - importalo a mano en Intune."
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    Pause-Fin; exit 1
}

# --- 6d. Esperar a que Intune procese el import ------------------------------

Write-Step 'Esperando resultado del import'

$statusUri = "$importUri/$($created.id)"
$final     = $null
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 5
    try {
        $chk    = Invoke-MgGraphRequest -Method GET -Uri $statusUri -ErrorAction Stop
        $status = $chk.state.deviceImportStatus
        Write-Host "    intento $i/30 - estado: $status"
        if ($status -and $status -ne 'pending' -and $status -ne 'unknown') { $final = $chk; break }
    } catch {
        Write-Warn "Consulta de estado fallida: $($_.Exception.Message)"
        break
    }
}

Write-Host ''
if (-not $final) {
    Write-Warn 'Sigue en pending tras 2.5 minutos. Normalmente acaba solo.'
    Write-Host "    Verifica en intune.microsoft.com buscando la serie $Serial"
} else {
    $st  = $final.state.deviceImportStatus
    $err = $final.state.deviceErrorName
    if ($st -eq 'complete') {
        Write-Ok "REGISTRADO CORRECTAMENTE. Serie $Serial"
        Write-Host "    DeviceRegistrationId: $($final.state.deviceRegistrationId)"
    } elseif ($err -match 'AlreadyAssigned|ZtdDeviceAlreadyAssigned') {
        Write-Ok "El equipo ya estaba asignado en Autopilot ($err). No hay nada mas que hacer."
    } else {
        Write-Bad "Import terminado con estado '$st' / error '$err' (codigo $($final.state.deviceErrorCode))"
        Write-Warn "El CSV esta a salvo en $CsvPath - importalo a mano."
    }
}

try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }

Write-Host ''
Write-Host '-----------------------------------------------------------' -ForegroundColor White
Write-Host " Serie   : $Serial"
Write-Host " CSV     : $CsvPath"
Write-Host " Verifica: intune.microsoft.com > Devices > Windows enrollment > Devices"
Write-Host '-----------------------------------------------------------' -ForegroundColor White
Pause-Fin
