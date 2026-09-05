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

Run from the repository root in PowerShell unless noted. Nothing here may assume
a particular checkout path. Steps 1 and 2 change nothing and are the minimum
after any edit. Steps 3 to 7 touch real Windows and WSL state, so run them when
the change affects behavior. Step 8 is a manual read, not a command.

Run the suite under Windows PowerShell 5.1 at least once. It is the version the
TLS 1.2 fallback and the BOM-less config writer exist for, and PowerShell 7
formats `config.json` differently.

### Run It In One Pass

`run-validation.ps1` automates steps 1 to 7 below, section for section and in
the same order, and prints one `PASS`, `FAIL`, `SKIP`, or `INFO` line per check,
with a summary and a non-zero exit code when anything failed:

```powershell
.\run-validation.ps1           # steps 1 and 2 only, changes nothing
.\run-validation.ps1 -Full     # adds steps 3 to 7, then restores a working setup
```

`-Full` prompts once before it touches real state; `-Force` skips that prompt and
`-SkipRollback` leaves the rollback cycle out. It reads the WSL distro from
`config.json` unless `-Distro` is given.

The script invokes `dev-proxy.ps1` as a child process on purpose: `Write-Line`
prints through `[Console]::Write`, which bypasses the PowerShell output stream,
so output cannot be captured by assignment or `Tee-Object` in the same process.

The steps below describe what each check asserts, and are the reference when a
check fails or when a new one needs writing.

### 1. Parse And Syntax

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

WSL template syntax check. Pipe the file in rather than naming a path, so the
check does not depend on the checkout being reachable from inside WSL, and read
the exit code rather than trusting a trailing string:

```powershell
$text = ((Get-Content .\templates\wsl-proxy-env.sh -Raw) -replace "`r`n", "`n") -replace "`r", "`n"
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
wsl.exe -- bash -c "printf '%s' '$b64' | base64 -d | bash -n"
if ($LASTEXITCODE -eq 0) { "bash -n ok" } else { "bash -n FAILED" }
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

### 3. Apply And Idempotence

Start the local proxy client first, then apply twice. Re-running must not
accumulate side effects:

```powershell
(Get-Item .\config.json).LastWriteTime
Get-ChildItem "$env:USERPROFILE\.wslconfig*" | Select-Object Name, LastWriteTime

.\dev-proxy.ps1 -NonInteractive -Distro Ubuntu-24.04
.\dev-proxy.ps1 -NonInteractive -Distro Ubuntu-24.04

(Get-Item .\config.json).LastWriteTime
Get-ChildItem "$env:USERPROFILE\.wslconfig*" | Select-Object Name, LastWriteTime
```

Both runs end with exit code `0`. The second prints
`[ OK ] ...\.wslconfig already has mirrored networking settings`, adds no `.bak`
file, and leaves both timestamps unchanged.

In a non-elevated shell the WinHTTP step must decline and print the command
instead of failing or elevating:

```text
[WARN] This step requires an elevated PowerShell. Run: netsh winhttp import proxy source=ie
```

Repeat once in an elevated shell to cover the other branch, where that step
becomes `[ OK ] WinHTTP proxy imported ...`.

If `.wslconfig` was changed, mirrored networking is not active until WSL
restarts. Run `wsl --shutdown` after saving work in WSL before trusting steps 5
and 6, otherwise expect `DEV_PROXY_HOST_SOURCE=nat-gateway` and
`proxy_tcp=unreachable` from a proxy client bound to loopback only.

### 4. Windows State

Confirm what landed on the Windows side:

```powershell
Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" |
    Select-Object ProxyEnable, ProxyServer, ProxyOverride
(Get-Item "HKCU:\Environment").Property | Where-Object { $_ -match "proxy" }
```

`ProxyOverride` ends in `<local>` and reflects `noProxy`. The registry lists
four proxy variable names, not eight: Windows environment variable names are
case-insensitive, so the upper-case and lower-case spellings the tool writes
collapse into the same four values. Reading any of the eight names back must
return the configured value.

### 5. Verification Exit Codes

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

HTTP `401`, `403`, or `404` still counts as a pass. For the negative case, point
the check at a port nothing listens on and expect `[FAIL]` lines, a
`Verification finished with N failure(s)` summary, and exit code `1`:

```powershell
.\dev-proxy.ps1 -Verify -ProxyPort 20199
$LASTEXITCODE
```

`-Verify` and `-Disable` do not write `config.json`, so the throwaway port is
not persisted. Confirm that by checking the file's timestamp afterwards.

### 6. WSL Helpers

```powershell
wsl.exe -d Ubuntu-24.04 -- bash -lc "proxy_status; proxy_refresh; proxy_status; proxy_off; proxy_status"
```

All three helpers must exist. `DEV_PROXY_HOST_SOURCE` must agree with the host
on the line above it: `mirrored-localhost` with `127.0.0.1`, `nat-gateway` with a
vEthernet address such as `172.17.0.1`, `override` when `DEV_PROXY_HOST_OVERRIDE`
is set, and `unresolved` only when no host was found at all. A resolved host
reported as `unresolved` means the source is being assigned inside a subshell
again. After `proxy_off`, both it and `HTTP_PROXY` return to their unset markers.

### 7. Rollback And Restore

`-Disable` asks for confirmation and defaults to No, so pressing Enter aborts
the rollback and leaves everything in place. Answer `y`, or pass
`-NonInteractive` to skip the prompt:

```powershell
.\dev-proxy.ps1 -Disable -NonInteractive

Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" | Select-Object ProxyEnable
[Environment]::GetEnvironmentVariable("HTTP_PROXY", "User")
wsl.exe -d Ubuntu-24.04 -- bash -lc "grep -n dev-proxy ~/.profile"
```

`ProxyEnable` is `0`, the user variable is empty, and the profile source line is
commented out rather than deleted. Running rollback twice must report
`already disabled` and add no second `.profile.dev-proxy.bak.*` file, and a
later install must re-enable that line rather than append a duplicate. Only
lines this tool commented out are recognized; a source line disabled by hand
with a different prefix is left alone and will produce a second entry.

### 8. Boundary Check

Not automated; read it yourself after any change that touches file or registry
writes. The tool writes only these locations. Anything outside them is a regression:

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
