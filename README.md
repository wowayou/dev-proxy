# Dev Proxy Tool

Standalone Windows and WSL proxy helper for local AI development tooling.

Default proxy target:

```text
http://127.0.0.1:20122
```

## Purpose And Scope

This tool configures the operating-system proxy pieces that are safe to manage from a local helper:

- Windows user system proxy.
- Windows user-level proxy environment variables, with upper-case and lower-case variants.
- WinHTTP proxy sync when PowerShell is already elevated.
- A selected WSL distro.
- A WSL shell proxy profile at `~/.config/dev-proxy/proxy-env.sh`.
- Verification, suggested CC Switch values, and rollback.

It does not edit CC Switch databases, Claude provider files, Codex provider files, proxy-client settings, or API keys. It also does not elevate itself.

## Recommended Setup

Open PowerShell in `C:\Users\Public\ops-tools\dev-proxy`:

```powershell
.\dev-proxy.ps1
```

Recommended flow:

1. Start your local proxy client with an HTTP or mixed listener on `127.0.0.1:20122`.
2. Choose `1. Configure proxy target` if your local proxy uses another host, port, or scheme.
3. Choose `2. Set Windows system proxy + user env`.
4. Choose `3. Select WSL distro`.
5. Choose `4. Configure WSL mirrored mode + install WSL env`.
6. Run `wsl --shutdown` only if `.wslconfig` was changed, then reopen WSL.
7. Choose `5. Verify all`.
8. Choose `6. Show CC Switch suggested values` and enter those values in CC Switch manually.

Non-interactive setup:

```powershell
.\dev-proxy.ps1 -NonInteractive -ProxyPort 20122 -Distro Ubuntu-24.04
```

Verification only:

```powershell
.\verify-dev-proxy.ps1
```

Rollback:

```powershell
.\dev-proxy.ps1 -Disable
```

## Configuration

`config.json` stores the local target and WSL preference:

```json
{
  "proxyHost": "127.0.0.1",
  "proxyPort": 20122,
  "proxyScheme": "http",
  "noProxy": "localhost,127.0.0.1,::1,.local",
  "distro": "Ubuntu-24.04",
  "enableWslMirrored": true
}
```

`enableWslMirrored` is a visible user preference. The menu header shows it, option 4 uses it as the default answer, and option 4 saves the answer back to `config.json`. In `-NonInteractive` mode, `.wslconfig` mirrored settings are applied only when this value is `true`; the WSL shell proxy environment is still installed either way.

## Windows Behavior

Option 2 writes the Windows user system proxy to the configured target, then writes user environment variables:

- `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`
- `http_proxy`, `https_proxy`, `all_proxy`, `no_proxy`

WinHTTP sync uses `netsh winhttp import proxy source=ie`, but only when the current PowerShell process is elevated or when you explicitly confirm it from an elevated shell. The tool will not auto-elevate.

Raw localized `netsh` output is suppressed to avoid mojibake in mixed-encoding terminals. Run this manually if you need the original Windows output:

```powershell
netsh winhttp show proxy
```

## WSL Behavior

Option 4 installs a shell profile for the selected distro. New WSL shells source `~/.config/dev-proxy/proxy-env.sh`, which provides:

- `proxy_status`
- `proxy_refresh`
- `proxy_off`

The WSL profile dynamically resolves the Windows proxy host:

- Mirrored networking: WSL can use the Windows proxy at `127.0.0.1:20122`.
- NAT fallback: WSL uses the Windows vEthernet gateway, for example `172.17.0.1`.

NAT fallback only works when your proxy client accepts non-loopback connections, such as LAN access or a `0.0.0.0` listener. Set `DEV_PROXY_HOST_OVERRIDE` only when you intentionally want to pin a fixed host; otherwise leave host detection dynamic.

## Validation Signals

Use option 5 or `.\verify-dev-proxy.ps1`.

Healthy WSL output usually includes:

```text
proxy_tcp=reachable
PASS_OPENAI
PASS_ANTHROPIC
```

HTTP `401`, `403`, or `404` from API endpoints is acceptable during these checks. It means the request reached the provider without credentials. A network timeout, connection refused, or missing `HTTP/` response is the problem to investigate.

## Troubleshooting

`ping` is not a valid proxy test. Windows may block ICMP to the WSL vEthernet address even when TCP proxy traffic works.

WSL startup may warn about invalid Windows PATH entries, such as `UtilTranslatePathList` or `Failed to translate`. The tool suppresses those warnings during its own WSL calls because they are not proxy failures. Clean Windows PATH later if they are noisy in normal shells.

If mirrored networking is disabled or unavailable, confirm these points:

- `proxy_status` shows a vEthernet gateway host, not `<unresolved>`.
- `proxy_tcp=reachable` is present.
- Your Windows proxy client is listening beyond `127.0.0.1`.
- Windows Firewall allows the proxy listener for the relevant network profile.

If mirrored networking is enabled, run `wsl --shutdown` after `.wslconfig` changes, then reopen WSL.

## CC Switch Values

Use menu option 6 to print suggested values. Typical values are:

```text
Global proxy: http://127.0.0.1:20122
Claude directory: \\wsl.localhost\<distro>\home\<wslUser>\.claude
Codex directory:  \\wsl.localhost\<distro>\home\<wslUser>\.codex
```

Enter those values manually in CC Switch. Do not put the Claude or Codex paths in CC Switch's app config directory field.

## Rollback

Run:

```powershell
.\dev-proxy.ps1 -Disable
```

Rollback disables the Windows user system proxy, clears the user-level proxy environment variables, resets WinHTTP when PowerShell is elevated, and comments out the WSL profile source line. Existing provider credentials and app-specific configs are not touched.

## Contact
Contact me in [linux.do](https://linux.do/): https://linux.do/u/wowayou/summary
