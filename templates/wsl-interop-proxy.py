"""Linux-local bridge to a Windows proxy listener.

The bridge is deliberately a byte-for-byte transport. It starts one Windows
PowerShell process for each connection that sends at least one byte; an empty
TCP probe therefore never creates a Windows child. The generated relay script
(``__WINDOWS_RELAY_ENCODED__``) owns the Windows-side connection.
"""

import glob
import os
import shutil
import socket
import stat
import subprocess
import sys
import threading
import signal
import time


LISTEN_HOST = "::1"
LISTEN_PORT = __INTEROP_PORT__
INSTANCE_TOKEN = "__INSTANCE_TOKEN__"
MAX_CONNECTIONS = 32
FIRST_READ_TIMEOUT = 10.0
CONNECTION_DRAIN_TIMEOUT = 3.0
PROCESS_WAIT_TIMEOUT = 3.0
THREAD_JOIN_TIMEOUT = 1.0

# Keep the generated PowerShell payload separate from the executable. The
# executable and WSL_INTEROP socket are resolved for every child process so a
# daemon can survive the shell that originally started it.
WINDOWS_RELAY_ARGUMENTS = [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-EncodedCommand",
    "__WINDOWS_RELAY_ENCODED__",
]


def close_quietly(stream):
    if stream is None:
        return
    try:
        stream.close()
    except (BrokenPipeError, ConnectionError, OSError, ValueError):
        pass


def write_all(stream, data):
    """Write all bytes, including when FileIO.write returns a short count."""
    view = memoryview(data)
    while view:
        written = stream.write(view)
        # A blocking subprocess pipe should never report no progress. Treat
        # it as a broken relay instead of silently dropping remaining bytes.
        if written is None or written <= 0:
            raise BrokenPipeError("relay stdin made no progress")
        view = view[written:]


def _executable_is_usable(candidate):
    if not candidate:
        return None
    resolved = shutil.which(candidate)
    if resolved:
        return resolved
    # shutil.which may not find an absolute path on a mounted Windows drive;
    # still require the path to exist rather than trusting a baked-in fallback.
    if os.path.isabs(candidate) and os.path.isfile(candidate):
        return candidate
    return None


def resolve_windows_executable():
    """Return the first configured/existing PowerShell executable.

    DEV_PROXY_WINDOWS_EXECUTABLE is an explicit override for controlled tests
    and unusual installations. If it is set but invalid, fail instead of
    silently selecting a different executable. Normal WSL installs are
    discovered through PATH first; mounted-drive paths are used only when they
    actually exist.
    """
    configured = os.environ.get("DEV_PROXY_WINDOWS_EXECUTABLE")
    if configured:
        return _executable_is_usable(configured)
    candidates = [
        "powershell.exe",
        "pwsh.exe",
        "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe",
        "/mnt/c/Program Files/PowerShell/7/pwsh.exe",
    ]
    for candidate in candidates:
        executable = _executable_is_usable(candidate)
        if executable:
            return executable
    return None


def _is_socket(path):
    try:
        return stat.S_ISSOCK(os.stat(path).st_mode)
    except (FileNotFoundError, OSError):
        return False


def resolve_wsl_interop():
    """Find a live WSL interop socket for this child process.

    Login shells can leave a stale WSL_INTEROP value in the daemon's
    environment. Prefer a currently valid value, then inspect standard WSL
    runtime directories. Returning None removes a stale inherited value.
    """
    current = os.environ.get("WSL_INTEROP")
    if current and _is_socket(current):
        return current

    candidates = []
    for directory in ("/run/WSL", "/var/run/WSL"):
        candidates.extend(glob.glob(os.path.join(directory, "*interop*")))
    valid = sorted({path for path in candidates if _is_socket(path)})
    return valid[0] if valid else None


def child_environment():
    environment = os.environ.copy()
    interop = resolve_wsl_interop()
    if interop:
        environment["WSL_INTEROP"] = interop
    else:
        # Never let a dead socket path survive into a new subprocess.
        environment.pop("WSL_INTEROP", None)
    return environment


def start_windows_relay():
    executable = resolve_windows_executable()
    if not executable:
        raise RuntimeError(
            "no usable Windows PowerShell executable (powershell.exe or pwsh.exe)"
        )
    command = [executable, *WINDOWS_RELAY_ARGUMENTS]
    return subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
        env=child_environment(),
    )


def pump_socket_to_process(client, process, first_chunk, finished):
    try:
        if first_chunk:
            write_all(process.stdin, first_chunk)
            process.stdin.flush()
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            write_all(process.stdin, chunk)
            process.stdin.flush()
    except (BrokenPipeError, ConnectionError, OSError, ValueError, socket.timeout):
        pass
    finally:
        # A client FIN must reach the relay. The main thread gives the relay a
        # bounded response-drain window before terminating it.
        close_quietly(process.stdin)
        finished.set()


def pump_process_to_socket(process, client, finished):
    try:
        while True:
            chunk = process.stdout.read(65536)
            if not chunk:
                break
            client.sendall(chunk)
    except (BrokenPipeError, ConnectionError, OSError, ValueError, socket.timeout):
        pass
    finally:
        finished.set()


def reap_process(process):
    """Terminate, close, and reap a relay within bounded time."""
    if process is None:
        return
    try:
        if process.poll() is None:
            try:
                process.terminate()
            except (OSError, ProcessLookupError):
                pass
        try:
            # Call wait even when poll() already observed exit; this closes the
            # race where an exited child has not yet been reaped by the caller.
            process.wait(timeout=PROCESS_WAIT_TIMEOUT)
        except (subprocess.TimeoutExpired, OSError, ProcessLookupError):
            try:
                process.kill()
            except (OSError, ProcessLookupError):
                pass
            try:
                process.wait(timeout=PROCESS_WAIT_TIMEOUT)
            except (subprocess.TimeoutExpired, OSError, ProcessLookupError):
                pass
    finally:
        close_quietly(process.stdin)
        close_quietly(process.stdout)
        close_quietly(getattr(process, "stderr", None))


def handle(client):
    process = None
    upload = None
    download = None
    try:
        # This is the only read with a timeout. Once a client sends data, a
        # healthy streaming connection may remain open indefinitely.
        client.settimeout(FIRST_READ_TIMEOUT)
        try:
            first_chunk = client.recv(65536)
        except (socket.timeout, ConnectionError, OSError):
            # An idle TCP probe (or a peer that disappears before sending a
            # request) is normal for health checks.  Do not emit a traceback
            # from the connection thread for it.
            return
        if not first_chunk:
            return
        try:
            client.settimeout(None)
        except (ConnectionError, OSError):
            return

        try:
            process = start_windows_relay()
        except (OSError, RuntimeError) as exc:
            sys.stderr.write("dev-proxy: could not start Windows relay: %s\n" % exc)
            sys.stderr.flush()
            return

        upload_done = threading.Event()
        download_done = threading.Event()
        upload = threading.Thread(
            target=pump_socket_to_process,
            args=(client, process, first_chunk, upload_done),
            name="dev-proxy-upload",
            daemon=True,
        )
        download = threading.Thread(
            target=pump_process_to_socket,
            args=(process, client, download_done),
            name="dev-proxy-download",
            daemon=True,
        )
        upload.start()
        download.start()

        while True:
            if download_done.wait(0.1):
                break
            if upload_done.is_set():
                # Client EOF/error: let a request/response relay finish, but
                # never retain a child forever after its input is closed.
                download_done.wait(CONNECTION_DRAIN_TIMEOUT)
                break
    finally:
        # shutdown() wakes a blocked client.recv in the upload thread. Do it
        # before closing process pipes, then reap the child and join both
        # threads for a short bounded interval.
        try:
            client.shutdown(socket.SHUT_RDWR)
        except (OSError, ConnectionError):
            pass
        close_quietly(client)
        reap_process(process)
        if upload is not None:
            upload.join(THREAD_JOIN_TIMEOUT)
        if download is not None:
            download.join(THREAD_JOIN_TIMEOUT)


def serve():
    if len(sys.argv) != 2 or sys.argv[1] != INSTANCE_TOKEN:
        raise SystemExit("dev-proxy: invalid interop identity")

    connection_slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
    stop_requested = threading.Event()
    active_clients = set()
    active_lock = threading.Lock()
    workers = set()

    def request_stop(_signum, _frame):
        stop_requested.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    with socket.create_server(
        (LISTEN_HOST, LISTEN_PORT), family=socket.AF_INET6, reuse_port=False
    ) as server:
        server.settimeout(0.5)
        while not stop_requested.is_set():
            try:
                client_socket, _ = server.accept()
            except socket.timeout:
                continue
            except (InterruptedError, OSError):
                if stop_requested.is_set():
                    break
                raise
            if not connection_slots.acquire(blocking=False):
                close_quietly(client_socket)
                continue
            with active_lock:
                active_clients.add(client_socket)

            def run_one(sock):
                try:
                    handle(sock)
                finally:
                    with active_lock:
                        active_clients.discard(sock)
                        workers.discard(threading.current_thread())
                    connection_slots.release()

            worker = threading.Thread(
                target=run_one,
                args=(client_socket,),
                name="dev-proxy-connection",
                daemon=True,
            )
            with active_lock:
                workers.add(worker)
            worker.start()

    with active_lock:
        clients = list(active_clients)
        pending_workers = list(workers)
    for client in clients:
        try:
            client.shutdown(socket.SHUT_RDWR)
        except (OSError, ConnectionError):
            pass
        close_quietly(client)

    # A stop signal must not leave relay children behind when daemon threads
    # are about to be discarded. Each handle() owns and reaps its child; wait
    # only for this instance's workers, with a bounded shutdown window.
    deadline = time.monotonic() + CONNECTION_DRAIN_TIMEOUT + (2 * PROCESS_WAIT_TIMEOUT) + (2 * THREAD_JOIN_TIMEOUT)
    for worker in pending_workers:
        remaining = max(0.0, deadline - time.monotonic())
        worker.join(remaining)


if __name__ == "__main__":
    serve()
