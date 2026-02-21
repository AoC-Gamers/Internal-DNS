<#
.SYNOPSIS
  VPN DNS Fix (OpenVPN Connect / Windows 10/11)

.DESCRIPTION
  Analiza el estado DNS cuando estA conectada la VPN (OpenVPN Connect / DCO)
  y aplica fixes si detecta que Windows estA resolviendo por DNS del ISP:
   - Desactiva Smart Multi-Homed Name Resolution (DisableSmartNameResolution=1)
   - Ajusta mAtricas: VPN/DCO baja, Ethernet/Wi-Fi alta (opcional configurable)
   - (Opcional) fija DNS 10.8.0.1 en el adaptador TAP si existe y estA vacAo
   - Limpia cachA DNS
   - Auto-elevaciAn a Administrador si no se ejecuta como admin
   - Logging a archivo (Start-Transcript) y opciAn -Pause para ver errores

  Requiere PowerShell como Administrador para escribir registro y mAtricas.
  Compatible con OpenVPN Connect (incl. DCO).

.PARAMETER VpnDns
  IP del DNS interno por la VPN. Default: 10.8.0.1

.PARAMETER TestName
  Nombre interno a resolver para validar. Default: valpo2.intra

.PARAMETER VpnDcoAliasPattern
  PatrAn para detectar el adaptador DCO. Default: 'OpenVPN*Offload*'

.PARAMETER VpnTapAliasPattern
  PatrAn para detectar el adaptador TAP de OpenVPN Connect. Default: 'OpenVPN*TAP*'

.PARAMETER PreferredMetric
  MAtrica deseada para interfaz VPN. Default: 5

.PARAMETER NonVpnMetric
  MAtrica deseada para Ethernet/Wi-Fi. Default: 50

.PARAMETER ApplyMetrics
  Si estA presente, ajusta mAtricas. Recomendado.

.PARAMETER ApplyTapDns
  Si estA presente, fija DNS en el TAP si estA vacAo.

.PARAMETER ApplyVpnDns
  Si estA presente, fija DNS en la(s) interfaz(es) VPN activa(s) detectadas (DCO/TAP).

.PARAMETER Pause
  Si estA presente, pausa al final para ver salida/errores.

.PARAMETER LogPath
  Ruta del log (transcript). Default: %TEMP%\fix-vpn-dns.log

.PARAMETER Panel
  Muestra panel interactivo (PS5/PS7) con opciones de diagnAstico y fix.

.EXAMPLE
  .\fix-vpn-dns.ps1 -ApplyMetrics -ApplyTapDns -Pause

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-vpn-dns.ps1 -ApplyMetrics -ApplyTapDns -Pause

.EXAMPLE
  .\fix-vpn-dns.ps1 -WhatIf -ApplyMetrics -ApplyTapDns -Pause
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$VpnDns,
  [string]$TestName,
  [string]$VpnDcoAliasPattern,
  [string]$VpnTapAliasPattern,
  [int]$PreferredMetric,
  [int]$NonVpnMetric,
  [switch]$ApplyMetrics,
  [switch]$ApplyVpnDns,
  [switch]$ApplyTapDns,
  [switch]$Panel,
  [switch]$Pause,
  [string]$LogPath,
  [string]$DomainsConfigPath
)

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$DomainsJsonPath = if ($DomainsConfigPath) { $DomainsConfigPath } else { Join-Path $ScriptDir "domains.json" }

function Get-StringFromObject($obj, [string]$propertyName) {
  if ($null -eq $obj) { return $null }
  if ($obj.PSObject.Properties.Name -contains $propertyName) {
    return [string]$obj.$propertyName
  }
  return $null
}

function Get-IntFromObject($obj, [string]$propertyName) {
  if ($null -eq $obj) { return $null }
  if (-not ($obj.PSObject.Properties.Name -contains $propertyName)) { return $null }
  $raw = $obj.$propertyName
  if ($null -eq $raw) { return $null }
  $parsed = 0
  if ([int]::TryParse([string]$raw, [ref]$parsed)) {
    return $parsed
  }
  return $null
}

function Get-VpnFixConfig {
  if (-not (Test-Path $DomainsJsonPath)) {
    Write-Warning "No existe archivo de configuracion: $DomainsJsonPath"
    return $null
  }

  try {
    $raw = Get-Content -Path $DomainsJsonPath -Raw -ErrorAction Stop
    $json = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -ne $json -and $json.PSObject.Properties.Name -contains "vpnFix") {
      return $json.vpnFix
    }
    Write-Warning "El archivo $DomainsJsonPath no contiene la seccion 'vpnFix'. Se usaran defaults del script."
  } catch {
    Write-Warning "No se pudo leer config JSON para Fix-DNS-VPN: $($_.Exception.Message). Se usaran defaults del script."
  }

  return $null
}

$vpnFixConfig = Get-VpnFixConfig

if (-not $PSBoundParameters.ContainsKey("VpnDns")) {
  $VpnDns = Get-StringFromObject $vpnFixConfig "vpnDns"
}
if (-not $PSBoundParameters.ContainsKey("TestName")) {
  $TestName = Get-StringFromObject $vpnFixConfig "testName"
}
if (-not $PSBoundParameters.ContainsKey("VpnDcoAliasPattern")) {
  $VpnDcoAliasPattern = Get-StringFromObject $vpnFixConfig "vpnDcoAliasPattern"
}
if (-not $PSBoundParameters.ContainsKey("VpnTapAliasPattern")) {
  $VpnTapAliasPattern = Get-StringFromObject $vpnFixConfig "vpnTapAliasPattern"
}
if (-not $PSBoundParameters.ContainsKey("PreferredMetric")) {
  $metric = Get-IntFromObject $vpnFixConfig "preferredMetric"
  if ($null -ne $metric) { $PreferredMetric = $metric }
}
if (-not $PSBoundParameters.ContainsKey("NonVpnMetric")) {
  $metric = Get-IntFromObject $vpnFixConfig "nonVpnMetric"
  if ($null -ne $metric) { $NonVpnMetric = $metric }
}
if (-not $PSBoundParameters.ContainsKey("LogPath")) {
  $LogPath = Get-StringFromObject $vpnFixConfig "logPath"
}

if ([string]::IsNullOrWhiteSpace([string]$VpnDns)) { $VpnDns = "10.8.0.1" }
if ([string]::IsNullOrWhiteSpace([string]$VpnDcoAliasPattern)) { $VpnDcoAliasPattern = "OpenVPN*Offload*" }
if ([string]::IsNullOrWhiteSpace([string]$VpnTapAliasPattern)) { $VpnTapAliasPattern = "OpenVPN*TAP*" }
if ($PreferredMetric -le 0) { $PreferredMetric = 5 }
if ($NonVpnMetric -le 0) { $NonVpnMetric = 50 }
if ([string]::IsNullOrWhiteSpace([string]$LogPath)) { $LogPath = "$env:TEMP\fix-vpn-dns.log" }

if ([string]::IsNullOrWhiteSpace([string]$TestName)) {
  Write-Error "Falta testName. Agrega 'vpnFix.testName' en domains.json o pasa -TestName en CLI."
  exit 1
}

$LogPath = [Environment]::ExpandEnvironmentVariables([string]$LogPath)

# --------------------------
# Helpers (console)
# --------------------------
function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "[ERR ] $msg" -ForegroundColor Red }
function Write-Ok  ($msg) { Write-Host "[OK  ] $msg" -ForegroundColor Green }

function Convert-BoundParametersToArgumentList([hashtable]$boundParameters) {
  $result = @()
  foreach ($key in $boundParameters.Keys) {
    $value = $boundParameters[$key]

    if ($value -is [System.Management.Automation.SwitchParameter]) {
      if ($value.IsPresent) {
        $result += "-$key"
      }
      continue
    }

    $result += "-$key"
    $result += [string]$value
  }

  return $result
}

function Write-NslookupServerInfo($serverInfo) {
  $serverLine = $serverInfo.ServerLine
  $addressLine = $serverInfo.AddressLine

  if ([string]::IsNullOrWhiteSpace([string]$serverLine)) {
    $serverLine = "Servidor: (no detectado)"
  }
  if ([string]::IsNullOrWhiteSpace([string]$addressLine)) {
    $addressLine = "Address: (no detectado)"
  }

  Write-Info $serverLine
  Write-Info $addressLine
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --------------------------
# Auto-elevaciAn
# --------------------------
$IsAdmin = Test-Admin
if (-not $IsAdmin) {
  Write-Warn "No estAs en modo Administrador. Se relanzarA con privilegios elevados."

  if (-not $PSCommandPath) {
    Write-Err "No puedo auto-elevar porque PSCommandPath estA vacAo. Ejecuta desde archivo: .\fix-vpn-dns.ps1"
    if ($Pause) { Read-Host "Presiona ENTER para cerrar" | Out-Null }
    exit 1
  }

  # Re-lanzar elevando y preservando argumentos
  $currentHostExe = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
  if ([string]::IsNullOrWhiteSpace([string]$currentHostExe)) {
    $currentHostExe = "powershell.exe"
  }

  $boundArgList = Convert-BoundParametersToArgumentList $PSBoundParameters
  $argList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $PSCommandPath
  ) + $boundArgList

  # Si quieres forzar que quede una ventana abierta siempre, usa cmd /k.
  # Pero por defecto lo relanzamos normal; si usas -Pause verAs la salida en la ventana elevada.
  Start-Process -FilePath $currentHostExe -Verb RunAs -ArgumentList $argList
  exit
}

# --------------------------
# Logging (Transcript)
# --------------------------
$TranscriptStarted = $false
try {
  Start-Transcript -Path $LogPath -Append -ErrorAction Stop | Out-Null
  $TranscriptStarted = $true
  Write-Info "Transcript habilitado: $LogPath"
} catch {
  Write-Warn "No se pudo iniciar transcript: $($_.Exception.Message)"
}

# --------------------------
# Network helpers
# --------------------------
function Get-DnsServersForInterface([string]$alias) {
  try {
    (Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
  } catch {
    @()
  }
}

function Ensure-VpnInterfaceDns {
  param(
    [object[]]$VpnAdapters,
    [string]$ExpectedDns
  )

  $changed = $false

  foreach ($adapter in $VpnAdapters) {
    if ($null -eq $adapter) { continue }

    $alias = $adapter.InterfaceAlias
    if ([string]::IsNullOrWhiteSpace([string]$alias)) { continue }

    $currentDns = @(Get-DnsServersForInterface $alias)
    $alreadyHasExpected = $currentDns -contains $ExpectedDns

    if ($alreadyHasExpected -and $currentDns.Count -eq 1) {
      Write-Ok "El adaptador VPN '$alias' ya usa DNS esperado: $ExpectedDns"
      continue
    }

    if ($currentDns.Count -eq 0) {
      Write-Warn "El adaptador VPN '$alias' no tiene DNS. Se fijara a $ExpectedDns."
    } else {
      Write-Warn "El adaptador VPN '$alias' tiene DNS distinto ($($currentDns -join ', ')). Se fijara a $ExpectedDns."
    }

    if ($PSCmdlet.ShouldProcess($alias, "Set DNS servers to $ExpectedDns")) {
      Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $ExpectedDns
    }
    $changed = $true
  }

  return $changed
}

function Resolve-UsingSystem([string]$name) {
  $out = & nslookup $name 2>&1
  return ($out -join "`n")
}

function Get-NslookupServer([string]$nslookupOutput) {
  $serverLine = ($nslookupOutput -split "`n" | Where-Object { $_ -match '^\s*Servidor:\s+' } | Select-Object -First 1)
  $addrLine   = ($nslookupOutput -split "`n" | Where-Object { $_ -match '^\s*Address:\s+' } | Select-Object -First 1)
  [pscustomobject]@{
    ServerLine  = $serverLine
    AddressLine = $addrLine
  }
}

function Ensure-DisableSmartNameResolution {
  $regPath = "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient"

  if (-not (Test-Path $regPath)) {
    if ($PSCmdlet.ShouldProcess($regPath, "Create registry key")) {
      New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows NT" -Name "DNSClient" -Force | Out-Null
    }
  }

  $current = $null
  try {
    $current = (Get-ItemProperty -Path $regPath -Name DisableSmartNameResolution -ErrorAction Stop).DisableSmartNameResolution
  } catch { }

  if ($current -ne 1) {
    Write-Warn "Smart Multi-Homed Name Resolution estA habilitado (o no configurado). Se desactivarA."
    if ($PSCmdlet.ShouldProcess("$regPath\DisableSmartNameResolution", "Set DWORD=1")) {
      New-ItemProperty -Path $regPath -Name DisableSmartNameResolution -PropertyType DWord -Value 1 -Force | Out-Null
    }
    return $true
  }

  Write-Ok "DisableSmartNameResolution ya estA aplicado (=1)."
  return $false
}

function Set-InterfaceMetricSafe([string]$alias, [int]$metric) {
  try {
    $ipif = Get-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction Stop
    if ($ipif.InterfaceMetric -ne $metric) {
      Write-Warn "Cambiando mAtrica IPv4 de '$alias' de $($ipif.InterfaceMetric) a $metric"
      if ($PSCmdlet.ShouldProcess($alias, "Set-NetIPInterface InterfaceMetric=$metric")) {
        Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -InterfaceMetric $metric | Out-Null
      }
      return $true
    } else {
      Write-Ok "MAtrica IPv4 de '$alias' ya estA en $metric"
      return $false
    }
  } catch {
    Write-Warn "No se pudo leer/cambiar mAtrica de '$alias' ($($_.Exception.Message))"
    return $false
  }
}

function Flush-Dns {
  Write-Info "Limpiando cachA DNS (ipconfig /flushdns)"
  if ($PSCmdlet.ShouldProcess("DNS cache", "Flush")) {
    & ipconfig /flushdns | Out-Null
  }
}

function Show-UiHeader {
  Clear-Host
  Write-Host ""
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    $top = [char]9556 + (([string][char]9552) * 38) + [char]9559
    $mid = [char]9553 + "         FIX DNS VPN - OPENVPN         " + [char]9553
    $bot = [char]9562 + (([string][char]9552) * 38) + [char]9565
    Write-Host $top -ForegroundColor Cyan
    Write-Host $mid -ForegroundColor Cyan
    Write-Host $bot -ForegroundColor Cyan
  } else {
    Write-Host "+========================================+" -ForegroundColor Cyan
    Write-Host "|         FIX DNS VPN - OPENVPN         |" -ForegroundColor Cyan
    Write-Host "+========================================+" -ForegroundColor Cyan
  }
  Write-Host ""
  Write-Host ("PowerShell: " + $PSVersionTable.PSVersion + " (" + $PSVersionTable.PSEdition + ")") -ForegroundColor DarkGray
  Write-Host ""
}

function Show-OptionsPanel {
  Show-UiHeader
  Write-Host "Selecciona una opcion:" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "  1) Diagnostico (sin cambios)" -ForegroundColor White
  Write-Host "  2) Aplicar fix recomendado (metricas + DNS VPN)" -ForegroundColor Green
  Write-Host "  3) Aplicar solo metricas" -ForegroundColor White
  Write-Host "  4) Aplicar solo DNS VPN" -ForegroundColor White
  Write-Host "  5) Limpiar cache DNS" -ForegroundColor White
  Write-Host "  6) Info de compatibilidad (PS5/PS7)" -ForegroundColor White
  Write-Host "  0) Salir" -ForegroundColor White
  Write-Host ""
}

function Show-CompatibilityPanel {
  Show-UiHeader
  Write-Host "INFORMACION DE COMPATIBILIDAD" -ForegroundColor Magenta
  Write-Host ""
  Write-Host "PowerShell: " -NoNewline
  Write-Host "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -ForegroundColor Cyan
  Write-Host "Host actual: " -NoNewline
  Write-Host "$(if ($PSVersionTable.PSVersion.Major -ge 7) { 'PS7+' } else { 'PS5.x' })" -ForegroundColor Yellow
  Write-Host "Administrador: " -NoNewline
  Write-Host "$(if (Test-Admin) { 'Si' } else { 'No' })" -ForegroundColor $(if (Test-Admin) { 'Green' } else { 'Red' })
  Write-Host "WhatIf: " -NoNewline
  Write-Host "$(if ($WhatIfPreference) { 'Activo' } else { 'Inactivo' })" -ForegroundColor $(if ($WhatIfPreference) { 'Yellow' } else { 'Green' })
  Write-Host "LogPath: " -NoNewline
  Write-Host $LogPath -ForegroundColor DarkGray
  Write-Host ""
}

function Invoke-VpnDnsFix {
  param(
    [switch]$DoApplyMetrics,
    [switch]$DoApplyVpnDns,
    [switch]$DoApplyTapDns,
    [switch]$DiagnosticsOnly,
    [switch]$DoFlushOnly
  )

  Write-Info "VPN DNS Fix - Inicio"
  Write-Info "VPN DNS esperado: $VpnDns | Host test: $TestName"
  if ($WhatIfPreference) { Write-Warn "Modo WhatIf activo: no se aplicarAn cambios reales." }

  if ($DoFlushOnly) {
    Flush-Dns
    Write-Ok "Cache DNS limpiada."
    Write-Info "VPN DNS Fix - Fin"
    return
  }

  # Detectar interfaces UP
  $allIf = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }

  # Detectar DCO y TAP
  $vpnDco = $allIf | Where-Object {
      $_.InterfaceDescription -like "*OpenVPN Data Channel Offload*" -or
      $_.Name -like $VpnDcoAliasPattern -or
      $_.InterfaceAlias -like $VpnDcoAliasPattern
    } | Select-Object -First 1

  $vpnTap = $allIf | Where-Object {
      ($_.InterfaceDescription -like "*TAP-Windows*" -and $_.InterfaceDescription -like "*OpenVPN*") -or
      $_.Name -like $VpnTapAliasPattern -or
      $_.InterfaceAlias -like $VpnTapAliasPattern
    } | Select-Object -First 1

  $vpnAdapters = @()
  if ($vpnDco) { $vpnAdapters += $vpnDco }
  if ($vpnTap -and (-not ($vpnAdapters | Where-Object { $_.InterfaceAlias -eq $vpnTap.InterfaceAlias }))) {
    $vpnAdapters += $vpnTap
  }

  if ($null -eq $vpnDco -and $null -eq $vpnTap) {
    Write-Err "No se detectA interfaz OpenVPN activa (DCO o TAP). AVPN conectada?"
    Write-Info "Interfaces UP actuales:"
    $allIf | Select-Object InterfaceAlias, InterfaceDescription | Format-Table -AutoSize
    return
  }

  if ($vpnDco) { Write-Ok "Detectado DCO: $($vpnDco.InterfaceAlias) | $($vpnDco.InterfaceDescription)" }
  if ($vpnTap) { Write-Ok "Detectado TAP: $($vpnTap.InterfaceAlias) | $($vpnTap.InterfaceDescription)" }

  # Probar resoluciAn por sistema
  Write-Info "Probando resoluciAn usando DNS del sistema (nslookup sin servidor)..."
  $sysOut = Resolve-UsingSystem $TestName
  $sysSrv = Get-NslookupServer $sysOut
  Write-NslookupServerInfo $sysSrv
  $systemFailed = ($sysOut -match "Non-existent domain|NXDOMAIN|no encuentra")

  if ($systemFailed) {
    Write-Warn "La resolucion por DNS del sistema FALLO para $TestName (posible uso de DNS ISP)."
  } else {
    Write-Ok "La resoluciAn por DNS del sistema parece OK para $TestName."
  }

  # Confirmar que el DNS VPN resuelve
  Write-Info "Probando resoluciAn directa contra DNS VPN ($VpnDns)..."
  $vpnNs = & nslookup $TestName $VpnDns 2>&1
  $vpnFailed = (($vpnNs -join "`n") -match "Non-existent domain|NXDOMAIN|no encuentra")
  $vpnDnsTestPassed = $true
  if ($vpnFailed) {
    Write-Err "El DNS VPN ($VpnDns) NO resolviA $TestName. Revisa dnsmasq/registros/rutas."
    Write-Host ($vpnNs -join "`n")
    Write-Warn "El host de prueba puede no existir en tu zona DNS. El script continuara con diagnostico/fix de interfaz VPN."
    Write-Warn "Sugerencia: define un host valido en vpnFix.testName dentro de domains.json"
    $vpnDnsTestPassed = $false
  } else {
    Write-Ok "El DNS VPN ($VpnDns) resuelve $TestName."
  }

  # Estado DNS por interfaz
  Write-Info "DNS por interfaz (IPv4):"
  Get-DnsClientServerAddress -AddressFamily IPv4 |
    Select-Object InterfaceAlias, ServerAddresses |
    Format-Table -AutoSize

  Write-Info "Diagnostico DNS en adaptadores VPN activos:"
  $diagVpnAdapterDnsHealthy = $true
  if ($vpnAdapters.Count -eq 0) {
    Write-Warn "No hay adaptadores VPN activos para evaluar DNS."
    $diagVpnAdapterDnsHealthy = $false
  } else {
    foreach ($adapter in $vpnAdapters) {
      $alias = $adapter.InterfaceAlias
      $currentDns = @(Get-DnsServersForInterface $alias)

      if ($currentDns.Count -eq 0) {
        Write-Warn "[$alias] sin DNS configurado. Recomendado: fijar a $VpnDns"
        $diagVpnAdapterDnsHealthy = $false
        continue
      }

      if (($currentDns -contains $VpnDns) -and $currentDns.Count -eq 1) {
        Write-Ok "[$alias] DNS correcto: $VpnDns"
      } else {
        Write-Warn "[$alias] DNS actual: $($currentDns -join ', ') | Recomendado: $VpnDns"
        $diagVpnAdapterDnsHealthy = $false
      }
    }
  }

  if ($DiagnosticsOnly) {
    $diagPending = New-Object System.Collections.Generic.List[string]

    if (-not $vpnDnsTestPassed) {
      $diagPending.Add("testName no resuelve en DNS VPN") | Out-Null
    }
    if ($systemFailed) {
      $diagPending.Add("DNS del sistema aun prioriza resolver externo/ISP") | Out-Null
    }
    if (-not $diagVpnAdapterDnsHealthy) {
      $diagPending.Add("adaptador VPN sin DNS esperado ($VpnDns)") | Out-Null
    }

    if (-not $vpnDnsTestPassed) {
      Write-Warn "Diagnostico completado con advertencia: testName no resolvio en DNS VPN."
    }
    if ($diagPending.Count -eq 0) {
      Write-Ok "Estado final: OK (diagnostico)"
    } else {
      Write-Warn "Estado final: WARNING (diagnostico). Revisa recomendaciones mostradas."
      Write-Warn ("Pendientes: " + ($diagPending -join "; "))
    }
    Write-Info "DiagnAstico finalizado (sin cambios)."
    Write-Info "VPN DNS Fix - Fin"
    return
  }

  $changes = $false

  # Siempre: aplicar DisableSmartNameResolution si no estA
  $changes = (Ensure-DisableSmartNameResolution) -or $changes

  # Opcional: ajustar mAtricas
  if ($DoApplyMetrics) {
    $vpnAlias = if ($vpnDco) { $vpnDco.InterfaceAlias } else { $vpnTap.InterfaceAlias }
    $changes = (Set-InterfaceMetricSafe $vpnAlias $PreferredMetric) -or $changes

    foreach ($name in @("Ethernet","Wi-Fi")) {
      $ifUp = $allIf | Where-Object { $_.InterfaceAlias -eq $name } | Select-Object -First 1
      if ($ifUp) {
        $changes = (Set-InterfaceMetricSafe $name $NonVpnMetric) -or $changes
      }
    }
  } else {
    Write-Info "MAtricas: no solicitado."
  }

  # Opcional: fijar DNS en adaptadores VPN activos (DCO/TAP)
  $requestVpnDnsFix = ($DoApplyVpnDns -or $DoApplyTapDns)
  if ($requestVpnDnsFix) {
    if ($vpnAdapters.Count -gt 0) {
      $changes = (Ensure-VpnInterfaceDns -VpnAdapters $vpnAdapters -ExpectedDns $VpnDns) -or $changes
    } else {
      Write-Warn "DNS VPN solicitado pero no se detectaron adaptadores VPN activos."
    }
  }

  $postSystemFailed = $systemFailed

  if ($changes) {
    Flush-Dns
    Write-Info "Reprobando resoluciAn (nslookup sin servidor)..."
    $sysOut2 = Resolve-UsingSystem $TestName
    $sysSrv2 = Get-NslookupServer $sysOut2
    Write-NslookupServerInfo $sysSrv2

    $postSystemFailed = ($sysOut2 -match "Non-existent domain|NXDOMAIN|no encuentra")

    if ($postSystemFailed) {
      Write-Warn "AAn falla la resoluciAn por DNS del sistema."
      Write-Warn "Sugerencias: desactiva DoH en navegador; prueba desactivar DCO en OpenVPN Connect; verifica mAtricas."
      Write-Host $sysOut2
    } else {
      Write-Ok "OK: la resoluciAn por DNS del sistema funciona ahora."
    }

    Write-Warn "Nota: DisableSmartNameResolution puede requerir reinicio para aplicar completamente."
  } else {
    Write-Info "No se aplicaron cambios (todo ya estaba configurado o no se solicitA acciAn)."
    if ($systemFailed) {
      Write-Warn "Aun asA, nslookup sin servidor fallA. Prueba con mAtricas o revisa DoH."
    }
  }

  $postVpnAdapterDnsHealthy = $true
  if ($vpnAdapters.Count -eq 0) {
    $postVpnAdapterDnsHealthy = $false
  } else {
    foreach ($adapter in $vpnAdapters) {
      $currentDns = @(Get-DnsServersForInterface $adapter.InterfaceAlias)
      if (-not (($currentDns -contains $VpnDns) -and $currentDns.Count -eq 1)) {
        $postVpnAdapterDnsHealthy = $false
        break
      }
    }
  }

  if ($vpnDnsTestPassed -and $postVpnAdapterDnsHealthy -and -not $postSystemFailed) {
    Write-Ok "Estado final: OK"
  } else {
    $finalPending = New-Object System.Collections.Generic.List[string]
    if (-not $vpnDnsTestPassed) {
      $finalPending.Add("testName no resuelve en DNS VPN") | Out-Null
    }
    if (-not $postVpnAdapterDnsHealthy) {
      $finalPending.Add("adaptador VPN sin DNS esperado ($VpnDns)") | Out-Null
    }
    if ($postSystemFailed) {
      $finalPending.Add("DNS del sistema aun falla o prioriza resolver externo/ISP") | Out-Null
    }

    Write-Warn "Estado final: WARNING. Revisa recomendaciones mostradas."
    if ($finalPending.Count -gt 0) {
      Write-Warn ("Pendientes: " + ($finalPending -join "; "))
    }
  }

  Write-Info "VPN DNS Fix - Fin"
}

# --------------------------
# MAIN
# --------------------------
try {
  $runPanel = $Panel -or (-not $ApplyMetrics -and -not $ApplyTapDns -and -not $ApplyVpnDns)

  if ($runPanel) {
    while ($true) {
      Show-OptionsPanel
      $choice = Read-Host "Elige una opcion"
      Write-Host ""
      switch ($choice) {
        "1" { Invoke-VpnDnsFix -DiagnosticsOnly }
        "2" { Invoke-VpnDnsFix -DoApplyMetrics -DoApplyVpnDns }
        "3" { Invoke-VpnDnsFix -DoApplyMetrics }
        "4" { Invoke-VpnDnsFix -DoApplyVpnDns }
        "5" { Invoke-VpnDnsFix -DoFlushOnly }
        "6" { Show-CompatibilityPanel }
        "0" { break }
        default { Write-Warn "Opcion invalida." }
      }

      if ($choice -eq "0") { break }
      Write-Host ""
      Read-Host "Presiona ENTER para volver al panel" | Out-Null
    }
  } else {
    $effectiveApplyVpnDns = ($ApplyVpnDns -or $ApplyTapDns)
    Invoke-VpnDnsFix -DoApplyMetrics:$ApplyMetrics -DoApplyVpnDns:$effectiveApplyVpnDns
  }
}
catch {
  Write-Err "ExcepciAn no controlada: $($_.Exception.Message)"
  Write-Err $_.ScriptStackTrace
  throw
}
finally {
  if ($TranscriptStarted) {
    try { Stop-Transcript | Out-Null } catch {}
  }
  if ($Pause) {
    Read-Host "Presiona ENTER para cerrar" | Out-Null
  }
}

