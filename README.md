# USB Intune Inscripcion

USB para registrar equipos en Windows Autopilot (Intune) desde el OOBE, sin
PSGallery, sin instalar modulos y sin depender de ventanas de login escondidas.

Los modulos de Graph y el proveedor NuGet viajan en el propio USB, asi que la
recogida del hardware hash funciona sin internet. El CSV se guarda **siempre**
antes de intentar subir nada: si la subida a Intune falla, el hash no se pierde.

> El USB no se ejecuta solo: AutoRun esta desactivado en pendrives desde
> Windows 7 y el OOBE ni lee `autorun.inf`. Hay que abrir la consola a mano una
> vez. Todo lo demas esta automatizado.

## Uso en el OOBE

1. `FN + SHIFT + F10` (o `SHIFT + F10`).
2. `D:\ap.cmd` — ajusta la letra a la que tenga el USB en ese equipo.
3. Sigue la pantalla.

La letra solo hace falta para **lanzar** el `.cmd`: escribiendo la ruta le dices
a la consola donde esta el fichero. A partir de ahi el script se orienta solo
(`%~dp0` le da su propia carpeta), asi que encuentra `Autopilot\` y guarda los
CSV en el USB correcto sea `D:`, `E:` o la que sea. No hay ninguna letra escrita
a fuego en los scripts.

Si no sabes cual es, o la pruebas a ciegas:

```
for %d in (C D E F G H I J) do @if exist "%d:\ap.cmd" call "%d:\ap.cmd"
```

`ap.cmd` comprueba permisos/TLS/modulos, saca serie, fabricante y modelo,
recoge el hash, guarda el CSV en `Autopilot\Hashes\`, sube a Intune evitando
duplicados y confirma el resultado real del import.

**Login (device code, por defecto):** sale el codigo, se copia al portapapeles
y se abre Edge en la pagina de login con el codigo ya en la URL (`?otc=CODIGO`).
Inicias sesion y el script sigue solo. Si Edge no arranca, deja URL y codigo en
pantalla para el movil. La cuenta necesita **Intune Administrator** o
**Global Administrator**.

## Lanzadores

| Fichero | Que hace |
|---|---|
| `ap.cmd` | Flujo completo: hash + CSV + subida (device code + Edge). Por defecto. |
| `ap-online.cmd` | Igual, delegando la subida en `Get-WindowsAutopilotInfo.ps1 -Online` (camino oficial de Microsoft). |
| `ap-csv.cmd` | Solo genera el CSV. Sin login, sin internet. |

### Parametros de `ap.cmd`

| Parametro | Efecto |
|---|---|
| `-GroupTag "Portatiles-ES"` | Group tag |
| `-AssignedUser "usuario@dominio.com"` | Usuario asignado |
| `-Unattended` | No pregunta nada |
| `-NoBrowser` | Device code sin abrir navegador |
| `-Interactive` | Login clasico. En el OOBE queda detras de PowerShell (`ALT+TAB`); si falla, cae a device code |
| `-TenantId "contoso.onmicrosoft.com"` | Solo si tu tenant exige autoridad concreta (por defecto `organizations`) |
| `-AddToGroup "Autopilot-Devices"` | Solo con `ap-online.cmd`: anade a un grupo de Entra |

Se combinan: `D:\ap.cmd -Unattended -GroupTag "Portatiles-ES" -NoBrowser`

**Que modo usar:** el de por defecto si quieres que funcione sin pelearte (no
depende de ninguna ventana). `-Online` si prefieres el camino oficial de
Microsoft o necesitas `-AddToGroup`; ahi el login es el interactivo del script
de Microsoft, con el aviso de ventana escondida.

## Preparar el USB

El repositorio no incluye los modulos (~135 MB) ni CSVs con hashes reales:

```powershell
git clone https://github.com/4leX-42/usb-intune-inscripcion.git
cd usb-intune-inscripcion
.\Setup-Usb.ps1 -UsbPath D:\
```

Copia lanzadores y scripts al USB y descarga (`Save-Module` / `Save-Script`)
`Microsoft.Graph.Authentication`, `Microsoft.Graph.Groups`,
`Microsoft.Graph.Identity.DirectoryManagement`, `WindowsAutopilotIntune`,
`Get-WindowsAutopilotInfo.ps1` y el proveedor `NuGet`. Necesita PowerShell 5.1+
y acceso a PSGallery **solo para preparar el USB**, no para usarlo.

## Ficheros generados

```
D:\Autopilot\Hashes\<SERIE>_<fecha-hora>.csv   un CSV por equipo
D:\Autopilot\Hashes\_TODOS.csv                 acumulado, importable de una vez
```

## Importar y verificar en Intune

`https://intune.microsoft.com` > **Devices > Windows enrollment > Devices**

- **Importar:** boton `Import`, selecciona el CSV, espera unos minutos y pulsa `Sync`.
- **Verificar:** busca por numero de serie (`wmic bios get serialnumber`). Si no
  aparece, pulsa `Sync` y refresca.

## Comandos utiles

Todo esto es PowerShell 5.1, que es lo que hay en el OOBE. `wmic` sigue
funcionando en equipos antiguos, pero ya no viene en Windows 11 24H2 en
adelante: estos equivalentes valen siempre.

### En el OOBE, antes de registrar

```powershell
# Letra del USB
Get-Volume | Where-Object DriveType -eq 'Removable' |
  Select-Object DriveLetter,FileSystemLabel,Size

# Serie, fabricante y modelo (lo que acaba en el CSV)
Get-CimInstance Win32_BIOS | Select-Object SerialNumber
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,Name

# Requisitos para que salga el hash: arranque UEFI + TPM activo
$env:firmware_type
Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm |
  Select-Object IsEnabled_InitialValue,IsActivated_InitialValue,SpecVersion

# El hash tal cual lo expone WMI (es lo que recoge el script)
(Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DevDetail_Ext01).DeviceHardwareData

# Red: sin estos dos no hay subida a Intune
netsh wlan show interfaces
Test-NetConnection login.microsoftonline.com -Port 443
Test-NetConnection graph.microsoft.com -Port 443
```

### Cuentas y permisos en el equipo

```powershell
# Administradores locales. Por SID, asi funciona en Windows en cualquier idioma
# ("Administrators" / "Administradores" cambia el nombre del grupo)
Get-LocalGroupMember -SID S-1-5-32-544

# Usuarios locales habilitados
Get-LocalUser | Where-Object Enabled |
  Select-Object Name,LastLogon,PasswordLastSet,PasswordExpires

# Quien soy y si la consola va realmente elevada
whoami
[Security.Principal.WindowsPrincipal]::new(
  [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

### Cuentas con permisos en el tenant

Con los modulos que ya viajan en el USB, sin instalar nada:

```powershell
Import-Module D:\Autopilot\Modules\Microsoft.Graph.Authentication
Import-Module D:\Autopilot\Modules\Microsoft.Graph.Identity.DirectoryManagement
Connect-MgGraph -Scopes RoleManagement.Read.Directory,Directory.Read.All -UseDeviceCode

# Quien tiene Intune Administrator o Global Administrator
Get-MgDirectoryRole -All |
  Where-Object DisplayName -in 'Intune Administrator','Global Administrator' |
  ForEach-Object {
    $rol = $_.DisplayName
    Get-MgDirectoryRoleMember -DirectoryRoleId $_.Id | ForEach-Object {
      [pscustomobject]@{
        Rol    = $rol
        Cuenta = $_.AdditionalProperties.userPrincipalName
      }
    }
  }

# Con que cuenta y permisos estoy conectado ahora mismo
Get-MgContext | Select-Object Account,TenantId,Scopes
```

`Get-MgDirectoryRole` solo devuelve los roles **activados** en el tenant. Si un
rol no aparece es que nadie lo tiene asignado todavia.

Para comprobar si un equipo ya esta en Autopilot antes de volver a subirlo
(modulo `WindowsAutopilotIntune`, tambien en el USB):

```powershell
Import-Module D:\Autopilot\Modules\WindowsAutopilotIntune
Get-AutopilotDevice -serial "1234567890" |
  Select-Object serialNumber,groupTag,enrollmentState,deploymentProfileAssignmentStatus
```

### Despues del despliegue, para verificar

```powershell
# Nombre del equipo y estado real de union a Entra / Intune
dsregcmd /status |
  Select-String 'Device Name|AzureAdJoined|DomainJoined|TenantName|DeviceId|MdmUrl'

# Solo el nombre
hostname

# Renombrar a mano (Autopilot lo hace solo si el perfil trae plantilla de nombre)
Rename-Computer -NewName "ES-LAP-001" -Restart

# Perfil de Autopilot que se aplico
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\AutoPilot' |
  Format-List CloudAssignedTenantDomain,CloudAssignedTenantId,CloudAssignedDeviceName
```

El nombre que se ve en Intune es el del equipo (`Device Name` de `dsregcmd`),
no el del CSV: el CSV solo lleva serie, hash y opcionalmente group tag y
usuario asignado.

## Notas tecnicas

- El OOBE usa **Windows PowerShell 5.1**, no PowerShell 7. Todo verificado ahi.
- El `-Online` oficial llama a `Find-PackageProvider NuGet -ForceBootstrap` si
  no encuentra el proveedor, y eso tira a internet. Por eso `Setup-Usb.ps1`
  deja el proveedor en `Providers\` y `Run-Autopilot.ps1` lo copia a
  `%ProgramFiles%\PackageManagement\ProviderAssemblies` antes de invocarlo.
- Los `.cmd` resuelven su propia ubicacion con `%~dp0`, no la letra del USB.
  Tu tienes que teclear la letra para lanzarlos, pero dentro ya no se usa: las
  rutas a `Autopilot\`, `Modules\` y `Hashes\` salen de ahi. Da igual `D:`,
  `E:` o `G:`, y el USB puede cambiar de letra entre equipos sin tocar nada.
- Si el USB esta protegido contra escritura, el CSV cae en `%TEMP%`.
- En `-Online` el hash se recoge dos veces a proposito: el CSV queda en el USB
  antes de que el script oficial conecte a Graph, que no escribe nada hasta
  autenticar. Un login fallido no te deja sin hash.
- La salida de progreso del script oficial tiene bugs conocidos (variable de
  bucle equivocada al listar resultados, y comprueba un estado que ya no existe
  al esperar el sync). No afecta al registro; por eso el modo por defecto hace
  su propio sondeo de `deviceImportStatus`.
- `Autopilot/Get-WindowsAutopilotInfo.ps1` es obra de Microsoft, descargado de
  PowerShell Gallery por `Setup-Usb.ps1`.
