# Dev Proxy Maintenance Notes

This is a standalone Windows and WSL ops tool. Its deployment location is `C:\Users\Public\ops-tools\dev-proxy`, but nothing may depend on that path: the scripts and the commands in these notes must work from whatever directory the repository sits in. Do not couple it back into the `cc-switch` repository.

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

From the repository root:

```powershell
.\run-validation.ps1           # parse, JSON, BOM, template syntax, dry run
.\run-validation.ps1 -Full     # also apply, verify, WSL helpers, rollback, restore
```

`run-validation.ps1` exits non-zero when any check fails. It covers the WSL
template syntax check too, by piping the file into `bash -n`, so no separate WSL
command is needed. See `AGENTS.md` for what each step asserts.

Expected connectivity signals include `DEV_PROXY_HOST_SOURCE=mirrored-localhost`, `proxy_tcp=reachable`, `PASS_OPENAI`, and `PASS_ANTHROPIC`. Under NAT the source reads `nat-gateway` instead, which is only healthy when the proxy client accepts non-loopback connections. HTTP `401`, `403`, or `404` can be acceptable because they prove the request reached the provider without credentials.

After edits, verify that CC Switch remains untouched and that provider secrets/configs were not read or changed.
