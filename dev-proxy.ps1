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

# The Windows user-scope knobs this tool owns. Nothing outside these is touched.
$InternetSettingsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$ProxyEnvNames = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy")
$DefaultProxyPort = 20122

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

try {
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
    if ($ProxyPort -gt 0) { $defaults.proxyPort = $ProxyPort }
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
    if ([string]::IsNullOrWhiteSpace("$($defaults.proxyHost)")) { $defaults.proxyHost = "127.0.0.1" }
    $defaults.enableWslMirrored = [bool]$defaults.enableWslMirrored
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
    # BOM-less UTF-8 so non-PowerShell readers of config.json do not trip on a BOM.
    [IO.File]::WriteAllText($ConfigPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

function Test-ProxyPort([int]$Port) {
    return ($Port -ge 1 -and $Port -le 65535)
}

function Get-ProxyUrl($Config) {
    "$($Config.proxyScheme)://$($Config.proxyHost):$($Config.proxyPort)"
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
    $server = "$($Config.proxyHost):$($Config.proxyPort)"
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
    if ($Text -match "localhost.*WSL|localhost.*proxy|localhost 代理|NAT 模式|WSL0NAT") { return $true }
    if ($Text -match "localhost" -and $Text -match "�|Km0R|N/ec|Nt0|NtM") { return $true }
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
    return "the WSL command exited with code $($Result.ExitCode)"
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
    try {
        $ErrorActionPreference = "Continue"
        # Pass WSL scripts as base64 to avoid PowerShell/native quoting issues with multiline bash.
        # The WSL-side timeout keeps the menu from hanging on bad profiles or startup warnings.
        $normalizedCommand = $Command -replace "`r`n", "`n"
        $normalizedCommand = $normalizedCommand -replace "`r", "`n"
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalizedCommand))
        $runner = "printf '%s' '$encodedCommand' | base64 -d | timeout $TimeoutSec bash"
        $raw = & wsl.exe -d $Distro -- bash -c $runner 2>&1
        $exitCode = $LASTEXITCODE
        $result = @()
        foreach ($item in $raw) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $result += $item.Exception.Message
            } else {
                $result += "$item"
            }
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            TimedOut = ($exitCode -eq 124)
            Failed = ($exitCode -ne 0)
            Lines = @($result)
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = -1
            TimedOut = $false
            Failed = $true
            Lines = @($_.Exception.Message)
        }
    } finally {
        $ErrorActionPreference = $oldPreference
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

function Set-IniValue([string[]]$Lines, [string]$Section, [string]$Key, [string]$Value) {
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
    if ($start -lt 0) {
        $result = @($Lines)
        if ($result.Count -gt 0 -and $result[-1].Trim() -ne "") { $result += "" }
        $result += $sectionHeader
        $result += "$Key=$Value"
        return $result
    }

    $keyPattern = "^\s*$([regex]::Escape($Key))\s*="
    $updated = $false
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -gt $start -and $i -lt $end -and $Lines[$i] -match $keyPattern) {
            if (!$updated) {
                $out.Add("$Key=$Value")
                $updated = $true
            }
        } else {
            $out.Add($Lines[$i])
        }
    }
    if (!$updated) {
        $out.Insert($end, "$Key=$Value")
    }
    return $out.ToArray()
}

function Configure-WslMirrored {
    $path = Join-Path $env:USERPROFILE ".wslconfig"
    $existing = @()
    if (Test-Path $path) {
        $existing = @(Get-Content $path)
    }
    $lines = $existing
    $lines = Set-IniValue $lines "wsl2" "networkingMode" "mirrored"
    $lines = Set-IniValue $lines "wsl2" "dnsTunneling" "true"
    $lines = Set-IniValue $lines "wsl2" "autoProxy" "true"

    if (($existing -join "`n") -eq (@($lines) -join "`n")) {
        # Repeat runs otherwise leave a new .bak file behind every time.
        Write-Ok "$path already has mirrored networking settings"
        return
    }

    if ($DryRun) {
        Write-Info "Dry-run: would update $path with mirrored networking"
        return
    }
    Write-Info "Updating WSL networking settings. Existing .wslconfig will be backed up first."
    if (Test-Path $path) {
        $backup = "$path.bak.$(Get-Date -Format yyyyMMddHHmmss)"
        Copy-Item $path $backup -Force
        Write-Info "Backed up existing .wslconfig to $backup"
    }
    $lines | Set-Content -Path $path -Encoding ASCII
    Write-Ok "Updated $path for WSL mirrored networking"
    Write-Warn "Run 'wsl --shutdown' after saving work in WSL, then reopen WSL."
}

function Install-WslProxyEnv($Config) {
    if (!$Config.distro) {
        Write-Warn "No WSL distro selected."
        return
    }
    if (!(Test-Path $TemplatePath)) {
        throw "Missing template: $TemplatePath"
    }
    $content = Get-Content $TemplatePath -Raw
    $content = $content.Replace("__PROXY_SCHEME__", [string]$Config.proxyScheme)
    $content = $content.Replace("__PROXY_PORT__", [string]$Config.proxyPort)
    $content = $content.Replace("__NO_PROXY__", [string]$Config.noProxy)

    if ($DryRun) {
        Write-Info "Dry-run: would install WSL proxy env into distro '$($Config.distro)'"
        return
    }
    Write-Info "Installing WSL proxy environment into '$($Config.distro)'. This writes ~/.config/dev-proxy/proxy-env.sh and sources it from ~/.profile."

    $content = $content -replace "`r`n", "`n"
    $content = $content -replace "`r", "`n"
    $contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))

    $installCmd = @'
set -e
mkdir -p "$HOME/.config/dev-proxy"
printf '%s' '__CONTENT_BASE64__' | base64 -d > "$HOME/.config/dev-proxy/proxy-env.sh"
chmod 600 "$HOME/.config/dev-proxy/proxy-env.sh"
touch "$HOME/.profile"
SOURCE_LINE='source "$HOME/.config/dev-proxy/proxy-env.sh"'
DISABLED_LINE="# disabled by dev-proxy: $SOURCE_LINE"

# Re-enable a line this tool disabled earlier instead of appending a second
# copy, which would leave the commented-out line behind for good.
if grep -qxF "$DISABLED_LINE" "$HOME/.profile"; then
  tmp="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$DISABLED_LINE" ]; then
      printf '%s\n' "$SOURCE_LINE"
    else
      printf '%s\n' "$line"
    fi
  done < "$HOME/.profile" > "$tmp"
  mv "$tmp" "$HOME/.profile"
fi

if ! grep -qxF "$SOURCE_LINE" "$HOME/.profile"; then
  {
    printf '\n# Dev proxy environment\n'
    printf '%s\n' "$SOURCE_LINE"
  } >> "$HOME/.profile"
fi
printf 'installed:%s\n' "$HOME/.config/dev-proxy/proxy-env.sh"
'@
    $installCmd = $installCmd.Replace("__CONTENT_BASE64__", $contentBase64)
    $result = Invoke-WslBash -Distro $Config.distro -Command $installCmd
    $parsed = Split-WslOutput $result.Lines
    Write-WslOutputLines $parsed
    if ($result.Failed -or -not ($parsed.Lines -match "^installed:")) {
        Write-Fail "Could not install the WSL proxy environment for $($Config.distro): $(Get-WslFailureReason $result)"
        return
    }
    Write-Ok "Installed WSL proxy environment for $($Config.distro)"
    Write-Tip "Open a new WSL shell, or run: source ~/.profile"
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
SOURCE_LINE='source "$HOME/.config/dev-proxy/proxy-env.sh"'
if [ ! -f "$HOME/.profile" ] || ! grep -qxF "$SOURCE_LINE" "$HOME/.profile"; then
  # Nothing active to disable, so do not leave another backup behind.
  printf 'already-disabled\n'
  exit 0
fi
cp "$HOME/.profile" "$HOME/.profile.dev-proxy.bak.$(date +%s)"
tmp="$(mktemp)"
awk '{ if ($0 == "source \"$HOME/.config/dev-proxy/proxy-env.sh\"") print "# disabled by dev-proxy: " $0; else print $0 }' "$HOME/.profile" > "$tmp"
mv "$tmp" "$HOME/.profile"
printf 'disabled\n'
'@
    $result = Invoke-WslBash -Distro $Config.distro -Command $cmd
    $parsed = Split-WslOutput $result.Lines
    if ($result.Failed) {
        Write-WslOutputLines $parsed
        Write-Fail "Could not disable the WSL proxy source line for $($Config.distro): $(Get-WslFailureReason $result)"
        return
    }
    if ($parsed.Lines -contains "already-disabled") {
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
        if ($reg.ProxyEnable -eq 1 -and "$($reg.ProxyServer)" -eq "$($Config.proxyHost):$($Config.proxyPort)") {
            Write-Ok "Windows user system proxy is enabled: $($reg.ProxyServer)"
        } else {
            Write-Warn "Windows user system proxy does not match target. Current: enabled=$($reg.ProxyEnable), server=$($reg.ProxyServer)"
        }
    } catch {
        Write-Warn "Could not read Windows proxy registry: $($_.Exception.Message)"
    }

    Show-Progress $activity "Checking Windows user proxy environment variables" 25
    $userProxy = [Environment]::GetEnvironmentVariable("HTTP_PROXY", "User")
    if ($userProxy -eq $proxyUrl) { Write-Ok "User HTTP_PROXY matches target" } else { Write-Warn "User HTTP_PROXY mismatch: $userProxy" }

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

# proxy_on returns non-zero when no host resolves. Keep going either way so
# proxy_status can report what actually happened.
. "$env_file" || true
proxy_status || true

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check_url() {
  label="$1"
  url="$2"
  # %{http_code} is the final response status, not the proxy's CONNECT reply,
  # and a zero exit code is what proves the tunnel and the TLS handshake
  # completed. Matching on "HTTP/" alone would accept a 200 Connection
  # established followed by a failed handshake.
  status="$(curl -sS -o /dev/null -I --max-time 15 -w '%{http_code}' "$url" 2>"$tmp/err")"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$status" ] && [ "$status" != "000" ]; then
    printf 'PASS_%s http=%s\n' "$label" "$status"
  else
    printf 'FAIL_%s rc=%s http=%s\n' "$label" "$rc" "${status:-none}"
    sed -n '1,3p' "$tmp/err"
  fi
}

check_url OPENAI https://api.openai.com/v1/models
check_url ANTHROPIC https://api.anthropic.com
# Sentinel: its absence means the script stopped early.
printf 'CHECKS_DONE\n'
'@
        $result = Invoke-WslBash -Distro $Config.distro -Command $cmd
        $parsed = Split-WslOutput $result.Lines
        Write-WslOutputLines $parsed
        if ($result.Failed) {
            Write-Fail "WSL checks did not run for $($Config.distro): $(Get-WslFailureReason $result)"
        } else {
            foreach ($line in $parsed.Lines) {
                if ($line -match "^FAIL_([A-Z_]+)") {
                    Write-Fail "WSL could not reach $($Matches[1]) through the proxy: $line"
                } elseif ($line -eq "MISSING_WSL_ENV") {
                    Write-Fail "WSL proxy profile is not installed in $($Config.distro)"
                } elseif ($line -eq "proxy_tcp=unreachable") {
                    Write-Fail "WSL has no TCP path to the proxy listener"
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
    Save-Config $Config
    Write-Ok "Saved proxy target: $(Get-ProxyUrl $Config)"
    Write-Ok "Bypass list: $($Config.noProxy)"
    Write-Ok "WSL mirrored preference: $(if ($Config.enableWslMirrored) { 'enabled' } else { 'disabled' })"
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
    Write-Info "Mirrored networking lets WSL reach the Windows proxy at 127.0.0.1:$($Config.proxyPort)."
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
}

function Show-Menu($Config) {
    while ($true) {
        Write-Line
        Write-Line "Dev Proxy Tool" ([ConsoleColor]::White)
        Write-Line "Target proxy: $(Get-ProxyUrl $Config)"
        Write-Line "WSL distro:   $(if ($Config.distro) { $Config.distro } else { '<not selected>' })"
        Write-Line "WSL mirrored: $(if ($Config.enableWslMirrored) { 'enabled' } else { 'disabled' })"
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

$config = Read-Config
# -Verify and -Disable do not change the target, so they must not write one
# either; otherwise a throwaway -ProxyPort would be saved to config.json.
if (!$Verify -and !$Disable) { Save-Config $config }

if ($Disable) {
    Disable-All $config
    exit
}

if ($Verify) {
    Verify-All $config
    exit ([int]($script:HadFailures))
}

if ($NonInteractive) {
    Apply-WindowsProxy $config
    if ($config.distro) {
        if ([bool]$config.enableWslMirrored) {
            Configure-WslMirrored
        } else {
            Write-Warn "Saved WSL mirrored preference is disabled; .wslconfig will not be changed."
            Write-Warn "WSL NAT fallback requires your proxy client to accept non-loopback connections from the WSL vEthernet gateway."
        }
        Install-WslProxyEnv $config
    } else {
        Write-Warn "No distro selected. Re-run interactively or pass -Distro."
    }
    if ($DryRun) {
        Write-Info "Dry-run complete; verification skipped."
        exit
    }
    Verify-All $config
    exit ([int]($script:HadFailures))
}

Show-Menu $config
