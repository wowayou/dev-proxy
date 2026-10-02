# Dev proxy environment for WSL shells.
# This file is generated from a Windows-side tool. It is safe to source more than once.

DEV_PROXY_SCHEME_DEFAULT='__PROXY_SCHEME__'
DEV_PROXY_TARGET_HOST_DEFAULT='__PROXY_HOST__'
DEV_PROXY_TARGET_PORT='__PROXY_PORT__'
DEV_PROXY_INTEROP_PORT='__INTEROP_PORT__'
DEV_PROXY_INTEROP_FALLBACK='__INTEROP_FALLBACK__'
DEV_PROXY_INTEROP_TOKEN='__INSTANCE_TOKEN__'
DEV_PROXY_PORT="${DEV_PROXY_TARGET_PORT}"
DEV_PROXY_SCHEME="$DEV_PROXY_SCHEME_DEFAULT"
DEV_PROXY_TARGET_SCHEME="$DEV_PROXY_SCHEME_DEFAULT"
DEV_PROXY_TARGET_HOST="$DEV_PROXY_TARGET_HOST_DEFAULT"
DEV_PROXY_NO_PROXY_DEFAULT='__NO_PROXY__'
DEV_PROXY_NO_PROXY="$DEV_PROXY_NO_PROXY_DEFAULT"
DEV_PROXY_MIRRORED_HOSTS_DEFAULT='__MIRRORED_PROXY_HOSTS__'
DEV_PROXY_MIRRORED_HOSTS="$DEV_PROXY_MIRRORED_HOSTS_DEFAULT"

_dev_proxy_can_connect() {
  local host="$1"
  local port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "${host}" "${port}" >/dev/null 2>&1
  elif command -v timeout >/dev/null 2>&1; then
    timeout 3 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$host" "$port" >/dev/null 2>&1
  else
    return 1
  fi
}

_dev_proxy_ensure_interop_proxy() {
  local base pid pid_file lock_file lock_dir token cmdline i lock_fd state_dir starttime current_starttime argv0 argv1 argv2 old_umask
  base="$HOME/.config/dev-proxy"
  token="$DEV_PROXY_INTEROP_TOKEN"
  # State is private to the configured port and generation.  The legacy
  # interop-proxy.pid is intentionally never overwritten: an older daemon may
  # still be serving existing shells while a new generation rolls out.
  state_dir="$base/interop-${DEV_PROXY_INTEROP_PORT}-${token}"
  pid_file="$state_dir/pid"
  lock_file="$base/interop-${DEV_PROXY_INTEROP_PORT}.lock"
  token="$DEV_PROXY_INTEROP_TOKEN"
  if ! printf '%s' "$DEV_PROXY_INTEROP_PORT" | grep -qE '^[0-9]+$' || [ "$DEV_PROXY_INTEROP_PORT" -lt 1 ] || [ "$DEV_PROXY_INTEROP_PORT" -gt 65535 ]; then
    _dev_proxy_interop_error="invalid relay port"
    return 1
  fi
  if ! command -v flock >/dev/null 2>&1; then
    _dev_proxy_interop_error="flock is required for safe relay lifecycle management"
    return 1
  fi
  old_umask="$(umask)"
  umask 077
  mkdir -p "$state_dir"
  umask "$old_umask"

  # flock on an open descriptor is released by the shell on every return and
  # by the kernel if the shell dies.
  lock_fd=""
  if command -v flock >/dev/null 2>&1; then
    exec {lock_fd}>"$lock_file"
    if ! flock -w 8 "$lock_fd"; then
      exec {lock_fd}>&-
      _dev_proxy_interop_error="timed out waiting for relay lock"
      return 1
    fi
  fi

  _dev_proxy_release_interop_lock() {
    if [ -n "${lock_fd:-}" ]; then
      flock -u "$lock_fd" 2>/dev/null || true
      exec {lock_fd}>&-
      lock_fd=""
    fi
  }

  if [ -f "$base/interop-proxy.pid" ]; then
    printf 'dev-proxy: legacy-relay-preserved (%s)\n' "$base/interop-proxy.pid" >&2
  fi

  if [ -n "${WSL_INTEROP:-}" ] && [ ! -S "$WSL_INTEROP" ]; then
    # Login shells can retain the first shell's dead interop socket path.
    unset WSL_INTEROP
  fi

  if [ -f "${pid_file}" ]; then
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    # Only numeric PIDs are accepted.  Also require the recorded Linux
    # /proc starttime and exact argv tokens so a reused PID or foreign process
    # can never be killed or treated as our relay.
    starttime="$(cat "$state_dir/starttime" 2>/dev/null || true)"
    argv0="$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n '1p' || true)"
    argv1="$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n '2p' || true)"
    argv2="$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n '3p' || true)"
    current_starttime="$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true)"
    if printf '%s' "$pid" | grep -qE '^[0-9]+$' && [ -n "$starttime" ] \
      && [ "$current_starttime" = "$starttime" ] && kill -0 "$pid" 2>/dev/null \
      && [ "$argv1" = "$base/interop-proxy.py" ] \
      && [ "$argv2" = "$token" ]; then
      if _dev_proxy_can_connect "::1" "${DEV_PROXY_INTEROP_PORT}"; then
        _dev_proxy_release_interop_lock
        return 0
      fi
      # The matching process is still starting.  Do not kill it; give it the
      # same bounded startup window before considering a new generation.
      for _dev_proxy_existing_wait in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if _dev_proxy_can_connect "::1" "${DEV_PROXY_INTEROP_PORT}"; then
          _dev_proxy_release_interop_lock
          return 0
        fi
        if ! kill -0 "${pid}" 2>/dev/null; then
          rm -f "${pid_file}"
          break
        fi
        sleep 0.2
      done
    elif [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; then
      rm -f "${pid_file}"
    fi
  fi

  # A listening socket without our PID+token identity is foreign (or a stale
  # prior generation).  It is never accepted as the relay and is never killed.
  if _dev_proxy_can_connect "::1" "${DEV_PROXY_INTEROP_PORT}"; then
    _dev_proxy_interop_error="relay port ${DEV_PROXY_INTEROP_PORT} is occupied by an unknown process or prior generation"
    _dev_proxy_release_interop_lock
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    _dev_proxy_interop_error="python3 is not available"
    _dev_proxy_release_interop_lock
    return 1
  fi
  if ! command -v powershell.exe >/dev/null 2>&1 && ! command -v pwsh.exe >/dev/null 2>&1 \
    && [ ! -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
    _dev_proxy_interop_error="no Windows PowerShell interop executable was found"
    _dev_proxy_release_interop_lock
    return 1
  fi

  # Do not let the long-lived daemon inherit the lifecycle lock descriptor.
  # Otherwise the descriptor would remain locked after this shell releases it.
  (
    exec {lock_fd}>&-
    exec nohup python3 "$base/interop-proxy.py" "$token" </dev/null >"$base/interop-proxy.log" 2>&1
  ) &
  pid=$!
  printf '%s\n' "${pid}" > "${pid_file}.tmp.$$" && mv -f "${pid_file}.tmp.$$" "${pid_file}"
  for _dev_proxy_identity_wait in 1 2 3 4 5; do
    current_starttime="$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true)"
    [ -n "$current_starttime" ] && break
    sleep 0.02
  done
  printf '%s\n' "$current_starttime" > "$state_dir/starttime"
  for _dev_proxy_wait in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    current_starttime="$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true)"
    argv1="$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n '2p' || true)"
    argv2="$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n '3p' || true)"
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pid_file" "$state_dir/starttime"
      _dev_proxy_interop_error="relay process exited before becoming ready"
      _dev_proxy_release_interop_lock
      return 1
    fi
    # The process can be alive while Python is still in exec.  Keep waiting
    # until its identity is complete instead of deleting state or accepting a
    # transient argv from the nohup/subshell startup race.
    if [ "$current_starttime" != "$(cat "$state_dir/starttime" 2>/dev/null || true)" ] \
      || [ "$argv1" != "$base/interop-proxy.py" ] || [ "$argv2" != "$token" ]; then
      sleep 0.2
      continue
    fi
    if _dev_proxy_can_connect "::1" "${DEV_PROXY_INTEROP_PORT}"; then
      _dev_proxy_release_interop_lock
      return 0
    fi
    sleep 0.2
  done
  current_starttime="$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true)"
  argv1="$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n '2p' || true)"
  argv2="$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | sed -n '3p' || true)"
  if kill -0 "$pid" 2>/dev/null && [ "$current_starttime" = "$(cat "$state_dir/starttime" 2>/dev/null || true)" ] \
    && [ "$argv1" = "$base/interop-proxy.py" ] && [ "$argv2" = "$token" ]; then
    # This is our PID and token; only this exact child may be reaped on a
    # failed startup.  Foreign listeners remain untouched.
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file" "$state_dir/starttime"
  _dev_proxy_interop_error="relay did not become ready within 4 seconds"
  _dev_proxy_release_interop_lock
  return 1
}

_dev_proxy_detect_networking_mode() {
  local mode
  if command -v wslinfo >/dev/null 2>&1; then
    mode="$(wslinfo --networking-mode 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [ "${mode}" = "mirrored" ]; then
      printf 'mirrored\n'
      return 0
    fi
  fi

  # wslinfo is the authoritative signal for mirrored mode. Older WSL builds
  # without it, and every other result, use the NAT-compatible path.
  printf 'nat\n'
}

_dev_proxy_resolve_host() {
  # Sets DEV_PROXY_HOST_SOURCE and _dev_proxy_resolved_host in the caller's
  # shell. It must not print the host for a "$(...)" capture: that runs in a
  # subshell, so the source assignment would be discarded.
  local candidate old_ifs
  DEV_PROXY_NETWORKING_MODE="$(_dev_proxy_detect_networking_mode)"
  export DEV_PROXY_NETWORKING_MODE

  if [ "${DEV_PROXY_NETWORKING_MODE}" = "mirrored" ]; then
    DEV_PROXY_PORT="${DEV_PROXY_TARGET_PORT}"
    export DEV_PROXY_PORT
    old_ifs="${IFS}"
    IFS=','
    for candidate in ${DEV_PROXY_MIRRORED_HOSTS}; do
      IFS="${old_ifs}"
      if [ -n "${candidate}" ] && _dev_proxy_can_connect "${candidate}" "${DEV_PROXY_PORT}"; then
        _dev_proxy_resolved_host="${candidate}"
        if [ "${candidate}" = "127.0.0.1" ]; then
          DEV_PROXY_HOST_SOURCE="mirrored-localhost"
        else
          DEV_PROXY_HOST_SOURCE="mirrored-host-address"
        fi
        return 0
      fi
      IFS=','
    done
    IFS="${old_ifs}"

    # Native mirrored localhost is the cheap path. Start the Linux-local
    # interop bridge only when every direct candidate failed and the persisted
    # fallback preference is enabled.
    if [ "${DEV_PROXY_INTEROP_FALLBACK}" = "true" ]; then
      if _dev_proxy_ensure_interop_proxy; then
        _dev_proxy_resolved_host="::1"
        DEV_PROXY_PORT="${DEV_PROXY_INTEROP_PORT}"
        DEV_PROXY_HOST_SOURCE="mirrored-interop"
        export DEV_PROXY_PORT
        return 0
      fi
      if [ -n "${_dev_proxy_interop_error:-}" ]; then
        printf 'dev-proxy: %s\n' "${_dev_proxy_interop_error}" >&2
      fi
    fi

    # Keep the preferred address visible when it is unreachable so verification
    # can report the TCP-layer failure instead of misidentifying a LAN router as
    # the Windows host.
    _dev_proxy_resolved_host="${DEV_PROXY_MIRRORED_HOSTS%%,*}"
    if [ "${_dev_proxy_resolved_host}" = "127.0.0.1" ]; then
      DEV_PROXY_HOST_SOURCE="mirrored-localhost"
    else
      DEV_PROXY_HOST_SOURCE="mirrored-host-address"
    fi
    return 0
  fi

  # NAT mode cannot use Windows localhost, so fall back to the default gateway,
  # which is the Windows vEthernet address and may change.
  _dev_proxy_resolved_host="$(ip route show default 2>/dev/null | awk 'NR==1 {print $3}')"
  DEV_PROXY_PORT="${DEV_PROXY_TARGET_PORT}"
  export DEV_PROXY_PORT
  if [ -n "${_dev_proxy_resolved_host}" ]; then
    DEV_PROXY_HOST_SOURCE="nat-gateway"
  else
    DEV_PROXY_HOST_SOURCE="unresolved"
  fi
}

proxy_on() {
  local host proxy_host_for_url
  # Set DEV_PROXY_HOST_OVERRIDE only when you intentionally want a fixed host.
  if [ -n "${DEV_PROXY_HOST_OVERRIDE:-}" ]; then
    DEV_PROXY_NETWORKING_MODE="$(_dev_proxy_detect_networking_mode)"
    host="${DEV_PROXY_HOST_OVERRIDE}"
    DEV_PROXY_PORT="${DEV_PROXY_TARGET_PORT}"
    DEV_PROXY_HOST_SOURCE="override"
  else
    _dev_proxy_resolve_host
    host="${_dev_proxy_resolved_host}"
  fi
  if [ -z "${host}" ]; then
    DEV_PROXY_HOST_SOURCE="unresolved"
    unset DEV_PROXY_HOST HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
    unset http_proxy https_proxy all_proxy no_proxy
    printf 'dev-proxy: unable to resolve Windows proxy host\n' >&2
    return 1
  fi

  export DEV_PROXY_HOST="${host}"
  export DEV_PROXY_PORT
  export DEV_PROXY_HOST_SOURCE
  proxy_host_for_url="${DEV_PROXY_HOST}"
  case "${proxy_host_for_url}" in
    *:*) proxy_host_for_url="[${proxy_host_for_url}]" ;;
  esac
  export HTTP_PROXY="${DEV_PROXY_SCHEME}://${proxy_host_for_url}:${DEV_PROXY_PORT}"
  export HTTPS_PROXY="${HTTP_PROXY}"
  export ALL_PROXY="${HTTP_PROXY}"
  export NO_PROXY="${DEV_PROXY_NO_PROXY}"

  export http_proxy="${HTTP_PROXY}"
  export https_proxy="${HTTPS_PROXY}"
  export all_proxy="${ALL_PROXY}"
  export no_proxy="${NO_PROXY}"
}

proxy_off() {
  unset DEV_PROXY_HOST DEV_PROXY_HOST_SOURCE DEV_PROXY_NETWORKING_MODE _dev_proxy_resolved_host
  DEV_PROXY_PORT="${DEV_PROXY_TARGET_PORT}"
  export DEV_PROXY_PORT
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
  unset http_proxy https_proxy all_proxy no_proxy
}

proxy_refresh() {
  # Reload the installed file so an existing interactive shell picks up the
  # latest target/token instead of retaining an old generation in memory.
  if [ -f "$HOME/.config/dev-proxy/proxy-env.sh" ] && [ -z "${DEV_PROXY_REFRESH_RELOAD:-}" ]; then
    DEV_PROXY_REFRESH_RELOAD=1
    export DEV_PROXY_REFRESH_RELOAD
    . "$HOME/.config/dev-proxy/proxy-env.sh"
    unset DEV_PROXY_REFRESH_RELOAD
    return $?
  fi
  unset DEV_PROXY_HOST DEV_PROXY_HOST_SOURCE DEV_PROXY_NETWORKING_MODE _dev_proxy_resolved_host
  DEV_PROXY_PORT="${DEV_PROXY_TARGET_PORT}"
  proxy_on
}

proxy_status() {
  printf 'DEV_PROXY_NETWORKING_MODE=%s\n' "${DEV_PROXY_NETWORKING_MODE:-<unknown>}"
  printf 'DEV_PROXY_HOST=%s\n' "${DEV_PROXY_HOST:-<unresolved>}"
  # Naming the source makes mirrored-vs-NAT problems obvious at a glance.
  printf 'DEV_PROXY_HOST_SOURCE=%s\n' "${DEV_PROXY_HOST_SOURCE:-<unresolved>}"
  if [ -n "${DEV_PROXY_HOST_OVERRIDE:-}" ]; then
    printf 'DEV_PROXY_HOST_OVERRIDE=%s\n' "${DEV_PROXY_HOST_OVERRIDE}"
  fi
  printf 'DEV_PROXY_PORT=%s\n' "${DEV_PROXY_PORT}"
  printf 'DEV_PROXY_TARGET_PORT=%s\n' "${DEV_PROXY_TARGET_PORT}"
  printf 'DEV_PROXY_TARGET_HOST=%s\n' "${DEV_PROXY_TARGET_HOST}"
  printf 'DEV_PROXY_TARGET_SCHEME=%s\n' "${DEV_PROXY_SCHEME}"
  printf 'DEV_PROXY_INTEROP_PORT=%s\n' "${DEV_PROXY_INTEROP_PORT}"
  printf 'DEV_PROXY_INTEROP_FALLBACK=%s\n' "${DEV_PROXY_INTEROP_FALLBACK}"
  printf 'DEV_PROXY_INTEROP_TOKEN=%s\n' "${DEV_PROXY_INTEROP_TOKEN}"
  printf 'HTTP_PROXY=%s\n' "${HTTP_PROXY:-<unset>}"
  printf 'NO_PROXY=%s\n' "${NO_PROXY:-<unset>}"
  if [ -z "${DEV_PROXY_HOST:-}" ] || [ -z "${HTTP_PROXY:-}" ]; then
    printf 'proxy_tcp=disabled\n'
  elif _dev_proxy_can_connect "${DEV_PROXY_HOST}" "${DEV_PROXY_PORT}"; then
    printf 'proxy_tcp=reachable\n'
  else
    printf 'proxy_tcp=unreachable\n'
  fi
}

# Sourced from ~/.profile: a failed lookup must not leave the login shell with a
# non-zero status. proxy_on already explains the failure on stderr.
proxy_on || true
