$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $ScriptRoot "dev-proxy.ps1") -Verify @args
# 'exit' inside the called script only sets $LASTEXITCODE, so pass it on.
exit ([int]$LASTEXITCODE)
