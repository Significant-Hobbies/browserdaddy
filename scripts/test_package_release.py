"""Resource staging checks with synthetic products; never signs or releases."""
from pathlib import Path
import os
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import sparkle_support

SCRIPTS = Path(__file__).resolve().parent
UI_BUNDLE = "SaaSMakerUI_SaaSMakerUI.bundle"


class StagingComplete(Exception):
    pass


class ResourcePackagingTests(unittest.TestCase):
    def release_fixture(self, root):
        products = root / "Release"
        products.mkdir()
        assets = root / "Sources/BrowserDaddy/Resources"
        assets.mkdir(parents=True)
        resources = products / "BrowserDaddy_BrowserDaddy.bundle/Contents/Resources"
        resources.mkdir(parents=True)
        for name in ("BrowserDaddyIcon.png", "BrowserDaddyScout.png"):
            (assets / name).write_bytes(b"synthetic artwork")
            (resources / name).write_bytes(b"synthetic artwork")
        support = root / "Support"
        support.mkdir()
        (support / "Info.plist").write_bytes(plistlib.dumps({}))
        (support / "BrowserDaddy.icns").write_bytes(b"synthetic icon")
        (support / "container-migration.plist").write_bytes(b"synthetic migration")
        (root / "Package.swift").write_text("// synthetic manifest")
        (products / "BrowserDaddy").write_bytes(b"synthetic executable")
        # The stale-source gate must still run and pass for valid products.
        os.utime(products / "BrowserDaddy", (2_000_000_000, 2_000_000_000))
        return products, resources

    def run_release(self, root, products):
        namespace = runpy.run_path(str(SCRIPTS / "package-release.py"))
        main = namespace["main"]
        main.__globals__["ROOT"] = root
        args = ["package-release.py", "--products", str(products), "--output",
                str(root / "output"), "--identity", "synthetic", "--version", "1.2.3", "--build", "4"]
        with patch.object(sys, "argv", args), \
             patch.object(sparkle_support, "configuration", return_value={}), \
             patch.object(sparkle_support, "embed", side_effect=StagingComplete), \
             patch.object(sparkle_support, "sign") as sign, \
             patch("subprocess.run") as run:
            try:
                main()
            finally:
                sign.assert_not_called()
                run.assert_not_called()

    def test_copies_font_bundle_alongside_artwork_before_signing(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            products, _ = self.release_fixture(root)
            fonts = products / UI_BUNDLE / "Contents/Resources/Fonts"
            fonts.mkdir(parents=True)
            (fonts / "Geist.ttf").write_bytes(b"synthetic font")
            with self.assertRaises(StagingComplete):
                self.run_release(root, products)
            resources = root / "output/image-contents/BrowserDaddy.app/Contents/Resources"
            self.assertEqual((resources / UI_BUNDLE / "Contents/Resources/Fonts/Geist.ttf").read_bytes(), b"synthetic font")
            self.assertTrue((resources / "BrowserDaddy_BrowserDaddy.bundle/Contents/Resources/BrowserDaddyIcon.png").is_file())

    def test_missing_bundle_fails_before_creating_output(self):
        for is_file in (False, True):
            with self.subTest(is_file=is_file), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                products, _ = self.release_fixture(root)
                if is_file:
                    (products / UI_BUNDLE).write_bytes(b"not a bundle")
                with self.assertRaisesRegex(SystemExit, "Missing SaaSMakerUI_SaaSMakerUI.bundle"):
                    self.run_release(root, products)
                self.assertFalse((root / "output").exists())

    def test_artwork_validation_still_rejects_extra_missing_and_stale_assets(self):
        for failure in ("extra", "missing", "stale", "source"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                products, resources = self.release_fixture(root)
                (products / UI_BUNDLE).mkdir()
                icon = resources / "BrowserDaddyIcon.png"
                if failure == "extra":
                    (resources / "extra.png").write_bytes(b"extra")
                elif failure == "missing":
                    icon.rename(root / "unused-icon.png")
                elif failure == "stale":
                    icon.write_bytes(b"stale")
                else:
                    os.utime(root / "Package.swift", (2_000_000_001, 2_000_000_001))
                with self.assertRaises(SystemExit):
                    self.run_release(root, products)
                self.assertFalse((root / "output").exists())

    def test_local_assembly_copies_bundle_and_fails_when_missing(self):
        for missing in (False, True):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                scripts = root / "scripts"
                scripts.mkdir()
                (scripts / "run-local.sh").write_text((SCRIPTS / "run-local.sh").read_text())
                (scripts / "build-icon.sh").write_text("#!/bin/sh\nexit 0\n")
                products = root / "products"
                products.mkdir()
                (products / "BrowserDaddy").write_bytes(b"synthetic executable")
                if not missing:
                    (products / UI_BUNDLE).mkdir()
                    (products / UI_BUNDLE / "font.ttf").write_bytes(b"synthetic font")
                support = root / "Support"
                support.mkdir()
                for name in ("Info.plist", "BrowserDaddy.icns"):
                    (support / name).write_bytes(b"synthetic")
                tools = root / "tools"
                tools.mkdir()
                stubs = {
                    "pgrep": "exit 1",
                    "swift": f'case "$*" in *--show-bin-path*) echo "{products}";; esac',
                    # Stop before extension build, credentials, signing or launch.
                    "xcodebuild": "exit 77",
                }
                for name, body in stubs.items():
                    tool = tools / name
                    tool.write_text("#!/bin/sh\n" + body + "\n")
                    tool.chmod(0o755)
                result = subprocess.run(["/bin/sh", str(scripts / "run-local.sh")],
                                        env={**os.environ, "PATH": str(tools) + ":/usr/bin:/bin"},
                                        capture_output=True, text=True)
                destination = root / ".build/BrowserDaddy.app/Contents/Resources" / UI_BUNDLE
                if missing:
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("Missing " + UI_BUNDLE, result.stderr)
                    self.assertFalse(destination.exists())
                else:
                    self.assertEqual(result.returncode, 77, result.stderr)
                    self.assertEqual((destination / "font.ttf").read_bytes(), b"synthetic font")


if __name__ == "__main__":
    unittest.main()
