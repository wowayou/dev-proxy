# Dev Proxy Agent Guide

This directory is a standalone ops tool. Keep it decoupled from the `cc-switch` repository.

## Boundaries

- Do not edit CC Switch databases or source files from this tool.
- Do not edit Claude, Codex, OpenCode, or other provider config files.
- Do not read, write, transform, log, or validate API keys.
- Do not add automatic elevation. WinHTTP and `.wslconfig` changes should remain explicit user actions.
- Do not change proxy-client configuration. The tool may tell the user when LAN or non-loopback listening is required.

## Safe Edit Rules

- Keep `dev-proxy.ps1`, `config.example.json`, `templates/wsl-proxy-env.sh`, and local docs self-contained.
- `config.json` is per-machine state and is not tracked. Keep `config.example.json` in step with `Get-DefaultConfig`, and never commit a real `config.json`.
- Preserve `enableWslMirrored` as a visible preference, not a hidden compatibility field.
- Preserve WSL commands: `proxy_status`, `proxy_refresh`, and `proxy_off`.
- Preserve dynamic NAT host detection. Use `DEV_PROXY_HOST_OVERRIDE` only as an intentional fixed-host override.
- Suppress noisy localized `netsh` output and WSL PATH translation warnings in tool output.
- Avoid coupling validation to live provider credentials. HTTP `401`, `403`, or `404` can still be a connectivity pass.

## Mirrored Vs NAT Reasoning

Mirrored networking lets WSL use the Windows proxy listener at `127.0.0.1:<port>`. NAT mode cannot rely on Windows localhost, so the WSL profile falls back to the default-route gateway, often similar to `172.17.0.1`.

When NAT fallback is active, the Windows proxy client must accept non-loopback connections. That usually means LAN access, a `0.0.0.0` listener, and compatible firewall rules.

## Validation Commands

Run from `C:\Users\Public\ops-tools\dev-proxy` in PowerShell unless noted. Steps
1 and 2 change nothing and are the minimum after any edit. Steps 3 to 7 touch
real Windows and WSL state, so run them when the change affects behavior.

Run the suite under Windows PowerShell 5.1 at least once. It is the version the
TLS 1.2 fallback and the BOM-less config writer exist for, and PowerShell 7
formats `config.json` differently.

### 1. Parse And Syntax Checks

Both scripts must parse:

```powershell
foreach ($f in @(".\dev-proxy.ps1", ".\verify-dev-proxy.ps1")) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) { "$f :"; $errors; exit 1 }
}
```

JSON parse check. `config.json` only exists after a first run, so check the tracked template too:

```powershell
Get-Content .\config.example.json -Raw | ConvertFrom-Json | Out-Null
if (Test-Path .\config.json) { Get-Content .\config.json -Raw | ConvertFrom-Json | Out-Null }
```

`config.json` must stay BOM-less. The first byte is `7B`, not `EF`:

```powershell
if (Test-Path .\config.json) { '{0:X2}' -f [IO.File]::ReadAllBytes((Resolve-Path .\config.json))[0] }
```

WSL template syntax check:

```powershell
wsl.exe -- bash -lc "bash -n /mnt/c/Users/Public/ops-tools/dev-proxy/templates/wsl-proxy-env.sh"
```

### 2. Dry Run

```powershell
.\dev-proxy.ps1 -NonInteractive -DryRun
```

The system proxy line must show a bypass list derived from `noProxy`, with
dot-prefixed entries rewritten to the WinINet form:

```text
[INFO] Dry-run: would set Windows system proxy to 127.0.0.1:20122 (bypass: localhost;127.0.0.1;::1;*.local;<local>)
```

Input validation must warn and fall back instead of writing a bad value:

```powershell
.\dev-proxy.ps1 -NonInteractive -DryRun -ProxyPort 99999
```

Expect `[WARN] Proxy port '99999' is not in 1-65535; using 20122.`

Dry-run with mirrored disabled, then restore the original value:

```powershell
$config = Get-Content .\config.json -Raw | ConvertFrom-Json
$original = $config.enableWslMirrored
$config.enableWslMirrored = $false
$config | ConvertTo-Json -Depth 4 | Set-Content .\config.json
.\dev-proxy.ps1 -NonInteractive -DryRun
$config.enableWslMirrored = $original
$config | ConvertTo-Json -Depth 4 | Set-Content .\config.json
```

### 3. Apply

Start the local proxy client first, then:

```powershell
.\dev-proxy.ps1 -NonInteractive -Distro Ubuntu-24.04
```

In a non-elevated shell the WinHTTP step must decline and print the command
instead of failing or elevating:

```text
[WARN] This step requires an elevated PowerShell. Run: netsh winhttp import proxy source=ie
```

Repeat once in an elevated shell to cover the other branch, where that step
becomes `[ OK ] WinHTTP proxy imported ...`.

Confirm what landed in the registry:

```powershell
Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" |
    Select-Object ProxyEnable, ProxyServer, ProxyOverride
```

### 4. Idempotence

Re-running must not accumulate side effects:

```powershell
(Get-Item .\config.json).LastWriteTime
Get-ChildItem "$env:USERPROFILE\.wslconfig*" | Select-Object Name, LastWriteTime

.\dev-proxy.ps1 -NonInteractive -Distro Ubuntu-24.04

(Get-Item .\config.json).LastWriteTime
Get-ChildItem "$env:USERPROFILE\.wslconfig*" | Select-Object Name, LastWriteTime
```

The second run prints `[ OK ] ...\.wslconfig already has mirrored networking settings`,
adds no `.bak` file, and leaves both timestamps unchanged.

### 5. Verification And Exit Code

```powershell
.\verify-dev-proxy.ps1
$LASTEXITCODE
```

A healthy run ends with `[ OK ] Verification finished with no failures` and exit
code `0`. The WSL section should include:

```text
DEV_PROXY_HOST=127.0.0.1
DEV_PROXY_HOST_SOURCE=mirrored-localhost
proxy_tcp=reachable
PASS_OPENAI
PASS_ANTHROPIC
```

HTTP `401`, `403`, or `404` still counts as a pass. For the negative case, stop
the local proxy client and re-run: expect `[FAIL]` lines, a
`Verification finished with N failure(s)` summary, and exit code `1`. Do not
force a failure by passing a different `-ProxyPort`; the main flow saves config
before the `-Verify` branch, so that would persist the throwaway port.

### 6. WSL Helpers

```powershell
wsl.exe -d Ubuntu-24.04 -- bash -lc "proxy_status; proxy_refresh; proxy_status; proxy_off; proxy_status"
```

All three helpers must exist. After `proxy_off`, `DEV_PROXY_HOST_SOURCE` returns
to `<unresolved>` and `HTTP_PROXY` to `<unset>`. With `enableWslMirrored` off and
WSL restarted, the source must read `nat-gateway` rather than `mirrored-localhost`.

### 7. Rollback

```powershell
.\dev-proxy.ps1 -Disable

Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" | Select-Object ProxyEnable
[Environment]::GetEnvironmentVariable("HTTP_PROXY", "User")
wsl.exe -d Ubuntu-24.04 -- bash -lc "grep -n dev-proxy ~/.profile"
```

`ProxyEnable` is `0`, the user variable is empty, and the profile source line is
commented out rather than deleted.

### 8. Boundary Check

The tool writes only these locations. Anything outside them is a regression:

- `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`
- User-scope proxy environment variables
- `%USERPROFILE%\.wslconfig` and its `.bak` copies
- WSL `~/.config/dev-proxy/proxy-env.sh` and `~/.profile`
- `config.json` in the tool directory

CC Switch databases, provider configs, and API keys must be untouched.

### Interactive Smoke Checks

- Option 1 saves the proxy target, the bypass list, and `enableWslMirrored`, and rejects an out-of-range port or an unknown scheme.
- Option 4 explains mirrored networking and NAT fallback, then persists `enableWslMirrored`.
- Option 5 reports Windows and WSL verification without raw localized `netsh` noise, and ends with a failure-count summary.
- Option 6 prints CC Switch paths only; it does not edit CC Switch.

## Pre-Finish Scan

Separate from the validation steps above, scan for temporary notes, debug-only output, progress UI calls, and markdown formatting mistakes. Keep the docs themselves free of those marker strings so the scan remains actionable.
