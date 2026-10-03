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
function Invoke-Fixture([string]$Command) {
    $normalized = ($Command -replace "`r`n", "`n") -replace "`r", "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    $runner = "export HOME='$script:FixtureHome'; LC_ALL=C sed '1s/^\xEF\xBB\xBF//' | tr -d '\r\n' | base64 -d | bash"
    $oldPreference = $ErrorActionPreference
    $oldOutputEncoding = $OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        $OutputEncoding = New-Object Text.ASCIIEncoding
        $raw = $encoded | & wsl.exe -- bash -c $runner 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
        $OutputEncoding = $oldOutputEncoding
    }
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
    if ($script:FixturePathPrefix) {
        $Command = "PATH='$script:FixturePathPrefix':`$PATH`n$Command"
    }
    $script:LastFixtureResult = Invoke-Fixture $Command
    return $script:LastFixtureResult
}

function Get-FixtureCount([string]$Expression) {
    $result = Invoke-Fixture $Expression
    return [int]((@($result.Lines) | Select-Object -Last 1) -join '').Trim()
}

try {
    $setup = Invoke-Fixture 'mkdir -p "$HOME/.config/dev-proxy"; printf "user-line\n" > "$HOME/profile-target"; ln -s "$HOME/profile-target" "$HOME/.profile"'
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
    $sourceLine = '. "$HOME/.config/dev-proxy/proxy-env.sh"'
    $firstSources = Get-FixtureCount "grep -cxF '$sourceLine' $profile || true"
    $firstBackups = Get-FixtureCount 'find "$HOME" -maxdepth 1 -name ''.profile.dev-proxy.bak.*'' | wc -l'
    Assert-True ($firstSources -eq 1) 'first install enables one source line'
    Assert-True ($firstBackups -eq 1) 'first install creates one profile backup'
    Assert-True ((Get-FixtureCount 'if [ -L "$HOME/.profile" ]; then echo 1; else echo 0; fi') -eq 1) 'install preserves a symlinked profile'

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
    Assert-True ((Get-FixtureCount 'if [ -L "$HOME/.profile" ]; then echo 1; else echo 0; fi') -eq 1) 'rollback preserves a symlinked profile'
    $afterDisableBackups = Get-FixtureCount 'find "$HOME" -maxdepth 1 -name ''.profile.dev-proxy.bak.*'' | wc -l'

    [void](Disable-WslProxyEnv $config)
    $disableAgain = $script:LastFixtureResult
    Assert-Contains $disableAgain.Lines 'disable-complete:already-disabled' 'repeat rollback is idempotent'
    Assert-Contains $disableAgain.Lines 'legacy-relay-preserved' 'repeat rollback still reports legacy PID'
    Assert-True ((Get-FixtureCount 'find "$HOME" -maxdepth 1 -name ''.profile.dev-proxy.bak.*'' | wc -l') -eq $afterDisableBackups) 'repeat rollback adds no backup'

    # Verification must treat disabled state as failure and must not source the
    # installed env file (which could otherwise restart the relay it just stopped).
    function Get-ItemProperty { [pscustomobject]@{ ProxyEnable = 0; ProxyServer = '' } }
    function Test-TcpPort { return $true }
    function Test-UrlViaProxy { return @{ ok = $true; status = 404; error = $null } }
    function Show-WinHttpProxy { }
    $beforeVerifyFailures = $script:VerifyFailures
    Verify-All $config
    Assert-True ($script:VerifyFailures -gt $beforeVerifyFailures) 'verification fails after rollback'
    Assert-Contains $script:LastFixtureResult.Lines 'WSL_PROFILE_INACTIVE' 'verification detects the disabled profile hook'
    Assert-True ((Get-FixtureCount "if [ -f `"`$HOME/.config/dev-proxy/interop-$interopPort-$token/pid`" ]; then echo 1; else echo 0; fi") -eq 0) 'verification after rollback does not restart the managed relay'

    Install-WslProxyEnv $config
    Assert-True ((Get-FixtureCount "grep -cxF '$sourceLine' $profile || true") -eq 1) 'reinstall re-enables one source line'
    Assert-True ((Get-FixtureCount "grep -cF '# disabled by dev-proxy: $sourceLine' $profile || true") -eq 0) 'reinstall removes the disabled copy'

    [void](Invoke-Fixture 'printf "echo login-profile-bypass\n" > "$HOME/.bash_profile"')
    Verify-All $config
    Assert-True ([bool]($script:LastFixtureResult.Lines -match '^WSL_PROFILE_BYPASSED path=')) 'verification detects a Bash login profile that bypasses ~/.profile'
    [void](Invoke-Fixture 'rm -f "$HOME/.bash_profile"')

    # An unavailable optional IPv6 fallback must not block installation of the
    # direct mirrored or NAT paths.
    $fakeBin = "$script:FixtureHome/fake-bin"
    [void](Invoke-Fixture "mkdir -p '$fakeBin'; printf '#!/bin/sh\nprintf `"install-warning: simulated IPv6 unavailability\\n`" >&2\nexit 2\n' > '$fakeBin/python3'; chmod 700 '$fakeBin/python3'")
    $script:FixturePathPrefix = $fakeBin
    Install-WslProxyEnv $config
    $script:FixturePathPrefix = $null
    Assert-True (!$script:LastFixtureResult.Failed) 'missing IPv6 fallback capability does not abort installation'
    Assert-True ((Get-FixtureCount "grep -cxF `"DEV_PROXY_INTEROP_AVAILABLE='false'`" `"`$HOME/.config/dev-proxy/proxy-env.sh`"") -eq 1) 'installed profile records unavailable interop fallback'
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
}
