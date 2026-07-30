<#
    Setup-Usb.ps1
    Prepara un USB de Autopilot desde cero a partir de este repositorio.

    Copia los lanzadores y el script principal, y descarga (via Save-Module /
    Save-Script) todo lo necesario para que la recogida del hardware hash
    funcione OFFLINE en el OOBE:

      - Get-WindowsAutopilotInfo.ps1 (script oficial de Microsoft)
      - Microsoft.Graph.Authentication
      - Microsoft.Graph.Groups
      - Microsoft.Graph.Identity.DirectoryManagement
      - WindowsAutopilotIntune
      - proveedor NuGet (solo lo necesita el modo -Online)

    Requiere acceso a PSGallery en la maquina donde se ejecuta este script.
    El USB resultante no necesita internet para recoger el hash.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $UsbPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $UsbPath)) {
    throw "No existe la ruta '$UsbPath'."
}
$UsbPath = (Resolve-Path $UsbPath).Path.TrimEnd('\')

$Root       = $PSScriptRoot
$AutopilotSrc = Join-Path $Root 'Autopilot'
$ModulesDir   = Join-Path $UsbPath 'Autopilot\Modules'
$ProvidersDir = Join-Path $UsbPath 'Autopilot\Providers\nuget'
$HashesDir    = Join-Path $UsbPath 'Autopilot\Hashes'

Write-Host "==> Copiando lanzadores a $UsbPath"
Copy-Item (Join-Path $Root 'ap.cmd')        $UsbPath -Force
Copy-Item (Join-Path $Root 'ap-online.cmd') $UsbPath -Force
Copy-Item (Join-Path $Root 'ap-csv.cmd')    $UsbPath -Force
Copy-Item (Join-Path $Root 'autorun.inf')   $UsbPath -Force

New-Item -ItemType Directory -Force (Join-Path $UsbPath 'Autopilot') | Out-Null
New-Item -ItemType Directory -Force $HashesDir | Out-Null
Copy-Item (Join-Path $AutopilotSrc 'Run-Autopilot.ps1') (Join-Path $UsbPath 'Autopilot') -Force

Write-Host '==> Script oficial de Microsoft (Get-WindowsAutopilotInfo.ps1)'
if (-not (Get-PSRepository PSGallery -ErrorAction SilentlyContinue) -or
    (Get-PSRepository PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository PSGallery -InstallationPolicy Trusted
}
Save-Script Get-WindowsAutoPilotInfo -Path (Join-Path $UsbPath 'Autopilot') -Repository PSGallery -Force

Write-Host '==> Modulos de Microsoft Graph (offline)'
New-Item -ItemType Directory -Force $ModulesDir | Out-Null
$mods = 'WindowsAutopilotIntune', 'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Groups', 'Microsoft.Graph.Identity.DirectoryManagement'
foreach ($m in $mods) {
    Write-Host "    - $m"
    Save-Module -Name $m -Path $ModulesDir -Repository PSGallery -Force
}

Write-Host '==> Proveedor NuGet (offline, solo para el modo -Online)'
New-Item -ItemType Directory -Force $ProvidersDir | Out-Null
$provider = Get-PackageProvider NuGet -ErrorAction SilentlyContinue
if ($provider -and $provider.ProviderPath -and (Test-Path $provider.ProviderPath)) {
    $verDir = Join-Path $ProvidersDir $provider.Version.ToString()
    New-Item -ItemType Directory -Force $verDir | Out-Null
    Copy-Item $provider.ProviderPath $verDir -Force
    Write-Host "    proveedor $($provider.Version) copiado"
} else {
    Write-Warning 'No hay proveedor NuGet cargado en esta maquina. El modo -Online necesitara internet para bootstrapearlo la primera vez.'
}

Write-Host ''
Write-Host "USB listo en $UsbPath" -ForegroundColor Green
Write-Host 'Lee README.md para el uso en el OOBE.'
