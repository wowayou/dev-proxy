"""Isolation tests for the generated WSL interop runtime."""

import importlib.util
import os
import base64
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "templates" / "wsl-interop-proxy.py"


# os.read returns available bytes immediately. Buffered read(65536) can wait
# for EOF after a small request and accidentally test the relay, not the bridge.
FAKE_RELAY = textwrap.dedent(
    r"""
    #!/usr/bin/env python3
    import os
    import time

    marker_dir = os.environ.get("DEV_PROXY_TEST_MARKERS")
    if marker_dir:
        with open(os.path.join(marker_dir, str(os.getpid())), "w", encoding="ascii") as handle:
            handle.write(os.environ.get("WSL_INTEROP", "<unset>"))

    mode = "echo"
    mode_file = os.environ.get("DEV_PROXY_TEST_RELAY_MODE_FILE")
    if mode_file:
        try:
            with open(mode_file, "r", encoding="ascii") as handle:
                mode = handle.read().strip() or mode
        except FileNotFoundError:
            pass

    if mode == "no-read":
        time.sleep(30)
        raise SystemExit(0)

    while True:
        chunk = os.read(0, 65536)
        if not chunk:
            break
        if mode == "exit":
            os._exit(0)
        if mode != "silent":
            view = memoryview(chunk)
            while view:
                view = view[os.write(1, view):]
    if mode == "hang":
        time.sleep(30)
    """
).lstrip()


@unittest.skipUnless(os.name == "posix", "the interop daemon runs in WSL")
class InteropRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dev-proxy-interop-")
        self.work = Path(self.temp.name)
        self.markers = self.work / "markers"
        self.markers.mkdir()
        self.mode_file = self.work / "relay-mode"
        self.mode_file.write_text("echo", encoding="ascii")
        self.relay = self.work / "relay.py"
        self.relay.write_text(FAKE_RELAY, encoding="utf-8")
        self.relay.chmod(self.relay.stat().st_mode | stat.S_IXUSR)
        self.port = self._free_port()
        source = TEMPLATE.read_text(encoding="utf-8")
        for old, new in (("__INTEROP_PORT__", str(self.port)), ("__INSTANCE_TOKEN__", "test-instance"), ("__WINDOWS_RELAY_ENCODED__", "AA==")):
            source = source.replace(old, new)
        self.runtime = self.work / "interop.py"
        self.runtime.write_text(source, encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update({
            "DEV_PROXY_WINDOWS_EXECUTABLE": str(self.relay),
            "DEV_PROXY_TEST_MARKERS": str(self.markers),
            "DEV_PROXY_TEST_RELAY_MODE_FILE": str(self.mode_file),
            "PYTHONUNBUFFERED": "1",
        })
        self.server = self._start_server()
        self._wait_ready()

    def tearDown(self):
        self._stop_server()
        self.temp.cleanup()

    @staticmethod
    def _free_port():
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as probe:
            probe.bind(("::1", 0))
            return probe.getsockname()[1]

    def _start_server(self, env=None):
        return subprocess.Popen([sys.executable, str(self.runtime), "test-instance"], cwd=self.work, env=env or self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def _stop_server(self):
        if not self.server:
            return
        if self.server.poll() is None:
            self.server.terminate()
            try:
                self.server.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait(timeout=2)
        if self.server.stderr:
            self.server.stderr.close()
        self.server = None

    def _wait_ready(self):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("::1", self.port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.02)
        self.fail("interop runtime did not bind IPv6 loopback")

    def _connect(self):
        return socket.create_connection(("::1", self.port), timeout=30)

    def _marker_paths(self):
        return list(self.markers.iterdir())

    def _wait_markers(self, expected, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if len(self._marker_paths()) == expected:
                return
            time.sleep(0.03)
        self.assertEqual(expected, len(self._marker_paths()))

    @staticmethod
    def _pid_alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    @staticmethod
    def _linux_counts(pid):
        return (
            len(list((Path("/proc") / str(pid) / "task").iterdir())),
            len(list((Path("/proc") / str(pid) / "fd").iterdir())),
        )

    def _wait_linux_quiescent(self, baseline, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._linux_counts(self.server.pid) == baseline:
                return
            time.sleep(0.05)
        self.fail(
            "Linux daemon did not return to baseline threads/fds: %s != %s"
            % (self._linux_counts(self.server.pid), baseline)
        )

    def _start_blocked_upload(self):
        self.mode_file.write_text("no-read", encoding="ascii")
        client = self._connect()
        client.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
        errors = []

        def send_large_request():
            try:
                client.sendall(b"x" * (8 * 1024 * 1024))
            except (BrokenPipeError, ConnectionError, OSError) as error:
                errors.append(error)

        sender = threading.Thread(target=send_large_request, daemon=True)
        sender.start()
        self._wait_markers(1)
        time.sleep(0.3)
        return client, sender, errors

    def _wait_children_gone(self, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not any(self._pid_alive(int(path.name)) for path in self._marker_paths()):
                return
            time.sleep(0.03)
        self.fail("relay children still alive")

    @staticmethod
    def _read_until_eof(client):
        received = bytearray()
        while True:
            chunk = client.recv(65536)
            if not chunk:
                return bytes(received)
            received.extend(chunk)

    def test_large_binary_payload_is_preserved(self):
        payload = bytes(range(256)) * 32768
        client = self._connect()
        client.settimeout(30)
        send_errors = []

        def send_payload():
            try:
                client.sendall(payload)
                client.shutdown(socket.SHUT_WR)
            except BaseException as error:
                send_errors.append(error)

        sender = threading.Thread(target=send_payload, daemon=True)
        sender.start()
        received = self._read_until_eof(client)
        sender.join(timeout=30)
        self.assertFalse(sender.is_alive())
        self.assertEqual([], send_errors)
        self.assertEqual(payload, received)
        client.close()
        self._wait_markers(1)
        self._wait_children_gone()

    def test_stream_survives_idle_longer_than_ten_seconds(self):
        client = self._connect()
        client.sendall(b"first")
        self.assertEqual(b"first", client.recv(5))
        time.sleep(10.2)
        client.sendall(b"second")
        self.assertEqual(b"second", client.recv(6))
        client.shutdown(socket.SHUT_WR)
        self.assertEqual(b"", self._read_until_eof(client))
        client.close()
        self._wait_children_gone()

    def test_fin_and_rst_reclaim_relay_child(self):
        client = self._connect()
        client.sendall(b"fin")
        client.shutdown(socket.SHUT_WR)
        self.assertEqual(b"fin", client.recv(3))
        self.assertEqual(b"", self._read_until_eof(client))
        client.close()
        self._wait_children_gone()

        client = self._connect()
        client.sendall(b"rst")
        self.assertEqual(b"rst", client.recv(3))
        client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        client.close()
        self._wait_markers(2)
        self._wait_children_gone()
        self.assertIsNone(self.server.poll())

    def test_hanging_child_is_reclaimed_after_client_eof(self):
        self.mode_file.write_text("hang", encoding="ascii")
        client = self._connect()
        client.sendall(b"request")
        client.shutdown(socket.SHUT_WR)
        self.assertEqual(b"request", client.recv(7))
        client.settimeout(7)
        self.assertEqual(b"", self._read_until_eof(client))
        client.close()
        self._wait_children_gone()

    def test_blocked_upload_rst_reclaims_child_threads_fds_and_slot(self):
        time.sleep(0.2)
        baseline = self._linux_counts(self.server.pid)
        client, sender, _errors = self._start_blocked_upload()
        client.setsockopt(
            socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
        )
        try:
            client.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        client.close()
        sender.join(timeout=5)
        self.assertFalse(sender.is_alive())
        self._wait_children_gone(timeout=8)
        self._wait_linux_quiescent(baseline)
        self.assertIsNone(self.server.poll())

        # The connection permit must also be reusable after the blocked path.
        self.mode_file.write_text("echo", encoding="ascii")
        probe = self._connect()
        probe.sendall(b"ok")
        self.assertEqual(b"ok", probe.recv(2))
        probe.close()
        self._wait_markers(2)
        self._wait_children_gone(timeout=8)
        self._wait_linux_quiescent(baseline)

    def test_daemon_shutdown_reaps_child_during_blocked_upload(self):
        client, sender, _errors = self._start_blocked_upload()
        self.server.terminate()
        self.server.wait(timeout=10)
        self.assertEqual(0, self.server.returncode)
        try:
            client.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        client.close()
        sender.join(timeout=5)
        self.assertFalse(sender.is_alive())
        self._wait_children_gone(timeout=8)

    def test_child_exit_closes_a_still_silent_client(self):
        self.mode_file.write_text("exit", encoding="ascii")
        client = self._connect()
        client.sendall(b"request")
        client.settimeout(5)
        self.assertEqual(b"", client.recv(1))
        client.close()
        self._wait_markers(1)
        self._wait_children_gone()

    def test_daemon_shutdown_reclaims_active_relay_child(self):
        self.mode_file.write_text("hang", encoding="ascii")
        client = self._connect()
        client.sendall(b"request")
        self.assertEqual(b"request", client.recv(7))
        self.server.terminate()
        self.server.wait(timeout=10)
        client.close()
        self._wait_markers(1)
        self._wait_children_gone()

    def test_zero_byte_probe_does_not_start_child(self):
        client = self._connect()
        client.close()
        time.sleep(0.4)
        self.assertEqual([], self._marker_paths())

    def test_first_byte_timeout_is_clean_and_reclaims_client(self):
        client = self._connect()
        client.settimeout(12)
        self.assertEqual(b"", client.recv(1))
        client.close()
        self.assertIsNone(self.server.poll())
        os.set_blocking(self.server.stderr.fileno(), False)
        self.assertNotIn(b"Traceback", self.server.stderr.read() or b"")

    def test_connection_cap_recovers_after_all_clients_close(self):
        clients = []
        try:
            for _ in range(32):
                client = self._connect()
                client.sendall(b"x")
                clients.append(client)
            self._wait_markers(32)
            extra = self._connect()
            extra.settimeout(1)
            self.assertEqual(b"", extra.recv(1))
            extra.close()
        finally:
            for client in clients:
                client.close()
        self._wait_children_gone(timeout=10)
        client = self._connect()
        client.sendall(b"ok")
        self.assertEqual(b"ok", client.recv(2))
        client.close()
        self._wait_markers(33)
        self._wait_children_gone(timeout=10)

    def test_invalid_identity_is_rejected(self):
        result = subprocess.run([sys.executable, str(self.runtime), "wrong-instance"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("invalid interop identity", result.stderr)

    def test_missing_executable_does_not_spawn_or_crash_server(self):
        self._stop_server()
        env = self.env.copy()
        env["DEV_PROXY_WINDOWS_EXECUTABLE"] = str(self.work / "missing.exe")
        self.server = self._start_server(env)
        self._wait_ready()
        client = self._connect()
        client.sendall(b"request")
        client.settimeout(2)
        self.assertEqual(b"", self._read_until_eof(client))
        client.close()
        self.assertEqual([], self._marker_paths())
        self.assertIsNone(self.server.poll())

    def test_stale_interop_path_is_removed_from_child_environment(self):
        self._stop_server()
        env = self.env.copy()
        env["WSL_INTEROP"] = str(self.work / "stale-interop")
        self.server = self._start_server(env)
        self._wait_ready()
        client = self._connect()
        client.sendall(b"env")
        self.assertEqual(b"env", client.recv(3))
        client.shutdown(socket.SHUT_WR)
        self.assertEqual(b"", self._read_until_eof(client))
        client.close()
        self._wait_markers(1)
        recorded = [path.read_text(encoding="ascii") for path in self._marker_paths()]
        self.assertEqual(1, len(recorded))
        self.assertNotEqual(str(env["WSL_INTEROP"]), recorded[0])

    def test_valid_interop_socket_is_forwarded_to_child(self):
        interop_path = self.work / "valid-interop"
        interop = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        interop.bind(str(interop_path))
        interop.listen(1)
        try:
            self._stop_server()
            env = self.env.copy()
            env["WSL_INTEROP"] = str(interop_path)
            self.server = self._start_server(env)
            self._wait_ready()
            client = self._connect()
            client.sendall(b"env")
            self.assertEqual(b"env", client.recv(3))
            client.shutdown(socket.SHUT_WR)
            self.assertEqual(b"", self._read_until_eof(client))
            client.close()
            self._wait_markers(1)
            self.assertEqual([str(interop_path)], [path.read_text(encoding="ascii") for path in self._marker_paths()])
        finally:
            interop.close()


class InteropRuntimeUnitTests(unittest.TestCase):
    def test_write_all_handles_partial_writes(self):
        source = TEMPLATE.read_text(encoding="utf-8")
        for old, new in (("__INTEROP_PORT__", "1"), ("__INSTANCE_TOKEN__", "unit-instance"), ("__WINDOWS_RELAY_ENCODED__", "AA==")):
            source = source.replace(old, new)
        with tempfile.TemporaryDirectory(prefix="dev-proxy-runtime-") as directory:
            path = Path(directory) / "runtime.py"
            path.write_text(source, encoding="utf-8")
            spec = importlib.util.spec_from_file_location("interop_runtime_unit", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)

            class PartialStream:
                def __init__(self):
                    self.data = bytearray()

                def write(self, chunk):
                    count = min(3, len(chunk))
                    self.data.extend(chunk[:count])
                    return count

            stream = PartialStream()
            payload = os.urandom(200000)
            module.write_all(stream, payload)
            self.assertEqual(payload, bytes(stream.data))


@unittest.skipUnless(
    os.name == "posix" and os.environ.get("DEV_PROXY_TEST_REAL_WINDOWS") == "1",
    "opt-in WSL-to-Windows relay test",
)
class RealWindowsRelayTests(unittest.TestCase):
    """Exercise a real powershell.exe child against a credentialless echo target."""

    def test_real_windows_process_streams_and_exits(self):
        powershell = shutil.which("powershell.exe")
        if not powershell:
            self.skipTest("powershell.exe is unavailable")

        with tempfile.TemporaryDirectory(prefix="dev-proxy-real-relay-") as directory:
            work = Path(directory)
            runtime_port = self._free_port(socket.AF_INET6, "::1")
            marker_name = "dev-proxy-real-%s-%s.txt" % (os.getpid(), runtime_port)
            windows_temp = subprocess.check_output(
                [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "[IO.Path]::GetTempPath()"],
                text=True,
            ).strip()
            marker = windows_temp.rstrip("\\/") + "\\" + marker_name
            target_script = textwrap.dedent("""
                $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'), 0)
                $listener.Start()
                [Console]::Out.WriteLine($listener.LocalEndpoint.Port)
                [Console]::Out.Flush()
                try {
                    for ($index = 0; $index -lt 2; $index++) {
                        $connection = $listener.AcceptTcpClient()
                        try {
                            $stream = $connection.GetStream()
                            $buffer = New-Object byte[] 65536
                            while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $stream.Write($buffer, 0, $count) }
                        } catch [IO.IOException] { }
                        finally { $connection.Close() }
                    }
                } finally { $listener.Stop() }
            """).strip()
            target = subprocess.Popen(
                [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", target_script],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            target_port_line = target.stdout.readline()
            if not target_port_line:
                diagnostics = target.stderr.read().decode("utf-8", "replace")
                target.wait(timeout=5)
                self.fail("echo target did not publish a port: " + diagnostics)
            target_port = int(target_port_line.decode("ascii").strip())
            source = TEMPLATE.read_text(encoding="utf-8")
            marker_literal = marker.replace("'", "''")
            relay = textwrap.dedent(f"""
                $ErrorActionPreference = 'Stop'
                Add-Content -LiteralPath '{marker_literal}' -Value ([string]$PID)
                $client = New-Object Net.Sockets.TcpClient
                try {{
                    $connect = $client.BeginConnect('127.0.0.1', {target_port}, $null, $null)
                    if (-not $connect.AsyncWaitHandle.WaitOne(5000, $false)) {{ throw 'target connect timeout' }}
                    $client.EndConnect($connect)
                    $network = $client.GetStream()
                    $stdin = [Console]::OpenStandardInput()
                    $stdout = [Console]::OpenStandardOutput()
                    $upload = $stdin.CopyToAsync($network)
                    $download = $network.CopyToAsync($stdout)
                    while (-not $download.IsCompleted) {{
                        if ($upload.IsCompleted) {{
                            try {{ $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send) }} catch {{ }}
                            break
                        }}
                        [Threading.Thread]::Sleep(25)
                    }}
                    $null = $download.GetAwaiter().GetResult()
                }} finally {{ $client.Close() }}
            """).strip()
            source = source.replace("__INTEROP_PORT__", str(runtime_port))
            source = source.replace("__INSTANCE_TOKEN__", "real-windows-test")
            source = source.replace(
                "__WINDOWS_RELAY_ENCODED__",
                base64.b64encode(relay.encode("utf-16le")).decode("ascii"),
            )
            runtime = work / "interop.py"
            runtime.write_text(source, encoding="utf-8")
            env = os.environ.copy()
            env["DEV_PROXY_WINDOWS_EXECUTABLE"] = powershell
            env["DEV_PROXY_REAL_MARKER"] = marker
            server = subprocess.Popen(
                [sys.executable, str(runtime), "real-windows-test"],
                cwd=work,
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            try:
                self._wait_ready(runtime_port)
                time.sleep(0.3)
                baseline = self._linux_counts(server.pid)
                client = socket.create_connection(("::1", runtime_port), timeout=30)
                client.sendall(b"first")
                self.assertEqual(b"first", client.recv(5))
                time.sleep(10.2)
                client.sendall(b"second")
                self.assertEqual(b"second", client.recv(6))
                client.shutdown(socket.SHUT_WR)
                self.assertEqual(b"", self._read_until_eof(client))
                client.close()
                pids = self._wait_marker_pids(powershell, marker, 1)
                sys.stderr.write("real relay Windows PID after FIN: %s; Linux baseline threads/fds=%s\n" % (pids[0], baseline))
                self._wait_windows_pids_gone(powershell, pids)
                self._wait_linux_quiescent(server.pid, baseline)

                client = socket.create_connection(("::1", runtime_port), timeout=30)
                client.sendall(b"r")
                self.assertEqual(b"r", client.recv(1))
                client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                client.close()
                pids = self._wait_marker_pids(powershell, marker, 2)
                sys.stderr.write("real relay Windows PIDs after RST: %s; Linux baseline threads/fds=%s\n" % (pids, baseline))
                self._wait_windows_pids_gone(powershell, pids)
                self._wait_linux_quiescent(server.pid, baseline)
            finally:
                if server.poll() is None:
                    server.terminate()
                server.wait(timeout=5)
                if target.poll() is None:
                    target.terminate()
                target.wait(timeout=5)
                if server.stderr:
                    diagnostics = server.stderr.read().decode("utf-8", "replace")
                    if diagnostics:
                        sys.stderr.write("real relay stderr: " + diagnostics)
                    server.stderr.close()
                if target.stderr:
                    diagnostics = target.stderr.read().decode("utf-8", "replace")
                    if diagnostics:
                        sys.stderr.write("echo target stderr: " + diagnostics)
                    target.stderr.close()
                if target.stdout:
                    target.stdout.close()
                subprocess.run(
                    [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Remove-Item -LiteralPath '%s' -Force -ErrorAction SilentlyContinue" % marker.replace("'", "''")],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )

    @staticmethod
    def _linux_counts(pid):
        return (
            len(list((Path("/proc") / str(pid) / "task").iterdir())),
            len(list((Path("/proc") / str(pid) / "fd").iterdir())),
        )

    @staticmethod
    def _windows_marker_pids(powershell, marker):
        command = "if (Test-Path -LiteralPath '%s') { Get-Content -LiteralPath '%s' }" % (
            marker.replace("'", "''"), marker.replace("'", "''"),
        )
        try:
            result = subprocess.run(
                [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
                timeout=5,
            )
        except subprocess.TimeoutExpired as error:
            raise AssertionError("Windows marker query timed out") from error
        if result.returncode != 0:
            raise AssertionError("Windows marker query failed: %s" % result.returncode)
        return [int(line.strip()) for line in result.stdout.splitlines() if line.strip().isdigit()]

    def _wait_marker_pids(self, powershell, marker, expected):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            pids = self._windows_marker_pids(powershell, marker)
            if len(pids) >= expected:
                return pids
            time.sleep(0.1)
        self.fail("Windows relay marker did not record %d PIDs" % expected)

    @staticmethod
    def _windows_process_exists(powershell, pid):
        try:
            result = subprocess.run(
                [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "(Get-Process -Id %d -ErrorAction SilentlyContinue) -ne $null" % pid],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
                timeout=5,
            )
        except subprocess.TimeoutExpired as error:
            raise AssertionError("Windows process query timed out for PID %d" % pid) from error
        if result.returncode != 0 or result.stdout.strip().lower() not in ("true", "false"):
            raise AssertionError("Windows process query failed for PID %d" % pid)
        return result.stdout.strip().lower() == "true"

    def _wait_windows_pids_gone(self, powershell, pids):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if not any(self._windows_process_exists(powershell, pid) for pid in pids):
                return
            time.sleep(0.1)
        self.fail("Windows relay PIDs still alive: %s" % pids)

    def _wait_linux_quiescent(self, pid, baseline):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self._linux_counts(pid) == baseline:
                return
            time.sleep(0.05)
        self.fail("Linux daemon did not return to baseline threads/fds: %s != %s" % (self._linux_counts(pid), baseline))

    @staticmethod
    def _free_port(family, host):
        with socket.socket(family, socket.SOCK_STREAM) as probe:
            probe.bind((host, 0))
            return probe.getsockname()[1]

    @staticmethod
    def _wait_ready(port):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("::1", port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.02)
        raise AssertionError("real relay runtime did not bind")

    @staticmethod
    def _read_until_eof(client):
        output = bytearray()
        while True:
            chunk = client.recv(65536)
            if not chunk:
                return bytes(output)
            output.extend(chunk)


if __name__ == "__main__":
    unittest.main()
