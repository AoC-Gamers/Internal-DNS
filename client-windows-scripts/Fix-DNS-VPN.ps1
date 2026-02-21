<#
.SYNOPSIS
  VPN DNS Fix (OpenVPN Connect / Windows 10/11)

.DESCRIPTION
  Analiza el estado DNS cuando está conectada la VPN (OpenVPN Connect / DCO)
  y aplica fixes si detecta que Windows está resolviendo por DNS del ISP:
   - Desactiva Smart Multi-Homed Name Resolution (DisableSmartNameResolution=1)
   - Ajusta métricas: VPN/DCO baja, Ethernet/Wi-Fi alta (opcional configurable)
   - (Opcional) fija DNS 10.8.0.1 en el adaptador TAP si existe y está vacío
   - Limpia caché DNS
   - Auto-elevación a Administrador si no se ejecuta como admin
   - Logging a archivo (Start-Transcript) y opción -Pause para ver errores

  Requiere PowerShell como Administrador para escribir registro y métricas.
  Compatible con OpenVPN Connect (incl. DCO).

.PARAMETER VpnDns
  IP del DNS interno por la VPN. Default: 10.8.0.1

.PARAMETER TestName
  Nombre interno a resolver para validar. Default: valpo2.intra

.PARAMETER VpnDcoAliasPattern
  Patrón para detectar el adaptador DCO. Default: 'OpenVPN*Offload*'

.PARAMETER VpnTapAliasPattern
  Patrón para detectar el adaptador TAP de OpenVPN Connect. Default: 'OpenVPN*TAP*'

.PARAMETER PreferredMetric
  Métrica deseada para interfaz VPN. Default: 5

.PARAMETER NonVpnMetric
  Métrica deseada para Ethernet/Wi-Fi. Default: 50

.PARAMETER ApplyMetrics
  Si está presente, ajusta métricas. Recomendado.

.PARAMETER ApplyTapDns
  Si está presente, fija DNS en el TAP si está vacío.

.PARAMETER Pause
  Si está presente, pausa al final para ver salida/errores.

.PARAMETER LogPath
  Ruta del log (transcript). Default: %TEMP%\fix-vpn-dns.log

.PARAMETER Panel
  Muestra panel interactivo (PS5/PS7) con opciones de diagnóstico y fix.

.EXAMPLE
  .\fix-vpn-dns.ps1 -ApplyMetrics -ApplyTapDns -Pause

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-vpn-dns.ps1 -ApplyMetrics -ApplyTapDns -Pause

.EXAMPLE
  .\fix-vpn-dns.ps1 -WhatIf -ApplyMetrics -ApplyTapDns -Pause
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$VpnDns = "10.8.0.1",
  [string]$TestName = "valpo2.intra",
  [string]$VpnDcoAliasPattern = "OpenVPN*Offload*",
  [string]$VpnTapAliasPattern = "OpenVPN*TAP*",
  [int]$PreferredMetric = 5,
  [int]$NonVpnMetric = 50,
  [switch]$ApplyMetrics,
  [switch]$ApplyTapDns,
  [switch]$Panel,
  [switch]$Pause,
  [string]$LogPath = "$env:TEMP\fix-vpn-dns.log"
)

# --------------------------
# Helpers (console)
# --------------------------
function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "[ERR ] $msg" -ForegroundColor Red }
function Write-Ok  ($msg) { Write-Host "[OK  ] $msg" -ForegroundColor Green }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --------------------------
# Auto-elevación
# --------------------------
$IsAdmin = Test-Admin
if (-not $IsAdmin) {
  Write-Warn "No estás en modo Administrador. Se relanzará con privilegios elevados."

  if (-not $PSCommandPath) {
    Write-Err "No puedo auto-elevar porque PSCommandPath está vacío. Ejecuta desde archivo: .\fix-vpn-dns.ps1"
    if ($Pause) { Read-Host "Presiona ENTER para cerrar" | Out-Null }
    exit 1
  }

  # Re-lanzar elevando y preservando argumentos
  $argList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$PSCommandPath`""
  ) + $args

  # Si quieres forzar que quede una ventana abierta siempre, usa cmd /k.
  # Pero por defecto lo relanzamos normal; si usas -Pause verás la salida en la ventana elevada.
  Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList
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
    Write-Warn "Smart Multi-Homed Name Resolution está habilitado (o no configurado). Se desactivará."
    if ($PSCmdlet.ShouldProcess("$regPath\DisableSmartNameResolution", "Set DWORD=1")) {
      New-ItemProperty -Path $regPath -Name DisableSmartNameResolution -PropertyType DWord -Value 1 -Force | Out-Null
    }
    return $true
  }

  Write-Ok "DisableSmartNameResolution ya está aplicado (=1)."
  return $false
}

function Set-InterfaceMetricSafe([string]$alias, [int]$metric) {
  try {
    $ipif = Get-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction Stop
    if ($ipif.InterfaceMetric -ne $metric) {
      Write-Warn "Cambiando métrica IPv4 de '$alias' de $($ipif.InterfaceMetric) a $metric"
      if ($PSCmdlet.ShouldProcess($alias, "Set-NetIPInterface InterfaceMetric=$metric")) {
        Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -InterfaceMetric $metric | Out-Null
      }
      return $true
    } else {
      Write-Ok "Métrica IPv4 de '$alias' ya está en $metric"
      return $false
    }
  } catch {
    Write-Warn "No se pudo leer/cambiar métrica de '$alias' ($($_.Exception.Message))"
    return $false
  }
}

function Flush-Dns {
  Write-Info "Limpiando caché DNS (ipconfig /flushdns)"
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
  Write-Host "  2) Aplicar fix recomendado (metricas + DNS TAP)" -ForegroundColor Green
  Write-Host "  3) Aplicar solo metricas" -ForegroundColor White
  Write-Host "  4) Aplicar solo DNS TAP" -ForegroundColor White
  Write-Host "  5) Limpiar cache DNS" -ForegroundColor White
  Write-Host "  0) Salir" -ForegroundColor White
  Write-Host ""
}

function Invoke-VpnDnsFix {
  param(
    [switch]$DoApplyMetrics,
    [switch]$DoApplyTapDns,
    [switch]$DiagnosticsOnly,
    [switch]$DoFlushOnly
  )

  Write-Info "VPN DNS Fix - Inicio"
  Write-Info "VPN DNS esperado: $VpnDns | Host test: $TestName"
  if ($WhatIfPreference) { Write-Warn "Modo WhatIf activo: no se aplicarán cambios reales." }

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

  if ($null -eq $vpnDco -and $null -eq $vpnTap) {
    Write-Err "No se detectó interfaz OpenVPN activa (DCO o TAP). ¿VPN conectada?"
    Write-Info "Interfaces UP actuales:"
    $allIf | Select-Object InterfaceAlias, InterfaceDescription | Format-Table -AutoSize
    return
  }

  if ($vpnDco) { Write-Ok "Detectado DCO: $($vpnDco.InterfaceAlias) | $($vpnDco.InterfaceDescription)" }
  if ($vpnTap) { Write-Ok "Detectado TAP: $($vpnTap.InterfaceAlias) | $($vpnTap.InterfaceDescription)" }

  # Probar resolución por sistema
  Write-Info "Probando resolución usando DNS del sistema (nslookup sin servidor)..."
  $sysOut = Resolve-UsingSystem $TestName
  $sysSrv = Get-NslookupServer $sysOut
  Write-Info ($sysSrv.ServerLine  ? $sysSrv.ServerLine  : "Servidor: (no detectado)")
  Write-Info ($sysSrv.AddressLine ? $sysSrv.AddressLine : "Address: (no detectado)")
  $systemFailed = ($sysOut -match "Non-existent domain|NXDOMAIN|no encuentra")

  if ($systemFailed) {
    Write-Warn "La resolución por DNS del sistema FALLÓ para $TestName (posible uso de DNS ISP)."
  } else {
    Write-Ok "La resolución por DNS del sistema parece OK para $TestName."
  }

  # Confirmar que el DNS VPN resuelve
  Write-Info "Probando resolución directa contra DNS VPN ($VpnDns)..."
  $vpnNs = & nslookup $TestName $VpnDns 2>&1
  $vpnFailed = (($vpnNs -join "`n") -match "Non-existent domain|NXDOMAIN|no encuentra")
  if ($vpnFailed) {
    Write-Err "El DNS VPN ($VpnDns) NO resolvió $TestName. Revisa dnsmasq/registros/rutas."
    Write-Host ($vpnNs -join "`n")
    return
  } else {
    Write-Ok "El DNS VPN ($VpnDns) resuelve $TestName."
  }

  # Estado DNS por interfaz
  Write-Info "DNS por interfaz (IPv4):"
  Get-DnsClientServerAddress -AddressFamily IPv4 |
    Select-Object InterfaceAlias, ServerAddresses |
    Format-Table -AutoSize

  if ($DiagnosticsOnly) {
    Write-Info "Diagnóstico finalizado (sin cambios)."
    Write-Info "VPN DNS Fix - Fin"
    return
  }

  $changes = $false

  # Siempre: aplicar DisableSmartNameResolution si no está
  $changes = (Ensure-DisableSmartNameResolution) -or $changes

  # Opcional: ajustar métricas
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
    Write-Info "Métricas: no solicitado."
  }

  # Opcional: fijar DNS en TAP si está vacío
  if ($DoApplyTapDns -and $vpnTap) {
    $tapAlias = $vpnTap.InterfaceAlias
    $tapDns = Get-DnsServersForInterface $tapAlias
    if (-not $tapDns -or $tapDns.Count -eq 0) {
      Write-Warn "El TAP '$tapAlias' no tiene DNS. Se fijará a $VpnDns."
      if ($PSCmdlet.ShouldProcess($tapAlias, "Set DNS servers to $VpnDns")) {
        Set-DnsClientServerAddress -InterfaceAlias $tapAlias -ServerAddresses $VpnDns
      }
      $changes = $true
    } else {
      Write-Ok "El TAP '$tapAlias' ya tiene DNS: $($tapDns -join ', ')"
    }
  } elseif ($DoApplyTapDns -and -not $vpnTap) {
    Write-Warn "DNS TAP solicitado pero no se detectó TAP activo."
  }

  if ($changes) {
    Flush-Dns
    Write-Info "Reprobando resolución (nslookup sin servidor)..."
    $sysOut2 = Resolve-UsingSystem $TestName
    $sysSrv2 = Get-NslookupServer $sysOut2
    Write-Info ($sysSrv2.ServerLine  ? $sysSrv2.ServerLine  : "Servidor: (no detectado)")
    Write-Info ($sysSrv2.AddressLine ? $sysSrv2.AddressLine : "Address: (no detectado)")

    if ($sysOut2 -match "Non-existent domain|NXDOMAIN|no encuentra") {
      Write-Warn "Aún falla la resolución por DNS del sistema."
      Write-Warn "Sugerencias: desactiva DoH en navegador; prueba desactivar DCO en OpenVPN Connect; verifica métricas."
      Write-Host $sysOut2
    } else {
      Write-Ok "OK: la resolución por DNS del sistema funciona ahora."
    }

    Write-Warn "Nota: DisableSmartNameResolution puede requerir reinicio para aplicar completamente."
  } else {
    Write-Info "No se aplicaron cambios (todo ya estaba configurado o no se solicitó acción)."
    if ($systemFailed) {
      Write-Warn "Aun así, nslookup sin servidor falló. Prueba con métricas o revisa DoH."
    }
  }

  Write-Info "VPN DNS Fix - Fin"
}

# --------------------------
# MAIN
# --------------------------
try {
  $runPanel = $Panel -or (-not $ApplyMetrics -and -not $ApplyTapDns)

  if ($runPanel) {
    while ($true) {
      Show-OptionsPanel
      $choice = Read-Host "Elige una opcion"
      Write-Host ""
      switch ($choice) {
        "1" { Invoke-VpnDnsFix -DiagnosticsOnly }
        "2" { Invoke-VpnDnsFix -DoApplyMetrics -DoApplyTapDns }
        "3" { Invoke-VpnDnsFix -DoApplyMetrics }
        "4" { Invoke-VpnDnsFix -DoApplyTapDns }
        "5" { Invoke-VpnDnsFix -DoFlushOnly }
        "0" { break }
        default { Write-Warn "Opcion invalida." }
      }

      if ($choice -eq "0") { break }
      Write-Host ""
      Read-Host "Presiona ENTER para volver al panel" | Out-Null
    }
  } else {
    Invoke-VpnDnsFix -DoApplyMetrics:$ApplyMetrics -DoApplyTapDns:$ApplyTapDns
  }
}
catch {
  Write-Err "Excepción no controlada: $($_.Exception.Message)"
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