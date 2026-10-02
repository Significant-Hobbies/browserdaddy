#!/usr/bin/env python3
"""Prepare a signed appcast from an already notarized DMG. Does not deploy."""
import argparse
from pathlib import Path
import os
import re
import subprocess
import sparkle_support
from appcast_core import select_dmg, checksum_from_file, validate_checksum, stage_dmg, validate_appcast

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("release_directory", type=Path)
parser.add_argument("output", type=Path, help="New directory; must not already exist")
parser.add_argument("--ed-key-stdin", action="store_true", help="Read protected Sparkle key from the environment")
args = parser.parse_args()
sparkle_support.configuration()
source = select_dmg(args.release_directory)
match = re.fullmatch(r"BrowserDaddy-(\d+(?:\.\d+)*)-(\d+)-universal\.dmg", source.name)
if not match:
    raise SystemExit(f"Unexpected release DMG name: {source.name}")
# Only signed, notarized and stapled releases can enter the appcast.
subprocess.run(["codesign", "--verify", "--verbose=2", str(source)], check=True)
subprocess.run(["xcrun", "stapler", "validate", str(source)], check=True)
digest = validate_checksum(source, checksum_from_file(args.release_directory / "SHA256SUMS", source.name))
filename = f"browserdaddy-{match.group(1)}-build{match.group(2)}-universal.dmg"
copied = stage_dmg(source, args.output, filename, digest)
tool = sparkle_support.ROOT / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
key = os.environ.get("SPARKLE_ED25519_PRIVATE_KEY") if args.ed_key_stdin else None
if args.ed_key_stdin and not key:
    raise SystemExit("Protected Sparkle signing key is missing")
signing = ["--ed-key-file", "-"] if args.ed_key_stdin else ["--account", "browserdaddy-updates"]
subprocess.run([str(tool), *signing, "--download-url-prefix",
                "https://browser.daddyrad.com/updates/", str(args.output)],
               check=True, input=key, text=True)
feed = args.output / "appcast.xml"
validate_appcast(feed, copied, "https://browser.daddyrad.com/updates/" + filename, digest)
print(feed)
