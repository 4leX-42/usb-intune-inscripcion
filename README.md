# intune-autopilot-oobe-toolkit

Kit de USB para registrar equipos en Windows Autopilot (Intune) directamente
desde el OOBE (la pantalla inicial de configuracion de Windows), sin conexion
previa a un dominio ni instalacion manual de modulos.

## Por que existe esto

El flujo oficial de Microsoft (`Install-Module` + `Install-Script` +
`Get-WindowsAutopilotInfo -Online`) depende de PSGallery, del proveedor NuGet
y de una ventana de login que en el OOBE puede quedar escondida detras de
PowerShell. Este kit resuelve los tres problemas:

- **Offline por defecto**: los modulos de Microsoft Graph y el proveedor NuGet
  se sirven desde el propio USB. La recogida del hardware hash no necesita
  internet.
- **Login sin depender de ventanas escondidas**: modo `-Device` por defecto,
  que hace el flujo de device code a mano, copia el codigo al portapapeles y
  abre Edge ya con el codigo puesto en la URL.
- **El CSV se guarda siempre antes de intentar subir nada**, en los tres
  modos. Si la subida a Intune falla, el hash no se pierde.

No existe forma de que Windows ejecute nada solo al insertar el USB durante
el OOBE (AutoRun para pendrives esta desactivado desde Windows 7, y el OOBE ni
siquiera lee `autorun.inf`). Siempre hace falta abrir una consola a mano una
vez; todo lo que viene despues esta automatizado.

## Preparar el USB

Este repositorio no incluye los modulos de PowerShell (binarios, ~135 MB) ni
CSVs con hashes de equipos reales. Se generan con un script:

```powershell
git clone <url-de-este-repo>
cd intune-autopilot-oobe-toolkit
.\Setup-Usb.ps1 -UsbPath D:\
```

Esto copia los lanzadores y el script al USB, y descarga (via `Save-Module` /
`Save-Script`) todo lo necesario para que la recogida del hash funcione sin
internet:

- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Groups`
- `Microsoft.Graph.Identity.DirectoryManagement`
- `WindowsAutopilotIntune`
- `Get-WindowsAutopilotInfo.ps1` (script oficial de Microsoft)
- proveedor `NuGet` (para el modo `-Online`)

Requiere ejecutarse en una maquina con PowerShell 5.1+ y acceso a PSGallery
(solo para preparar el USB, no para usarlo despues).

## Uso en el OOBE

1. En la pantalla del OOBE: `FN + SHIFT + F10` (o `SHIFT + F10`).
2. Escribe (ajusta la letra si el USB no es `D:`):

   ```
   D:\ap.cmd
   ```

3. Sigue la pantalla. El flujo por defecto:
   - comprueba permisos de administrador, TLS 1.2 y modulos offline
   - saca numero de serie, fabricante y modelo
   - recoge el hardware hash
   - guarda el CSV en el USB (`Autopilot\Hashes\`)
   - pregunta si subir a Intune y, si dices que si, autentica y sube
   - comprueba si el equipo ya estaba registrado (evita duplicados)
   - espera y confirma el resultado real del import

Si no sabes la letra del USB en el OOBE:

```
wmic logicaldisk get caption,volumename
```

## Autenticacion

Modo por defecto: **device code con apertura automatica del navegador**.

1. Sale el codigo en pantalla dentro de un recuadro.
2. El codigo se copia al portapapeles (`CTRL+V` en la pagina).
3. Se abre Edge en el propio equipo, en la pagina de login, con el codigo
   ya puesto en la URL (`?otc=CODIGO`).
4. Inicias sesion con la cuenta de administrador. El script detecta el login
   y continua solo.

Si Edge no esta disponible o no arranca, el script no se bloquea: deja la
URL y el codigo en pantalla para completarlos desde el movil u otro equipo.

La cuenta necesita rol **Intune Administrator** o **Global Administrator**.

## Lanzadores

| Fichero | Que hace |
|---|---|
| `ap.cmd` | Flujo completo: hash + CSV + subida (device code + Edge). Modo por defecto. |
| `ap-online.cmd` | Igual, pero delegando la subida en `Get-WindowsAutopilotInfo.ps1 -Online` (camino oficial de Microsoft). |
| `ap-csv.cmd` | Solo genera el CSV en el USB. Sin login, sin internet. |

### Parametros

```
D:\ap.cmd -GroupTag "Portatiles-ES"
D:\ap.cmd -GroupTag "Portatiles-ES" -AssignedUser "usuario@dominio.com"
D:\ap.cmd -Unattended
D:\ap.cmd -Unattended -GroupTag "Portatiles-ES" -NoBrowser
D:\ap.cmd -Interactive
D:\ap.cmd -NoBrowser
D:\ap.cmd -TenantId "contoso.onmicrosoft.com"
D:\ap-online.cmd -AddToGroup "Autopilot-Devices"
```

- `-Interactive`: ventana de login clasica en vez de device code. En el OOBE
  puede quedar detras de PowerShell (`ALT+TAB` para encontrarla). Si falla,
  cae automaticamente a device code.
- `-Online`: delega en el script oficial de Microsoft tal cual (incluye
  `-AddToGroup`, que no existe en los otros modos). Usa su propio login
  interactivo, asi que aqui si aplica el aviso de la ventana escondida.
- `-NoBrowser`: device code sin abrir navegador, solo imprime URL y codigo.
- `-TenantId`: por defecto `organizations`. Solo hace falta si tu tenant
  necesita una autoridad concreta.

### Que modo usar

`-Device` (por defecto) si quieres que funcione sin depender de que aparezca
ninguna ventana concreta. `-Online` si prefieres el camino oficial de
Microsoft sin intermediarios, o necesitas `-AddToGroup`.

## Donde quedan los ficheros

```
D:\Autopilot\Hashes\<SERIE>_<fecha-hora>.csv   un CSV por equipo procesado
D:\Autopilot\Hashes\_TODOS.csv                 acumulado de todos los equipos
```

`_TODOS.csv` se puede importar de golpe en Intune con un solo `Import`.

## Importar a mano en Intune

1. `https://intune.microsoft.com` con la cuenta de administrador.
2. **Devices → Windows enrollment → Devices**
3. **Import** y selecciona el CSV.
4. Espera unos minutos y pulsa **Sync**.

## Verificar el registro

1. `https://intune.microsoft.com`
2. **Devices → Windows enrollment → Devices**
3. Busca por numero de serie. Si no aparece, pulsa **Sync** y refresca.

```
wmic bios get serialnumber
```

## Errores comunes

| Mensaje | Causa | Solucion |
|---|---|---|
| `insufficient privileges` / `forbidden` | La cuenta no tiene permisos | Usa Intune Administrator o Global Administrator |
| `consent required` / `needs admin approval` | Falta consentimiento de la app de Graph en el tenant | Un Global Admin debe aprobarlo |
| `could not connect` / TLS | Sin internet en el OOBE | Conecta red antes de abrir la consola, o usa `ap-csv.cmd` y sube el CSV desde otro equipo |
| `running scripts is disabled` | Estas ejecutando el `.ps1` directamente en vez del `.cmd` | Usa `ap.cmd`, que ya lanza PowerShell con `-ExecutionPolicy Bypass` |
| `Unable to retrieve device hardware data (hash)` | El equipo no expone el hash por WMI | Comprueba arranque UEFI y TPM activado en BIOS |

## Estructura del repositorio

```
ap.cmd                          lanzador principal (device code + Edge)
ap-online.cmd                   lanzador con el -Online oficial
ap-csv.cmd                      lanzador solo-CSV
autorun.inf                     entrada de AutoPlay en Windows normal (no afecta al OOBE)
Setup-Usb.ps1                   prepara un USB desde cero (descarga dependencias)
Autopilot/
  Run-Autopilot.ps1             logica principal (recogida de hash, auth, subida)
Autopilot/Get-WindowsAutopilotInfo.ps1   script oficial de Microsoft (via Setup-Usb.ps1)
Autopilot/Modules/                        modulos de Graph offline (via Setup-Usb.ps1, no versionado)
Autopilot/Providers/                      proveedor NuGet offline (via Setup-Usb.ps1, no versionado)
Autopilot/Hashes/                         CSVs generados en uso real (no versionado)
```

## Notas tecnicas

- El OOBE usa **Windows PowerShell 5.1**, no PowerShell 7. Todo esta
  verificado bajo ese entorno.
- El modo `-Online` oficial llama a `Find-PackageProvider NuGet
  -ForceBootstrap` si no encuentra el proveedor, lo que intenta salir a
  internet. Por eso `Setup-Usb.ps1` deja el proveedor en `Providers\` y
  `Run-Autopilot.ps1` lo copia a
  `%ProgramFiles%\PackageManagement\ProviderAssemblies` antes de invocarlo.
- La letra del USB se detecta sola (`%~dp0` en los `.cmd`). Da igual si el
  OOBE lo monta como `E:` o `F:`.
- Si el USB esta protegido contra escritura, el CSV cae en `%TEMP%` del
  equipo en el que se ejecuta.
- En modo `-Online` el hash se recoge dos veces a proposito: una para dejar
  el CSV en el USB, y otra dentro del script oficial (que conecta a Graph
  antes de escribir nada, asi que si el login falla no dejaria ningun CSV).
- La salida de progreso del script oficial de Microsoft (`-Online`) tiene un
  par de bugs conocidos (usa una variable de bucle equivocada al listar
  resultados, y comprueba un estado que ya no existe al esperar el sync). No
  afecta al registro en si; por eso el modo `-Device` hace su propio sondeo
  de `deviceImportStatus` y confirma el resultado real.

## Licencia

`Autopilot/Get-WindowsAutopilotInfo.ps1` es obra de Microsoft, distribuida
via PowerShell Gallery. El resto del contenido de este repositorio se
distribuye tal cual, sin garantia.
