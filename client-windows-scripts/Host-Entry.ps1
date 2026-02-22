param(
    [switch]$FlushDns
)

# ===== DETECCION DE VERSION POWERSHELL =====
$PSVersion = $PSVersionTable.PSVersion
$PSMajor = $PSVersion.Major
$PSMajorMinor = "$($PSVersion.Major).$($PSVersion.Minor)"

# Validar version minima (PS5.0 o PS7.x)
if ($PSMajor -lt 5 -and $PSMajor -ne 7) {
    Write-Error "PowerShell $PSMajor no es compatible. Requiere PS5.0+ o PS7.x+"
    exit 1
}

$PSEditionType = $PSVersionTable.PSEdition
$IsPS7 = $PSMajor -eq 7
$IsPS5 = $PSMajor -eq 5

# Entradas DNS cargadas desde JSON
$DnsEntries = @()

$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$DnsConfigPath = Join-Path $ScriptDir "domains.json"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-RequireAdmin {
    if (-not (Test-IsAdmin)) {
        Write-Host "[!] Elevando privilegios a Administrador..." -ForegroundColor Yellow
        Write-Host ""
        
        try {
            $scriptPath = $MyInvocation.ScriptName
            if ([string]::IsNullOrEmpty($scriptPath)) {
                $scriptPath = $PSCommandPath
            }
            if ([string]::IsNullOrEmpty($scriptPath)) {
                Write-Error "No se pudo determinar la ruta del script para relanzar"
                exit 1
            }

            $arguments = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", "`"$scriptPath`""
            )

            # Agregar parametros originales si existen
            if ($PSBoundParameters.Count -gt 0) {
                foreach ($key in $PSBoundParameters.Keys) {
                    $value = $PSBoundParameters[$key]
                    if ($value -is [System.Management.Automation.SwitchParameter]) {
                        if ($value.IsPresent) {
                            $arguments += "-$key"
                        }
                    } else {
                        $arguments += "-$key"
                        $arguments += "`"$value`""
                    }
                }
            }

            Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs
            exit 0
        } catch {
            Write-Host "" 
            Write-Host "[!] ERROR: No se pudo elevar a Administrador" -ForegroundColor Red
            Write-Host ""
            Write-Host "Solucion manual:" -ForegroundColor Yellow
            Write-Host "  1. Abre PowerShell" -ForegroundColor White
            Write-Host "  2. Haz clic derecho > Ejecutar como administrador" -ForegroundColor White
            Write-Host "  3. Navega a la carpeta del script" -ForegroundColor White
            Write-Host "  4. Ejecuta: .\Host-Entry.ps1" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor DarkGray
            Write-Host ""
            exit 1
        }
    }
}

function Write-HostsFileWithRetry {
    param(
        [object[]]$Lines,
        [int]$MaxRetries = 8,
        [int]$DelayMs = 300
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Set-Content -Path $hostsPath -Value $Lines -Encoding ASCII -ErrorAction Stop
            return $true
        } catch {
            if ($attempt -ge $MaxRetries) {
                Show-Error "No se pudo escribir en el archivo hosts. Puede estar bloqueado por otro proceso."
                Show-Warning "Cierra editores/antivirus que usen hosts y vuelve a intentar."
                Write-Host "Detalle: $($_.Exception.Message)" -ForegroundColor DarkGray
                return $false
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }

    return $false
}

function Show-Header {
    Clear-Host
    Write-Host ""
    
    if ($IsPS7) {
        # PS7: Estilo Unicode (generado por codigo)
        $top = [char]9556 + (([string][char]9552) * 40) + [char]9559
        $mid = [char]9553 + "   GESTOR DE HOSTS PARA VPN AOC-GAMERS  " + [char]9553
        $bot = [char]9562 + (([string][char]9552) * 40) + [char]9565
        Write-Host $top -ForegroundColor Cyan
        Write-Host $mid -ForegroundColor Cyan
        Write-Host $bot -ForegroundColor Cyan
    } else {
        # PS5: Estetica simple ASCII
        Write-Host "+========================================+" -ForegroundColor Cyan
        $headerLine = [char]124 + "   GESTOR DE HOSTS PARA VPN AOC-GAMERS  " + [char]124
        Write-Host $headerLine -ForegroundColor Cyan
        Write-Host "+========================================+" -ForegroundColor Cyan
    }
    
    Write-Host ""
    Write-Host "Administra entradas en el archivo hosts de Windows para resolver" -ForegroundColor Gray
    Write-Host "nombres de dominio internos sin depender del DNS publico." -ForegroundColor Gray
    Write-Host ""
    
    # Mostrar info de version
    $versionColor = if ($IsPS7) { "Green" } else { "Yellow" }
    $adminStatus = if (Test-IsAdmin) { "Si" } else { "No" }
    $adminColor = if (Test-IsAdmin) { "Green" } else { "Red" }
    
    if ($IsPS7) {
        $itop = [char]9484 + (([string][char]9472) * 40) + [char]9488
        $imid = [char]9474 + " PowerShell: $PSMajorMinor ($PSEditionType) | Admin: $adminStatus"
        $ibot = [char]9492 + (([string][char]9472) * 40) + [char]9496
        Write-Host $itop -ForegroundColor DarkGray
        Write-Host $imid -ForegroundColor $versionColor
        Write-Host $ibot -ForegroundColor DarkGray
    } else {
        Write-Host "+----------------------------------------+" -ForegroundColor DarkGray
        Write-Host ("| PowerShell: " + $PSMajorMinor + " (" + $PSEditionType + ")") -ForegroundColor $versionColor
        Write-Host ("| Admin: " + $adminStatus) -ForegroundColor $adminColor
        Write-Host "+----------------------------------------+" -ForegroundColor DarkGray
    }
    
    Write-Host ""
}

function Show-Animation-Loading {
    param([int]$Seconds = 2)
    $spinner = @(".", "o", "O", "o")
    $end = (Get-Date).AddSeconds($Seconds)
    $i = 0
    while ((Get-Date) -lt $end) {
        $frame = $spinner[$i % $spinner.Length]
        $msg = [char]13 + $frame + " Procesando..."
        [Console]::Write($msg)
        Start-Sleep -Milliseconds 100
        $i++
    }
    $finalMsg = [char]13 + "[+] Completado        " + [char]10
    [Console]::Write($finalMsg)
    Write-Host "" -ForegroundColor Green
}

function Get-PSCapabilities {
    $capabilities = @{
        SupportsHtmlColorOutput = $IsPS7
        SupportsUtf8 = $IsPS7
        SupportsParallel = $IsPS7
        SupportsOutGrid = $true
        SupportsFormat = $true
    }
    return $capabilities
}

function Get-DnsEntriesFromConfig {
    param(
        [string]$ConfigPath
    )

    if (-not (Test-Path $ConfigPath)) {
        Show-Error "No se encontro config DNS en: $ConfigPath"
        Show-Warning "Copia domains.example.json a domains.json y personalizalo antes de ejecutar."
        return @()
    }

    try {
        $jsonRaw = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
        $config = $jsonRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Show-Error "No se pudo leer/parsing el archivo DNS: $ConfigPath"
        Write-Host "Detalle: $($_.Exception.Message)" -ForegroundColor DarkGray
        return @()
    }

    $sourceEntries = @()
    if ($config -is [System.Array]) {
        $sourceEntries = @($config)
    } elseif ($null -ne $config.entries) {
        $sourceEntries = @($config.entries)
    } else {
        Show-Error "El archivo DNS no contiene 'entries': $ConfigPath"
        return @()
    }

    $validatedEntries = @()

    foreach ($entry in $sourceEntries) {
        if ($null -eq $entry) {
            continue
        }

        $isEnabled = $true
        if ($entry.PSObject.Properties.Name -contains "enabled") {
            $isEnabled = [bool]$entry.enabled
        }
        if (-not $isEnabled) {
            continue
        }

        $hostname = ""
        if ($entry.PSObject.Properties.Name -contains "hostname") {
            $hostname = [string]$entry.hostname
        } elseif ($entry.PSObject.Properties.Name -contains "Hostname") {
            $hostname = [string]$entry.Hostname
        }

        $ipAddress = ""
        if ($entry.PSObject.Properties.Name -contains "ipAddress") {
            $ipAddress = [string]$entry.ipAddress
        } elseif ($entry.PSObject.Properties.Name -contains "IpAddress") {
            $ipAddress = [string]$entry.IpAddress
        }

        $hostname = $hostname.Trim()
        $ipAddress = $ipAddress.Trim()

        if ([string]::IsNullOrWhiteSpace($hostname) -or [string]::IsNullOrWhiteSpace($ipAddress)) {
            continue
        }

        $validatedEntries += @{ Hostname = $hostname; IpAddress = $ipAddress }
    }

    if ($validatedEntries.Count -eq 0) {
        Show-Error "No hay entradas validas habilitadas en: $ConfigPath"
        return @()
    }

    return @($validatedEntries)
}

function Show-Divider {
    if ($IsPS7) {
        Write-Host ((([string][char]9472) * 38)) -ForegroundColor DarkGray
    } else {
        Write-Host "========================================" -ForegroundColor DarkGray
    }
}

function Show-ListItem {
    param(
        [int]$Number,
        [string]$Text,
        [string]$Color = "White"
    )
    
    # Validar color con fallback seguro para PS5
    $resolvedColor = [System.ConsoleColor]::White
    if (-not [string]::IsNullOrWhiteSpace([string]$Color)) {
        try {
            $resolvedColor = [System.Enum]::Parse([System.ConsoleColor], [string]$Color, $true)
        } catch {
            $resolvedColor = [System.ConsoleColor]::White
        }
    }

    if ($null -eq $Text) {
        $Text = ""
    }
    
    Write-Host "  " -NoNewline
    if ($IsPS7) {
        Write-Host "?" -ForegroundColor Cyan -NoNewline
    } else {
        $pipe = [char]124
        Write-Host $pipe -ForegroundColor Cyan -NoNewline
    }
    Write-Host " " -NoNewline
    Write-Host $Number -ForegroundColor Green -NoNewline
    $output = "  " + $Text
    Write-Host $output -ForegroundColor $resolvedColor
}

function Show-Success {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Show-Error {
    param([string]$Message)
    Write-Host "[-] $Message" -ForegroundColor Red
}

function Show-Warning {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Show-MainMenu {
    Show-Header
    Write-Host "Que deseas hacer?" -ForegroundColor Yellow
    Write-Host ""

    if ($IsPS7) {
        $vbar = [char]9475
        Write-Host ("  " + $vbar + " ") -NoNewline; Write-Host "1" -ForegroundColor Green -NoNewline; Write-Host "  Agregar TODAS las DNS predefinidas" -ForegroundColor White
        Write-Host ("  " + $vbar + " ") -NoNewline; Write-Host "2" -ForegroundColor Green -NoNewline; Write-Host "  Agregar DNS especifica manualmente" -ForegroundColor White
        Write-Host ("  " + $vbar + " ") -NoNewline; Write-Host "3" -ForegroundColor Green -NoNewline; Write-Host "  Ver DNS configuradas" -ForegroundColor White
        Write-Host ("  " + $vbar + " ") -NoNewline; Write-Host "4" -ForegroundColor Green -NoNewline; Write-Host "  Eliminar una DNS" -ForegroundColor White
        Write-Host ("  " + $vbar + " ") -NoNewline; Write-Host "5" -ForegroundColor Red   -NoNewline; Write-Host "  Eliminar TODAS las DNS predefinidas" -ForegroundColor Red
        Write-Host ("  " + $vbar + " ") -NoNewline; Write-Host "6" -ForegroundColor Green -NoNewline; Write-Host "  Limpiar cache DNS del sistema" -ForegroundColor White
        Write-Host ("  " + $vbar + " ") -NoNewline; Write-Host "7" -ForegroundColor Green -NoNewline; Write-Host "  Ver archivo hosts completo" -ForegroundColor White
        Write-Host ("  " + $vbar + " ") -NoNewline; Write-Host "8" -ForegroundColor Green -NoNewline; Write-Host "  Info de compatibilidad" -ForegroundColor White
        Write-Host ("  " + $vbar + " ") -NoNewline; Write-Host "0" -ForegroundColor White -NoNewline; Write-Host "  Salir" -ForegroundColor White
    } else {
        $pipe = [char]124
        Write-Host ("  " + $pipe + " ") -NoNewline; Write-Host "1" -ForegroundColor Green -NoNewline; Write-Host "  Agregar TODAS las DNS predefinidas" -ForegroundColor White
        Write-Host ("  " + $pipe + " ") -NoNewline; Write-Host "2" -ForegroundColor Green -NoNewline; Write-Host "  Agregar DNS especifica manualmente" -ForegroundColor White
        Write-Host ("  " + $pipe + " ") -NoNewline; Write-Host "3" -ForegroundColor Green -NoNewline; Write-Host "  Ver DNS configuradas" -ForegroundColor White
        Write-Host ("  " + $pipe + " ") -NoNewline; Write-Host "4" -ForegroundColor Green -NoNewline; Write-Host "  Eliminar una DNS" -ForegroundColor White
        Write-Host ("  " + $pipe + " ") -NoNewline; Write-Host "5" -ForegroundColor Red   -NoNewline; Write-Host "  Eliminar TODAS las DNS predefinidas" -ForegroundColor Red
        Write-Host ("  " + $pipe + " ") -NoNewline; Write-Host "6" -ForegroundColor Green -NoNewline; Write-Host "  Limpiar cache DNS del sistema" -ForegroundColor White
        Write-Host ("  " + $pipe + " ") -NoNewline; Write-Host "7" -ForegroundColor Green -NoNewline; Write-Host "  Ver archivo hosts completo" -ForegroundColor White
        Write-Host ("  " + $pipe + " ") -NoNewline; Write-Host "8" -ForegroundColor Green -NoNewline; Write-Host "  Info de compatibilidad" -ForegroundColor White
        Write-Host ("  " + $pipe + " ") -NoNewline; Write-Host "0" -ForegroundColor White -NoNewline; Write-Host "  Salir" -ForegroundColor White
    }
    
    Write-Host ""
}

function Show-CompatibilityInfo {
    Show-Header
    Write-Host "i  INFORMACION DE COMPATIBILIDAD:" -ForegroundColor Magenta
    Write-Host ""
    $caps = Get-PSCapabilities
    
    Write-Host "Version PowerShell: " -NoNewline
    Write-Host "$PSMajorMinor ($PSEditionType)" -ForegroundColor Cyan
    Write-Host "Plataforma: " -NoNewline
    Write-Host "$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)" -ForegroundColor Gray
    Write-Host ""
    
    Show-Divider
    Write-Host "Capacidades:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host "$(if ($caps.SupportsHtmlColorOutput) { '?' } else { '?' })" -ForegroundColor $(if ($caps.SupportsHtmlColorOutput) { 'Green' } else { 'Red' }) -NoNewline
    Write-Host " Output HTML: " -NoNewline
    Write-Host "$(if ($caps.SupportsHtmlColorOutput) { 'Si' } else { 'No' })" -ForegroundColor $(if ($caps.SupportsHtmlColorOutput) { 'Green' } else { 'Red' })
    
    Write-Host "  " -NoNewline
    Write-Host "$(if ($caps.SupportsUtf8) { '?' } else { '?' })" -ForegroundColor $(if ($caps.SupportsUtf8) { 'Green' } else { 'Red' }) -NoNewline
    Write-Host " UTF-8: " -NoNewline
    Write-Host "$(if ($caps.SupportsUtf8) { 'Si' } else { 'No' })" -ForegroundColor $(if ($caps.SupportsUtf8) { 'Green' } else { 'Red' })
    
    Write-Host "  " -NoNewline
    Write-Host "$(if ($caps.SupportsParallel) { '?' } else { '?' })" -ForegroundColor $(if ($caps.SupportsParallel) { 'Green' } else { 'Red' }) -NoNewline
    Write-Host " Parallelizacion: " -NoNewline
    Write-Host "$(if ($caps.SupportsParallel) { 'Disponible (PS7)' } else { 'No (PS5)' })" -ForegroundColor $(if ($caps.SupportsParallel) { 'Green' } else { 'Yellow' })
    
    Write-Host "  " -NoNewline
    Write-Host "$(if ($caps.SupportsOutGrid) { '?' } else { '?' })" -ForegroundColor $(if ($caps.SupportsOutGrid) { 'Green' } else { 'Red' }) -NoNewline
    Write-Host " Out-GridView: " -NoNewline
    Write-Host "$(if ($caps.SupportsOutGrid) { 'Si' } else { 'No' })" -ForegroundColor $(if ($caps.SupportsOutGrid) { 'Green' } else { 'Red' })
    
    Write-Host "  " -NoNewline
    Write-Host "$(if ($caps.SupportsFormat) { '?' } else { '?' })" -ForegroundColor $(if ($caps.SupportsFormat) { 'Green' } else { 'Red' }) -NoNewline
    Write-Host " Format-Table: " -NoNewline
    Write-Host "$(if ($caps.SupportsFormat) { 'Si' } else { 'No' })" -ForegroundColor $(if ($caps.SupportsFormat) { 'Green' } else { 'Red' })
    
    Write-Host ""
    Show-Divider
    Write-Host "Notas:" -ForegroundColor Yellow
    Write-Host ""
    if ($IsPS7) {
        Write-Host "  [ok] Ejecutando en PowerShell 7+ (mejor rendimiento)" -ForegroundColor Green
    } else {
        Write-Host "  i Ejecutando en PowerShell 5 (compatible pero legacy)" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Add-DnsEntry {
    param(
        [string]$Hostname,
        [string]$IpAddress
    )

    if (-not (Test-Path $hostsPath)) {
        Write-Error "No se encontro el archivo hosts en: $hostsPath"
        return $false
    }

    $rawLines = Get-Content -Path $hostsPath -ErrorAction Stop
    $updatedLines = New-Object System.Collections.Generic.List[string]
    $found = $false

    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            $updatedLines.Add($line)
            continue
        }

        $parts = ($trimmed -split "\s+")
        if ($parts.Count -lt 2) {
            $updatedLines.Add($line)
            continue
        }

        $lineHosts = $parts[1..($parts.Count - 1)]
        if ($lineHosts -contains $Hostname) {
            $found = $true
            $lineIp = $parts[0]
            if ($lineIp -eq $IpAddress) {
                $updatedLines.Add($line)
            } else {
                $otherHosts = @($lineHosts | Where-Object { $_ -ne $Hostname })
                if ($otherHosts.Count -gt 0) {
                    $updatedLines.Add("$($parts[0])`t$($otherHosts -join ' ')")
                }
            }
        } else {
            $updatedLines.Add($line)
        }
    }

    if (-not $found) {
        $updatedLines.Add("$IpAddress`t$Hostname")
    }

    if (-not (Write-HostsFileWithRetry -Lines $updatedLines)) {
        return $false
    }
    return $true
}

function Add-AllDnsEntries {
    if (-not (Test-Path $hostsPath)) {
        Write-Error "No se encontro el archivo hosts"
        return
    }

    $timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $backupPath = $hostsPath + ".bak." + $timestamp
    Copy-Item $hostsPath $backupPath -Force

    Show-Header
    Write-Host "Procesando DNS..." -ForegroundColor Cyan
    Write-Host ""

    $rawLines = Get-Content -Path $hostsPath -ErrorAction Stop
    $updatedLines = New-Object System.Collections.Generic.List[string]
    $processedHosts = New-Object System.Collections.Generic.HashSet[string]

    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            $updatedLines.Add($line)
            continue
        }

        $parts = ($trimmed -split "\s+")
        if ($parts.Count -lt 2) {
            $updatedLines.Add($line)
            continue
        }

        $lineIp = $parts[0]
        $lineHosts = $parts[1..($parts.Count - 1)]
        $newLineHosts = New-Object System.Collections.Generic.List[string]

        foreach ($hostname in $lineHosts) {
            $matchingEntry = $DnsEntries | Where-Object { $_.Hostname -eq $hostname }
            if ($matchingEntry) {
                $processedHosts.Add($hostname) | Out-Null
            } else {
                $newLineHosts.Add($hostname)
            }
        }

        if ($newLineHosts.Count -gt 0) {
            $updatedLines.Add("$lineIp`t$($newLineHosts -join ' ')")
        }
    }

    foreach ($entry in $DnsEntries) {
        if (-not $processedHosts.Contains($entry.Hostname)) {
            $updatedLines.Add("$($entry.IpAddress)`t$($entry.Hostname)")
        }
    }

    if (-not (Write-HostsFileWithRetry -Lines $updatedLines)) {
        return
    }
    
    Write-Host " " -NoNewline
    Show-Animation-Loading -Seconds 1
    
    Write-Host ""
    Write-Host "[i] Backup creado:" -ForegroundColor Green -NoNewline
    Write-Host " $backupPath" -ForegroundColor Gray
    Write-Host "[ok] DNS agregadas correctamente" -ForegroundColor Green
    Write-Host ""
}

function Show-DnsEntries {
    if (-not (Test-Path $hostsPath)) {
        Write-Error "No se encontro el archivo hosts"
        return
    }

    Show-Header
    Write-Host "DNS CONFIGURADAS EN EL ARCHIVO HOSTS:" -ForegroundColor Yellow
    Write-Host ""
    Show-Divider
    
    $rawLines = Get-Content -Path $hostsPath -ErrorAction Stop
    $count = 0

    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            continue
        }

        $parts = ($trimmed -split "\s+")
        if ($parts.Count -ge 2) {
            $count++
            $ip = $parts[0]
            $hostnames = $parts[1..($parts.Count - 1)] -join ", "
            
            Write-Host "  " -NoNewline
            Write-Host "[$count]" -ForegroundColor Magenta -NoNewline
            Write-Host " IP: " -NoNewline
            Write-Host "$ip" -ForegroundColor Cyan -NoNewline
            Write-Host " -> " -NoNewline
            Write-Host "$hostnames" -ForegroundColor Green
        }
    }

    if ($count -eq 0) {
        Write-Host "  (No hay entradas personalizadas)" -ForegroundColor Gray
    }

    Write-Host ""
    Show-Divider
    Write-Host ""
}

function Show-HostsFile {
    Show-Header
    Write-Host "[i] CONTENIDO DEL ARCHIVO HOSTS:" -ForegroundColor Cyan
    Write-Host ""
    Show-Divider
    
    Get-Content -Path $hostsPath | ForEach-Object { 
        if ($_ -match "^\s*#") {
            Write-Host $_ -ForegroundColor DarkGray
        } elseif ($_ -match "^\s*$") {
            Write-Host ""
        } else {
            $parts = $_ -split "\s+"
            if ($parts.Count -ge 2) {
                Write-Host $parts[0] -ForegroundColor Cyan -NoNewline
                Write-Host ("`t" + ($parts[1..($parts.Count-1)] -join " ")) -ForegroundColor Green
            } else {
                Write-Host $_
            }
        }
    }
    
    Show-Divider
    Write-Host ""
}

function Remove-DnsEntry {
    Show-Header
    Write-Host "[!] ELIMINAR UNA DNS:" -ForegroundColor Red
    Write-Host ""

    $hostname = Read-Host "Ingresa el hostname a eliminar"
    if (-not $hostname) {
        Write-Host "Cancelado" -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path $hostsPath)) {
        Write-Error "No se encontro el archivo hosts"
        return
    }

    Show-Header
    Write-Host "Procesando eliminacion..." -ForegroundColor Cyan

    $rawLines = Get-Content -Path $hostsPath -ErrorAction Stop
    $updatedLines = New-Object System.Collections.Generic.List[string]
    $found = $false

    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            $updatedLines.Add($line)
            continue
        }

        $parts = ($trimmed -split "\s+")
        if ($parts.Count -ge 2) {
            $lineHosts = $parts[1..($parts.Count - 1)]
            if ($lineHosts -contains $hostname) {
                $found = $true
                $otherHosts = @($lineHosts | Where-Object { $_ -ne $hostname })
                if ($otherHosts.Count -gt 0) {
                    $updatedLines.Add("$($parts[0])`t$($otherHosts -join ' ')")
                }
                continue
            }
        }
        $updatedLines.Add($line)
    }

    if ($found) {
        if (-not (Write-HostsFileWithRetry -Lines $updatedLines)) {
            return
        }
        Show-Animation-Loading -Seconds 1
        Write-Host ""
        Write-Host "[ok] DNS eliminada:" -ForegroundColor Green
        Write-Host "  $hostname" -ForegroundColor Yellow
        Write-Host ""
    } else {
        Write-Host "[!] No se encontro: " -ForegroundColor Red -NoNewline
        Write-Host "$hostname" -ForegroundColor Yellow
        Write-Host ""
    }
}

function Add-ManualDnsEntry {
    Show-Header
    Write-Host "[i] AGREGAR DNS MANUALMENTE:" -ForegroundColor Green
    Write-Host ""

    $hostname = Read-Host "Ingresa el hostname"
    if (-not $hostname) {
        Write-Host "[i] Cancelado" -ForegroundColor Red
        return
    }

    $ipaddress = Read-Host "Ingresa la direccion IP"
    if (-not $ipaddress) {
        Write-Host "[i] Cancelado" -ForegroundColor Red
        return
    }

    Show-Header
    Write-Host "Agregando DNS..." -ForegroundColor Cyan
    
    if (Add-DnsEntry -Hostname $hostname -IpAddress $ipaddress) {
        Show-Animation-Loading -Seconds 1
        Write-Host ""
        Write-Host "[ok] DNS agregada:" -ForegroundColor Green
        Write-Host "  $hostname" -ForegroundColor Cyan -NoNewline
        Write-Host " -> " -NoNewline
        Write-Host "$ipaddress" -ForegroundColor Yellow
        Write-Host ""
    } else {
        Write-Host "[!] Error al agregar DNS" -ForegroundColor Red
    }
}

function Flush-DnsCache {
    Show-Header
    Write-Host "[*] LIMPIAR CACHE DNS:" -ForegroundColor Cyan
    Write-Host ""

    try {
        Write-Host "Ejecutando ipconfig /flushdns..." -ForegroundColor Yellow
        ipconfig /flushdns | Out-Null
        
        Show-Animation-Loading -Seconds 1
        Write-Host ""
        Write-Host "[+] Cache DNS limpiada correctamente" -ForegroundColor Green
        Write-Host ""
    } catch {
        Write-Host "[-] Error al limpiar cache DNS" -ForegroundColor Red
    }
}

function Remove-AllDnsEntries {
    Show-Header
    Write-Host "[!] ELIMINAR TODAS LAS DNS PREDEFINIDAS" -ForegroundColor Red
    Write-Host ""
    Write-Host "[!] Estas seguro? Esta accion eliminara:" -ForegroundColor Yellow
    Write-Host ""
    Show-Divider
    
    foreach ($entry in $DnsEntries) {
        Write-Host "  o " -NoNewline
        Write-Host "$($entry.Hostname)" -ForegroundColor Cyan -NoNewline
        Write-Host " ->" -NoNewline
        Write-Host " $($entry.IpAddress)" -ForegroundColor Yellow
    }
    
    Show-Divider
    Write-Host ""
    Write-Host "Escribe " -NoNewline
    Write-Host "'SI'" -ForegroundColor Yellow -NoNewline
    Write-Host " para confirmar" -NoNewline
    Write-Host ": " -ForegroundColor Gray
    
    $confirm = Read-Host
    
    if ($confirm -ne "SI") {
        Write-Host "[i] Cancelado" -ForegroundColor Red
        return
    }

    if (-not (Test-Path $hostsPath)) {
        Write-Error "No se encontro el archivo hosts"
        return
    }

    Show-Header
    Write-Host "Eliminando DNS..." -ForegroundColor Cyan

    $timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $backupPath = $hostsPath + ".bak." + $timestamp
    Copy-Item $hostsPath $backupPath -Force

    $rawLines = Get-Content -Path $hostsPath -ErrorAction Stop
    $updatedLines = New-Object System.Collections.Generic.List[string]
    $removedCount = 0

    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            $updatedLines.Add($line)
            continue
        }

        $parts = ($trimmed -split "\s+")
        if ($parts.Count -lt 2) {
            $updatedLines.Add($line)
            continue
        }

        $lineIp = $parts[0]
        $lineHosts = $parts[1..($parts.Count - 1)]
        $newLineHosts = New-Object System.Collections.Generic.List[string]

        foreach ($hostname in $lineHosts) {
            $matchingEntry = $DnsEntries | Where-Object { $_.Hostname -eq $hostname }
            if ($matchingEntry) {
                $removedCount++
            } else {
                $newLineHosts.Add($hostname)
            }
        }

        if ($newLineHosts.Count -gt 0) {
            $updatedLines.Add("$lineIp`t$($newLineHosts -join ' ')")
        }
    }

    if (-not (Write-HostsFileWithRetry -Lines $updatedLines)) {
        return
    }
    
    Show-Animation-Loading -Seconds 1
    
    Write-Host ""
    Write-Host "[i] Backup creado:" -ForegroundColor Green -NoNewline
    Write-Host " $backupPath" -ForegroundColor Gray
    Write-Host "[ok] $removedCount DNS eliminadas" -ForegroundColor Green
    Write-Host ""
}

# MAIN
# Auto-elevar a administrador si es necesario
Invoke-RequireAdmin

# Validar acceso al archivo hosts
if (-not (Test-Path $hostsPath)) {
    Write-Error "No se puede acceder a: $hostsPath"
    Write-Error "Asegurate de ejecutar como Administrador"
    exit 1
}

$DnsEntries = @(Get-DnsEntriesFromConfig -ConfigPath $DnsConfigPath)

if ($DnsEntries.Count -eq 0) {
    Write-Error "No hay entradas DNS disponibles para operar."
    exit 1
}

$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$backupPath = $hostsPath + ".bak." + $timestamp
Copy-Item $hostsPath $backupPath -Force | Out-Null

while ($true) {
    Show-MainMenu
    $choice = Read-Host "Elige una opcion"

    switch ($choice) {
        "1" {
            $timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
            $backupPath = $hostsPath + ".bak." + $timestamp
            Copy-Item $hostsPath $backupPath -Force | Out-Null
            Add-AllDnsEntries
            Read-Host "Presiona Enter para continuar"
        }
        "2" {
            Add-ManualDnsEntry
            Read-Host "Presiona Enter para continuar"
        }
        "3" {
            Show-DnsEntries
            Read-Host "Presiona Enter para continuar"
        }
        "4" {
            Remove-DnsEntry
            Read-Host "Presiona Enter para continuar"
        }
        "5" {
            Remove-AllDnsEntries
            Read-Host "Presiona Enter para continuar"
        }
        "6" {
            Flush-DnsCache
            Read-Host "Presiona Enter para continuar"
        }
        "7" {
            Show-HostsFile
            Read-Host "Presiona Enter para continuar"
        }
        "8" {
            Show-CompatibilityInfo
            Read-Host "Presiona Enter para continuar"
        }
        "0" {
            Show-Header
            Write-Host "Hasta luego!" -ForegroundColor Green
            Write-Host ""
            Start-Sleep -Milliseconds 500
            exit 0
        }
        default {
            Write-Host ""
            Write-Host "Opcion invalida" -ForegroundColor Yellow
            Start-Sleep -Milliseconds 1000
        }
    }
}

