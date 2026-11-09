"""Validate a private, already-signed candidate before protected notarization."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

TEAM = "8F7LXHTJZR"
BUNDLE = "com.significanthobbies.browserdaddy"


def candidate_asset(release, tag, digest):
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)-([1-9]\d*)", tag)
    if not match or not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise ValueError("Expected a release tag and lowercase SHA-256")
    if release.get("isDraft") is not True or release.get("tagName") != tag:
        raise ValueError("Only the specified private draft candidate is allowed")
    name = f"BrowserDaddy-{match[1]}-{match[2]}-universal.dmg"
    if sum(asset.get("name") == name for asset in release.get("assets", [])) != 1:
        raise ValueError("Expected exactly one matching candidate asset")
    return name


def verify_bundle(app, identifier, host=False):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    result = subprocess.run(["codesign", "--display", "--verbose=4", str(app)],
                            capture_output=True, text=True, check=True)
    fields = result.stderr.splitlines()
    if "TeamIdentifier=" + TEAM not in fields or not any(
            line.startswith("Authority=Developer ID Application:") for line in fields):
        raise ValueError("Candidate must use the BrowserDaddy Developer ID identity")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != identifier:
        raise ValueError("Unexpected candidate bundle identifier")
    profile = plistlib.loads(subprocess.check_output([
        "security", "cms", "-D", "-i", str(app / "Contents/embedded.provisionprofile")]))
    entitlements = profile["Entitlements"]
    if profile.get("TeamIdentifier") != [TEAM] or entitlements.get(
            "com.apple.application-identifier") != TEAM + "." + identifier:
        raise ValueError("Provisioning profile does not match the signed candidate")
    if "content-filter-provider-systemextension" not in entitlements.get(
            "com.apple.developer.networking.networkextension", []):
        raise ValueError("Missing content-filter provisioning")
    if host and entitlements.get("com.apple.developer.system-extension.install") is not True:
        raise ValueError("Missing system-extension installation provisioning")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-json", type=Path)
    parser.add_argument("--tag")
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    if args.release_json:
        print(candidate_asset(json.loads(args.release_json.read_text()), args.tag, args.sha256))
        return
    if not args.dmg or not args.app or not re.fullmatch(r"[a-f0-9]{64}", args.sha256):
        parser.error("Verification requires --dmg, --app and a lowercase SHA-256")
    if hashlib.sha256(args.dmg.read_bytes()).hexdigest() != args.sha256:
        raise ValueError("Candidate digest changed")
    verify_bundle(args.app, BUNDLE, host=True)
    extension_root = args.app / "Contents/Library/SystemExtensions"
    extensions = list(extension_root.glob("*.systemextension"))
    if len(extensions) != 1:
        raise ValueError("Expected exactly one embedded system extension")
    verify_bundle(extensions[0], BUNDLE + ".filter")
    print("Verified signed candidate, embedded filter and provisioning")


if __name__ == "__main__":
    main()
