from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import ui_resources


class UIResourceProbeTests(unittest.TestCase):
    def test_window_failure_missing_marker_and_timeout_restore_font_inputs(self):
        for error in (None, subprocess.CalledProcessError(5, ["fixture"]),
                      subprocess.TimeoutExpired(["fixture"], 30), RuntimeError("no marker")):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                bundle = root / ui_resources.UI_BUNDLE
                bundle.mkdir()
                (bundle / "font.ttf").write_bytes(b"fixture")
                calls = []

                def probe(command, **kwargs):
                    self.assertFalse(bundle.exists())
                    calls.append(command[1])
                    if command[1] == "--check-app-startup":
                        if isinstance(error, RuntimeError):
                            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
                        if error:
                            raise error
                        marker = "Fixture app startup verified"
                    else:
                        marker = "Fixture UI resources loaded"
                    return subprocess.CompletedProcess(command, 0, stdout=marker + "\n", stderr="")

                with patch("subprocess.run", side_effect=probe):
                    if error:
                        with self.assertRaises(type(error)):
                            ui_resources.check_startup(root / "Fixture", root / "Fixture.app", "Fixture")
                    else:
                        ui_resources.check_startup(root / "Fixture", root / "Fixture.app", "Fixture")
                self.assertEqual(calls, ["--check-ui-resources", "--check-app-startup"])
                self.assertEqual((bundle / "font.ttf").read_bytes(), b"fixture")
