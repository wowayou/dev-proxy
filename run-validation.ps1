# Runs the AGENTS.md validation suite in one pass.
# Read-only by default. -Full adds the checks that change real Windows and WSL
# state, and restores a working configuration when it finishes.

[CmdletBinding()]
param(
    [string]$Distro,
    [switch]$Full,
    [switch]$SkipRollback,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolPath = Join-Path $ScriptRoot "dev-proxy.ps1"
$ConfigPath = Join-Path $ScriptRoot "config.json"
$ExamplePath = Join-Path $ScriptRoot "config.example.json"
$TemplatePath = Join-Path $ScriptRoot "templates\wsl-proxy-env.sh"
$InternetSettingsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$ProxyEnvNames = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy")

$script:Results = New-Object System.Collections.Generic.List[object]
$script:HostExe = (Get-Process -Id $PID).Path

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host $Title -ForegroundColor White
    Write-Host ("-" * $Title.Length) -ForegroundColor DarkGray
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "FAIL", "SKIP", "INFO")][string]$Status,
        [string]$Detail = ""
    )

    $script:Results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $color = switch ($Status) {
        "PASS" { [ConsoleColor]::Green }
        "FAIL" { [ConsoleColor]::Red }
        "SKIP" { [ConsoleColor]::DarkGray }
        default { [ConsoleColor]::Cyan }
    }
    $line = "[{0}] {1}" -f $Status, $Name
    if ($Detail) { $line += "  --  $Detail" }
    Write-Host $line -ForegroundColor $color
}

function Add-Check([string]$Name, [bool]$Ok, [string]$Detail = "") {
    Add-Result -Name $Name -Status $(if ($Ok) { "PASS" } else { "FAIL" }) -Detail $Detail
}

function Invoke-DevProxy([string[]]$Arguments) {
    # dev-proxy.ps1 prints through [Console]::Write, which bypasses the
    # PowerShell output stream. Running it as a child process puts that console
    # output into a pipe this script can actually read.
    $output = & $script:HostExe -NoProfile -File $ToolPath @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $code
        Output = @($output)
        Text = (@($output) -join "`n")
    }
}

function Invoke-WslScript([string]$Distro, [string]$Script) {
    # Same base64 hand-off dev-proxy.ps1 uses, to avoid quoting damage between
    # PowerShell, wsl.exe, and bash. The login shell sources ~/.profile, which
    # is what makes the proxy_* helpers available.
    $normalized = ($Script -replace "`r`n", "`n") -replace "`r", "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    $runner = "printf '%s' '$encoded' | base64 -d | timeout 45 bash -l"
    $raw = & wsl.exe -d $Distro -- bash -c $runner 2>&1
    $lines = @()
    foreach ($item in $raw) {
        $text = ("$item" -replace "`0", "").Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match "UtilTranslatePathList|Failed to translate") { continue }
        $lines += $text
    }
    return $lines
}

function Get-UnusedPort {
    # Bind an ephemeral port and release it, so the caller gets a port that is
    # known to have nothing listening on it.
    $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Get-ExpectedProxyOverride([string]$NoProxy) {
    # Mirrors what the tool must produce from noProxy, so the check follows the
    # configuration instead of pinning one literal bypass string.
    $parts = @()
    foreach ($item in ("$NoProxy" -split "[,;]")) {
        $trimmed = $item.Trim()
        if (!$trimmed) { continue }
        if ($trimmed.StartsWith(".")) { $trimmed = "*$trimmed" }
        if ($parts -notcontains $trimmed) { $parts += $trimmed }
    }
    if ($parts -notcontains "<local>") { $parts += "<local>" }
    return ($parts -join ";")
}

function Get-WslConfigBackupCount {
    return @(Get-ChildItem "$env:USERPROFILE\.wslconfig.bak.*" -ErrorAction SilentlyContinue).Count
}

Write-Host "Dev proxy validation" -ForegroundColor White
Write-Host "Tool:  $ToolPath" -ForegroundColor DarkGray
Write-Host "Host:  $script:HostExe" -ForegroundColor DarkGray
Write-Host "Mode:  $(if ($Full) { 'full (changes real state)' } else { 'read-only' })" -ForegroundColor DarkGray

Write-Section "1. Parse and syntax"

foreach ($file in (Get-ChildItem $ScriptRoot -Filter *.ps1 | Sort-Object Name)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Add-Check "parses: $($file.Name)" (-not $errors) ($errors | Select-Object -First 1)
}

try {
    Get-Content $ExamplePath -Raw | ConvertFrom-Json | Out-Null
    Add-Check "config.example.json parses" $true
} catch {
    Add-Check "config.example.json parses" $false $_.Exception.Message
}

if (Test-Path $ConfigPath) {
    try {
        Get-Content $ConfigPath -Raw | ConvertFrom-Json | Out-Null
        Add-Check "config.json parses" $true
    } catch {
        Add-Check "config.json parses" $false $_.Exception.Message
    }
    $firstByte = [IO.File]::ReadAllBytes($ConfigPath)[0]
    Add-Check "config.json has no BOM" ($firstByte -eq 0x7B) ("first byte 0x{0:X2}" -f $firstByte)
} else {
    Add-Result -Name "config.json checks" -Status "SKIP" -Detail "no config.json yet; it is written on first run"
}

# AGENTS.md requires config.example.json to stay in step with Get-DefaultConfig.
# Read the keys out of the function's AST so the rule is enforced, not just stated.
try {
    $astTokens = $null
    $astErrors = $null
    $toolAst = [System.Management.Automation.Language.Parser]::ParseFile($ToolPath, [ref]$astTokens, [ref]$astErrors)
    $defaultFn = $toolAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-DefaultConfig"
    }, $true)
    $hashAst = if ($defaultFn) {
        $defaultFn.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)
    } else { $null }

    if (-not $hashAst) {
        Add-Check "config.example.json matches Get-DefaultConfig" $false "could not locate Get-DefaultConfig in dev-proxy.ps1"
    } else {
        $defaultKeys = @($hashAst.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text })
        $exampleKeys = @((Get-Content $ExamplePath -Raw | ConvertFrom-Json).PSObject.Properties.Name)
        $missing = @($defaultKeys | Where-Object { $_ -notin $exampleKeys })
        $extra = @($exampleKeys | Where-Object { $_ -notin $defaultKeys })
        $detail = @()
        if ($missing) { $detail += "missing: $($missing -join ', ')" }
        if ($extra) { $detail += "unexpected: $($extra -join ', ')" }
        Add-Check "config.example.json matches Get-DefaultConfig" (($missing.Count + $extra.Count) -eq 0) ($detail -join "; ")
    }
} catch {
    Add-Check "config.example.json matches Get-DefaultConfig" $false $_.Exception.Message
}

$hasWsl = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
if ($hasWsl) {
    # Hand the template to bash over stdin rather than translating its path.
    # A path-based check needs the checkout to be reachable from inside WSL,
    # which depends on where it was cloned and on how drives are mounted; the
    # file content is always available on this side.
    $templateText = ((Get-Content $TemplatePath -Raw) -replace "`r`n", "`n") -replace "`r", "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($templateText))
    $syntax = & wsl.exe -- bash -c "printf '%s' '$encoded' | base64 -d | bash -n" 2>&1
    Add-Check "bash -n templates/wsl-proxy-env.sh" ($LASTEXITCODE -eq 0) (@($syntax | ForEach-Object { "$_" }) -join " ")
} else {
    Add-Result -Name "WSL template syntax" -Status "SKIP" -Detail "wsl.exe not found"
}

if ((Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $ScriptRoot ".git"))) {
    $ignored = & git -C $ScriptRoot check-ignore config.json 2>$null
    Add-Check "config.json is untracked and ignored" ([bool]$ignored)
    $dirty = (& git -C $ScriptRoot status --porcelain | Out-String).Trim()
    Add-Result -Name "working tree state" -Status "INFO" -Detail $(if ($dirty) { "$(@($dirty -split "`n").Count) changed file(s)" } else { "clean" })
}

Write-Section "2. Dry run"

$configSource = if (Test-Path $ConfigPath) { $ConfigPath } else { $ExamplePath }
$config = Get-Content $configSource -Raw | ConvertFrom-Json
$expectedOverride = Get-ExpectedProxyOverride $config.noProxy

$dry = Invoke-DevProxy @("-NonInteractive", "-DryRun")
Add-Check "dry run completes" ($dry.ExitCode -eq 0) "exit $($dry.ExitCode)"
Add-Check "bypass list derives from noProxy" ($dry.Text.Contains("(bypass: $expectedOverride)")) "expected $expectedOverride"

$envWrites = @($dry.Output | Where-Object { $_ -match "would set user env" }).Count
Add-Check "writes all 8 proxy env vars" ($envWrites -eq 8) "$envWrites of 8"

$badPort = Invoke-DevProxy @("-NonInteractive", "-DryRun", "-ProxyPort", "99999")
Add-Check "rejects an out-of-range port" ([bool]($badPort.Text -match "is not in 1-65535"))

if (-not $Full) {
    # No section header here; the summary below is the only one.
    Write-Host ""
    Write-Host "Read-only checks only. Re-run with -Full to cover apply, verification exit codes, WSL helpers, and rollback." -ForegroundColor DarkCyan
} else {
    if (-not $Distro -and (Test-Path $ConfigPath)) {
        $Distro = (Get-Content $ConfigPath -Raw | ConvertFrom-Json).distro
    }

    $expectMirrored = [bool]$config.enableWslMirrored

    if (-not $Force) {
        Write-Host ""
        Write-Host "The remaining checks apply the proxy, roll it back, and apply it again." -ForegroundColor Yellow
        Write-Host "Your local proxy client should be listening before you continue." -ForegroundColor Yellow
        $answer = Read-Host "Continue? [y/N]"
        if ("$answer".Trim().ToLowerInvariant() -notin @("y", "yes")) {
            Add-Result -Name "state-changing checks" -Status "SKIP" -Detail "declined at the prompt"
            $Full = $false
        }
    }

    if ($Full -and -not $Distro) {
        Add-Result -Name "state-changing checks" -Status "SKIP" -Detail "no WSL distro selected; pass -Distro"
        $Full = $false
    }

    if ($Full) {
        Write-Section "3. Apply and idempotence"

        $applyArgs = @("-NonInteractive", "-Distro", $Distro)

        $first = Invoke-DevProxy $applyArgs
        Add-Check "apply and verify" ($first.ExitCode -eq 0) "exit $($first.ExitCode)"

        # Take the baseline after the first apply. That run may legitimately
        # create .wslconfig or save a distro; idempotence is a property of the
        # second run, not of the first.
        $configBefore = if (Test-Path $ConfigPath) { (Get-Item $ConfigPath).LastWriteTimeUtc } else { $null }
        $backupsBefore = Get-WslConfigBackupCount

        $second = Invoke-DevProxy $applyArgs
        Add-Check "second apply verifies too" ($second.ExitCode -eq 0) "exit $($second.ExitCode)"
        if ($expectMirrored) {
            Add-Check ".wslconfig left unchanged on repeat" ([bool]($second.Text -match "already has mirrored networking"))
        } else {
            Add-Result -Name ".wslconfig repeat check" -Status "SKIP" -Detail "enableWslMirrored is disabled"
        }
        Add-Check "no extra .wslconfig backup" ((Get-WslConfigBackupCount) -eq $backupsBefore) "$backupsBefore before"
        if ($configBefore) {
            Add-Check "config.json not rewritten" ((Get-Item $ConfigPath).LastWriteTimeUtc -eq $configBefore)
        }

        Write-Section "4. Windows state"

        $reg = Get-ItemProperty $InternetSettingsPath
        Add-Check "system proxy enabled" ($reg.ProxyEnable -eq 1) "$($reg.ProxyServer)"
        Add-Check "bypass list applied" ("$($reg.ProxyOverride)" -eq $expectedOverride) "$($reg.ProxyOverride)"
        $unset = @($ProxyEnvNames | Where-Object { [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_, "User")) })
        Add-Check "all proxy env names resolve" ($unset.Count -eq 0) $(if ($unset) { "unset: $($unset -join ', ')" } else { "" })
        $stored = @((Get-Item "HKCU:\Environment").Property | Where-Object { $_ -match "proxy" })
        Add-Result -Name "env names stored in registry" -Status "INFO" -Detail "$($stored.Count) ($($stored -join ', ')) -- Windows env names are case-insensitive, so the 8 writes collapse to 4 values"

        Write-Section "5. Verification exit codes"

        $healthy = Invoke-DevProxy @("-Verify")
        Add-Check "verification exits 0 when healthy" ($healthy.ExitCode -eq 0) "exit $($healthy.ExitCode)"

        $deadPort = Get-UnusedPort
        $configBefore = (Get-Item $ConfigPath).LastWriteTimeUtc
        $unhealthy = Invoke-DevProxy @("-Verify", "-ProxyPort", "$deadPort")
        Add-Check "verification exits 1 on failure" ($unhealthy.ExitCode -eq 1) "port $deadPort, exit $($unhealthy.ExitCode)"
        Add-Check "-Verify does not write config.json" ((Get-Item $ConfigPath).LastWriteTimeUtc -eq $configBefore)

        # Regression guard: a WSL call that never ran used to leave verification
        # reporting no failures at all. -Verify does not save config.json, so
        # naming a distro that does not exist changes nothing.
        $noDistro = Invoke-DevProxy @("-Verify", "-Distro", "dev-proxy-validation-no-such-distro")
        Add-Check "verification fails when WSL cannot run" ($noDistro.ExitCode -eq 1) "exit $($noDistro.ExitCode)"
        Add-Check "WSL failure is reported, not skipped" ([bool]($noDistro.Text -match "WSL checks did not run"))

        Write-Section "6. WSL helpers"

        $statusLines = Invoke-WslScript $Distro "proxy_status`necho ---`nproxy_off`nproxy_status"
        $marker = [array]::IndexOf($statusLines, "---")
        $before = if ($marker -gt 0) { @($statusLines[0..($marker - 1)]) } else { @($statusLines) }
        $after = if ($marker -ge 0 -and $marker -lt ($statusLines.Count - 1)) { @($statusLines[($marker + 1)..($statusLines.Count - 1)]) } else { @() }

        $resolvedHost = ("$($before | Where-Object { $_ -like 'DEV_PROXY_HOST=*' } | Select-Object -First 1)" -replace "^DEV_PROXY_HOST=", "")
        $source = ("$($before | Where-Object { $_ -like 'DEV_PROXY_HOST_SOURCE=*' } | Select-Object -First 1)" -replace "^DEV_PROXY_HOST_SOURCE=", "")
        $consistent = switch ($source) {
            "mirrored-localhost" { $resolvedHost -eq "127.0.0.1" }
            "nat-gateway" { $resolvedHost -and $resolvedHost -ne "127.0.0.1" -and $resolvedHost -ne "<unresolved>" }
            "override" { $resolvedHost -and $resolvedHost -ne "<unresolved>" }
            "unresolved" { $resolvedHost -eq "<unresolved>" }
            default { $false }
        }
        Add-Check "host source agrees with resolved host" ([bool]$consistent) "$source / $resolvedHost"
        Add-Check "proxy_tcp reports reachable" ($before -contains "proxy_tcp=reachable") ($before | Where-Object { $_ -like "proxy_tcp=*" })
        Add-Check "proxy_off clears the environment" (($after -contains "HTTP_PROXY=<unset>") -and ($after -contains "DEV_PROXY_HOST_SOURCE=<unresolved>"))

        if ($SkipRollback) {
            Add-Result -Name "rollback checks" -Status "SKIP" -Detail "-SkipRollback"
        } else {
            Write-Section "7. Rollback and restore"

            $profileBackupsBefore = [int](Invoke-WslScript $Distro 'ls "$HOME"/.profile.dev-proxy.bak.* 2>/dev/null | wc -l' | Select-Object -Last 1)

            $rollback = Invoke-DevProxy @("-Disable", "-NonInteractive")
            Add-Check "rollback runs" ($rollback.ExitCode -eq 0) "exit $($rollback.ExitCode)"
            $reg = Get-ItemProperty $InternetSettingsPath
            Add-Check "rollback disables system proxy" ($reg.ProxyEnable -eq 0)
            Add-Check "rollback clears user env" ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable("HTTP_PROXY", "User")))

            $again = Invoke-DevProxy @("-Disable", "-NonInteractive")
            Add-Check "second rollback is a no-op" ([bool]($again.Text -match "already disabled"))
            $profileBackupsAfter = [int](Invoke-WslScript $Distro 'ls "$HOME"/.profile.dev-proxy.bak.* 2>/dev/null | wc -l' | Select-Object -Last 1)
            Add-Check "no extra ~/.profile backup" ($profileBackupsAfter -eq ($profileBackupsBefore + 1)) "$profileBackupsBefore -> $profileBackupsAfter"

            $restore = Invoke-DevProxy $applyArgs
            Add-Check "restore succeeds" ($restore.ExitCode -eq 0) "exit $($restore.ExitCode)"
            $activeLines = [int](Invoke-WslScript $Distro 'grep -cxF ''source "$HOME/.config/dev-proxy/proxy-env.sh"'' "$HOME/.profile"' | Select-Object -Last 1)
            Add-Check "profile has exactly one active source line" ($activeLines -eq 1) "found $activeLines"
        }
    }
}

Write-Section "Summary"

$passed = @($script:Results | Where-Object { $_.Status -eq "PASS" }).Count
$failed = @($script:Results | Where-Object { $_.Status -eq "FAIL" })
$skipped = @($script:Results | Where-Object { $_.Status -eq "SKIP" }).Count

Write-Host ("{0} passed, {1} failed, {2} skipped" -f $passed, $failed.Count, $skipped)
foreach ($item in $failed) {
    Write-Host ("  FAIL  {0}{1}" -f $item.Name, $(if ($item.Detail) { "  --  $($item.Detail)" } else { "" })) -ForegroundColor Red
}

exit ([int]($failed.Count -gt 0))
