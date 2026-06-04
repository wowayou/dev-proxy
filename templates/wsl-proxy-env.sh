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

_dev_proxy_windows_host() {
  # Mirrored networking can use Windows localhost. NAT mode must use the WSL
  # default gateway, which is the Windows vEthernet address and may change.
  if _dev_proxy_can_connect "127.0.0.1" "${DEV_PROXY_PORT}"; then
    printf '%s\n' "127.0.0.1"
    return 0
  fi

  ip route show default 2>/dev/null | awk 'NR==1 {print $3}'
}

proxy_on() {
  local host
  # Set DEV_PROXY_HOST_OVERRIDE only when you intentionally want a fixed host.
  host="${DEV_PROXY_HOST_OVERRIDE:-$(_dev_proxy_windows_host)}"
  if [ -z "${host}" ]; then
    printf 'dev-proxy: unable to resolve Windows proxy host\n' >&2
    return 1
  fi

  export DEV_PROXY_HOST="${host}"
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
  unset DEV_PROXY_HOST
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
  unset http_proxy https_proxy all_proxy no_proxy
}

proxy_refresh() {
  unset DEV_PROXY_HOST
  proxy_on
}

proxy_status() {
  printf 'DEV_PROXY_HOST=%s\n' "${DEV_PROXY_HOST:-<unresolved>}"
  if [ -n "${DEV_PROXY_HOST_OVERRIDE:-}" ]; then
    printf 'DEV_PROXY_HOST_OVERRIDE=%s\n' "${DEV_PROXY_HOST_OVERRIDE}"
  fi
  printf 'DEV_PROXY_PORT=%s\n' "${DEV_PROXY_PORT}"
  printf 'HTTP_PROXY=%s\n' "${HTTP_PROXY:-<unset>}"
  if _dev_proxy_can_connect "${DEV_PROXY_HOST:-127.0.0.1}" "${DEV_PROXY_PORT}"; then
    printf 'proxy_tcp=reachable\n'
  else
    printf 'proxy_tcp=unreachable\n'
  fi
}

proxy_on
