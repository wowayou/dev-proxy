$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'dev-proxy.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'dev-proxy.ps1 parse failed' }
$script:ScriptRoot = $repo
$script:TemplatePath = Join-Path $repo 'templates\wsl-proxy-env.sh'
$script:InteropTemplatePath = Join-Path $repo 'templates\wsl-interop-proxy.py'
$script:DefaultWslInteropPort = 20180
$script:DefaultProxyPort = 20122
$script:WslInteropPort = $script:DefaultWslInteropPort
$script:WindowsRelayImplementationVersion = '3'
$script:DryRun = $false
$script:VerifyFailures = 0
$script:HadFailures = $false
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}

$script:FixtureHome = "/tmp/dev-proxy-temp-relay-$([guid]::NewGuid().ToString('N'))"
$script:CommandFileWindows = Join-Path $repo ".tmp-temp-relay-$([guid]::NewGuid().ToString('N')).b64"
$drive = $script:CommandFileWindows.Substring(0, 1).ToLowerInvariant()
$rest = $script:CommandFileWindows.Substring(2).Replace('\', '/')
$script:CommandFileWsl = "/mnt/$drive$rest"
function Invoke-Fixture([string]$Command) {
    $normalized = ($Command -replace "`r`n", "`n") -replace "`r", "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    [IO.File]::WriteAllText($script:CommandFileWindows, $encoded, (New-Object Text.UTF8Encoding($false)))
    $runner = "export HOME='$script:FixtureHome'; base64 -d < '$script:CommandFileWsl' | bash"
    $raw = & wsl.exe -- bash --noprofile --norc -c $runner 2>&1
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{ ExitCode = $exitCode; Failed = ($exitCode -ne 0); TimedOut = ($exitCode -eq 124); Lines = @($raw | ForEach-Object { "$_" }) }
}
function Invoke-WslBash {
    param([string]$Distro, [string]$Command, [int]$TimeoutSec = 45)
    $script:LastResult = Invoke-Fixture $Command
    return $script:LastResult
}
function Assert-True([bool]$ok, [string]$message) { if (!$ok) { throw "ASSERTION FAILED: $message" } }

try {
    [void](Invoke-Fixture 'mkdir -p "$HOME/.config/dev-proxy"')
    $portResult = Invoke-Fixture "python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind((`"::1`",0)); print(s.getsockname()[1]); s.close()'"
    $interopPort = [int]((@($portResult.Lines) | Select-Object -Last 1) -join '').Trim()
    $script:WslInteropPort = $interopPort
    $config = [pscustomobject]@{ proxyScheme='http'; proxyHost='127.0.0.1'; proxyPort=20122; noProxy='localhost,127.0.0.1,::1,.local'; distro='fixture'; enableWslMirrored=$true; enableWslInteropFallback=$true; wslInteropPort=$interopPort }
    Install-WslProxyEnv $config
    Assert-True (!$script:LastResult.Failed) 'temporary relay profile installation succeeds'
    # This is specifically the relay integration test. Remove direct candidates
    # only from the isolated generated profile so a currently healthy mirrored
    # localhost path cannot bypass the relay under test.
    $rewrite = Invoke-Fixture "sed -i `"s|^DEV_PROXY_MIRRORED_HOSTS_DEFAULT=.*|DEV_PROXY_MIRRORED_HOSTS_DEFAULT=''|`" `"`$HOME/.config/dev-proxy/proxy-env.sh`""
    Assert-True (!$rewrite.Failed) 'temporary profile forces the fallback path'
    $probeCommand = @'
. "$HOME/.config/dev-proxy/proxy-env.sh" || true
printf 'HTTP_PROXY=%s\n' "$HTTP_PROXY"
printf 'DEV_PROXY_HOST_SOURCE=%s\n' "$DEV_PROXY_HOST_SOURCE"
curl --noproxy '' -sS -o /dev/null -X GET --connect-timeout 5 --max-time 20 --proxy "$HTTP_PROXY" -w 'ANTHROPIC_HTTP=%{http_code}\n' https://api.anthropic.com
'@
    $probe = Invoke-Fixture $probeCommand
    $probe.Lines | ForEach-Object { Write-Output $_ }
    $http = @($probe.Lines | Where-Object { $_ -match '^ANTHROPIC_HTTP=' } | Select-Object -Last 1)
    Assert-True ($probe.Lines -contains 'DEV_PROXY_HOST_SOURCE=mirrored-interop') 'temporary probe uses the interop fallback'
    Assert-True (!$probe.Failed -and $http -match '^ANTHROPIC_HTTP=404$') 'temporary relay reaches Anthropic with HTTP 404'
    Write-Output 'PASS test_temp_relay_http.ps1'
}
finally {
    if ($script:FixtureHome -match '^/tmp/dev-proxy-temp-relay-[0-9a-f]{32}$') {
        $cleanup = @'
base="$HOME/.config/dev-proxy"
for state in "$base"/interop-*-*; do
  [ -f "$state/pid" ] || continue
  pid=$(cat "$state/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) continue;; esac
  kill "$pid" 2>/dev/null || true
done
'@
        [void](Invoke-Fixture $cleanup)
        [void](Invoke-Fixture "rm -rf -- '$script:FixtureHome'")
    }
    if (Test-Path -LiteralPath $script:CommandFileWindows) { Remove-Item -LiteralPath $script:CommandFileWindows -Force -ErrorAction SilentlyContinue }
}
