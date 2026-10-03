# Dev proxy setup helper for Windows + WSL development environments.
# This tool is intentionally standalone and does not modify CC Switch data files.

[CmdletBinding()]
param(
    [string]$ProxyHost,
    [int]$ProxyPort,
    [ValidateSet("http", "https")]
    [string]$ProxyScheme,
    [string]$Distro,
    [switch]$NonInteractive,
    [switch]$Verify,
    [switch]$Disable,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot "config.json"
$TemplatePath = Join-Path $ScriptRoot "templates\wsl-proxy-env.sh"
$InteropTemplatePath = Join-Path $ScriptRoot "templates\wsl-interop-proxy.py"

# The Windows user-scope knobs this tool owns. Nothing outside these is touched.
$InternetSettingsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$ProxyEnvNames = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy")
$DefaultProxyPort = 20122
$DefaultWslInteropPort = 20180
$WslInteropPort = $DefaultWslInteropPort
$script:WindowsRelayImplementationVersion = "3"
$script:ProxyPortWasSupplied = $PSBoundParameters.ContainsKey("ProxyPort")

# VerifyFailures counts one verification run, for its summary line. HadFailures
# is never reset, so a failure raised before verification still reaches the
# exit code.
$script:VerifyFailures = 0
$script:HadFailures = $false

try {
    # Windows PowerShell 5.1 still offers TLS 1.0 first, which the endpoints used
    # for verification refuse outright. Add TLS 1.2 without dropping newer values.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # Some constrained hosts forbid changing this. Verification still runs.
}

$script:OriginalConsoleOutputEncoding = $null
$script:OriginalPipelineOutputEncoding = $OutputEncoding
try {
    $script:OriginalConsoleOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Console]::OutputEncoding
} catch {
    # Older hosts may not expose a writable console encoding. Output still works.
}

function Write-Line {
    param(
        [AllowNull()]
        [string]$Message = "",
        [Nullable[ConsoleColor]]$ForegroundColor = $null
    )

    if ($null -eq $Message) { $Message = "" }

    # Windows Terminal can render bare LF as a stair-step after native command output.
    # Emit explicit CRLF so menus and progress lines always return to column 0.
    $oldColor = $null
    try {
        $oldColor = [Console]::ForegroundColor
        if ($ForegroundColor.HasValue) {
            [Console]::ForegroundColor = $ForegroundColor.Value
        }
        [Console]::Write("$Message`r`n")
    } catch {
        Microsoft.PowerShell.Utility\Write-Output $Message
    } finally {
        try {
            if ($ForegroundColor.HasValue -and $null -ne $oldColor) {
                [Console]::ForegroundColor = $oldColor
            }
        } catch {
        }
    }
}

function Write-Info($Message) { Write-Line "[INFO] $Message" ([ConsoleColor]::Cyan) }
function Write-Ok($Message) { Write-Line "[ OK ] $Message" ([ConsoleColor]::Green) }
function Write-Warn($Message) { Write-Line "[WARN] $Message" ([ConsoleColor]::Yellow) }
function Write-Fail($Message) {
    $script:VerifyFailures++
    $script:HadFailures = $true
    Write-Line "[FAIL] $Message" ([ConsoleColor]::Red)
}
function Write-Tip($Message) { Write-Line "[TIP ] $Message" ([ConsoleColor]::DarkCyan) }
function Show-Progress($Activity, $Status, [int]$Percent) {
    Write-Info ("{0} [{1,3}%] {2}" -f $Activity, $Percent, $Status)
}
function Complete-Progress($Activity) {
    Write-Info "$Activity complete"
}

function Read-YesNo($Prompt, [bool]$Default = $true) {
    $suffix = if ($Default) { "Y/n" } else { "y/N" }
    $answer = Read-Host "$Prompt [$suffix]"
    $answer = "$answer".Trim().ToLowerInvariant()
    if ($answer -in @("y", "yes")) { return $true }
    if ($answer -in @("n", "no")) { return $false }
    # Blank or unrecognized input keeps the shown default rather than silently meaning "no".
    return $Default
}

function Get-DefaultConfig {
    [pscustomobject]@{
        proxyHost = "127.0.0.1"
        proxyPort = $DefaultProxyPort
        proxyScheme = "http"
        noProxy = "localhost,127.0.0.1,::1,.local"
        distro = $null
        enableWslMirrored = $true
        enableWslInteropFallback = $true
        wslInteropPort = $DefaultWslInteropPort
    }
}

function Read-Config {
    $defaults = Get-DefaultConfig
    if (Test-Path $ConfigPath) {
        try {
            $loaded = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            foreach ($name in $defaults.PSObject.Properties.Name) {
                if ($null -ne $loaded.$name -and "$($loaded.$name)" -ne "") {
                    $defaults.$name = $loaded.$name
                }
            }
        } catch {
            Write-Warn "config.json could not be parsed; using defaults. $($_.Exception.Message)"
        }
    }
    if ($ProxyHost) { $defaults.proxyHost = $ProxyHost.Trim() }
    if ($script:ProxyPortWasSupplied) { $defaults.proxyPort = $ProxyPort }
    if ($ProxyScheme) { $defaults.proxyScheme = $ProxyScheme }
    if ($Distro) { $defaults.distro = $Distro.Trim() }

    # config.json is hand-editable, so normalize before anything writes it into
    # the registry, the WSL template, or an env var.
    $port = 0
    if (![int]::TryParse("$($defaults.proxyPort)", [ref]$port) -or !(Test-ProxyPort $port)) {
        Write-Warn "Proxy port '$($defaults.proxyPort)' is not in 1-65535; using $DefaultProxyPort."
        $port = $DefaultProxyPort
    }
    $defaults.proxyPort = $port
    if ("$($defaults.proxyScheme)" -notin @("http", "https")) {
        Write-Warn "Proxy scheme '$($defaults.proxyScheme)' is not http or https; using http."
        $defaults.proxyScheme = "http"
    }
    if ([string]::IsNullOrWhiteSpace("$($defaults.proxyHost)") -or "$($defaults.proxyHost)" -match '[\r\n\t;]') {
        Write-Warn "Proxy host '$($defaults.proxyHost)' is empty or contains unsafe characters; using 127.0.0.1."
        $defaults.proxyHost = "127.0.0.1"
    } else {
        $defaults.proxyHost = "$($defaults.proxyHost)".Trim()
    }
    $defaults.enableWslMirrored = [bool]$defaults.enableWslMirrored
    $defaults.enableWslInteropFallback = [bool]$defaults.enableWslInteropFallback
    $interopPort = 0
    if (![int]::TryParse("$($defaults.wslInteropPort)", [ref]$interopPort) -or !(Test-ProxyPort $interopPort)) {
        Write-Warn "WSL interop port '$($defaults.wslInteropPort)' is not in 1-65535; using $DefaultWslInteropPort."
        $interopPort = $DefaultWslInteropPort
    }
    $defaults.wslInteropPort = $interopPort
    return $defaults
}

function Save-Config($Config) {
    $json = ($Config | ConvertTo-Json -Depth 4)
    if ($DryRun) {
        Write-Info "Dry-run: would save $ConfigPath"
        return
    }
    if (Test-Path $ConfigPath) {
        try {
            if ((Get-Content $ConfigPath -Raw).Trim() -eq $json.Trim()) { return }
        } catch {
            # Unreadable file just means we rewrite it below.
        }
    }
    # BOM-less UTF-8 so non-PowerShell readers do not trip on a BOM. Write and
    # replace through a same-directory temporary file so an interrupted write
    # cannot leave a half-generated config.
    $tempPath = "$ConfigPath.tmp.$PID"
    try {
        [IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tempPath -Destination $ConfigPath -Force
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Test-ProxyPort([int]$Port) {
    return ($Port -ge 1 -and $Port -le 65535)
}

function Get-ProxyUrl($Config) {
    $proxyHostText = [string]$Config.proxyHost
    if ($proxyHostText.Contains(":") -and !$proxyHostText.StartsWith("[") -and !$proxyHostText.EndsWith("]")) { $proxyHostText = "[$proxyHostText]" }
    "$($Config.proxyScheme)://${proxyHostText}:$($Config.proxyPort)"
}

function Get-InteropIdentityToken($Config) {
    # A deterministic, non-secret generation id lets a new install detect a
    # relay from an older target without killing it.  It also keeps repeat
    # installs idempotent while making target updates require an explicit
    # relay restart/parallel-port rollout.
    $interopTemplateMaterial = ""
    if (Test-Path $InteropTemplatePath) { $interopTemplateMaterial = Get-Content $InteropTemplatePath -Raw }
    $material = "{0}|{1}|{2}|{3}|{4}|relay={5}|template={6}" -f $Config.proxyScheme, $Config.proxyHost, $Config.proxyPort, $WslInteropPort, $Config.noProxy, $script:WindowsRelayImplementationVersion, $interopTemplateMaterial
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($material)
        return (([BitConverter]::ToString($sha.ComputeHash($bytes))) -replace "-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-BashSingleQuotedContent([string]$Value) {
    # The caller supplies the surrounding single quotes in the template. A
    # single quote inside the value is represented by the POSIX ''' splice;
    # dollar signs, backticks, semicolons, and command substitutions then stay
    # literal when the generated file is sourced.
    return ([string]$Value).Replace("'", "'\''")
}

function ConvertTo-ProxyOverride([string]$NoProxy) {
    # WinINet wants semicolons and its own <local> token, config.json uses the
    # comma-separated form the CLI env vars expect. Keep one source of truth.
    $parts = @()
    foreach ($item in ("$NoProxy" -split "[,;]")) {
        $trimmed = $item.Trim()
        if (!$trimmed) { continue }
        # curl-style ".local" means "any host in that suffix"; WinINet needs "*.local".
        if ($trimmed.StartsWith(".")) { $trimmed = "*$trimmed" }
        if ($parts -notcontains $trimmed) { $parts += $trimmed }
    }
    if ($parts -notcontains "<local>") { $parts += "<local>" }
    return ($parts -join ";")
}

function Get-ProxyEnvEntries($Config) {
    # A hashtable would fold HTTP_PROXY and http_proxy into a single entry,
    # because PowerShell compares its keys case-insensitively. Both spellings
    # have to be written, so keep them as an ordered list of pairs.
    $proxy = Get-ProxyUrl $Config
    $entries = @()
    foreach ($name in $ProxyEnvNames) {
        $value = if ($name -ieq "NO_PROXY") { [string]$Config.noProxy } else { $proxy }
        $entries += [pscustomobject]@{ Name = $name; Value = $value }
    }
    return $entries
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-WinInetRefresh {
    try {
        if (-not ("DevProxyWinInet" -as [type])) {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DevProxyWinInet {
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
"@
        }
        [void][DevProxyWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][DevProxyWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
        Write-Ok "WinINet proxy settings refreshed"
    } catch {
        Write-Warn "Could not refresh WinINet settings automatically: $($_.Exception.Message)"
    }
}

function Set-WindowsSystemProxy($Config) {
    $server = (Get-ProxyUrl $Config) -replace "^[^:]+://", ""
    $override = ConvertTo-ProxyOverride $Config.noProxy

    if ($DryRun) {
        Write-Info "Dry-run: would set Windows system proxy to $server (bypass: $override)"
        return
    }

    Set-ItemProperty -Path $InternetSettingsPath -Name ProxyEnable -Type DWord -Value 1
    Set-ItemProperty -Path $InternetSettingsPath -Name ProxyServer -Type String -Value $server
    Set-ItemProperty -Path $InternetSettingsPath -Name ProxyOverride -Type String -Value $override
    Invoke-WinInetRefresh
    Write-Ok "Windows user system proxy set to $server"
}

function Clear-WindowsSystemProxy {
    if ($DryRun) {
        Write-Info "Dry-run: would disable Windows user system proxy"
        return
    }
    Set-ItemProperty -Path $InternetSettingsPath -Name ProxyEnable -Type DWord -Value 0
    Invoke-WinInetRefresh
    Write-Ok "Windows user system proxy disabled"
}

function Set-UserProxyEnv($Config) {
    foreach ($entry in @(Get-ProxyEnvEntries $Config)) {
        if ($DryRun) {
            Write-Info "Dry-run: would set user env $($entry.Name)=$($entry.Value)"
        } else {
            [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, "User")
        }
    }
    if (!$DryRun) { Write-Ok "Windows user proxy environment variables updated" }
}

function Clear-UserProxyEnv {
    foreach ($name in $ProxyEnvNames) {
        if ($DryRun) {
            Write-Info "Dry-run: would clear user env $name"
        } else {
            [Environment]::SetEnvironmentVariable($name, $null, "User")
        }
    }
    if (!$DryRun) { Write-Ok "Windows user proxy environment variables cleared" }
}

function Invoke-NetshWinHttp {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Progress,
        [Parameter(Mandatory = $true)][string]$Success
    )

    # Never elevates on its own; it only tells the user the command to run.
    $command = "netsh " + ($Arguments -join " ")
    if (!(Test-IsAdmin)) {
        Write-Warn "This step requires an elevated PowerShell. Run: $command"
        return
    }
    if ($DryRun) {
        Write-Info "Dry-run: would run $command"
        return
    }
    Write-Info $Progress
    # Raw localized netsh output is suppressed to avoid mojibake in mixed-encoding terminals.
    & netsh.exe @Arguments *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok $Success
    } else {
        Write-Warn "'$command' returned exit code $LASTEXITCODE"
    }
}

function Sync-WinHttpProxy {
    Invoke-NetshWinHttp -Arguments @("winhttp", "import", "proxy", "source=ie") -Progress "Syncing WinHTTP from Windows user system proxy. This can take a few seconds..." -Success "WinHTTP proxy imported from Windows user system proxy"
}

function Reset-WinHttpProxy {
    Invoke-NetshWinHttp -Arguments @("winhttp", "reset", "proxy") -Progress "Resetting WinHTTP proxy..." -Success "WinHTTP proxy reset"
}

function Show-WinHttpProxy {
    Write-Info "WinHTTP raw localized output is suppressed to avoid console mojibake."
    Write-Info "Inspect manually if needed: netsh winhttp show proxy"
}

function Test-WslLocalhostProxyNoise([string]$Text) {
    # Keep this script ASCII so Windows PowerShell 5.1 cannot decode these
    # regex alternatives through the active ANSI code page and swallow a '|'.
    if ($Text -match "localhost.*WSL|localhost.*proxy|localhost \u4EE3\u7406|NAT \u6A21\u5F0F|WSL0NAT") { return $true }
    if ($Text -match "localhost" -and $Text -match "\uFFFD|Km0R|N/ec|Nt0|NtM") { return $true }
    return $false
}

function Split-WslOutput($Output) {
    # Separates real output from the two startup noise categories WSL emits, so
    # callers can print, count, or parse the same filtered lines.
    $lines = New-Object System.Collections.Generic.List[string]
    $sawPathNoise = $false
    $sawLocalhostNoise = $false
    foreach ($item in $Output) {
        $text = ("$item" -replace "`0", "").TrimEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match "UtilTranslatePathList|Failed to translate") { $sawPathNoise = $true; continue }
        if (Test-WslLocalhostProxyNoise $text) { $sawLocalhostNoise = $true; continue }
        $lines.Add($text)
    }
    return [pscustomobject]@{
        Lines = $lines.ToArray()
        SawPathNoise = $sawPathNoise
        SawLocalhostNoise = $sawLocalhostNoise
    }
}

function Write-WslOutputLines($Parsed) {
    if ($Parsed.SawPathNoise) {
        Write-Warn "WSL skipped invalid Windows PATH entries while starting. This is harmless for this tool; clean Windows PATH later if desired."
    }
    if ($Parsed.SawLocalhostNoise) {
        Write-Warn "WSL reports localhost proxy is not mirrored. In NAT mode, enable mirrored networking or make your proxy client listen on LAN/0.0.0.0."
    }
    foreach ($line in $Parsed.Lines) { Write-Line $line }
}

function Get-WslCleanLines($Output) {
    return (Split-WslOutput $Output).Lines
}

function Get-WslFailureReason($Result) {
    if ($Result.TimedOut) { return "the WSL command timed out" }
    if ($Result.PSObject.Properties.Name -contains "Completed" -and !$Result.Completed) {
        return "the WSL command did not report a verified completion marker"
    }
    return "the WSL command exited with code $($Result.ExitCode)"
}

function New-WslPayloadRunner([int]$TimeoutSec, [int]$ExpectedBytes, [string]$ExpectedSha256, [string]$CompletionMarker) {
    # Only numeric/hex values and the generated alphanumeric marker are
    # interpolated. The command itself arrives as base64 on standard input.
    if ($TimeoutSec -lt 1 -or $ExpectedBytes -lt 1 -or $ExpectedSha256 -notmatch '^[0-9a-f]{64}$' -or $CompletionMarker -notmatch '^[A-Za-z0-9_]+$') {
        throw "Invalid WSL payload runner parameters."
    }
    return @"
payload=`$(mktemp)
trap 'rm -f "`$payload"' EXIT
if ! LC_ALL=C sed '1s/^\xEF\xBB\xBF//' | tr -d '\r\n' | base64 -d > "`$payload"; then
  printf 'dev-proxy: WSL payload decode failed\n' >&2
  exit 65
fi
actual_bytes=`$(wc -c < "`$payload" | tr -d '[:space:]')
actual_sha=`$(sha256sum "`$payload" 2>/dev/null | awk '{print `$1}')
if [ "`$actual_bytes" != '$ExpectedBytes' ] || [ "`$actual_sha" != '$ExpectedSha256' ]; then
  printf 'dev-proxy: WSL payload integrity check failed\n' >&2
  exit 65
fi
timeout $TimeoutSec bash "`$payload"
command_rc=`$?
if [ "`$command_rc" -eq 0 ]; then
  printf '%s\n' '$CompletionMarker'
fi
exit "`$command_rc"
"@
}

function New-WslRunnerBootstrap([string]$Runner) {
    # Keep the verified runner itself out of native Windows argument quoting.
    # Bash reads it from a process-substitution descriptor, leaving standard
    # input exclusively for the command payload.
    $runnerBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Runner))
    return "bash <(printf %s $runnerBase64 | base64 -d)"
}

function ConvertTo-WslCommandResult($Raw, [int]$ExitCode, [string]$CompletionMarker) {
    $lines = @()
    $completionCount = 0
    foreach ($item in @($Raw)) {
        $line = if ($item -is [System.Management.Automation.ErrorRecord]) { $item.Exception.Message } else { "$item" }
        if ($line -eq $CompletionMarker) {
            $completionCount++
        } else {
            $lines += $line
        }
    }
    $completed = ($completionCount -eq 1)
    return [pscustomobject]@{
        ExitCode = $ExitCode
        TimedOut = ($ExitCode -eq 124)
        Completed = $completed
        Failed = ($ExitCode -ne 0 -or !$completed)
        Lines = @($lines)
    }
}

function Invoke-WslBash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro,
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [int]$TimeoutSec = 45
    )

    $oldPreference = $ErrorActionPreference
    $oldOutputEncoding = $OutputEncoding
    try {
        $ErrorActionPreference = "Continue"
        # Keep the transport body in the ASCII subset. Some Windows PowerShell
        # 5.1 -> wsl.exe paths still prefix native-pipeline input with a UTF-8
        # BOM; the WSL runner removes that optional prefix before decoding.
        $OutputEncoding = New-Object Text.ASCIIEncoding
        # Pass WSL scripts as base64 on standard input to avoid PowerShell/native
        # quoting issues and any dependency on Windows-drive mount paths. The
        # WSL-side runner verifies exact bytes before execution and emits a
        # per-call completion marker only after a successful command.
        $normalizedCommand = $Command -replace "`r`n", "`n"
        $normalizedCommand = $normalizedCommand -replace "`r", "`n"
        $commandBytes = [Text.Encoding]::UTF8.GetBytes($normalizedCommand)
        $encodedCommand = [Convert]::ToBase64String($commandBytes)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $expectedSha = (([BitConverter]::ToString($sha.ComputeHash($commandBytes))) -replace "-", "").ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
        $completionMarker = "DEV_PROXY_WSL_COMPLETE_$([guid]::NewGuid().ToString('N'))"
        $runner = New-WslPayloadRunner -TimeoutSec $TimeoutSec -ExpectedBytes $commandBytes.Length -ExpectedSha256 $expectedSha -CompletionMarker $completionMarker
        $bootstrap = New-WslRunnerBootstrap $runner
        $raw = $encodedCommand | & wsl.exe -d $Distro -- bash -c $bootstrap 2>&1
        $exitCode = $LASTEXITCODE
        return ConvertTo-WslCommandResult -Raw $raw -ExitCode $exitCode -CompletionMarker $completionMarker
    } catch {
        return [pscustomobject]@{
            ExitCode = -1
            TimedOut = $false
            Completed = $false
            Failed = $true
            Lines = @($_.Exception.Message)
        }
    } finally {
        $ErrorActionPreference = $oldPreference
        $OutputEncoding = $oldOutputEncoding
    }
}

function Get-WslDistros {
    try {
        $raw = & wsl.exe --list --quiet 2>$null
        $distros = @()
        foreach ($line in $raw) {
            $clean = ($line -replace "`0", "").Trim()
            if ($clean -and $clean -notmatch "^docker-desktop") { $distros += $clean }
        }
        return $distros
    } catch {
        return @()
    }
}

function Select-WslDistro($Config) {
    $distros = @(Get-WslDistros)
    if ($distros.Count -eq 0) {
        Write-Warn "No WSL distributions were detected."
        return $null
    }
    Write-Line
    Write-Info "Detected WSL distributions:"
    for ($i = 0; $i -lt $distros.Count; $i++) {
        $marker = if ($distros[$i] -eq $Config.distro) { "*" } else { " " }
        Write-Line ("  {0}. [{1}] {2}" -f ($i + 1), $marker, $distros[$i])
    }
    $defaultIndex = 1
    if ($Config.distro) {
        $existing = [array]::IndexOf($distros, $Config.distro)
        if ($existing -ge 0) { $defaultIndex = $existing + 1 }
    }
    $answer = Read-Host "Select distro number [$defaultIndex]"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "$defaultIndex" }
    if (($answer -as [int]) -and [int]$answer -ge 1 -and [int]$answer -le $distros.Count) {
        $Config.distro = $distros[[int]$answer - 1]
        Save-Config $Config
        Write-Ok "Selected WSL distro: $($Config.distro)"
        Write-Tip "This only saves the selected distro for this helper. It does not modify WSL yet."
        return $Config.distro
    }
    Write-Warn "Invalid selection."
    return $null
}

function Get-IniSectionBounds([string[]]$Lines, [string]$Section) {
    $sectionHeader = "[$Section]"
    $start = -1
    $end = $Lines.Count
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim().Equals($sectionHeader, [StringComparison]::OrdinalIgnoreCase)) {
            $start = $i
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j].Trim() -match "^\[.+\]$") { $end = $j; break }
            }
            break
        }
    }
    return [pscustomobject]@{ Start = $start; End = $end }
}

function Set-ManagedIniValue([string[]]$Lines, [string]$Section, [string]$Key, [string]$Value) {
    $markerPrefix = "# dev-proxy managed: [$Section] $Key previous="
    $keyPattern = "^\s*$([regex]::Escape($Key))\s*="

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].StartsWith($markerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $result = @($Lines)
            if ($i + 1 -lt $result.Count -and $result[$i + 1] -match $keyPattern) {
                $result[$i + 1] = "$Key=$Value"
            } else {
                $before = @($result[0..$i])
                $after = if ($i + 1 -lt $result.Count) { @($result[($i + 1)..($result.Count - 1)]) } else { @() }
                $result = @($before + "$Key=$Value" + $after)
            }
            return $result
        }
    }

    $working = @($Lines)
    $bounds = Get-IniSectionBounds $working $Section
    if ($bounds.Start -lt 0) {
        if ($working.Count -gt 0 -and $working[-1].Trim() -ne "") { $working += "" }
        $working += "# dev-proxy managed: created section [$Section]"
        $working += "[$Section]"
        $bounds = Get-IniSectionBounds $working $Section
    }

    for ($i = $bounds.Start + 1; $i -lt $bounds.End; $i++) {
        if ($working[$i] -match $keyPattern) {
            if ($working[$i].Trim() -ieq "$Key=$Value") { return $working }
            $previous = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($working[$i]))
            $before = @($working[0..($i - 1)])
            $after = if ($i + 1 -lt $working.Count) { @($working[($i + 1)..($working.Count - 1)]) } else { @() }
            return @($before + "${markerPrefix}${previous}" + "$Key=$Value" + $after)
        }
    }

    $insert = $bounds.End
    $before = if ($insert -gt 0) { @($working[0..($insert - 1)]) } else { @() }
    $after = if ($insert -lt $working.Count) { @($working[$insert..($working.Count - 1)]) } else { @() }
    return @($before + "${markerPrefix}<absent>" + "$Key=$Value" + $after)
}

function Restore-ManagedWslConfig {
    $path = Join-Path $env:USERPROFILE ".wslconfig"
    if (!(Test-Path $path)) {
        Write-Ok "$path has no dev-proxy managed settings to restore"
        return
    }

    # Windows PowerShell 5.1 treats BOM-less UTF-8 as the legacy ANSI code page
    # in Get-Content. Read explicitly as UTF-8 so comments are preserved.
    $existing = @([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))
    $restored = New-Object System.Collections.Generic.List[string]
    $changed = $false
    $expected = @{
        "wsl2.networkingMode" = "networkingMode=mirrored"
        "wsl2.dnsTunneling" = "dnsTunneling=true"
        "wsl2.autoProxy" = "autoProxy=false"
        "experimental.hostAddressLoopback" = "hostAddressLoopback=true"
    }

    for ($i = 0; $i -lt $existing.Count; $i++) {
        $line = $existing[$i]
        if ($line -match '^# dev-proxy managed: \[([^\]]+)\] ([^ ]+) previous=(.+)$') {
            $section = $Matches[1]
            $key = $Matches[2]
            $previous = $Matches[3]
            $managedKey = "$section.$key"
            $next = if ($i + 1 -lt $existing.Count) { $existing[$i + 1] } else { "" }
            $expectedLine = if ($expected.ContainsKey($managedKey)) { $expected[$managedKey] } else { $null }
            if ($managedKey -ieq "experimental.ignoredPorts") {
                $priorPorts = @()
                if ($previous -ne "<absent>") {
                    try {
                        $priorLine = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($previous))
                        if ($priorLine -match '^[^=]+=(.*)$') {
                            $priorPorts = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                        }
                    } catch {
                        $priorPorts = @()
                    }
                }
                $currentPorts = @()
                if ($next -match '^\s*ignoredPorts\s*=\s*(.*)$') {
                    $currentPorts = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
                # Accept either the current generation's merged list or the
                # legacy port-only list. This lets a 20181 rollout restore a
                # managed 20180 baseline without treating it as user editing.
                $mergedPorts = @($priorPorts + "$WslInteropPort" | Select-Object -Unique)
                $samePorts = (($currentPorts -join ',') -eq ($mergedPorts -join ','))
                $legacyPorts = (($currentPorts -join ',') -eq ($priorPorts -join ','))
                # Older installs wrote ignoredPorts=20180 with previous=<absent>
                # and did not encode the generated port in the marker.  Remove
                # that exact legacy-only value during a later 20181 rollout,
                # while preserving lists that contain any other user port.
                $legacyDefaultOnly = ($previous -eq "<absent>" -and $currentPorts.Count -eq 1 -and $currentPorts[0] -eq "$DefaultWslInteropPort")
                $legacyMergedDefault = ($currentPorts -contains "$DefaultWslInteropPort" -and
                    (@($currentPorts | Where-Object { $_ -ne "$DefaultWslInteropPort" }) -join ',') -eq ($priorPorts -join ','))
                if ($samePorts -or $legacyPorts -or $legacyDefaultOnly -or $legacyMergedDefault) { $expectedLine = $next.Trim() }
                else { $expectedLine = $null }
            }
            if ($null -ne $expectedLine -and ($managedKey -ieq "experimental.ignoredPorts" -or $next.Trim() -ieq $expectedLine)) {
                if ($previous -ne "<absent>") {
                    try {
                        $restored.Add([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($previous)))
                    } catch {
                        $restored.Add($line)
                        $restored.Add($next)
                        Write-Warn "Could not decode the saved .wslconfig value for [$section] $key; left it unchanged."
                    }
                }
                $i++
                $changed = $true
                continue
            }
            Write-Warn "Managed .wslconfig value [$section] $key was edited after setup; left it unchanged."
        }
        $restored.Add($line)
    }

    $lines = @($restored.ToArray())
    $final = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^# dev-proxy managed: created section \[([^\]]+)\]$' -and $i + 1 -lt $lines.Count) {
            $headerIndex = $i + 1
            $end = $lines.Count
            for ($j = $headerIndex + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j].Trim() -match '^\[.+\]$') { $end = $j; break }
            }
            # A created section may have acquired user comments/settings after
            # installation. Remove it only when it is genuinely empty after
            # managed key restoration; comments are not disposable metadata.
            $remaining = if ($end -gt $headerIndex + 1) {
                @($lines[($headerIndex + 1)..($end - 1)] | Where-Object { $_.Trim() -ne "" })
            } else { @() }
            if ($remaining.Count -eq 0) {
                $i = $end - 1
                $changed = $true
                continue
            }
            $final.Add($lines[$i])
            continue
        }
        $final.Add($lines[$i])
    }

    if (!$changed -or (($existing -join "`n") -eq (@($final.ToArray()) -join "`n"))) {
        Write-Ok "$path has no dev-proxy managed settings to restore"
        return
    }
    if ($DryRun) {
        Write-Info "Dry-run: would restore dev-proxy managed settings in $path"
        return
    }
    $backup = "$path.bak.$(Get-Date -Format yyyyMMddHHmmssfff)"
    Copy-Item $path $backup -Force
    Write-Info "Backed up existing .wslconfig to $backup"
    [IO.File]::WriteAllLines($path, @($final.ToArray()), (New-Object Text.UTF8Encoding($false)))
    Write-Ok "Restored dev-proxy managed settings in $path"
    Write-Warn "Run 'wsl --shutdown' after saving work in WSL for the rollback to take effect."
}

function Configure-WslMirrored {
    $path = Join-Path $env:USERPROFILE ".wslconfig"
    $existing = @()
    if (Test-Path $path) {
        $existing = @([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))
    }
    $lines = $existing
    $lines = Set-ManagedIniValue $lines "wsl2" "networkingMode" "mirrored"
    $lines = Set-ManagedIniValue $lines "wsl2" "dnsTunneling" "true"
    # The shell profile is the single owner of proxy variables. Leaving WSL
    # autoProxy enabled would race and then duplicate that source.
    $lines = Set-ManagedIniValue $lines "wsl2" "autoProxy" "false"
    # The IPv6-only Linux bridge binds ::1 directly; current WSL mirrored mode
    # does not need hostAddressLoopback or ignoredPorts.  Restore-ManagedWslConfig
    # still understands those legacy markers so upgrades remain reversible.

    if (($existing -join "`n") -eq (@($lines) -join "`n")) {
        # Repeat runs otherwise leave a new .bak file behind every time.
        Write-Ok "$path already has mirrored networking settings managed by dev-proxy"
        return
    }

    if ($DryRun) {
        Write-Info "Dry-run: would update $path with mirrored networking"
        return
    }
    Write-Info "Updating WSL networking settings. Existing .wslconfig will be backed up first."
    if (Test-Path $path) {
        $backup = "$path.bak.$(Get-Date -Format yyyyMMddHHmmssfff)"
        Copy-Item $path $backup -Force
        Write-Info "Backed up existing .wslconfig to $backup"
    }
    [IO.File]::WriteAllLines($path, @($lines), (New-Object Text.UTF8Encoding($false)))
    Write-Ok "Updated $path for WSL mirrored networking"
    Write-Warn "Run 'wsl --shutdown' after saving work in WSL, then reopen WSL."
}

function Restore-WslMirroredValues($Lines) {
    # Switching the saved preference off should undo only the mirrored values
    # this tool previously wrote.  autoProxy remains managed by the generated
    # shell profile, and unmarked/user-edited values remain untouched.
    $expected = @{
        "wsl2.networkingMode" = "networkingMode=mirrored"
        "wsl2.dnsTunneling" = "dnsTunneling=true"
    }
    $restored = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^# dev-proxy managed: \[([^\]]+)\] ([^ ]+) previous=(.+)$') {
            $managedKey = "$($Matches[1]).$($Matches[2])"
            $previous = $Matches[3]
            if ($expected.ContainsKey($managedKey)) {
                $next = if ($i + 1 -lt $Lines.Count) { $Lines[$i + 1] } else { "" }
                if ($next.Trim() -ieq $expected[$managedKey]) {
                    if ($previous -ne "<absent>") {
                        try {
                            $restored.Add([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($previous)))
                        } catch {
                            $restored.Add($line)
                            $restored.Add($next)
                            Write-Warn "Could not decode the saved .wslconfig value for $managedKey; left it unchanged."
                        }
                    }
                    $i++
                    continue
                }
                Write-Warn "Managed .wslconfig value $managedKey was edited after setup; left it unchanged."
            }
        }
        $restored.Add($line)
    }
    return @($restored.ToArray())
}

function Configure-WslProxyOwnership {
    $path = Join-Path $env:USERPROFILE ".wslconfig"
    $existing = @()
    if (Test-Path $path) {
        $existing = @([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))
    }
    # The generated shell profile is the single owner of proxy variables in
    # both mirrored and NAT modes. Restore only mirrored settings this tool
    # previously selected, then retain autoProxy ownership for the profile.
    $lines = @(Restore-WslMirroredValues $existing)
    $lines = Set-ManagedIniValue $lines "wsl2" "autoProxy" "false"
    if (($existing -join "`n") -eq (@($lines) -join "`n")) {
        Write-Ok "$path already disables WSL autoProxy for the dev-proxy shell profile"
        return
    }
    if ($DryRun) {
        Write-Info "Dry-run: would restore managed mirrored settings and update $path with autoProxy=false"
        return
    }
    Write-Info "Restoring tool-managed mirrored settings and disabling WSL autoProxy so the generated shell profile remains the only proxy-variable owner."
    if (Test-Path $path) {
        $backup = "$path.bak.$(Get-Date -Format yyyyMMddHHmmssfff)"
        Copy-Item $path $backup -Force
        Write-Info "Backed up existing .wslconfig to $backup"
    }
    [IO.File]::WriteAllLines($path, @($lines), (New-Object Text.UTF8Encoding($false)))
    Write-Ok "Updated $path with autoProxy=false"
    Write-Warn "Run 'wsl --shutdown' after saving work in WSL, then reopen WSL."
}

function Get-WslMirrorableWindowsHosts {
    $hosts = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
            $properties = $adapter.GetIPProperties()
            $hasIpv4Gateway = @($properties.GatewayAddresses | Where-Object {
                $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                $_.Address.ToString() -ne "0.0.0.0"
            }).Count -gt 0
            if (!$hasIpv4Gateway) { continue }
            foreach ($unicast in @($properties.UnicastAddresses)) {
                if ($unicast.Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $text = $unicast.Address.ToString()
                if ($text -ne "127.0.0.1" -and -not $hosts.Contains($text)) { $hosts.Add($text) }
            }
        }
    } catch {
        Write-Warn "Could not inspect mirrorable Windows host addresses for WSL: $($_.Exception.Message)"
    }
    return @($hosts.ToArray())
}

function Get-WslMirroredProxyHosts($Config) {
    $hosts = New-Object System.Collections.Generic.List[string]
    $mirrorable = @(Get-WslMirrorableWindowsHosts)
    # Try the configured target first. For the normal loopback target this
    # keeps native mirrored localhost ahead of the interop fallback.
    if ($Config.proxyHost -and -not $hosts.Contains([string]$Config.proxyHost)) {
        $hosts.Add([string]$Config.proxyHost)
    }
    try {
        $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        foreach ($endpoint in @($listeners | Where-Object { $_.Port -eq $Config.proxyPort })) {
            $text = $endpoint.Address.ToString()
            if ($text -in $mirrorable -and -not $hosts.Contains($text)) { $hosts.Add($text) }
        }
    } catch {
        Write-Warn "Could not inspect Windows listener addresses for WSL: $($_.Exception.Message)"
    }
    if (-not $hosts.Contains("127.0.0.1")) { $hosts.Add("127.0.0.1") }
    if ($hosts.Count -eq 1 -and $mirrorable.Count -gt 0) {
        Write-Info "No proxy listener is bound to a mirrorable Windows host address on port $($Config.proxyPort). Available address(es): $($mirrorable -join ', ')"
    }
    return @($hosts.ToArray())
}

function Install-WslProxyEnv($Config) {
    if (!$Config.distro) {
        Write-Warn "No WSL distro selected."
        return
    }
    if (!(Test-Path $TemplatePath) -or !(Test-Path $InteropTemplatePath)) {
        throw "Missing WSL template: $TemplatePath or $InteropTemplatePath"
    }
    $content = Get-Content $TemplatePath -Raw
    $content = $content.Replace("__PROXY_SCHEME__", [string]$Config.proxyScheme)
    $content = $content.Replace("__PROXY_HOST__", (ConvertTo-BashSingleQuotedContent ([string]$Config.proxyHost)))
    $content = $content.Replace("__PROXY_PORT__", [string]$Config.proxyPort)
    $content = $content.Replace("__INTEROP_PORT__", [string]$WslInteropPort)
    $content = $content.Replace("__INTEROP_FALLBACK__", ([string][bool]$Config.enableWslInteropFallback).ToLowerInvariant())
    $content = $content.Replace("__NO_PROXY__", (ConvertTo-BashSingleQuotedContent ([string]$Config.noProxy)))
    $mirroredHosts = @(Get-WslMirroredProxyHosts $Config)
    $content = $content.Replace("__MIRRORED_PROXY_HOSTS__", (ConvertTo-BashSingleQuotedContent ($mirroredHosts -join ",")))
    $interopToken = Get-InteropIdentityToken $Config
    $content = $content.Replace("__INSTANCE_TOKEN__", $interopToken)

    # PowerShell recognizes several Unicode single-quote characters as string
    # delimiters. Use its code generator rather than escaping ASCII apostrophes
    # only, otherwise a hand-edited host value could alter the relay script.
    $relayHost = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$Config.proxyHost)
    $windowsRelay = @"
`$ErrorActionPreference = 'Stop'
`$client = New-Object Net.Sockets.TcpClient
try {
    `$connect = `$client.BeginConnect('$relayHost', $($Config.proxyPort), `$null, `$null)
    if (-not `$connect.AsyncWaitHandle.WaitOne(5000, `$false)) {
        throw 'proxy connection timed out after 5 seconds'
    }
    `$client.EndConnect(`$connect)
    `$network = `$client.GetStream()
    `$stdin = [Console]::OpenStandardInput()
    `$stdout = [Console]::OpenStandardOutput()
    `$upload = `$stdin.CopyToAsync(`$network)
    `$download = `$network.CopyToAsync(`$stdout)
    # A client half-close is a normal HTTP request boundary.  Propagate only
    # the send-side shutdown and continue draining the response until the
    # Windows proxy closes its output; WaitAny would close the download here.
    while (-not `$download.IsCompleted) {
        if (`$upload.IsCompleted) {
            try { `$client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send) } catch { }
            break
        }
        [Threading.Thread]::Sleep(25)
    }
    `$null = `$download.GetAwaiter().GetResult()
} finally {
    `$client.Close()
}
"@
    # Windows PowerShell -EncodedCommand expects UTF-16LE, not UTF-8.
    $windowsRelayEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($windowsRelay))
    $interopContent = Get-Content $InteropTemplatePath -Raw
    $interopContent = $interopContent.Replace("__INTEROP_PORT__", [string]$WslInteropPort)
    $interopContent = $interopContent.Replace("__WINDOWS_RELAY_ENCODED__", $windowsRelayEncoded)
    $interopContent = $interopContent.Replace("__INSTANCE_TOKEN__", $interopToken)

    if ($DryRun) {
        Write-Info "Dry-run: would install WSL proxy env into distro '$($Config.distro)'"
        return
    }
    Write-Info "Installing WSL proxy environment into '$($Config.distro)'. This writes ~/.config/dev-proxy/proxy-env.sh and sources it from ~/.profile."
    Write-Info "Mirrored-mode proxy candidates: $($mirroredHosts -join ', ')"

    $content = $content -replace "`r`n", "`n"
    $content = $content -replace "`r", "`n"
    $contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    $interopContent = ($interopContent -replace "`r`n", "`n") -replace "`r", "`n"
    $interopBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($interopContent))

    $installCmd = @'
set -e
umask 077
mkdir -p "$HOME/.config/dev-proxy"
if ! command -v flock >/dev/null 2>&1; then
  printf 'install-error: flock is required for safe relay/profile installation\n' >&2
  exit 1
fi
exec 9>"$HOME/.config/dev-proxy/interop-__INTEROP_PORT__.lock"
flock -x 9
# Preflight the optional IPv6 relay before replacing generated files. Missing
# prerequisites or an occupied relay port disable only the fallback for this
# installed profile. The profile never sends traffic to an unverified process.
interop_available=false
if [ "__INTEROP_FALLBACK__" = "true" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'install-warning: WSL interop fallback is unavailable because python3 is not installed; installing direct/NAT paths only\n' >&2
  elif ! command -v powershell.exe >/dev/null 2>&1 \
    && ! command -v pwsh.exe >/dev/null 2>&1 \
    && [ ! -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
    printf 'install-warning: WSL interop fallback is unavailable because Windows PowerShell interop is not accessible; installing direct/NAT paths only\n' >&2
  else
    set +e
    python3 - "__INTEROP_PORT__" "$HOME/.config/dev-proxy/interop-__INTEROP_PORT__-__INSTANCE_TOKEN__" "__INSTANCE_TOKEN__" <<'PY'
import errno, os, socket, sys
port = int(sys.argv[1])
state = sys.argv[2]
token = sys.argv[3]
try:
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as probe:
        probe.bind(("::1", port))
except OSError as bind_error:
    if bind_error.errno != errno.EADDRINUSE:
        print("install-warning: WSL interop fallback cannot bind IPv6 loopback (%s); installing direct/NAT paths only" % bind_error, file=sys.stderr)
        raise SystemExit(2)
    try:
        pid = open(os.path.join(state, "pid"), encoding="ascii").read().strip()
        start = open(os.path.join(state, "starttime"), encoding="ascii").read().strip()
        actual_start = open("/proc/%s/stat" % pid, encoding="ascii").read().split()[21]
        argv = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")
        if not pid.isdigit() or actual_start != start or len(argv) < 3:
            raise RuntimeError("identity mismatch")
        if argv[1].decode() != os.path.join(os.path.dirname(state), "interop-proxy.py") or argv[2].decode() != token:
            raise RuntimeError("identity mismatch")
    except Exception as exc:
        print("install-warning: WSL interop fallback is unavailable because relay port %s is occupied by an unknown or prior generation (%s); installing direct/NAT paths only" % (port, exc), file=sys.stderr)
        raise SystemExit(2)
PY
    relay_preflight_rc=$?
    set -e
    case "$relay_preflight_rc" in
      0) interop_available=true ;;
      2) interop_available=false ;;
      *) exit 1 ;;
    esac
  fi
fi
tmp_env="$(mktemp "$HOME/.config/dev-proxy/proxy-env.sh.tmp.XXXXXX")"
tmp_interop="$(mktemp "$HOME/.config/dev-proxy/interop-proxy.py.tmp.XXXXXX")"
trap 'rm -f "$tmp_env" "$tmp_interop"' EXIT
printf '%s' '__CONTENT_BASE64__' | base64 -d > "$tmp_env"
printf '%s' '__INTEROP_BASE64__' | base64 -d > "$tmp_interop"
sed -i "s/__INTEROP_AVAILABLE__/$interop_available/g" "$tmp_env"
chmod 600 "$tmp_env" "$tmp_interop"
mv -f "$tmp_env" "$HOME/.config/dev-proxy/proxy-env.sh"
mv -f "$tmp_interop" "$HOME/.config/dev-proxy/interop-proxy.py"
trap - EXIT
touch "$HOME/.profile"
SOURCE_LINE='. "$HOME/.config/dev-proxy/proxy-env.sh"'
LEGACY_SOURCE_LINE='source "$HOME/.config/dev-proxy/proxy-env.sh"'
DISABLED_LINE="# disabled by dev-proxy: $SOURCE_LINE"
LEGACY_DISABLED_LINE="# disabled by dev-proxy: $LEGACY_SOURCE_LINE"

# Re-enable only the exact line this tool disabled, collapse duplicate copies,
# and make one backup immediately before an actual profile replacement.
tmp_profile="$(mktemp "$HOME/.profile.dev-proxy.tmp.XXXXXX")"
found=0
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$line" = "$DISABLED_LINE" ] || [ "$line" = "$LEGACY_DISABLED_LINE" ]; then
    if [ "$found" -eq 0 ]; then printf '%s\n' "$SOURCE_LINE"; found=1; fi
  elif [ "$line" = "$SOURCE_LINE" ] || [ "$line" = "$LEGACY_SOURCE_LINE" ]; then
    if [ "$found" -eq 0 ]; then printf '%s\n' "$SOURCE_LINE"; found=1; fi
  else
    printf '%s\n' "$line"
  fi
done < "$HOME/.profile" > "$tmp_profile"
if [ "$found" -eq 0 ]; then
  printf '\n# Dev proxy environment\n%s\n' "$SOURCE_LINE" >> "$tmp_profile"
fi
if ! cmp -s "$tmp_profile" "$HOME/.profile"; then
  profile_backup="$(mktemp "$HOME/.profile.dev-proxy.bak.XXXXXX")"
  cp "$HOME/.profile" "$profile_backup"
  if [ -L "$HOME/.profile" ]; then
    cat "$tmp_profile" > "$HOME/.profile"
    rm -f "$tmp_profile"
  else
    mv -f "$tmp_profile" "$HOME/.profile"
  fi
else
  rm -f "$tmp_profile"
fi
printf 'installed:%s\n' "$HOME/.config/dev-proxy/proxy-env.sh"
_dev_proxy_login_profile_loads_profile() {
  grep -Ev '^[[:space:]]*#' "$1" \
    | awk -v profile="$HOME/.profile" '{
        while ((position = index($0, profile)) > 0) {
          $0 = substr($0, 1, position - 1) "$HOME/.profile" substr($0, position + length(profile))
        }
        print
      }' \
    | sed -e 's/"//g' -e "s/'//g" -e 's/${HOME}/$HOME/g' \
    | grep -Eq '(^|[;[:space:]])(\.|source)[[:space:]]+(\$HOME|~)/\.profile([;[:space:]]|$)'
}
for login_profile in "$HOME/.bash_profile" "$HOME/.bash_login"; do
  [ -f "$login_profile" ] || continue
  if ! _dev_proxy_login_profile_loads_profile "$login_profile"; then
    printf 'install-warning: %s exists and does not directly load ~/.profile; Bash login shells may skip the dev-proxy hook\n' "$login_profile" >&2
  fi
  break
done
'@
    $installCmd = $installCmd.Replace("__CONTENT_BASE64__", $contentBase64)
    $installCmd = $installCmd.Replace("__INTEROP_BASE64__", $interopBase64)
    $installCmd = $installCmd.Replace("__INTEROP_PORT__", [string]$WslInteropPort)
    $installCmd = $installCmd.Replace("__INSTANCE_TOKEN__", $interopToken)
    $installCmd = $installCmd.Replace("__INTEROP_FALLBACK__", ([string][bool]$Config.enableWslInteropFallback).ToLowerInvariant())
    $result = Invoke-WslBash -Distro $Config.distro -Command $installCmd
    $parsed = Split-WslOutput $result.Lines
    Write-WslOutputLines $parsed
    if ($result.Failed -or -not ($parsed.Lines -match "^installed:")) {
        Write-Fail "Could not install the WSL proxy environment for $($Config.distro): $(Get-WslFailureReason $result)"
        return
    }
    Write-Ok "Installed WSL proxy environment for $($Config.distro)"
    Write-Tip "Open a new WSL shell, or run: . ~/.profile"
}

function Disable-WslProxyEnv($Config) {
    if (!$Config.distro) {
        Write-Warn "No WSL distro selected; skipping WSL rollback."
        return
    }
    if ($DryRun) {
        Write-Info "Dry-run: would disable WSL profile source line in '$($Config.distro)'"
        return
    }
    $cmd = @'
set -e
SOURCE_LINE='. "$HOME/.config/dev-proxy/proxy-env.sh"'
LEGACY_SOURCE_LINE='source "$HOME/.config/dev-proxy/proxy-env.sh"'
# Enumerate every private generation state.  Rollback must stop an installed
# older target even when config.json has since changed; the legacy fixed PID
# file is intentionally ignored because it has no generation identity.
BASE="$HOME/.config/dev-proxy"
for state_dir in "$BASE"/interop-*-*; do
  [ -d "$state_dir" ] || continue
  state_name="${state_dir##*/}"
  case "$state_name" in
    interop-[0-9]*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) continue ;;
  esac
  port="${state_name#interop-}"; port="${port%%-*}"
  printf '%s' "$port" | grep -qE '^[0-9]+$' || continue
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || continue
  token="${state_name#interop-${port}-}"
  printf '%s' "$token" | grep -qE '^[0-9a-f]{64}$' || continue
  exec 9>"$BASE/interop-${port}.lock"
  flock -x 9
  pid_file="$state_dir/pid"
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  expected_start="$(cat "$state_dir/starttime" 2>/dev/null || true)"
  actual_start="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
  argv1="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '2p' || true)"
  argv2="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '3p' || true)"
  if printf '%s' "$pid" | grep -qE '^[0-9]+$' && [ -n "$expected_start" ] \
    && [ "$actual_start" = "$expected_start" ] && kill -0 "$pid" 2>/dev/null \
    && [ "$argv1" = "$BASE/interop-proxy.py" ] && [ "$argv2" = "$token" ]; then
    kill "$pid"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      printf 'relay-stop-failed:%s\n' "$pid"
    else
      rm -f "$pid_file" "$state_dir/starttime"
    fi
  elif [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
  else
    printf 'foreign-relay-preserved\n'
  fi
  flock -u 9 2>/dev/null || true
  exec 9>&-
done
if [ -f "$BASE/interop-proxy.pid" ]; then
  printf 'legacy-relay-preserved\n'
fi
if [ ! -f "$HOME/.profile" ] \
  || { ! grep -qxF "$SOURCE_LINE" "$HOME/.profile" && ! grep -qxF "$LEGACY_SOURCE_LINE" "$HOME/.profile"; }; then
  # Nothing active to disable, so do not leave another backup behind.
  printf 'disable-complete:already-disabled\n'
  exit 0
fi
profile_backup="$(mktemp "$HOME/.profile.dev-proxy.bak.XXXXXX")"
cp "$HOME/.profile" "$profile_backup"
tmp="$(mktemp)"
awk '{ if ($0 == ". \"$HOME/.config/dev-proxy/proxy-env.sh\"" || $0 == "source \"$HOME/.config/dev-proxy/proxy-env.sh\"") print "# disabled by dev-proxy: " $0; else print $0 }' "$HOME/.profile" > "$tmp"
if [ -L "$HOME/.profile" ]; then
  cat "$tmp" > "$HOME/.profile"
  rm -f "$tmp"
else
  mv "$tmp" "$HOME/.profile"
fi
printf 'disable-complete:disabled\n'
'@
    $result = Invoke-WslBash -Distro $Config.distro -Command $cmd
    $parsed = Split-WslOutput $result.Lines
    if ($result.Failed) {
        Write-WslOutputLines $parsed
        Write-Fail "Could not disable the WSL proxy source line for $($Config.distro): $(Get-WslFailureReason $result)"
        return
    }
    $stopFailure = @($parsed.Lines | Where-Object { $_ -match '^relay-stop-failed:' })
    if ($stopFailure.Count -gt 0) {
        Write-WslOutputLines $parsed
        Write-Fail "Could not stop one or more managed WSL relay processes; state was retained for retry."
        return
    }
    $completion = @($parsed.Lines | Where-Object { $_ -match '^disable-complete:(already-disabled|disabled)$' })
    if ($completion.Count -ne 1) {
        Write-WslOutputLines $parsed
        Write-Fail "Could not verify WSL rollback completion for $($Config.distro); no unique completion marker was returned."
        return
    }
    if ($parsed.Lines -contains "disable-complete:already-disabled") {
        Write-Ok "WSL proxy source line was already disabled for $($Config.distro)"
        return
    }
    Write-WslOutputLines $parsed
    Write-Ok "Disabled WSL proxy source line for $($Config.distro)"
}

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 700) {
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) { $client.EndConnect($iar) }
        return $ok
    } catch {
        return $false
    } finally {
        # EndConnect can throw on a refused port; without this the socket leaks.
        if ($null -ne $client) { $client.Close() }
    }
}

function Test-UrlViaProxy([string]$Url, [string]$ProxyUrl) {
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Url -Proxy $ProxyUrl -TimeoutSec 12
        return @{ ok = $true; status = [int]$resp.StatusCode; error = $null }
    } catch {
        $response = $_.Exception.Response
        if ($response -and $response.StatusCode) {
            $code = [int]$response.StatusCode
            if ($code -in @(200, 301, 302, 400, 401, 403, 404, 405)) {
                return @{ ok = $true; status = $code; error = $null }
            }
            return @{ ok = $false; status = $code; error = $_.Exception.Message }
        }
        return @{ ok = $false; status = $null; error = $_.Exception.Message }
    }
}

function Verify-All($Config) {
    $script:VerifyFailures = 0
    $proxyUrl = Get-ProxyUrl $Config
    Write-Line
    Write-Info "Verifying dev proxy configuration ($proxyUrl)"
    $activity = "Verifying dev proxy"
    Show-Progress $activity "Checking Windows system proxy" 10

    try {
        $reg = Get-ItemProperty $InternetSettingsPath
        $expectedProxyServer = (Get-ProxyUrl $Config) -replace "^[^:]+://", ""
        if ($reg.ProxyEnable -eq 1 -and "$($reg.ProxyServer)" -eq $expectedProxyServer) {
            Write-Ok "Windows user system proxy is enabled: $($reg.ProxyServer)"
        } else {
            Write-Fail "Windows user system proxy does not match target. Current: enabled=$($reg.ProxyEnable), server=$($reg.ProxyServer)"
        }
    } catch {
        Write-Fail "Could not read Windows proxy registry: $($_.Exception.Message)"
    }

    Show-Progress $activity "Checking Windows user proxy environment variables" 25
    $envMismatches = @()
    foreach ($entry in @(Get-ProxyEnvEntries $Config)) {
        $actual = [Environment]::GetEnvironmentVariable($entry.Name, "User")
        if ($actual -ne $entry.Value) {
            $envMismatches += "$($entry.Name)='$actual'"
        }
    }
    if ($envMismatches.Count -eq 0) {
        Write-Ok "Windows user proxy environment variables match target"
    } else {
        Write-Fail "Windows user proxy environment variables do not match target: $($envMismatches -join ', ')"
    }

    Show-Progress $activity "Checking proxy TCP listener" 40
    if (Test-TcpPort $Config.proxyHost $Config.proxyPort) {
        Write-Ok "Proxy listener is reachable at $($Config.proxyHost):$($Config.proxyPort)"
    } else {
        Write-Fail "No TCP listener detected at $($Config.proxyHost):$($Config.proxyPort)"
    }

    Show-Progress $activity "Checking WinHTTP status" 50
    Show-WinHttpProxy

    Show-Progress $activity "Testing Windows outbound connectivity through proxy" 65
    foreach ($url in @("https://api.openai.com/v1/models", "https://api.anthropic.com")) {
        $result = Test-UrlViaProxy $url $proxyUrl
        if ($result.ok) {
            Write-Ok "Windows proxy can reach $url (HTTP $($result.status))"
        } else {
            Write-Fail "Windows proxy failed for ${url}: $($result.error)"
        }
    }

    if ($Config.distro) {
        Show-Progress $activity "Testing WSL proxy environment and connectivity" 82
        Write-Info "Verifying WSL distro: $($Config.distro)"
        $cmd = @'
env_file="$HOME/.config/dev-proxy/proxy-env.sh"
if [ ! -f "$env_file" ]; then
  printf 'MISSING_WSL_ENV\n'
  exit 0
fi

SOURCE_LINE='. "$HOME/.config/dev-proxy/proxy-env.sh"'
LEGACY_SOURCE_LINE='source "$HOME/.config/dev-proxy/proxy-env.sh"'
if [ ! -f "$HOME/.profile" ] \
  || { ! grep -qxF "$SOURCE_LINE" "$HOME/.profile" && ! grep -qxF "$LEGACY_SOURCE_LINE" "$HOME/.profile"; }; then
  printf 'WSL_PROFILE_INACTIVE\n'
  printf 'CHECKS_DONE\n'
  exit 0
fi
_dev_proxy_login_profile_loads_profile() {
  grep -Ev '^[[:space:]]*#' "$1" \
    | awk -v profile="$HOME/.profile" '{
        while ((position = index($0, profile)) > 0) {
          $0 = substr($0, 1, position - 1) "$HOME/.profile" substr($0, position + length(profile))
        }
        print
      }' \
    | sed -e 's/"//g' -e "s/'//g" -e 's/${HOME}/$HOME/g' \
    | grep -Eq '(^|[;[:space:]])(\.|source)[[:space:]]+(\$HOME|~)/\.profile([;[:space:]]|$)'
}
for login_profile in "$HOME/.bash_profile" "$HOME/.bash_login"; do
  [ -f "$login_profile" ] || continue
  if ! _dev_proxy_login_profile_loads_profile "$login_profile"; then
    printf 'WSL_PROFILE_BYPASSED path=%s\n' "$login_profile"
    printf 'CHECKS_DONE\n'
    exit 0
  fi
  break
done

# proxy_on returns non-zero when no host resolves. Keep going either way so
# proxy_status can report what actually happened.
. "$env_file" || true
proxy_status || true

# The TCP listener alone is insufficient: an old generation on the same
# machine must not satisfy verification for a new target/relay config.
if [ "${DEV_PROXY_TARGET_HOST:-}" = '__EXPECTED_PROXY_HOST__' ] \
  && [ "${DEV_PROXY_TARGET_PORT:-}" = '__EXPECTED_PROXY_PORT__' ] \
  && [ "${DEV_PROXY_TARGET_SCHEME:-}" = '__EXPECTED_PROXY_SCHEME__' ] \
  && [ "${DEV_PROXY_INTEROP_PORT:-}" = '__EXPECTED_INTEROP_PORT__' ] \
  && [ "${DEV_PROXY_INTEROP_FALLBACK:-}" = '__EXPECTED_INTEROP_FALLBACK__' ] \
  && [ "${DEV_PROXY_INTEROP_TOKEN:-}" = '__EXPECTED_INTEROP_TOKEN__' ]; then
  printf 'TARGET_MATCH\n'
  target_ok=1
else
  printf 'TARGET_MISMATCH host=%s port=%s scheme=%s interop=%s fallback=%s\n' \
    "${DEV_PROXY_TARGET_HOST:-<unset>}" "${DEV_PROXY_TARGET_PORT:-<unset>}" \
    "${DEV_PROXY_TARGET_SCHEME:-<unset>}" "${DEV_PROXY_INTEROP_PORT:-<unset>}" \
    "${DEV_PROXY_INTEROP_FALLBACK:-<unset>}"
  target_ok=0
fi

proxy_path_host="${DEV_PROXY_HOST:-}"
case "$proxy_path_host" in *:*) proxy_path_host="[$proxy_path_host]" ;; esac
expected_http="${DEV_PROXY_SCHEME:-}://${proxy_path_host}:${DEV_PROXY_PORT:-}"
if [ -n "${HTTP_PROXY:-}" ] && [ "$HTTP_PROXY" = "$expected_http" ]; then
  printf 'PROXY_PATH_MATCH\n'
else
  printf 'PROXY_PATH_MISMATCH expected=%s actual=%s\n' "$expected_http" "${HTTP_PROXY:-<unset>}"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check_tcp() {
  tcp_err="$tmp/tcp.err"
  if command -v nc >/dev/null 2>&1; then
    nc -zv -w 3 "${DEV_PROXY_HOST}" "${DEV_PROXY_PORT}" >"$tmp/tcp.out" 2>"$tcp_err"
    rc=$?
  elif command -v timeout >/dev/null 2>&1; then
    timeout 3 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "${DEV_PROXY_HOST}" "${DEV_PROXY_PORT}" >"$tmp/tcp.out" 2>"$tcp_err"
    rc=$?
  else
    rc=127
    printf 'no bounded TCP probe tool (nc or timeout) is available\n' >"$tcp_err"
  fi

  if [ "$rc" -eq 0 ]; then
    printf 'PASS_PROXY_TCP host=%s port=%s\n' "${DEV_PROXY_HOST}" "${DEV_PROXY_PORT}"
    return 0
  fi

  kind="unreachable"
  if grep -qi 'refused' "$tcp_err"; then
    kind="connection-refused"
  elif grep -qiE 'timed out|timeout' "$tcp_err" || [ "$rc" -eq 124 ]; then
    kind="timeout"
  fi
  printf 'FAIL_PROXY_TCP kind=%s rc=%s host=%s port=%s\n' "$kind" "$rc" "${DEV_PROXY_HOST}" "${DEV_PROXY_PORT}"
  sed -n '1,3p' "$tcp_err"
  return 1
}

check_url() {
  label="$1"
  url="$2"
  # %{http_code} is the final response status, not the proxy's CONNECT reply,
  # and a zero exit code is what proves the tunnel and the TLS handshake
  # completed. Matching on "HTTP/" alone would accept a 200 Connection
  # established followed by a failed handshake.
  # Ignore inherited bypass lists: this check must prove the configured relay
  # handled the request, not that curl connected directly.
  status="$(curl -sS -o /dev/null -I --noproxy '' --connect-timeout 5 --max-time 15 --proxy "${HTTP_PROXY}" -w '%{http_code}' "$url" 2>"$tmp/${label}.err")"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$status" ] && [ "$status" != "000" ]; then
    printf 'PASS_%s http=%s\n' "$label" "$status"
  else
    case "$rc" in
      28) kind="timeout" ;;
      7) kind="connection-failed" ;;
      *) kind="proxy-or-upstream" ;;
    esac
    printf 'FAIL_%s kind=%s curl_rc=%s http=%s\n' "$label" "$kind" "$rc" "${status:-none}"
    sed -n '1,3p' "$tmp/${label}.err"
  fi
}

if [ "$target_ok" -eq 1 ]; then
  check_tcp || true
  check_url OPENAI https://api.openai.com/v1/models
  check_url ANTHROPIC https://api.anthropic.com
else
  printf 'SKIP_ENDPOINT_CHECK target-mismatch\n'
fi
# Sentinel: its absence means the script stopped early.
printf 'CHECKS_DONE\n'
'@
        $expectedHost = ConvertTo-BashSingleQuotedContent ([string]$Config.proxyHost)
        $expectedScheme = ConvertTo-BashSingleQuotedContent ([string]$Config.proxyScheme)
        $expectedPort = [string]$Config.proxyPort
        $expectedInteropPort = [string]$WslInteropPort
        $expectedInteropFallback = ([string][bool]$Config.enableWslInteropFallback).ToLowerInvariant()
        $expectedInteropToken = Get-InteropIdentityToken $Config
        $cmd = $cmd.Replace("__EXPECTED_PROXY_HOST__", $expectedHost)
        $cmd = $cmd.Replace("__EXPECTED_PROXY_SCHEME__", $expectedScheme)
        $cmd = $cmd.Replace("__EXPECTED_PROXY_PORT__", $expectedPort)
        $cmd = $cmd.Replace("__EXPECTED_INTEROP_PORT__", $expectedInteropPort)
        $cmd = $cmd.Replace("__EXPECTED_INTEROP_FALLBACK__", $expectedInteropFallback)
        $cmd = $cmd.Replace("__EXPECTED_INTEROP_TOKEN__", $expectedInteropToken)
        $result = Invoke-WslBash -Distro $Config.distro -Command $cmd
        $parsed = Split-WslOutput $result.Lines
        Write-WslOutputLines $parsed
        if ($result.Failed) {
            Write-Fail "WSL checks did not run for $($Config.distro): $(Get-WslFailureReason $result)"
        } else {
            $profileUnavailable = ($parsed.Lines -contains "MISSING_WSL_ENV") -or
                ($parsed.Lines -contains "WSL_PROFILE_INACTIVE") -or
                [bool]($parsed.Lines -match '^WSL_PROFILE_BYPASSED ')
            if (!$profileUnavailable) {
                if ($parsed.Lines -contains "TARGET_MISMATCH" -or ($parsed.Lines -match '^TARGET_MISMATCH ')) {
                    Write-Fail "WSL proxy profile target/relay generation does not match configured target; reinstall it or use a parallel interop port."
                } elseif (-not ($parsed.Lines -contains "TARGET_MATCH")) {
                    Write-Fail "WSL proxy profile did not report a target match; reinstall it with option 4."
                }
                if (-not ($parsed.Lines -contains "PROXY_PATH_MATCH")) {
                    Write-Fail "WSL HTTP proxy path does not match the resolved host/port; profile may be stale or disabled."
                }
            }
            foreach ($line in $parsed.Lines) {
                if ($line -match "^FAIL_PROXY_TCP kind=([^ ]+)") {
                    $kind = $Matches[1]
                    if ($kind -eq "timeout") {
                        Write-Fail "WSL TCP connection to the proxy timed out: $line"
                    } elseif ($kind -eq "connection-refused") {
                        Write-Fail "WSL TCP connection to the proxy was refused: $line"
                    } else {
                        Write-Fail "WSL has no TCP path to the proxy listener: $line"
                    }
                } elseif ($line -match "^FAIL_([A-Z_]+) kind=([^ ]+) curl_rc=([0-9]+)") {
                    $label = $Matches[1]
                    $kind = $Matches[2]
                    $curlCode = $Matches[3]
                    if ($curlCode -eq "28") {
                        Write-Fail "WSL HTTPS request to $label timed out (curl 28): $line"
                    } elseif ($curlCode -eq "7") {
                        Write-Fail "WSL HTTPS request to $label could not connect to the proxy (curl 7): $line"
                    } else {
                        Write-Fail "WSL proxy tunnel or upstream request failed for ${label}: $line"
                    }
                } elseif ($line -eq "MISSING_WSL_ENV") {
                    Write-Fail "WSL proxy profile is not installed in $($Config.distro)"
                } elseif ($line -eq "WSL_PROFILE_INACTIVE") {
                    Write-Fail "WSL proxy profile is installed but its ~/.profile hook is disabled or missing. Reinstall it with option 4."
                } elseif ($line -match '^WSL_PROFILE_BYPASSED path=(.+)$') {
                    Write-Fail "WSL Bash login profile $($Matches[1]) does not load ~/.profile, so new login shells skip the proxy hook."
                }
            }
            if (!$profileUnavailable) {
                if (-not ($parsed.Lines -match '^DEV_PROXY_NETWORKING_MODE=(mirrored|nat)$')) {
                    Write-Fail "WSL proxy profile did not report a networking mode; reinstall it with option 4."
                }
                if (-not ($parsed.Lines -match '^(PASS|FAIL)_PROXY_TCP ')) {
                    Write-Fail "WSL TCP-layer proxy check did not produce a result."
                }
            }
            # Without the sentinel the script stopped partway, which must not
            # read as a clean run just because no FAIL_ marker was printed.
            if (-not ($parsed.Lines -contains "MISSING_WSL_ENV") -and -not ($parsed.Lines -contains "CHECKS_DONE")) {
                Write-Fail "WSL connectivity checks did not complete for $($Config.distro)"
            }
        }
    } else {
        Write-Warn "No WSL distro selected; skipping WSL checks."
    }
    Complete-Progress $activity
    Write-Tip "HTTP 401/403/404 from API endpoints is acceptable here; it means network connectivity worked without credentials."
    if ($script:VerifyFailures -eq 0) {
        Write-Ok "Verification finished with no failures"
    } else {
        Write-Line ("[FAIL] Verification finished with {0} failure(s)" -f $script:VerifyFailures) ([ConsoleColor]::Red)
    }
}

function Show-CcSwitchSuggestions($Config) {
    if (!$Config.distro) {
        Write-Warn "Select a WSL distro first."
        return
    }
    $homeResult = Invoke-WslBash -Distro $Config.distro -Command 'printf "%s\n" "$HOME"'
    $wslHome = if ($homeResult.Failed) { "" } else { (@(Get-WslCleanLines $homeResult.Lines) -join "").Trim() }
    # Root and custom accounts do not live under /home, so ask the distro instead of guessing.
    if (!$wslHome) { $wslHome = "/home/<wslUser>" }
    $uncHome = "\\wsl.localhost\$($Config.distro)" + ($wslHome -replace "/", "\")
    Write-Line
    Write-Info "CC Switch suggested values"
    Write-Line "Global proxy: $(Get-ProxyUrl $Config)"
    Write-Line "Claude directory: $uncHome\.claude"
    Write-Line "Codex directory:  $uncHome\.codex"
    Write-Line
    Write-Warn "Do not put these paths in CC Switch's app config directory field."
}

function Configure-Settings($Config) {
    Write-Line
    Write-Tip "Press Enter to keep the value shown in brackets."
    $portAnswer = Read-Host "Proxy port [$($Config.proxyPort)]"
    if (![string]::IsNullOrWhiteSpace($portAnswer)) {
        $port = 0
        if ([int]::TryParse($portAnswer.Trim(), [ref]$port) -and (Test-ProxyPort $port)) {
            $Config.proxyPort = $port
        } else {
            Write-Warn "Ignoring '$portAnswer'; the port must be a number in 1-65535."
        }
    }
    $hostAnswer = Read-Host "Proxy host [$($Config.proxyHost)]"
    if (![string]::IsNullOrWhiteSpace($hostAnswer)) { $Config.proxyHost = $hostAnswer.Trim() }
    $schemeAnswer = Read-Host "Proxy scheme http/https [$($Config.proxyScheme)]"
    if (![string]::IsNullOrWhiteSpace($schemeAnswer)) {
        $scheme = $schemeAnswer.Trim().ToLowerInvariant()
        if ($scheme -in @("http", "https")) {
            $Config.proxyScheme = $scheme
        } else {
            Write-Warn "Ignoring '$schemeAnswer'; the scheme must be http or https."
        }
    }
    $noProxyAnswer = Read-Host "Bypass list, comma separated [$($Config.noProxy)]"
    if (![string]::IsNullOrWhiteSpace($noProxyAnswer)) { $Config.noProxy = $noProxyAnswer.Trim() }
    $Config.enableWslMirrored = Read-YesNo "Prefer WSL mirrored networking?" ([bool]$Config.enableWslMirrored)
    $Config.enableWslInteropFallback = Read-YesNo "Enable the WSL interop bridge only when mirrored localhost is unreachable?" ([bool]$Config.enableWslInteropFallback)
    Save-Config $Config
    Write-Ok "Saved proxy target: $(Get-ProxyUrl $Config)"
    Write-Ok "Bypass list: $($Config.noProxy)"
    Write-Ok "WSL mirrored preference: $(if ($Config.enableWslMirrored) { 'enabled' } else { 'disabled' })"
    Write-Ok "WSL interop fallback: $(if ($Config.enableWslInteropFallback) { 'enabled' } else { 'disabled' })"
    Write-Tip "Make sure your local proxy client exposes an HTTP or mixed listener on this address."
    Write-Tip "Re-run option 2 and option 4 to apply the new values."
}

function Apply-WindowsProxy($Config) {
    $activity = "Setting Windows proxy"
    Write-Info "This will update Windows user system proxy and user-level CLI proxy environment variables."
    Write-Info "It will not modify CC Switch, Claude, Codex, or any API keys."
    if (!$NonInteractive -and !(Read-YesNo "Continue with Windows proxy setup?" $true)) { return }
    Show-Progress $activity "Writing Windows user system proxy" 25
    Set-WindowsSystemProxy $Config
    Show-Progress $activity "Writing user-level CLI proxy environment variables" 55
    Set-UserProxyEnv $Config
    Show-Progress $activity "Optionally syncing WinHTTP" 75
    $syncWinHttp = if ($NonInteractive) { Test-IsAdmin } else { Read-YesNo "Sync WinHTTP proxy now?" (Test-IsAdmin) }
    if ($syncWinHttp) {
        Sync-WinHttpProxy
    } else {
        Write-Info "WinHTTP sync skipped."
    }
    Complete-Progress $activity
    Write-Tip "Restart Windows Terminal and desktop apps so they pick up user environment changes."
}

function Apply-WslProxy($Config) {
    $activity = "Setting WSL proxy"
    Write-Info "This will select a WSL distro, optionally update .wslconfig, and install a shell proxy profile."
    Write-Info "It will not install CLI tools or change Claude/Codex provider files."
    Write-Info "Mirrored networking tries the Windows localhost listener first and uses the interop bridge only as an enabled fallback; NAT mode uses the default gateway."
    Write-Info "Without mirrored mode, WSL uses the vEthernet gateway, for example 172.17.0.1; your proxy client must accept non-loopback connections."
    if (!$NonInteractive -and !(Read-YesNo "Continue with WSL proxy setup?" $true)) { return }
    Show-Progress $activity "Selecting WSL distro" 15
    if (!$Config.distro) { [void](Select-WslDistro $Config) }
    if (!$Config.distro) { return }
    $useMirrored = if ($NonInteractive) {
        [bool]$Config.enableWslMirrored
    } else {
        Read-YesNo "Update %USERPROFILE%\.wslconfig for mirrored networking?" ([bool]$Config.enableWslMirrored)
    }
    $Config.enableWslMirrored = $useMirrored
    Save-Config $Config
    if ($useMirrored) {
        Show-Progress $activity "Updating .wslconfig for mirrored networking" 45
        Configure-WslMirrored
    } else {
        Show-Progress $activity "Disabling WSL autoProxy ownership conflict" 45
        Configure-WslProxyOwnership
        Write-Warn "Mirrored networking was skipped. WSL will fall back to the Windows host IP; this only works if your proxy client accepts non-loopback connections."
    }
    Show-Progress $activity "Installing WSL shell proxy environment" 75
    Install-WslProxyEnv $Config
    Complete-Progress $activity
    Write-Tip "If .wslconfig changed, run 'wsl --shutdown' after saving WSL work."
}

function Disable-All($Config) {
    if (!$NonInteractive) {
        if (!(Read-YesNo "Disable Windows/WSL proxy settings managed by this tool?" $false)) { return }
    }
    Clear-WindowsSystemProxy
    Clear-UserProxyEnv
    Reset-WinHttpProxy
    Disable-WslProxyEnv $Config
    Restore-ManagedWslConfig
}

function Show-Menu($Config) {
    while ($true) {
        Write-Line
        Write-Line "Dev Proxy Tool" ([ConsoleColor]::White)
        Write-Line "Target proxy: $(Get-ProxyUrl $Config)"
        Write-Line "WSL distro:   $(if ($Config.distro) { $Config.distro } else { '<not selected>' })"
        Write-Line "WSL mirrored: $(if ($Config.enableWslMirrored) { 'enabled' } else { 'disabled' })"
        Write-Line "WSL interop fallback: $(if ($Config.enableWslInteropFallback) { 'enabled' } else { 'disabled' })"
        Write-Line "Scope: Windows user proxy/env + selected WSL shell env" ([ConsoleColor]::DarkGray)
        Write-Line "Safe:  CC Switch/provider files are not edited" ([ConsoleColor]::DarkGray)
        Write-Line
        Write-Line "1. Configure proxy target and preferences"
        Write-Line "2. Set Windows system proxy + user env"
        Write-Line "3. Select WSL distro"
        Write-Line "4. Configure WSL mirrored mode + install WSL env"
        Write-Line "5. Verify all"
        Write-Line "6. Show CC Switch suggested values"
        Write-Line "7. Disable / rollback"
        Write-Line "0. Exit"
        Write-Line "Press Enter without input to exit"
        $choice = Read-Host "Choose"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            Write-Info "No menu choice entered; exiting."
            return
        }
        switch ($choice) {
            "1" { Configure-Settings $Config }
            "2" { Apply-WindowsProxy $Config }
            "3" { [void](Select-WslDistro $Config) }
            "4" { Apply-WslProxy $Config }
            "5" { Verify-All $Config }
            "6" { Show-CcSwitchSuggestions $Config }
            "7" { Disable-All $Config }
            "0" { return }
            default { Write-Warn "Unknown choice." }
        }
    }
}

$exitCode = 0
try {
    $config = Read-Config
    # Keep the relay generation/port in the same persisted config as the target.
    # A changed value deliberately does not stop an old relay; installation then
    # fails clearly if the old port is still occupied, enabling a parallel-port
    # rollout for new shells.
    $WslInteropPort = [int]$config.wslInteropPort
    # -Verify and -Disable do not change the target, so they must not write one
    # either; otherwise a throwaway -ProxyPort would be saved to config.json.
    if (!$Verify -and !$Disable) { Save-Config $config }

    if ($Disable) {
        Disable-All $config
    } elseif ($Verify) {
        Verify-All $config
    } elseif ($NonInteractive) {
        Apply-WindowsProxy $config
        if ($config.distro) {
            if ([bool]$config.enableWslMirrored) {
                Configure-WslMirrored
            } else {
                Configure-WslProxyOwnership
                Write-Warn "Saved WSL mirrored preference is disabled; prior tool-managed mirrored settings are restored while autoProxy ownership remains managed."
                Write-Warn "WSL NAT fallback requires your proxy client to accept non-loopback connections from the WSL vEthernet gateway."
            }
            Install-WslProxyEnv $config
        } else {
            Write-Warn "No distro selected. Re-run interactively or pass -Distro."
        }
        if ($DryRun) {
            Write-Info "Dry-run complete; verification skipped."
        } else {
            Verify-All $config
        }
    } else {
        Show-Menu $config
    }
    $exitCode = [int]($script:HadFailures)
} finally {
    # Do not leak this script's UTF-8 console/pipeline preference into callers
    # that dot-source it or host it in a long-lived PowerShell process.
    try {
        if ($null -ne $script:OriginalConsoleOutputEncoding) {
            [Console]::OutputEncoding = $script:OriginalConsoleOutputEncoding
        }
        $OutputEncoding = $script:OriginalPipelineOutputEncoding
    } catch {
    }
}
exit $exitCode
