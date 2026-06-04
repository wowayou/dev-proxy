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
function Write-Fail($Message) { Write-Line "[FAIL] $Message" ([ConsoleColor]::Red) }
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
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().ToLowerInvariant().StartsWith("y")
}

function Get-DefaultConfig {
    [pscustomobject]@{
        proxyHost = "127.0.0.1"
        proxyPort = 20122
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
    if ($ProxyHost) { $defaults.proxyHost = $ProxyHost }
    if ($ProxyPort -gt 0) { $defaults.proxyPort = $ProxyPort }
    if ($ProxyScheme) { $defaults.proxyScheme = $ProxyScheme }
    if ($Distro) { $defaults.distro = $Distro }
    return $defaults
}

function Save-Config($Config) {
    if ($DryRun) {
        Write-Info "Dry-run: would save $ConfigPath"
        return
    }
    if (!(Test-Path $ScriptRoot)) { New-Item -ItemType Directory -Path $ScriptRoot -Force | Out-Null }
    $Config | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Get-ProxyUrl($Config) {
    "$($Config.proxyScheme)://$($Config.proxyHost):$($Config.proxyPort)"
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
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $server = "$($Config.proxyHost):$($Config.proxyPort)"
    $override = "localhost;127.0.0.1;::1;<local>"

    if ($DryRun) {
        Write-Info "Dry-run: would set Windows system proxy to $server"
        return
    }

    Set-ItemProperty -Path $path -Name ProxyEnable -Type DWord -Value 1
    Set-ItemProperty -Path $path -Name ProxyServer -Type String -Value $server
    Set-ItemProperty -Path $path -Name ProxyOverride -Type String -Value $override
    Invoke-WinInetRefresh
    Write-Ok "Windows user system proxy set to $server"
}

function Clear-WindowsSystemProxy {
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    if ($DryRun) {
        Write-Info "Dry-run: would disable Windows user system proxy"
        return
    }
    Set-ItemProperty -Path $path -Name ProxyEnable -Type DWord -Value 0
    Invoke-WinInetRefresh
    Write-Ok "Windows user system proxy disabled"
}

function Set-UserProxyEnv($Config) {
    $proxy = Get-ProxyUrl $Config
    $vars = @(
        @{ Name = "HTTP_PROXY"; Value = $proxy },
        @{ Name = "HTTPS_PROXY"; Value = $proxy },
        @{ Name = "ALL_PROXY"; Value = $proxy },
        @{ Name = "NO_PROXY"; Value = $Config.noProxy },
        @{ Name = "http_proxy"; Value = $proxy },
        @{ Name = "https_proxy"; Value = $proxy },
        @{ Name = "all_proxy"; Value = $proxy },
        @{ Name = "no_proxy"; Value = $Config.noProxy }
    )
    foreach ($entry in $vars) {
        if ($DryRun) {
            Write-Info "Dry-run: would set user env $($entry.Name)=$($entry.Value)"
        } else {
            [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, "User")
        }
    }
    if (!$DryRun) { Write-Ok "Windows user proxy environment variables updated" }
}

function Clear-UserProxyEnv {
    foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy")) {
        if ($DryRun) {
            Write-Info "Dry-run: would clear user env $name"
        } else {
            [Environment]::SetEnvironmentVariable($name, $null, "User")
        }
    }
    if (!$DryRun) { Write-Ok "Windows user proxy environment variables cleared" }
}

function Sync-WinHttpProxy {
    if (!(Test-IsAdmin)) {
        Write-Warn "WinHTTP sync requires an elevated PowerShell. Run: netsh winhttp import proxy source=ie"
        return
    }
    if ($DryRun) {
        Write-Info "Dry-run: would run netsh winhttp import proxy source=ie"
        return
    }
    Write-Info "Syncing WinHTTP from Windows user system proxy. This can take a few seconds..."
    & netsh.exe winhttp import proxy source=ie *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "WinHTTP proxy imported from Windows user system proxy"
    } else {
        Write-Warn "WinHTTP proxy import returned exit code $LASTEXITCODE"
    }
}

function Reset-WinHttpProxy {
    if (!(Test-IsAdmin)) {
        Write-Warn "WinHTTP reset requires an elevated PowerShell. Run: netsh winhttp reset proxy"
        return
    }
    if ($DryRun) {
        Write-Info "Dry-run: would run netsh winhttp reset proxy"
        return
    }
    Write-Info "Resetting WinHTTP proxy..."
    & netsh.exe winhttp reset proxy *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "WinHTTP proxy reset"
    } else {
        Write-Warn "WinHTTP proxy reset returned exit code $LASTEXITCODE"
    }
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

function Write-WslCommandOutput($Output) {
    $warnedPath = $false
    $warnedLocalhost = $false
    foreach ($item in $Output) {
        $text = ("$item" -replace "`0", "").TrimEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($text -match "UtilTranslatePathList|Failed to translate") {
            if (!$warnedPath) {
                Write-Warn "WSL skipped invalid Windows PATH entries while starting. This is harmless for this tool; clean Windows PATH later if desired."
                $warnedPath = $true
            }
            continue
        }

        if (Test-WslLocalhostProxyNoise $text) {
            if (!$warnedLocalhost) {
                Write-Warn "WSL reports localhost proxy is not mirrored. In NAT mode, enable mirrored networking or make your proxy client listen on LAN/0.0.0.0."
                $warnedLocalhost = $true
            }
            continue
        }

        Write-Line $text
    }
}

function Get-WslCleanLines($Output) {
    $lines = @()
    foreach ($item in $Output) {
        $text = ("$item" -replace "`0", "").TrimEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match "UtilTranslatePathList|Failed to translate") { continue }
        if (Test-WslLocalhostProxyNoise $text) { continue }
        $lines += $text
    }
    return $lines
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
        if ($exitCode -eq 124) {
            $result += "WSL command timed out after ${TimeoutSec}s"
        } elseif ($exitCode -ne 0) {
            $result += "WSL command exited with code $exitCode"
        }
        return $result
    } catch {
        return @($_.Exception.Message)
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
    $lines = @()
    if (Test-Path $path) {
        $lines = Get-Content $path
    }
    $lines = Set-IniValue $lines "wsl2" "networkingMode" "mirrored"
    $lines = Set-IniValue $lines "wsl2" "dnsTunneling" "true"
    $lines = Set-IniValue $lines "wsl2" "autoProxy" "true"

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
if ! grep -qxF "$SOURCE_LINE" "$HOME/.profile"; then
  {
    printf '\n# Dev proxy environment\n'
    printf '%s\n' "$SOURCE_LINE"
  } >> "$HOME/.profile"
fi
printf 'installed:%s\n' "$HOME/.config/dev-proxy/proxy-env.sh"
'@
    $installCmd = $installCmd.Replace("__CONTENT_BASE64__", $contentBase64)
    $output = Invoke-WslBash -Distro $Config.distro -Command $installCmd
    Write-WslCommandOutput $output
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
if [ -f "$HOME/.profile" ]; then
  cp "$HOME/.profile" "$HOME/.profile.dev-proxy.bak.$(date +%s)"
  tmp="$(mktemp)"
  awk '{ if ($0 == "source \"$HOME/.config/dev-proxy/proxy-env.sh\"") print "# disabled by dev-proxy: " $0; else print $0 }' "$HOME/.profile" > "$tmp"
  mv "$tmp" "$HOME/.profile"
fi
'@
    $output = Invoke-WslBash -Distro $Config.distro -Command $cmd
    Write-WslCommandOutput $output
    Write-Ok "Disabled WSL proxy source line for $($Config.distro)"
}

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 700) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) { $client.EndConnect($iar) }
        $client.Close()
        return $ok
    } catch {
        return $false
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
    $proxyUrl = Get-ProxyUrl $Config
    Write-Line
    Write-Info "Verifying dev proxy configuration ($proxyUrl)"
    $activity = "Verifying dev proxy"
    Show-Progress $activity "Checking Windows system proxy" 10

    $internetPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    try {
        $reg = Get-ItemProperty $internetPath
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
set -e
if [ -f "$HOME/.config/dev-proxy/proxy-env.sh" ]; then
  . "$HOME/.config/dev-proxy/proxy-env.sh"
  proxy_status || true
  curl -I --max-time 15 https://api.openai.com/v1/models >/tmp/dev-proxy-openai.headers 2>/tmp/dev-proxy-openai.err || true
  if grep -qi '^HTTP/' /tmp/dev-proxy-openai.headers; then echo PASS_OPENAI; else echo FAIL_OPENAI; cat /tmp/dev-proxy-openai.err; fi
  curl -I --max-time 15 https://api.anthropic.com >/tmp/dev-proxy-anthropic.headers 2>/tmp/dev-proxy-anthropic.err || true
  if grep -qi '^HTTP/' /tmp/dev-proxy-anthropic.headers; then echo PASS_ANTHROPIC; else echo FAIL_ANTHROPIC; cat /tmp/dev-proxy-anthropic.err; fi
else
  echo MISSING_WSL_ENV
fi
'@
        $output = Invoke-WslBash -Distro $Config.distro -Command $cmd
        Write-WslCommandOutput $output
    } else {
        Write-Warn "No WSL distro selected; skipping WSL checks."
    }
    Complete-Progress $activity
    Write-Tip "HTTP 401/403/404 from API endpoints is acceptable here; it means network connectivity worked without credentials."
}

function Show-CcSwitchSuggestions($Config) {
    if (!$Config.distro) {
        Write-Warn "Select a WSL distro first."
        return
    }
    $rawUserOutput = Invoke-WslBash -Distro $Config.distro -Command 'id -un'
    $cleanUserOutput = @(Get-WslCleanLines $rawUserOutput)
    $wslUser = ($cleanUserOutput -join "").Trim()
    if (!$wslUser) { $wslUser = "<wslUser>" }
    Write-Line
    Write-Info "CC Switch suggested values"
    Write-Line "Global proxy: $(Get-ProxyUrl $Config)"
    Write-Line "Claude directory: \\wsl.localhost\$($Config.distro)\home\$wslUser\.claude"
    Write-Line "Codex directory:  \\wsl.localhost\$($Config.distro)\home\$wslUser\.codex"
    Write-Line
    Write-Warn "Do not put these paths in CC Switch's app config directory field."
}

function Configure-Settings($Config) {
    Write-Line
    $portAnswer = Read-Host "Proxy port [$($Config.proxyPort)]"
    if ($portAnswer -as [int]) { $Config.proxyPort = [int]$portAnswer }
    $hostAnswer = Read-Host "Proxy host [$($Config.proxyHost)]"
    if (![string]::IsNullOrWhiteSpace($hostAnswer)) { $Config.proxyHost = $hostAnswer.Trim() }
    $schemeAnswer = Read-Host "Proxy scheme http/https [$($Config.proxyScheme)]"
    if ($schemeAnswer -in @("http", "https")) { $Config.proxyScheme = $schemeAnswer }
    Save-Config $Config
    Write-Ok "Saved proxy target: $(Get-ProxyUrl $Config)"
    Write-Tip "Make sure your local proxy client exposes an HTTP or mixed listener on this address."
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
        Write-Line "1. Configure proxy target"
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
Save-Config $config

if ($Disable) {
    Disable-All $config
    exit
}

if ($Verify) {
    Verify-All $config
    exit
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
    exit
}

Show-Menu $config
