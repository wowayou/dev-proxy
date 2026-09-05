# Dev Proxy Maintenance Notes

This is a standalone Windows and WSL ops tool. Maintain it in place at `C:\Users\Public\ops-tools\dev-proxy`; do not couple it back into the `cc-switch` repository.

## Operating Boundaries

- Do not touch CC Switch databases, source files, or app-specific config fields.
- Do not touch Claude, Codex, OpenCode, or other provider secrets/configs.
- Do not handle API keys.
- Do not add automatic elevation.
- Keep the tool focused on Windows proxy settings, WinHTTP sync, selected WSL shell proxy setup, validation, suggestions, and rollback.

## Editing Workflow

1. Read `dev-proxy.ps1`, `config.example.json`, and `templates/wsl-proxy-env.sh` before changing behavior. `config.json` is per-machine state, is not tracked, and may be absent; keep `config.example.json` in step with `Get-DefaultConfig`.
2. Preserve `enableWslMirrored` as a user-visible preference shown in the menu and saved to `config.json`.
3. Preserve WSL helper commands: `proxy_status`, `proxy_refresh`, and `proxy_off`.
4. Preserve dynamic NAT fallback through the WSL default-route gateway.
5. Use `DEV_PROXY_HOST_OVERRIDE` only for intentional fixed-host overrides.
6. Keep raw localized `netsh` output suppressed.

## Mirrored Vs NAT

When `enableWslMirrored` is `true`, non-interactive setup may update `%USERPROFILE%\.wslconfig` so WSL can reach Windows localhost, such as `127.0.0.1:20122`.

When it is `false`, non-interactive setup must still install the WSL shell proxy profile but must not change `.wslconfig`. WSL then falls back to the Windows vEthernet gateway, for example `172.17.0.1`. That requires the Windows proxy client to accept non-loopback connections.

## Verification

From `C:\Users\Public\ops-tools\dev-proxy`:

```powershell
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\dev-proxy.ps1), [ref]$tokens, [ref]$errors) | Out-Null
if ($errors) { $errors; exit 1 }
Get-Content .\config.example.json -Raw | ConvertFrom-Json | Out-Null
.\dev-proxy.ps1 -NonInteractive -DryRun
```

From WSL:

```bash
bash -n /mnt/c/Users/Public/ops-tools/dev-proxy/templates/wsl-proxy-env.sh
```

Expected connectivity signals include `proxy_tcp=reachable`, `PASS_OPENAI`, and `PASS_ANTHROPIC`. HTTP `401`, `403`, or `404` can be acceptable because they prove the request reached the provider without credentials.

After edits, verify that CC Switch remains untouched and that provider secrets/configs were not read or changed.
