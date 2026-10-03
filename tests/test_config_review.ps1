$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'dev-proxy.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw "dev-proxy.ps1 parse failed" }
$script:ScriptRoot = $repo
$script:ConfigPath = Join-Path $repo 'config.json'
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
function Assert-True([bool]$ok, [string]$msg) { if (!$ok) { throw "ASSERTION FAILED: $msg" } }
function Assert-Equal($actual, $expected, [string]$msg) {
    if ([string]$actual -cne [string]$expected) { throw "ASSERTION FAILED: $msg (actual='$actual', expected='$expected')" }
}
function Assert-Contains([string]$text, [string]$needle, [string]$msg) { Assert-True $text.Contains($needle) "$msg (missing '$needle')" }
function New-Fixture { Join-Path ([IO.Path]::GetTempPath()) ('dev-proxy-review-' + [guid]::NewGuid().ToString('N')) }
$fixture = New-Fixture
New-Item -ItemType Directory -Path $fixture | Out-Null
$oldConfigPath = $script:ConfigPath
$oldUserProfile = $env:USERPROFILE
try {
    $script:ConfigPath = Join-Path $fixture 'config.json'
    $example = Get-Content (Join-Path $repo 'config.example.json') -Raw | ConvertFrom-Json
    $defaults = Get-DefaultConfig
    foreach ($name in 'proxyHost','proxyPort','proxyScheme','noProxy','distro','enableWslMirrored','enableWslInteropFallback','wslInteropPort') {
        Assert-Equal $defaults.$name $example.$name "default/template field $name"
    }
    foreach ($badPort in 0, -1) {
        @{ proxyHost='127.0.0.1'; proxyPort=$badPort; proxyScheme='http'; noProxy=''; distro=$null; enableWslMirrored=$true; enableWslInteropFallback=$true; wslInteropPort=20180 } |
            ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
        Assert-Equal (Read-Config).proxyPort 20122 "invalid proxy port $badPort falls back"
    }
    $ipv6 = [pscustomobject]@{ proxyScheme='http'; proxyHost='::1'; proxyPort=20122 }
    Assert-Equal (Get-ProxyUrl $ipv6) 'http://[::1]:20122' 'IPv6 URL is bracketed'
    Assert-True ($null -eq (Get-Variable -Name readonlyHost -ErrorAction SilentlyContinue)) 'no readonlyHost variable'
    $danger = "a" + [char]39 + '$()' + [char]96 + 'nline'
    $quoted = ConvertTo-BashSingleQuotedContent $danger
    Assert-Contains $quoted "'\''" 'shell quote escaping marker'
    Assert-Contains $quoted '$()' 'command substitution remains literal'
    $unicodeQuote = [char]0x2019
    $relayDanger = "127.0.0.1${unicodeQuote}+(Write-Output INJECTED)+${unicodeQuote}"
    $relayQuoted = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($relayDanger)
    Assert-True ($relayQuoted -notmatch "(?<!$unicodeQuote)$unicodeQuote(?!$unicodeQuote)") 'PowerShell relay quoting doubles typographic delimiters'

    $config = [pscustomobject]@{ proxyScheme='http'; proxyHost='127.0.0.1'; proxyPort=20122; noProxy='localhost'; enableWslMirrored=$true; enableWslInteropFallback=$true; distro='fixture'; wslInteropPort=20180 }
    $token1 = Get-InteropIdentityToken $config
    $config.proxyPort = 20123
    Assert-True ((Get-InteropIdentityToken $config) -cne $token1) 'generation changes when target changes'
    $config.proxyPort = 20122
    $originalTemplatePath = $script:InteropTemplatePath
    $fixtureTemplatePath = Join-Path $fixture 'interop-proxy.py'
    Copy-Item -LiteralPath $originalTemplatePath -Destination $fixtureTemplatePath
    $script:InteropTemplatePath = $fixtureTemplatePath
    $originalTemplate = Get-Content $script:InteropTemplatePath -Raw
    try {
        Set-Content -LiteralPath $script:InteropTemplatePath -Value ($originalTemplate + [Environment]::NewLine + '# review fixture') -NoNewline
        Assert-True ((Get-InteropIdentityToken $config) -cne $token1) 'generation changes when runtime template changes'
    } finally { $script:InteropTemplatePath = $originalTemplatePath }

    $env:USERPROFILE = $fixture
    $userComment = 'userComment=' + ([char]0x4fdd) + ([char]0x7559)
    $ini = @('[wsl2]','networkingMode=nat','dnsTunneling=false','autoProxy=true','memory=8GB','swap=2GB','','[experimental]','ignoredPorts=80,20180',$userComment)
    $managed = $ini
    foreach ($item in @(@('wsl2','networkingMode','mirrored'),@('wsl2','dnsTunneling','true'),@('wsl2','autoProxy','false'),@('experimental','ignoredPorts','80,20180'))) {
        $managed = Set-ManagedIniValue $managed $item[0] $item[1] $item[2]
    }
    [IO.File]::WriteAllLines((Join-Path $fixture '.wslconfig'), $managed, (New-Object Text.UTF8Encoding($false)))
    $script:WslInteropPort = 20181
    Restore-ManagedWslConfig
    $restored = [IO.File]::ReadAllText((Join-Path $fixture '.wslconfig'), [Text.Encoding]::UTF8)
    foreach ($needle in 'networkingMode=nat','dnsTunneling=false','autoProxy=true','memory=8GB','swap=2GB','ignoredPorts=80,20180',$userComment) {
        Assert-Contains $restored $needle "restore preserved $needle"
    }
    $expectedRestored = @('[wsl2]','networkingMode=nat','dnsTunneling=false','autoProxy=true','memory=8GB','swap=2GB','','[experimental]','ignoredPorts=80,20180',$userComment) -join [Environment]::NewLine
    Assert-Equal $restored.TrimEnd() $expectedRestored 'restore preserves exact fixture line order'
    $restoreSnapshot = $restored
    Restore-ManagedWslConfig
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $fixture '.wslconfig'), [Text.Encoding]::UTF8)) $restoreSnapshot 'second restore is idempotent'
    $created = Set-ManagedIniValue @('[wsl2]','memory=4GB') 'experimental' 'autoProxy' 'false'
    $created += 'user-added-comment'
    [IO.File]::WriteAllLines((Join-Path $fixture '.wslconfig'), $created, (New-Object Text.UTF8Encoding($false)))
    Restore-ManagedWslConfig
    Assert-Contains ([IO.File]::ReadAllText((Join-Path $fixture '.wslconfig'), [Text.Encoding]::UTF8)) 'user-added-comment' 'created section comment retained'
    $corrupt = @('[experimental]','# dev-proxy managed: [experimental] ignoredPorts previous=%%%','ignoredPorts=20181')
    [IO.File]::WriteAllLines((Join-Path $fixture '.wslconfig'), $corrupt, (New-Object Text.UTF8Encoding($false)))
    Restore-ManagedWslConfig
    $corruptRestored = [IO.File]::ReadAllText((Join-Path $fixture '.wslconfig'), [Text.Encoding]::UTF8)
    Assert-Contains $corruptRestored 'previous=%%%' 'corrupt metadata retained'
    Assert-Contains $corruptRestored 'ignoredPorts=20181' 'corrupt value retained'

    $legacyAbsent = @('[experimental]','# dev-proxy managed: [experimental] ignoredPorts previous=<absent>','ignoredPorts=20180')
    [IO.File]::WriteAllLines((Join-Path $fixture '.wslconfig'), $legacyAbsent, (New-Object Text.UTF8Encoding($false)))
    Restore-ManagedWslConfig
    $legacyRestored = [IO.File]::ReadAllText((Join-Path $fixture '.wslconfig'), [Text.Encoding]::UTF8)
    Assert-True ($legacyRestored -notmatch 'ignoredPorts=20180') 'legacy absent 20180 marker is removed during 20181 restore'
    $edited = @('[wsl2]','# dev-proxy managed: [wsl2] autoProxy previous=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('autoProxy=true')),'autoProxy=user-edited')
    [IO.File]::WriteAllLines((Join-Path $fixture '.wslconfig'), $edited, (New-Object Text.UTF8Encoding($false)))
    Restore-ManagedWslConfig
    Assert-Contains ([IO.File]::ReadAllText((Join-Path $fixture '.wslconfig'), [Text.Encoding]::UTF8)) 'autoProxy=user-edited' 'postinstall user edit retained'
    foreach ($conflict in @(@('[wsl2]','autoProxy=true'), @('[wsl2]'))) {
        [IO.File]::WriteAllLines((Join-Path $fixture '.wslconfig'), $conflict, (New-Object Text.UTF8Encoding($false)))
        Configure-WslProxyOwnership
        $owned = [IO.File]::ReadAllText((Join-Path $fixture '.wslconfig'), [Text.Encoding]::UTF8)
        Assert-Contains $owned 'autoProxy=false' 'NAT-mode ownership disables WSL autoProxy'
        Assert-True ($owned -notmatch '(?im)^networkingMode=mirrored\s*$') 'NAT-mode ownership does not enable mirrored networking'
        Restore-ManagedWslConfig
    }
    Remove-Item -LiteralPath (Join-Path $fixture '.wslconfig') -Force
    Configure-WslProxyOwnership
    $createdOwnership = [IO.File]::ReadAllText((Join-Path $fixture '.wslconfig'), [Text.Encoding]::UTF8)
    Assert-Contains $createdOwnership 'autoProxy=false' 'missing .wslconfig is created with explicit proxy ownership'
    Assert-True ($createdOwnership -notmatch '(?im)^networkingMode=mirrored\s*$') 'new NAT-mode config does not enable mirrored networking'
    $config.enableWslMirrored = $false
    $beforeFailures = $script:VerifyFailures
    $script:DryRun = $true
    Install-WslProxyEnv $config
    $script:DryRun = $false
    Assert-Equal $script:VerifyFailures $beforeFailures 'mirrored-disabled dry-run still installs the WSL profile'

    # A zero transport exit without the rollback's own completion marker must
    # never produce an OK result.
    $script:CapturedOk = @()
    function Write-Ok($Message) { $script:CapturedOk += "$Message" }
    function Write-WslOutputLines($Output) { }
    function Invoke-WslBash {
        [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Completed = $true; Failed = $false; Lines = @('legacy-relay-preserved') }
    }
    $config.distro = 'fixture'
    $script:DryRun = $false
    $beforeFailures = $script:VerifyFailures
    Disable-WslProxyEnv $config
    Assert-True ($script:VerifyFailures -gt $beforeFailures) 'rollback without a business completion marker fails'
    Assert-True ($script:CapturedOk.Count -eq 0) 'rollback without a completion marker prints no success'
    Write-Output 'PASS test_config_review.ps1'
} finally {
    $script:ConfigPath = $oldConfigPath
    $env:USERPROFILE = $oldUserProfile
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
