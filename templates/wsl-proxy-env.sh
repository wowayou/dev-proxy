# Dev proxy environment for WSL shells.
# This file is generated from a Windows-side tool. It is safe to source more than once.

DEV_PROXY_SCHEME="${DEV_PROXY_SCHEME:-__PROXY_SCHEME__}"
DEV_PROXY_PORT="${DEV_PROXY_PORT:-__PROXY_PORT__}"
DEV_PROXY_NO_PROXY="${DEV_PROXY_NO_PROXY:-__NO_PROXY__}"

_dev_proxy_can_connect() {
  local host="$1"
  local port="$2"
  if command -v timeout >/dev/null 2>&1; then
    timeout 0.4 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

_dev_proxy_resolve_host() {
  # Sets DEV_PROXY_HOST_SOURCE and _dev_proxy_resolved_host in the caller's
  # shell. It must not print the host for a "$(...)" capture: that runs in a
  # subshell, so the source assignment would be discarded.
  if _dev_proxy_can_connect "127.0.0.1" "${DEV_PROXY_PORT}"; then
    DEV_PROXY_HOST_SOURCE="mirrored-localhost"
    _dev_proxy_resolved_host="127.0.0.1"
    return 0
  fi

  # NAT mode cannot use Windows localhost, so fall back to the default gateway,
  # which is the Windows vEthernet address and may change.
  _dev_proxy_resolved_host="$(ip route show default 2>/dev/null | awk 'NR==1 {print $3}')"
  if [ -n "${_dev_proxy_resolved_host}" ]; then
    DEV_PROXY_HOST_SOURCE="nat-gateway"
  else
    DEV_PROXY_HOST_SOURCE="unresolved"
  fi
}

proxy_on() {
  local host
  # Set DEV_PROXY_HOST_OVERRIDE only when you intentionally want a fixed host.
  if [ -n "${DEV_PROXY_HOST_OVERRIDE:-}" ]; then
    host="${DEV_PROXY_HOST_OVERRIDE}"
    DEV_PROXY_HOST_SOURCE="override"
  else
    _dev_proxy_resolve_host
    host="${_dev_proxy_resolved_host}"
  fi
  if [ -z "${host}" ]; then
    DEV_PROXY_HOST_SOURCE="unresolved"
    printf 'dev-proxy: unable to resolve Windows proxy host\n' >&2
    return 1
  fi

  export DEV_PROXY_HOST="${host}"
  export DEV_PROXY_HOST_SOURCE
  export HTTP_PROXY="${DEV_PROXY_SCHEME}://${DEV_PROXY_HOST}:${DEV_PROXY_PORT}"
  export HTTPS_PROXY="${HTTP_PROXY}"
  export ALL_PROXY="${HTTP_PROXY}"
  export NO_PROXY="${DEV_PROXY_NO_PROXY}"

  export http_proxy="${HTTP_PROXY}"
  export https_proxy="${HTTPS_PROXY}"
  export all_proxy="${ALL_PROXY}"
  export no_proxy="${NO_PROXY}"
}

proxy_off() {
  unset DEV_PROXY_HOST DEV_PROXY_HOST_SOURCE _dev_proxy_resolved_host
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
  unset http_proxy https_proxy all_proxy no_proxy
}

proxy_refresh() {
  unset DEV_PROXY_HOST DEV_PROXY_HOST_SOURCE _dev_proxy_resolved_host
  proxy_on
}

proxy_status() {
  printf 'DEV_PROXY_HOST=%s\n' "${DEV_PROXY_HOST:-<unresolved>}"
  # Naming the source makes mirrored-vs-NAT problems obvious at a glance.
  printf 'DEV_PROXY_HOST_SOURCE=%s\n' "${DEV_PROXY_HOST_SOURCE:-<unresolved>}"
  if [ -n "${DEV_PROXY_HOST_OVERRIDE:-}" ]; then
    printf 'DEV_PROXY_HOST_OVERRIDE=%s\n' "${DEV_PROXY_HOST_OVERRIDE}"
  fi
  printf 'DEV_PROXY_PORT=%s\n' "${DEV_PROXY_PORT}"
  printf 'HTTP_PROXY=%s\n' "${HTTP_PROXY:-<unset>}"
  printf 'NO_PROXY=%s\n' "${NO_PROXY:-<unset>}"
  if _dev_proxy_can_connect "${DEV_PROXY_HOST:-127.0.0.1}" "${DEV_PROXY_PORT}"; then
    printf 'proxy_tcp=reachable\n'
  else
    printf 'proxy_tcp=unreachable\n'
  fi
}

# Sourced from ~/.profile: a failed lookup must not leave the login shell with a
# non-zero status. proxy_on already explains the failure on stderr.
proxy_on || true
