$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'dev-proxy.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'dev-proxy.ps1 parse failed' }

$script:ScriptRoot = $repo
$script:TemplatePath = Join-Path $repo 'templates\wsl-proxy-env.sh'
$script:InteropTemplatePath = Join-Path $repo 'templates\wsl-interop-proxy.py'
$script:DefaultWslInteropPort = 20180
$script:DefaultProxyPort = 20122
$script:WslInteropPort = 20180
$script:WindowsRelayImplementationVersion = '3'
$script:DryRun = $false
$script:VerifyFailures = 0
$script:HadFailures = $false

foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}

function Assert-True([bool]$ok, [string]$message) {
    if (!$ok) { throw "ASSERTION FAILED: $message" }
}
function Assert-Contains([string[]]$lines, [string]$needle, [string]$message) {
    Assert-True (@($lines | Where-Object { $_ -eq $needle }).Count -gt 0) "$message (missing '$needle')"
}
function Get-LastLine([object]$result, [string]$prefix) {
    return @($result.Lines | Where-Object { $_ -like "$prefix*" } | Select-Object -Last 1)
}

$script:FixtureHome = "/tmp/dev-proxy-install-review-$([guid]::NewGuid().ToString('N'))"
$script:CommandFileWindows = Join-Path $repo ".tmp-wsl-install-review-$([guid]::NewGuid().ToString('N')).b64"
$drive = $script:CommandFileWindows.Substring(0, 1).ToLowerInvariant()
$rest = ($script:CommandFileWindows.Substring(2) -replace '\\', '/')
$script:CommandFileWsl = "/mnt/$drive$rest"
function Invoke-Fixture([string]$Command) {
    $normalized = ($Command -replace "`r`n", "`n") -replace "`r", "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    [IO.File]::WriteAllText($script:CommandFileWindows, $encoded, (New-Object Text.UTF8Encoding($false)))
    $runner = "export HOME='$script:FixtureHome'; base64 -d < '$script:CommandFileWsl' | bash"
    $raw = & wsl.exe -- bash -c $runner 2>&1
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $exitCode
        Failed = ($exitCode -ne 0)
        TimedOut = ($exitCode -eq 124)
        Lines = @($raw | ForEach-Object { "$_" })
    }
}

# Generated install/disable commands use this override; no command is sent to
# a named distro and HOME is always the isolated fixture directory.
function Invoke-WslBash {
    param([string]$Distro, [string]$Command, [int]$TimeoutSec = 45)
    $script:LastFixtureResult = Invoke-Fixture $Command
    return $script:LastFixtureResult
}

function Get-FixtureCount([string]$Expression) {
    $result = Invoke-Fixture $Expression
    return [int]((@($result.Lines) | Select-Object -Last 1) -join '').Trim()
}

try {
    $setup = Invoke-Fixture 'mkdir -p "$HOME/.config/dev-proxy"'
    Assert-True (!$setup.Failed) 'fixture HOME setup succeeds'
    $portResult = Invoke-Fixture "python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind((`"::1`",0)); print(s.getsockname()[1]); s.close()'"
    $proxyPort = [int]((@($portResult.Lines) | Select-Object -Last 1) -join '').Trim()
    $interopResult = Invoke-Fixture "python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind((`"::1`",0)); print(s.getsockname()[1]); s.close()'"
    $interopPort = [int]((@($interopResult.Lines) | Select-Object -Last 1) -join '').Trim()

    $config = [pscustomobject]@{
        proxyScheme = 'http'
        proxyHost = '127.0.0.1'
        proxyPort = $proxyPort
        noProxy = 'localhost,127.0.0.1,.local'
        distro = 'fixture'
        enableWslMirrored = $true
        enableWslInteropFallback = $true
        wslInteropPort = $interopPort
    }
    $script:WslInteropPort = $interopPort

    Install-WslProxyEnv $config
    $profile = '$HOME/.profile'
    $sourceLine = 'source "$HOME/.config/dev-proxy/proxy-env.sh"'
    $firstSources = Get-FixtureCount "grep -cxF '$sourceLine' $profile || true"
    $firstBackups = Get-FixtureCount 'find "$HOME" -maxdepth 1 -name ''.profile.dev-proxy.bak.*'' | wc -l'
    Assert-True ($firstSources -eq 1) 'first install enables one source line'
    Assert-True ($firstBackups -eq 1) 'first install creates one profile backup'

    Install-WslProxyEnv $config
    Assert-True ((Get-FixtureCount "grep -cxF '$sourceLine' $profile || true") -eq 1) 'repeat install keeps one source line'
    Assert-True ((Get-FixtureCount 'find "$HOME" -maxdepth 1 -name ''.profile.dev-proxy.bak.*'' | wc -l') -eq $firstBackups) 'repeat install adds no backup'
    $fakeRuntime = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("import time`ntime.sleep(30)`n"))
    $fakeRuntimePath = "$script:FixtureHome/.config/dev-proxy/interop-proxy.py"
    [void](Invoke-Fixture "printf '%s' '$fakeRuntime' | base64 -d > '$fakeRuntimePath'; chmod 700 '$fakeRuntimePath'")

    $token = Get-InteropIdentityToken $config
    $oldStateCommand = @"
base="`$HOME/.config/dev-proxy"
state="`$base/interop-$interopPort-$token"
mkdir -p "`$state"
nohup python3 "`$base/interop-proxy.py" "$token" </dev/null >"`$HOME/old-relay.log" 2>&1 &
pid=`$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -r "/proc/`$pid/stat" ] && break; sleep 0.05; done
printf 'OLD_PID=%s\n' "`$pid"
printf 'OLD_START=%s\n' "`$(awk '{print `$22}' "/proc/`$pid/stat")"
printf '%s\n' "`$pid" > "`$state/pid"
awk '{print `$22}' "/proc/`$pid/stat" > "`$state/starttime"
"@
    $oldStarted = Invoke-Fixture $oldStateCommand
    $oldPid = [int]((Get-LastLine $oldStarted 'OLD_PID=') -replace '^OLD_PID=', '')
    $oldStart = (Get-LastLine $oldStarted 'OLD_START=') -replace '^OLD_START=', ''

    $foreignToken = ('b' * 64)
    $foreignCommand = @"
state="`$HOME/.config/dev-proxy/interop-$interopPort-$foreignToken"
mkdir -p "`$state"
nohup sleep 120 </dev/null >/dev/null 2>&1 &
pid=`$!
printf 'FOREIGN_PID=%s\n' "`$pid"
printf 'FOREIGN_START=%s\n' "`$(awk '{print `$22}' "/proc/`$pid/stat")"
printf '%s\n' "`$pid" > "`$state/pid"
awk '{print `$22}' "/proc/`$pid/stat" > "`$state/starttime"
"@
    $foreignStarted = Invoke-Fixture $foreignCommand
    $foreignPid = [int]((Get-LastLine $foreignStarted 'FOREIGN_PID=') -replace '^FOREIGN_PID=', '')
    $foreignStart = (Get-LastLine $foreignStarted 'FOREIGN_START=') -replace '^FOREIGN_START=', ''
    [void](Invoke-Fixture 'printf ''1187\n'' > "$HOME/.config/dev-proxy/interop-proxy.pid"')

    # Change the desired target and relay port before rollback. Disable must
    # use installed private state, not derive identity from this new config.
    $config.proxyPort = $proxyPort + 1
    $script:WslInteropPort = $interopPort + 1
    [void](Disable-WslProxyEnv $config)
    $disable = $script:LastFixtureResult
    Assert-Contains $disable.Lines 'legacy-relay-preserved' 'rollback reports preserved legacy PID'
    Assert-Contains $disable.Lines 'disable-complete:disabled' 'rollback reports an explicit completion marker'
    Assert-True ((Get-FixtureCount "if kill -0 $oldPid 2>/dev/null; then echo 1; else echo 0; fi") -eq 0) 'rollback stops installed old generation'
    Assert-True ((Get-FixtureCount "if kill -0 $foreignPid 2>/dev/null; then echo 0; else echo 1; fi") -eq 0) 'rollback preserves foreign relay'
    Assert-True ((Get-FixtureCount "grep -cF '# disabled by dev-proxy: $sourceLine' $profile || true") -eq 1) 'rollback comments source exactly once'
    $afterDisableBackups = Get-FixtureCount 'find "$HOME" -maxdepth 1 -name ''.profile.dev-proxy.bak.*'' | wc -l'

    [void](Disable-WslProxyEnv $config)
    $disableAgain = $script:LastFixtureResult
    Assert-Contains $disableAgain.Lines 'disable-complete:already-disabled' 'repeat rollback is idempotent'
    Assert-Contains $disableAgain.Lines 'legacy-relay-preserved' 'repeat rollback still reports legacy PID'
    Assert-True ((Get-FixtureCount 'find "$HOME" -maxdepth 1 -name ''.profile.dev-proxy.bak.*'' | wc -l') -eq $afterDisableBackups) 'repeat rollback adds no backup'

    Install-WslProxyEnv $config
    Assert-True ((Get-FixtureCount "grep -cxF '$sourceLine' $profile || true") -eq 1) 'reinstall re-enables one source line'
    Assert-True ((Get-FixtureCount "grep -cF '# disabled by dev-proxy: $sourceLine' $profile || true") -eq 0) 'reinstall removes the disabled copy'
    Write-Output 'PASS test_wsl_install_review.ps1'
}
finally {
    if ($script:FixtureHome -match '^/tmp/dev-proxy-install-review-[0-9a-f]{32}$') {
        if ($oldPid -and $oldPid -match '^[0-9]+$') {
            [void](Invoke-Fixture ('if [ "$(awk ''{print $22}'' "/proc/' + $oldPid + '/stat" 2>/dev/null)" = "' + $oldStart + '" ]; then kill ' + $oldPid + ' 2>/dev/null || true; fi'))
        }
        if ($foreignPid -and $foreignPid -match '^[0-9]+$') {
            [void](Invoke-Fixture ('if [ "$(awk ''{print $22}'' "/proc/' + $foreignPid + '/stat" 2>/dev/null)" = "' + $foreignStart + '" ]; then kill ' + $foreignPid + ' 2>/dev/null || true; fi'))
        }
        [void](Invoke-Fixture "rm -rf -- '$script:FixtureHome'")
    }
    if (Test-Path -LiteralPath $script:CommandFileWindows) { Remove-Item -LiteralPath $script:CommandFileWindows -Force -ErrorAction SilentlyContinue }
}
