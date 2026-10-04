import base64
import hashlib
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import sparkle_support

class SparklePackagingTests(unittest.TestCase):
    def test_missing_or_invalid_key_blocks_packaging(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "public-key.txt"
            with patch.object(sparkle_support, "PUBLIC_KEY", path):
                with self.assertRaises(RuntimeError): sparkle_support.configuration()
                path.write_text("invalid public key")
                with self.assertRaises(ValueError): sparkle_support.configuration()
                path.write_text(base64.b64encode(b"too short").decode())
                with self.assertRaises(ValueError): sparkle_support.configuration()

    def test_signed_archive_verification_and_https_are_required(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "public-key.txt"
            path.write_text(base64.b64encode(bytes(range(32))).decode())
            with patch.object(sparkle_support, "PUBLIC_KEY", path):
                config = sparkle_support.configuration()
            self.assertTrue(config["SUVerifyUpdateBeforeExtraction"])
            self.assertTrue(config["SUFeedURL"].startswith("https://browser.daddyrad.com/"))
            self.assertFalse(config["SUAllowsAutomaticUpdates"])
            self.assertFalse(config["SUSendProfileInfo"])

class AppcastWrapperTests(unittest.TestCase):
    """Exercise the actual consumer wrapper with synthetic artifacts and tools."""

    def run_wrapper(self, failure=None, protected=False):
        wrapper = Path(__file__).with_name("prepare-appcast.py")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            release = root / "release"
            release.mkdir()
            output = root / "output"
            source = release / "BrowserDaddy-1.2.3-4-universal.dmg"
            payload = b"synthetic post-staple DMG bytes"
            source.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            sums = release / "SHA256SUMS"
            sums.write_text(f"{digest}  {source.name}\n")
            if failure == "missing-dmg":
                source.unlink()
            elif failure == "multiple-dmg":
                (release / "other.dmg").write_bytes(b"other")
            elif failure == "directory-dmg":
                source.unlink()
                source.mkdir()
            elif failure == "symlink-dmg":
                source.unlink()
                target = root / "target"
                target.write_bytes(payload)
                source.symlink_to(target)
            elif failure == "name":
                source.rename(release / "wrong.dmg")
            elif failure == "missing-checksum":
                sums.unlink()
            elif failure == "duplicate-checksum":
                sums.write_text(sums.read_text() * 2)
            elif failure == "malformed-checksum":
                sums.write_text(f"{digest}  {source.name}\nmalformed row\n")
            elif failure == "nonhex-checksum":
                sums.write_text(f"{'z' * 64}  {source.name}\n")
            elif failure == "checksum":
                sums.write_text(f"{'0' * 64}  {source.name}\n")
            calls = []

            def run(command, **kwargs):
                calls.append(command)
                self.assertTrue(kwargs["check"])
                if command[0] in ("codesign", "xcrun"):
                    if failure == command[0]:
                        raise subprocess.CalledProcessError(1, command)
                    return
                self.assertEqual(command, [
                    str(root / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"),
                    *( ["--ed-key-file", "-"] if protected else
                       ["--account", "browserdaddy-updates"] ),
                    "--download-url-prefix", "https://browser.daddyrad.com/updates/",
                    str(output),
                ])
                self.assertEqual(kwargs["input"], "synthetic-test-key" if protected else None)
                self.assertTrue(kwargs["text"])
                staged = output / "browserdaddy-1.2.3-build4-universal.dmg"
                self.assertEqual(staged.read_bytes(), payload)
                url = "https://browser.daddyrad.com/updates/" + staged.name
                length = str(len(payload))
                signature = base64.b64encode(bytes(64)).decode()
                if failure == "url":
                    url += "?wrong"
                elif failure == "length":
                    length = "1"
                elif failure == "unsigned":
                    signature = ""
                elif failure == "signature":
                    signature = "malformed"
                elif failure == "short-signature":
                    signature = base64.b64encode(bytes(63)).decode()
                enclosure = (f'<enclosure url="{url}" length="{length}" '
                             f'sparkle:edSignature="{signature}"/>')
                if failure == "empty-feed":
                    enclosure = ""
                elif failure == "multiple-feed":
                    enclosure *= 2
                xml = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                       f'<channel><item>{enclosure}</item></channel></rss>')
                if failure == "hidden-enclosure":
                    xml = xml.replace("</rss>", f"<extra>{enclosure}</extra></rss>")
                elif failure == "malformed-feed":
                    xml = "<rss>"
                elif failure == "staged-drift":
                    staged.write_bytes(b"changed after signing")
                if failure != "missing-feed":
                    (output / "appcast.xml").write_text(xml)

            argv = [str(wrapper), str(release), str(output)]
            if protected:
                argv.append("--ed-key-stdin")
            environment = {"SPARKLE_ED25519_PRIVATE_KEY": "synthetic-test-key"} if protected else {}
            if failure == "missing-key":
                environment = {}
            with patch.object(sparkle_support, "configuration") as configuration, \
                 patch.object(sparkle_support, "ROOT", root), \
                 patch.object(sys, "argv", argv), patch("os.environ", environment), \
                 patch("subprocess.run", side_effect=run), patch("builtins.print"):
                if failure:
                    with self.assertRaises((ValueError, SystemExit, subprocess.CalledProcessError)):
                        runpy.run_path(str(wrapper), run_name="__main__")
                else:
                    runpy.run_path(str(wrapper), run_name="__main__")
                    self.assertEqual(calls[:2], [
                        ["codesign", "--verify", "--verbose=2", str(source)],
                        ["xcrun", "stapler", "validate", str(source)],
                    ])
                    self.assertEqual(len(calls), 3)
                    self.assertEqual((output / "browserdaddy-1.2.3-build4-universal.dmg").read_bytes(), payload)
                configuration.assert_called_once_with()
                if failure in ("missing-checksum", "duplicate-checksum", "malformed-checksum",
                               "nonhex-checksum", "checksum", "codesign", "xcrun"):
                    self.assertFalse(output.exists())
                if failure == "missing-key":
                    self.assertEqual(len(calls), 2)

    def test_preserves_qualification_signing_url_and_staged_bytes(self):
        for protected in (False, True):
            with self.subTest(protected=protected):
                self.run_wrapper(protected=protected)

    def test_rejects_invalid_artifacts_checksums_and_qualification(self):
        for failure in ("missing-dmg", "multiple-dmg", "directory-dmg", "symlink-dmg", "name",
                        "missing-checksum", "duplicate-checksum", "malformed-checksum",
                        "nonhex-checksum", "checksum", "codesign", "xcrun"):
            with self.subTest(failure=failure):
                self.run_wrapper(failure)

    def test_rejects_adversarial_signed_feeds_and_byte_drift(self):
        for failure in ("url", "length", "unsigned", "signature", "short-signature",
                        "empty-feed", "multiple-feed", "hidden-enclosure", "malformed-feed",
                        "missing-feed", "staged-drift"):
            with self.subTest(failure=failure):
                self.run_wrapper(failure)

    def test_protected_signing_requires_key(self):
        self.run_wrapper("missing-key", protected=True)


if __name__ == "__main__": unittest.main()
