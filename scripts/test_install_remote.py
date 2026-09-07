#!/usr/bin/env python3
"""Exercise deployment and rollback in temporary directories, without sudo/hardware."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


HELPER = Path(__file__).with_name("install-remote.sh")


class RemoteInstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="radar-install-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.stage = self.root / "staging"
        self.app = self.root / "app"
        self.bin = self.root / "bin"
        for directory in (self.stage, self.app, self.bin):
            directory.mkdir()
        self.service = "radar-uploader.service"
        self.unit = self.root / self.service
        self.elf = self.app / "radar-a-chepers"
        self.flasher = self.bin / "espflash"
        self.env_file = self.app / ".env"
        self.state = self.root / "state.json"
        self.log = self.root / "actions.jsonl"
        self.hardware = self.root / "firmware"
        self.state.write_text(json.dumps({"active": True, "enabled": True}))
        self.hardware.write_text("old firmware")
        self.elf.write_text("old firmware")
        self.unit.write_text("old unit")
        (self.app / "uploader").write_text("old uploader")
        self.env_file.write_text("old environment")
        self.env_file.chmod(0o600)
        (self.stage / "radar-a-chepers").write_text("new firmware")
        (self.stage / "uploader").write_text("new uploader")
        (self.stage / "uploader.env").write_text("new environment")
        (self.stage / self.service).write_text("new unit")
        self.environment = dict(
            os.environ,
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            REVIEW_ROOT=str(self.root),
        )
        self.write_executable(self.bin / "systemctl", """
            import json, os, pathlib, sys
            root = pathlib.Path(os.environ['REVIEW_ROOT'])
            state_file = root / 'state.json'
            state = json.loads(state_file.read_text())
            action = sys.argv[1]
            with (root / 'actions.jsonl').open('a') as log:
                log.write(json.dumps(['systemctl', action]) + '\\n')
            if action == 'show':
                print('loaded' if (root / 'radar-uploader.service').exists() else 'not-found')
            elif action == 'is-active':
                sys.exit(0 if state['active'] else 3)
            elif action == 'is-enabled':
                sys.exit(0 if state['enabled'] else 1)
            elif action == 'stop':
                state['active'] = False
            elif action == 'start':
                assert (root / 'firmware').read_text() == (root / 'app/radar-a-chepers').read_text(), 'mismatched firmware/ELF'
                if os.environ.get('FAIL_START_NEW') and (root / 'firmware').read_text() == 'new firmware':
                    sys.exit(7)
                state['active'] = True
            elif action == 'enable':
                state['enabled'] = True
            elif action == 'disable':
                state['enabled'] = False
            elif action != 'daemon-reload':
                raise AssertionError(sys.argv)
            state_file.write_text(json.dumps(state))
        """)
        flash_code = """
            import json, os, pathlib, sys
            root = pathlib.Path(os.environ['REVIEW_ROOT'])
            firmware = pathlib.Path(sys.argv[-1]).read_text()
            with (root / 'actions.jsonl').open('a') as log:
                log.write(json.dumps(['flash', firmware, sys.argv[-1]]) + '\\n')
            # A failed flash may already have modified the ESP.
            (root / 'firmware').write_text('partial firmware')
            if (firmware == 'new firmware' and os.environ.get('FAIL_NEW_FLASH')) or (firmware == 'old firmware' and os.environ.get('FAIL_OLD_FLASH')):
                sys.exit(23)
            (root / 'firmware').write_text(firmware)
        """
        self.write_executable(self.flasher, flash_code)
        self.write_executable(self.stage / "espflash", flash_code)

    @staticmethod
    def write_executable(path, code):
        path.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(code))
        path.chmod(0o755)

    def run_install(self, **failures):
        return subprocess.run(
            ["bash", str(HELPER), str(self.stage), str(self.app), str(self.env_file),
             str(self.root / "infractions"), str(self.elf), str(self.flasher),
             self.service, str(self.unit), "/dev/review-only"],
            env=dict(self.environment, **failures),
            text=True, capture_output=True, timeout=10,
        )

    def assert_old_installation(self):
        self.assertEqual(self.elf.read_text(), "old firmware")
        self.assertEqual((self.app / "uploader").read_text(), "old uploader")
        self.assertEqual(self.env_file.read_text(), "old environment")
        self.assertEqual(self.env_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.unit.read_text(), "old unit")

    def actions(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_success_flashes_staged_elf_then_starts_matching_installation(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.elf.read_text(), "new firmware")
        self.assertEqual(self.hardware.read_text(), "new firmware")
        self.assertEqual(json.loads(self.state.read_text()), {"active": True, "enabled": True})
        flash = next(action for action in self.actions() if action[0] == "flash")
        self.assertEqual(flash[2], str(self.stage / "radar-a-chepers"))

    def test_failed_flash_reflashes_backup_and_restarts_previous_installation(self):
        result = self.run_install(FAIL_NEW_FLASH="1")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assert_old_installation()
        self.assertEqual(self.hardware.read_text(), "old firmware")
        self.assertEqual(json.loads(self.state.read_text()), {"active": True, "enabled": True})
        self.assertEqual([a[1] for a in self.actions() if a[0] == "flash"], ["new firmware", "old firmware"])

    def test_failed_service_start_restores_firmware_runtime_environment_and_unit(self):
        result = self.run_install(FAIL_START_NEW="1")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assert_old_installation()
        self.assertEqual(self.hardware.read_text(), "old firmware")
        self.assertTrue(json.loads(self.state.read_text())["active"])

    def test_failed_rollback_never_restarts_with_unknown_firmware(self):
        result = self.run_install(FAIL_NEW_FLASH="1", FAIL_OLD_FLASH="1")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assert_old_installation()
        self.assertEqual(json.loads(self.state.read_text()), {"active": False, "enabled": False})
        self.assertNotIn(["systemctl", "start"], self.actions())
        self.assertIn("Recovery is incomplete", result.stderr)
        self.assertTrue((self.stage / "previous/1").exists())

    def test_first_install_failure_leaves_service_stopped_without_decoder_file(self):
        for file in (self.elf, self.unit, self.app / "uploader", self.env_file, self.flasher):
            file.unlink()
        self.state.write_text(json.dumps({"active": False, "enabled": False}))
        result = self.run_install(FAIL_NEW_FLASH="1")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertFalse(self.elf.exists())
        self.assertFalse(json.loads(self.state.read_text())["active"])
        self.assertNotIn(["systemctl", "start"], self.actions())


if __name__ == "__main__":
    unittest.main()
