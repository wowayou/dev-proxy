"""Offline lifecycle checks for the generated WSL shell profile.

The fixture uses a temporary HOME and loopback port.  It never sources the
installed user profile or touches the production relay state.
"""

import os
import socket
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "templates" / "wsl-proxy-env.sh"


RELAY = textwrap.dedent(
    """
    import os, socket, sys, time
    port = int(os.environ["DEV_PROXY_TEST_PORT"])
    server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("::1", port))
    server.listen(4)
    while True:
        client, _ = server.accept()
        client.close()
    """
).lstrip()


@unittest.skipUnless(os.name == "posix", "the shell profile runs in WSL")
class ShellTemplateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dev-proxy-shell-")
        self.home = Path(self.temp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.port = self._free_port()
        self.target_port = self._free_ipv4_port()
        while self.target_port == self.port:
            self.target_port = self._free_ipv4_port()
        self.token = "a" * 64
        self.base = self.home / ".config" / "dev-proxy"
        self.base.mkdir(parents=True)
        (self.base / "interop-proxy.py").write_text(RELAY, encoding="utf-8")
        (self.base / "interop-proxy.py").chmod(0o700)
        self._write_executable("wslinfo", "#!/bin/sh\nprintf mirrored\n")
        self._write_executable("powershell.exe", "#!/bin/sh\nexit 0\n")
        source = TEMPLATE.read_text(encoding="utf-8")
        source = source.replace("__PROXY_SCHEME__", "http")
        source = source.replace("__PROXY_HOST__", "127.0.0.1")
        source = source.replace("__PROXY_PORT__", str(self.target_port))
        source = source.replace("__INTEROP_PORT__", str(self.port))
        source = source.replace("__INTEROP_FALLBACK__", "true")
        source = source.replace("__NO_PROXY__", "localhost,127.0.0.1,.local")
        source = source.replace("__MIRRORED_PROXY_HOSTS__", "127.0.0.1")
        source = source.replace("__INSTANCE_TOKEN__", self.token)
        self.profile = self.base / "proxy-env.sh"
        self.profile.write_text(source, encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), PATH=f"{self.bin}:{self.env.get('PATH', '')}", DEV_PROXY_TEST_PORT=str(self.port))

    def tearDown(self):
        for path in self.base.glob("interop-*/pid"):
            try:
                os.kill(int(path.read_text().strip()), 15)
            except (ValueError, OSError):
                pass
        self.temp.cleanup()

    def _write_executable(self, name, body):
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    @staticmethod
    def _free_port():
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as probe:
            probe.bind(("::1", 0))
            return probe.getsockname()[1]

    @staticmethod
    def _free_ipv4_port():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.bind(("127.0.0.1", 0))
            return probe.getsockname()[1]

    def _source(self, extra=""):
        command = f'. "{self.profile}"; {extra}'
        return subprocess.run(
            ["bash", "-c", command], env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def _set_profile_values(self, old, new):
        self.profile.write_text(self.profile.read_text(encoding="utf-8").replace(old, new), encoding="utf-8")

    def test_concurrent_sources_share_one_generation(self):
        script = f'. "{self.profile}"; printf "%s\\n" "$DEV_PROXY_HOST_SOURCE"'
        with tempfile.TemporaryDirectory(prefix="dev-proxy-shell-concurrent-") as work:
            first = subprocess.Popen(["bash", "-c", script], env=self.env, cwd=work,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            second = subprocess.Popen(["bash", "-c", script], env=self.env, cwd=work,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            out1, _ = first.communicate(timeout=12)
            out2, _ = second.communicate(timeout=12)
        self.assertEqual(0, first.returncode)
        self.assertEqual(0, second.returncode)
        self.assertEqual(["mirrored-interop"], [line for line in out1.splitlines() if line])
        self.assertEqual(["mirrored-interop"], [line for line in out2.splitlines() if line])
        state = self.base / f"interop-{self.port}-{self.token}"
        self.assertTrue((state / "pid").is_file())
        self.assertTrue((state / "starttime").read_text().strip().isdigit())

    def test_native_mirrored_localhost_wins_without_starting_relay(self):
        holder = subprocess.Popen(
            [sys.executable, "-c", "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',int(__import__('sys').argv[1]))); s.listen(); time.sleep(20)", str(self.target_port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            time.sleep(0.15)
            result = self._source("printf '%s,%s\\n' \"$DEV_PROXY_HOST_SOURCE\" \"$DEV_PROXY_PORT\"")
            self.assertEqual(0, result.returncode)
            self.assertIn(f"mirrored-localhost,{self.target_port}", result.stdout)
            self.assertFalse(any(self.base.glob("interop-*/pid")))
        finally:
            holder.terminate()
            holder.wait(timeout=2)

    def test_disabled_fallback_never_starts_relay(self):
        self._set_profile_values("DEV_PROXY_INTEROP_FALLBACK='true'", "DEV_PROXY_INTEROP_FALLBACK='false'")
        result = self._source("proxy_status")
        self.assertEqual(0, result.returncode)
        self.assertIn("DEV_PROXY_INTEROP_FALLBACK=false", result.stdout)
        self.assertIn("DEV_PROXY_HOST_SOURCE=mirrored-localhost", result.stdout)
        self.assertIn("proxy_tcp=unreachable", result.stdout)
        self.assertFalse(any(self.base.glob("interop-*/pid")))

    def test_legacy_pid_is_not_overwritten(self):
        legacy = self.base / "interop-proxy.pid"
        legacy.write_text("1187\n", encoding="ascii")
        result = self._source("proxy_status")
        self.assertEqual(0, result.returncode)
        self.assertEqual("1187\n", legacy.read_text(encoding="ascii"))

    def test_foreign_listener_is_never_accepted_or_killed(self):
        holder = subprocess.Popen(
            [sys.executable, "-c", "import socket,time; s=socket.socket(socket.AF_INET6); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('::1',int(__import__('sys').argv[1]))); s.listen(); time.sleep(20)", str(self.port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            time.sleep(0.15)
            result = self._source("proxy_status")
            self.assertIn("unknown process or prior generation", result.stderr)
            self.assertIsNone(holder.poll())
        finally:
            holder.terminate()
            holder.wait(timeout=2)

    def test_stale_starttime_does_not_kill_reused_pid(self):
        sleeper = subprocess.Popen(["sleep", "20"])
        state = self.base / f"interop-{self.port}-{self.token}"
        state.mkdir()
        (state / "pid").write_text(str(sleeper.pid), encoding="ascii")
        (state / "starttime").write_text("1", encoding="ascii")
        try:
            result = self._source("printf '%s\\n' \"$DEV_PROXY_HOST_SOURCE\"")
            self.assertEqual(0, result.returncode)
            self.assertIn("mirrored-interop", result.stdout)
            self.assertIsNone(sleeper.poll())
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=2)

    def test_proxy_off_is_disabled_without_a_tcp_probe(self):
        counter = self.home / "nc-calls"
        self._write_executable("nc", f"#!/bin/sh\nprintf x >> '{counter}'\nexit 1\n")
        result = self._source(f"before=$(wc -c < '{counter}' 2>/dev/null || echo 0); proxy_off; proxy_status; after=$(wc -c < '{counter}' 2>/dev/null || echo 0); printf 'COUNTS=%s,%s\\n' \"$before\" \"$after\"")
        self.assertEqual(0, result.returncode)
        self.assertIn("proxy_tcp=disabled", result.stdout)
        self.assertIn("COUNTS=", result.stdout)
        counts = result.stdout.split("COUNTS=")[-1].strip().split(",")
        self.assertGreater(int(counts[0]), 0)
        self.assertEqual(counts[0], counts[1])

    def test_nat_mode_uses_gateway_when_wslinfo_is_missing(self):
        # Keep the command name shadowed but make it unavailable, which also
        # works on WSL images that provide a system wslinfo in /usr/bin.
        self._write_executable("wslinfo", "#!/bin/sh\nexit 127\n")
        self._write_executable("ip", "#!/bin/sh\nprintf 'default via 172.17.0.1 dev eth0\\n'\n")
        result = self._source("proxy_status")
        self.assertEqual(0, result.returncode)
        self.assertIn("DEV_PROXY_NETWORKING_MODE=nat", result.stdout)
        self.assertIn("DEV_PROXY_HOST_SOURCE=nat-gateway", result.stdout)
        self.assertIn("DEV_PROXY_HOST=172.17.0.1", result.stdout)

    def test_literal_no_proxy_is_not_executed(self):
        marker = self.home / "literal-marker"
        literal = f"literal$(touch {marker})`echo nope`"
        source = self.profile.read_text(encoding="utf-8").replace("localhost,127.0.0.1,.local", literal)
        self.profile.write_text(source, encoding="utf-8")
        result = self._source("printf '%s\\n' \"$NO_PROXY\"")
        self.assertEqual(0, result.returncode)
        self.assertFalse(marker.exists())
        self.assertIn(literal, result.stdout)

    def test_proxy_refresh_reloads_installed_profile(self):
        new_port = self._free_port()
        self.env["DEV_PROXY_TEST_PORT"] = str(new_port)
        source = self.profile.read_text(encoding="utf-8")
        source = source.replace(str(self.port), str(new_port))
        replacement = self.home / "replacement-profile.sh"
        replacement.write_text(source, encoding="utf-8")
        result = self._source(f"cp '{replacement}' '{self.profile}'; proxy_refresh; printf '%s,%s\\n' \"$DEV_PROXY_INTEROP_PORT\" \"$DEV_PROXY_PORT\"")
        self.assertEqual(0, result.returncode)
        self.assertIn(f"{new_port},{new_port}", result.stdout)

    def test_old_generation_listener_is_not_claimed_by_new_token(self):
        old_token = "b" * 64
        holder = subprocess.Popen(
            [sys.executable, "-c", "import os,socket,time; s=socket.socket(socket.AF_INET6); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('::1',int(os.environ['DEV_PROXY_TEST_PORT']))); s.listen(); time.sleep(20)"],
            env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        old_state = self.base / f"interop-{self.port}-{old_token}"
        old_state.mkdir()
        try:
            time.sleep(0.15)
            starttime = Path(f"/proc/{holder.pid}/stat").read_text().split()[21]
            (old_state / "pid").write_text(str(holder.pid), encoding="ascii")
            (old_state / "starttime").write_text(starttime, encoding="ascii")
            result = self._source("proxy_status")
            self.assertIn("unknown process or prior generation", result.stderr)
            self.assertIsNone(holder.poll())
        finally:
            holder.terminate()
            holder.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
