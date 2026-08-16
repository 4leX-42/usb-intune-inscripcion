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
2. `D:\ap.cmd` (ajusta la letra; `wmic logicaldisk get caption,volumename` si no la sabes).
3. Sigue la pantalla.

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

## Errores comunes

| Mensaje | Causa | Solucion |
|---|---|---|
| `insufficient privileges` / `forbidden` | Cuenta sin permisos | Intune Administrator o Global Administrator |
| `consent required` / `needs admin approval` | Falta consentimiento de la app de Graph | Lo aprueba un Global Admin |
| `could not connect` / TLS | Sin internet en el OOBE | Conecta red antes de abrir la consola, o usa `ap-csv.cmd` y sube el CSV desde otro equipo |
| `running scripts is disabled` | Estas lanzando el `.ps1` directamente | Usa `ap.cmd` (ya lanza PowerShell con `-ExecutionPolicy Bypass`) |
| `Unable to retrieve device hardware data (hash)` | El equipo no expone el hash por WMI | Arranque UEFI y TPM activado en BIOS |

## Estructura

```
ap.cmd / ap-online.cmd / ap-csv.cmd   lanzadores
autorun.inf                           AutoPlay en Windows normal (no afecta al OOBE)
Setup-Usb.ps1                         prepara un USB desde cero
Autopilot/Run-Autopilot.ps1           logica principal (hash, auth, subida)
Autopilot/Get-WindowsAutopilotInfo.ps1   script oficial de Microsoft
Autopilot/{Modules,Providers,Hashes}/    generados por Setup-Usb.ps1 / uso real (no versionados)
```

## Notas tecnicas

- El OOBE usa **Windows PowerShell 5.1**, no PowerShell 7. Todo verificado ahi.
- El `-Online` oficial llama a `Find-PackageProvider NuGet -ForceBootstrap` si
  no encuentra el proveedor, y eso tira a internet. Por eso `Setup-Usb.ps1`
  deja el proveedor en `Providers\` y `Run-Autopilot.ps1` lo copia a
  `%ProgramFiles%\PackageManagement\ProviderAssemblies` antes de invocarlo.
- La letra del USB se autodetecta (`%~dp0`). Da igual `E:`, `F:` o `G:`.
- Si el USB esta protegido contra escritura, el CSV cae en `%TEMP%`.
- En `-Online` el hash se recoge dos veces a proposito: el CSV queda en el USB
  antes de que el script oficial conecte a Graph, que no escribe nada hasta
  autenticar. Un login fallido no te deja sin hash.
- La salida de progreso del script oficial tiene bugs conocidos (variable de
  bucle equivocada al listar resultados, y comprueba un estado que ya no existe
  al esperar el sync). No afecta al registro; por eso el modo por defecto hace
  su propio sondeo de `deviceImportStatus`.

## Licencia

`Autopilot/Get-WindowsAutopilotInfo.ps1` es obra de Microsoft, distribuida via
PowerShell Gallery. El resto se distribuye tal cual, sin garantia.
