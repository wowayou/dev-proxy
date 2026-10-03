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

Open PowerShell in the tool directory. The recommended deployment location is
`C:\Users\Public\ops-tools\dev-proxy`, but the scripts run from anywhere:

```powershell
.\dev-proxy.ps1
```

Recommended flow:

1. Start your local proxy client with an HTTP or mixed listener on `127.0.0.1:20122`.
2. Choose `1. Configure proxy target and preferences` if your local proxy uses another host, port, or scheme, or if you want a different bypass list or WSL mirrored preference.
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

Verification exits `0` when every check passes and `1` when any check fails, so it can gate a script:

```powershell
.\verify-dev-proxy.ps1
if ($LASTEXITCODE -ne 0) { "proxy is not healthy" }
```

Rollback:

```powershell
.\dev-proxy.ps1 -Disable
```

## Command Line

`dev-proxy.ps1` takes these parameters. With none of them it opens the menu.

| Parameter | Effect |
| --- | --- |
| `-ProxyHost <name>` | Override the saved proxy host for this run. |
| `-ProxyPort <n>` | Override the saved port. Values outside 1-65535 warn and fall back. |
| `-ProxyScheme http\|https` | Override the saved scheme. |
| `-Distro <name>` | Use this WSL distro instead of the saved one. |
| `-NonInteractive` | Apply Windows and WSL setup without prompting, then verify. |
| `-Verify` | Run verification only. Exits `0` when clean, `1` on any failure. |
| `-Disable` | Roll back everything this tool configured. |
| `-DryRun` | Print what would change and write nothing. |

`-Verify` and `-Disable` do not save `config.json`, so an override passed
alongside them applies to that run only. Every other combination saves the
resolved target.

`verify-dev-proxy.ps1` is a shortcut for `-Verify` and passes its exit code
through. `run-validation.ps1` checks the tool itself rather than the proxy; see
`AGENTS.md`.

## Configuration

`config.json` stores the local target and WSL preference. It holds per-machine
settings, so it is not tracked in git; `config.example.json` is the tracked
template:

```json
{
  "proxyHost": "127.0.0.1",
  "proxyPort": 20122,
  "proxyScheme": "http",
  "noProxy": "localhost,127.0.0.1,::1,.local",
  "distro": null,
  "enableWslMirrored": true,
  "enableWslInteropFallback": true,
  "wslInteropPort": 20180
}
```

A fresh clone has no `config.json`. The tool falls back to the values above and
writes the file on its first run, so nothing needs to be copied by hand. Copy
the template only if you want to pre-seed values:

```powershell
Copy-Item .\config.example.json .\config.json
```

`distro` is filled in by menu option 3 or by passing `-Distro`.

`wslInteropPort` is the Linux-local IPv6 relay port (default `20180`). It is
independent of the Windows proxy listener at `127.0.0.1:20122`. During a
parallel migration you may intentionally install a second generation on
`20181`, verify it, and switch new shells; do not stop the existing `20180`
relay while old connections still use it.

`enableWslInteropFallback` keeps that relay as a fallback instead of the normal
mirrored path. With the default `true`, WSL first tries the configured Windows
listener directly (normally `127.0.0.1:20122`) and starts the `[::1]` relay only
when every direct mirrored candidate is unreachable. Set it to `false` to
disable relay startup without disabling mirrored networking itself. Installation
preflights Python 3, Windows process interop, IPv6 loopback, and ownership of
the configured relay port; if any is unavailable, it warns and
records `DEV_PROXY_INTEROP_AVAILABLE=false` in that distro's generated profile,
while keeping direct mirrored and NAT paths usable. An unknown or older relay
on that port is left running but is never selected by the newly installed
profile; choose another `wslInteropPort` to restore the fallback.

`enableWslMirrored` is a visible user preference. The menu header shows it, options 1 and 4 both let you change it, and both save the answer back to `config.json`. `noProxy` feeds the CLI bypass variables and the Windows system-proxy bypass list; entries that start with a dot, such as `.local`, are rewritten to the `*.local` form WinINet expects. Values are validated on load, so an out-of-range port or an unknown scheme falls back to the default with a warning instead of being written to the registry. In `-NonInteractive` mode, mirrored networking and DNS settings are applied only when this value is `true`; the WSL shell proxy environment is installed either way. When it changes to `false`, the tool restores the prior `networkingMode` and `dnsTunneling` values recorded by its own management markers, leaves user-edited or unowned settings alone, and continues to manage `autoProxy=false` so WSL's automatic proxy import cannot conflict with the generated shell profile.

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

After installing or migrating the profile, use a new WSL terminal or run
`. ~/.profile` in an existing Bash shell. `proxy_refresh` re-resolves the
relay for the current shell, but it cannot replace environment variables or
runtime functions already captured by an older shell/profile generation.
Path selection happens when the profile is loaded or `proxy_refresh` runs; it
does not retry an individual request through another path after that request
has already failed.

The hook in `~/.profile` is POSIX-compatible, but the generated helper file is
intentionally Bash-only and returns immediately when `.profile` is loaded by
dash or another non-Bash shell. If `.bash_profile` or `.bash_login` exists,
installation and verification recognize common ways of loading `.profile`,
including `${HOME}`, split quotes such as `"$HOME"/.profile`, and the absolute
home path.

`proxy_status` reports `DEV_PROXY_NETWORKING_MODE` and identifies `DEV_PROXY_HOST_SOURCE` as `mirrored-interop`, `mirrored-localhost`, `mirrored-host-address`, `nat-gateway`, or `override`.

The WSL profile dynamically resolves the Windows proxy host, using
`wslinfo --networking-mode` as the authoritative mode signal:

- Mirrored networking: WSL first tries the configured Windows listener directly
  (normally `127.0.0.1:20122`). If that path is unreachable and
  `enableWslInteropFallback` is enabled, the generated relay listens only on
  Linux IPv6 loopback (`[::1]:20180` by default). For each relay connection
  that sends data, it starts one Windows PowerShell interop process, which
  connects to the existing Windows listener and copies bytes in both
  directions. An empty TCP probe does not start a Windows child.
- NAT fallback: WSL uses the current default-route gateway (normally a
  Windows vEthernet address such as `172.17.0.1`), never Windows localhost.
  The Windows proxy client must explicitly accept that address and a narrowly
  scoped firewall rule; the tool does not change proxy-client configuration.
- `DEV_PROXY_HOST_OVERRIDE` is an intentional fixed-host override, not a
  replacement for dynamic mode detection.

Option 4 backs up `.wslconfig` and always sets global WSL2 `autoProxy=false`.
When mirrored mode is enabled it also enables mirrored networking and DNS
tunneling; when mirrored mode is disabled it restores only the prior values
saved by this tool for those two settings. A
new install does not add `hostAddressLoopback` or
`ignoredPorts`; the IPv6 loopback relay does not need either setting. Legacy
management markers for those keys remain understood until an explicit
rollback, which can restore their prior values. The selected distro's Bash
login profile is the only source that injects proxy environment variables.
Managed values carry comments that let option 7 restore the prior managed
`.wslconfig` lines without replacing unrelated memory, swap, crash-dump, or
experimental settings.

NAT fallback only works when the proxy client accepts non-loopback connections. Prefer one explicit host address plus a firewall rule limited to the required source over a `0.0.0.0` listener. Set `DEV_PROXY_HOST_OVERRIDE` only when you intentionally want to pin a fixed host; otherwise leave host detection dynamic.

## Validation Signals

Use option 5 or `.\verify-dev-proxy.ps1`. To check the tool itself rather than
the proxy, `.\run-validation.ps1` runs the maintenance suite described in
`AGENTS.md` and exits non-zero on any failure.

Healthy WSL output normally uses the direct mirrored path:

```text
DEV_PROXY_NETWORKING_MODE=mirrored
DEV_PROXY_HOST=127.0.0.1
DEV_PROXY_HOST_SOURCE=mirrored-localhost
proxy_tcp=reachable
PASS_PROXY_TCP
PASS_OPENAI
PASS_ANTHROPIC
```

When direct mirrored localhost is broken and the fallback is enabled, the host
and source instead become `::1` and `mirrored-interop`.

The run ends with a summary line and, for `-Verify`, a matching exit code.

HTTP `401`, `403`, or `404` from API endpoints is acceptable during these checks. Verification tests the proxy TCP port first and the HTTPS tunnel second. It labels TCP timeout/refusal separately and reports curl exit 28 (timeout) separately from exit 7 (connection failure).

## Troubleshooting

`ping` is not a valid proxy test. Windows may block ICMP to the WSL vEthernet address even when TCP proxy traffic works.

WSL startup may warn about invalid Windows PATH entries, such as `UtilTranslatePathList` or `Failed to translate`. The tool suppresses those warnings during its own WSL calls because they are not proxy failures. Clean Windows PATH later if they are noisy in normal shells.

If mirrored networking is disabled or unavailable, confirm these points:

- `proxy_status` shows `DEV_PROXY_HOST_SOURCE=nat-gateway` and a real host, not `<unresolved>`.
- `proxy_tcp=reachable` is present.
- Your Windows proxy client is listening beyond `127.0.0.1`.
- Windows Firewall allows the proxy listener for the relevant network profile.

If mirrored networking is enabled, run `wsl --shutdown` after `.wslconfig` changes, then reopen WSL. The tool does not add `hostAddressLoopback`; native `127.0.0.1` and the Linux-local IPv6 fallback do not require it. If you separately expose additional Windows IPv4 addresses, the proxy must actually listen on an address that WSL mirrors. A VMware-only address, for example, may still route toward the LAN gateway instead of the Windows host.

A report in [microsoft/WSL#40343](https://github.com/microsoft/WSL/issues/40343) describes mirrored-mode TCP failures involving incorrect reply ports. Similar localhost timeouts do not prove that a particular machine has that exact defect; no local packet capture establishes that diagnosis. The IPv6-local interop bridge is a narrow workaround: it remains bound only to WSL localhost, and does not repair WSL's networking stack, edit proxy-client configuration, or create firewall rules.

## Reliability And Limits

The bridge is a local development fallback, not a VPN or a replacement for
sing-box. Windows applications connect to the Windows proxy directly. WSL
applications that inherit the generated environment normally use the mirrored
Windows listener directly; only when that path is unreachable and the fallback
is enabled do they connect to Linux IPv6 loopback, where the bridge copies TCP
bytes through Windows interop to the configured Windows proxy. It does not
decrypt HTTPS.

- Only applications that honor the proxy variables are covered. A shell that
  does not source `~/.profile`, a service, container, another Linux user, or an
  already-running application can retain different settings. The generated
  profile is intended for Bash; it is not a universal shell startup hook. If
  `~/.bash_profile` or `~/.bash_login` exists but does not load `~/.profile`,
  installation warns and verification fails instead of reporting a false
  healthy state.
- UDP, QUIC, ICMP, arbitrary system traffic, and DNS for applications making
  direct connections are outside the bridge's scope.
- `proxy_off` affects only the current shell and its future child processes.
  It does not rewrite the environment of existing processes or disconnect
  their established requests.
- The interop path depends on Python 3, Linux IPv6 loopback, WSL Windows-process
  interoperability, and a running Windows proxy. Each active connection has
  the cost of a Windows PowerShell process; this is not a high-throughput
  multi-user proxy service. The relay caps active connections at 32, waits up
  to 10 seconds for the first request bytes, and allows up to 3 seconds to
  drain a response after client EOF before reaping the child. When request
  bytes are pending but the Windows child pipe makes no progress for 10
  seconds, the relay cancels that connection and reaps its child. Healthy idle
  or streaming connections are not cut off by an idle-duration limit. These
  bounded drain and blocked-write windows can truncate a peer that needs more
  time to make progress.
- An HTTP `401`, `403`, or `404` in verification proves network connectivity,
  not valid API credentials, model permissions, quota, or successful inference.
- HTTPS websites reached through an HTTP proxy are carried as opaque bytes; the
  origin connection remains the application's responsibility. An HTTPS proxy
  endpoint is different: its certificate name must match the proxy address
  seen by the client. A certificate for the original Windows host may not be
  valid for `[::1]`; TLS certificate validation is never disabled by the tool.
- Rollback restores managed `.wslconfig` values, but the Windows side disables
  proxy settings and clears proxy variables. It is not a snapshot restoration
  of arbitrary Windows proxy settings that existed before installation.
- `.wslconfig` is global to the user's WSL 2 distributions. Disabling
  `autoProxy` affects all of them, although this tool installs the shell
  profile only in the selected distribution.
- A loopback listener prevents LAN access but is not authentication between
  local users. Other processes with access to the same loopback interface can
  connect to it. The runtime generation identifier detects stale processes;
  it is not an API key or an access-control credential.

See [the reliability audit](RELIABILITY-AUDIT.md) for concrete findings,
regression checks, deployment evidence, and checks that have not been run.

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

Menu option `7. Disable / rollback` does the same thing. Either way it asks for confirmation and defaults to No, so pressing Enter aborts and leaves everything in place. Answer `y`, or add `-NonInteractive` to skip the prompt.

Rollback disables the Windows user system proxy, clears the user-level proxy environment variables, resets WinHTTP when PowerShell is elevated, stops every relay generation whose state identity is independently verified as managed by this tool, comments out the WSL profile source line, and restores only the `.wslconfig` lines managed by this tool. A legacy PID file without matching generation metadata (including `starttime`) is retained and reported rather than guessed or killed. It backs up `.wslconfig` before that restoration. Running it again reports no managed changes and adds no second profile backup; a later setup re-enables the profile line instead of appending a duplicate. Existing provider credentials, unrelated `.wslconfig` settings, and app-specific configs are not touched.

## Contact
Contact me in [linux.do](https://linux.do/): https://linux.do/u/wowayou/summary
