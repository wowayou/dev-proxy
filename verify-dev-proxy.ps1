$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $ScriptRoot "dev-proxy.ps1") -Verify @args
