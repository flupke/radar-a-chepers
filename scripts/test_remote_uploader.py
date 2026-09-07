#!/usr/bin/env python3
"""Check development-session cleanup with isolated SSH/systemd process doubles."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest


REPO = Path(__file__).resolve().parent.parent


class RemoteUploaderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="radar-session-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "app").mkdir()
        (self.root / "normal").write_text("active")
        self.runner = None
        self.write_executable(self.bin / "sudo", """
            import os, sys
            os.execvp(sys.argv[1], sys.argv[1:])
        """)
        self.write_executable(self.bin / "ssh", """
            import os, subprocess, sys
            # Unlike exec, an SSH transport closes the remote stdin pipe when
            # its local client is killed, without killing the remote command.
            remote = subprocess.Popen(['bash', '-c', sys.argv[-1]], stdin=subprocess.PIPE)
            try:
                while data := os.read(0, 4096):
                    remote.stdin.write(data)
                    remote.stdin.flush()
            except BrokenPipeError:
                pass
            remote.stdin.close()
            sys.exit(remote.wait())
        """)
        self.write_executable(self.bin / "systemctl", """
            import json, os, pathlib, signal, sys, time
            root = pathlib.Path(os.environ['REVIEW_ROOT'])
            action, unit = sys.argv[1], sys.argv[-1]
            path = root / 'unit.json'
            with (root / 'actions').open('a') as log:
                log.write(action + ' ' + unit + '\\n')
            if action == 'show':
                print('loaded' if path.exists() and json.loads(path.read_text())['active'] else 'not-found')
            elif unit.startswith('radar-dev-uploader-') and action == 'stop':
                state = json.loads(path.read_text())
                if state['active']:
                    try: os.killpg(state['pgid'], signal.SIGTERM)
                    except ProcessLookupError: pass
                    deadline = time.monotonic() + 5
                    while json.loads(path.read_text())['active']:
                        if time.monotonic() > deadline: sys.exit(1)
                        time.sleep(0.01)
            elif unit == 'radar-uploader.service' and action in ('stop', 'start'):
                if action == 'start' and (root / 'worker.json').exists():
                    pid = json.loads((root / 'worker.json').read_text())['pid']
                    stat = pathlib.Path('/proc') / str(pid) / 'stat'
                    assert not stat.exists() or stat.read_text().split()[2] == 'Z', 'restored production while development uploader was alive'
                (root / 'normal').write_text('active' if action == 'start' else 'inactive')
            else:
                raise AssertionError(sys.argv)
        """)
        self.write_executable(self.bin / "systemd-run", """
            import json, os, pathlib, signal, subprocess, sys, time
            root = pathlib.Path(os.environ['REVIEW_ROOT'])
            args = sys.argv[1:]
            (root / 'systemd-args.json').write_text(json.dumps(args))
            assert '--property=KillMode=control-group' in args
            assert '--property=TimeoutStopSec=15s' in args
            assert '--property=ExecStopPost=/usr/bin/systemctl start radar-uploader.service' in args
            # Model systemd's ExecStart dollar expansion and control-group stop.
            command = [arg.replace('$$', '$') for arg in args[args.index('/bin/bash'):]]
            worker = subprocess.Popen(command, start_new_session=True)
            state = {'pgid': worker.pid, 'active': True}
            (root / 'unit.json').write_text(json.dumps(state))
            status = worker.wait()
            try: os.killpg(worker.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            deadline = time.monotonic() + 3
            if (root / 'worker.json').exists():
                pid = json.loads((root / 'worker.json').read_text())['pid']
                stat = pathlib.Path('/proc') / str(pid) / 'stat'
                while stat.exists() and stat.read_text().split()[2] != 'Z':
                    assert time.monotonic() < deadline, 'uploader did not terminate'
                    time.sleep(0.01)
            state['active'] = False
            (root / 'unit.json').write_text(json.dumps(state))
            subprocess.run(['systemctl', 'start', 'radar-uploader.service'], check=True)
            sys.exit(status)
        """)
        self.write_executable(self.root / "app/uploader", """
            import json, os, pathlib, sys, time
            root = pathlib.Path(os.environ['REVIEW_ROOT'])
            (root / 'worker.json').write_text(json.dumps({'pid': os.getpid(), 'args': sys.argv[1:]}))
            time.sleep(60)
        """)

    def tearDown(self):
        # Clean both the local session and the simulated service group on failure.
        state = self.root / "unit.json"
        if state.exists():
            try:
                os.killpg(json.loads(state.read_text())["pgid"], signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.runner:
            try:
                os.killpg(self.runner.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.runner.wait(timeout=5)

    @staticmethod
    def write_executable(path, code):
        path.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(code))
        path.chmod(0o755)

    def wait_for(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("Session did not reach expected state; " + (self.root / "output").read_text())
            time.sleep(0.02)

    def launch(self, cleanup):
        definitions = (REPO / "start.sh").read_text().split('while [ "$#" -gt 0 ]; do', 1)[0]
        definitions = definitions.replace(
            'ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"',
            "ROOT_DIR=" + shlex.quote(str(REPO)),
        )
        script = definitions + "\n" + ("" if cleanup else "trap - EXIT INT TERM\n") + """
REMOTE_UPLOADER_HOST=review-pi
REMOTE_APP_DIR="$REVIEW_ROOT/app"
SSH_BIN="$REVIEW_ROOT/bin/ssh"
RADAR_DEVICE=rd03d
start_remote_uploader http://review.invalid 'review-$key with spaces'
printf '%s' "${CHILD_PIDS[0]}" > "$REVIEW_ROOT/ssh.pid"
wait "${CHILD_PIDS[@]}"
"""
        with (self.root / "output").open("w") as output:
            self.runner = subprocess.Popen(
                ["bash", "-c", script], stdin=subprocess.DEVNULL,
                stdout=output, stderr=output, start_new_session=True,
                env=dict(os.environ, REVIEW_ROOT=str(self.root), PATH=str(self.bin) + os.pathsep + os.environ["PATH"]),
            )
        self.wait_for(lambda: (self.root / "worker.json").exists())
        self.assertEqual((self.root / "normal").read_text(), "inactive")
        worker_args = json.loads((self.root / "worker.json").read_text())["args"]
        self.assertEqual(worker_args[worker_args.index("--api-key") + 1], "review-$key with spaces")

    def test_normal_shutdown_awaits_remote_unit_before_restoring_production(self):
        self.launch(cleanup=True)
        self.runner.send_signal(signal.SIGTERM)
        self.runner.wait(timeout=8)
        self.assertEqual(self.runner.returncode, 143, (self.root / "output").read_text())
        self.wait_for(lambda: (self.root / "normal").read_text() == "active")
        self.assertFalse(json.loads((self.root / "unit.json").read_text())["active"])
        self.assertNotIn("AssertionError", (self.root / "output").read_text())

    def test_disconnected_ssh_restores_production_without_local_cleanup(self):
        self.launch(cleanup=False)
        os.kill(int((self.root / "ssh.pid").read_text()), signal.SIGTERM)
        self.runner.wait(timeout=5)
        self.wait_for(lambda: (self.root / "normal").read_text() == "active")
        self.assertFalse(json.loads((self.root / "unit.json").read_text())["active"])
        self.assertNotIn("AssertionError", (self.root / "output").read_text())

    def test_killed_local_parent_ends_the_heartbeat_lease(self):
        self.launch(cleanup=False)
        self.runner.kill()
        self.runner.wait(timeout=5)
        self.wait_for(lambda: (self.root / "normal").read_text() == "active", timeout=8)
        self.assertFalse(json.loads((self.root / "unit.json").read_text())["active"])
        self.assertNotIn("AssertionError", (self.root / "output").read_text())


if __name__ == "__main__":
    unittest.main()
