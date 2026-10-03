param([string]$Distro)

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $OutputEncoding = New-Object Text.ASCIIEncoding
} catch {
}
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'dev-proxy.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'dev-proxy.ps1 parse failed' }
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}

function Assert-True([bool]$ok, [string]$message) {
    if (!$ok) { throw "ASSERTION FAILED: $message" }
}

if ([string]::IsNullOrWhiteSpace($Distro)) {
    $configPath = Join-Path $repo 'config.json'
    if (Test-Path -LiteralPath $configPath) {
        $Distro = "$((Get-Content $configPath -Raw | ConvertFrom-Json).distro)".Trim()
    }
}
if ([string]::IsNullOrWhiteSpace($Distro)) { throw 'Pass -Distro or set distro in config.json for transport tests.' }

$payloadBytes = [Text.Encoding]::UTF8.GetBytes('test')
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $payloadSha = (([BitConverter]::ToString($sha.ComputeHash($payloadBytes))) -replace '-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

foreach ($case in @(
    @{ Name = 'missing payload'; Input = '' },
    @{ Name = 'invalid base64 payload'; Input = 'not-base64!' },
    @{ Name = 'corrupt valid payload'; Input = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('fail')) }
)) {
    $marker = "DEV_PROXY_WSL_COMPLETE_$([guid]::NewGuid().ToString('N'))"
    $runner = New-WslPayloadRunner -TimeoutSec 5 -ExpectedBytes $payloadBytes.Length -ExpectedSha256 $payloadSha -CompletionMarker $marker
    $bootstrap = New-WslRunnerBootstrap $runner
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = $case.Input | & wsl.exe -d $Distro -- bash -c $bootstrap 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $result = ConvertTo-WslCommandResult -Raw $raw -ExitCode $exitCode -CompletionMarker $marker
    Assert-True $result.Failed "$($case.Name) fails"
    Assert-True (!$result.Completed) "$($case.Name) has no completion marker"
    Assert-True ($result.ExitCode -ne 0) "$($case.Name) exits non-zero"
}

$missingMarker = ConvertTo-WslCommandResult -Raw @('payload-ran') -ExitCode 0 -CompletionMarker 'DEV_PROXY_WSL_COMPLETE_missing'
Assert-True $missingMarker.Failed 'exit zero without a completion marker fails'
Assert-True ((Get-WslFailureReason $missingMarker) -match 'completion marker') 'missing marker has an explicit failure reason'

$quotedPath = "/tmp/dev proxy 'quoted' $([guid]::NewGuid().ToString('N'))"
$quotedCommand = @"
path='$($quotedPath.Replace("'", "'\''"))'
trap 'rm -f "`$path"' EXIT
printf 'payload-ok' > "`$path"
test "`$(cat "`$path")" = 'payload-ok'
printf 'PATH_OK\n'
"@
$quotedResult = Invoke-WslBash -Distro $Distro -Command $quotedCommand -TimeoutSec 5
if ($quotedResult.Failed) {
    Write-Output ("quoted-path diagnostics: exit={0} timedOut={1} completed={2} lines={3}" -f $quotedResult.ExitCode, $quotedResult.TimedOut, $quotedResult.Completed, ($quotedResult.Lines -join ' | '))
}
Assert-True (!$quotedResult.Failed -and $quotedResult.Completed) 'payload with a path containing spaces and a single quote completes'
Assert-True ($quotedResult.Lines -contains 'PATH_OK') 'quoted-path payload actually ran'

$timeoutResult = Invoke-WslBash -Distro $Distro -Command 'sleep 3' -TimeoutSec 1
Assert-True ($timeoutResult.Failed -and $timeoutResult.TimedOut) 'execution timeout fails with timeout status'
Assert-True (!$timeoutResult.Completed) 'timed-out execution has no completion marker'

Write-Output 'PASS test_wsl_transport_review.ps1'
