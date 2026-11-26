#!/usr/bin/env python3
"""Embed BrowserDaddy extensions in a staged daddyrad app before host signing."""
import argparse
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from notary_candidate import TEAM, verify_bundle

ROOT = Path(__file__).resolve().parents[1]
HOST = "com.significanthobbies.daddyrad"
FILTER = "com.significanthobbies.browserdaddy.filter"
SPEC = importlib.util.spec_from_file_location("browser_package", ROOT / "scripts/package-release.py")
packaging = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(packaging)


def validate_profile(profile):
    entitlement = profile["Entitlements"]
    expiration = profile["ExpirationDate"].replace(tzinfo=timezone.utc)
    if expiration <= datetime.now(timezone.utc) or profile["TeamIdentifier"] != [TEAM]:
        raise ValueError("Filter host profile is expired or belongs to another team")
    if entitlement.get("com.apple.application-identifier") != TEAM + "." + HOST or \
            entitlement.get("com.apple.developer.system-extension.install") is not True or \
            "content-filter-provider-systemextension" not in entitlement.get(
                "com.apple.developer.networking.networkextension", []):
        raise ValueError("Filter profile must authorize daddyrad to install the content filter")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--filter-extension", type=Path)
    parser.add_argument("--filter-host-profile", type=Path)
    args = parser.parse_args()
    if bool(args.filter_extension) != bool(args.filter_host_profile):
        parser.error("Supply both the signed filter extension and the daddyrad provisioning profile")
    contents = args.app.resolve() / "Contents"
    host = plistlib.loads((contents / "Info.plist").read_bytes())
    if host["CFBundleIdentifier"] != HOST:
        parser.error("Expected a staged daddyrad app")
    if args.filter_extension:
        verify_bundle(args.filter_extension, FILTER)
        info = plistlib.loads((args.filter_extension / "Contents/Info.plist").read_bytes())
        if info.get("NetworkExtension", {}).get("NEMachServiceName") != packaging.FILTER_SERVICE:
            parser.error("Unexpected filter Mach service")
        packaging.validate_filter_pairing(args.filter_extension, info,
                                         info["CFBundleShortVersionString"], info["CFBundleVersion"])
        validate_profile(plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(args.filter_host_profile)])))
    safari_target = contents / "PlugIns/SafariTabsExtension.appex"
    filter_target = contents / ("Library/SystemExtensions/" + FILTER + ".systemextension")
    profile_target = contents / "embedded.provisionprofile"
    if safari_target.exists() or filter_target.exists() or (args.filter_host_profile and profile_target.exists()):
        parser.error("Build in a fresh staging app to preserve existing extensions and provisioning")
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcodebuild", "-project", str(ROOT / "SafariTabsExtension/SafariTabsExtension.xcodeproj"),
                        "-target", "SafariTabsExtension", "-configuration", "Release", f"SYMROOT={tmp}",
                        f"OBJROOT={tmp}/obj", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
                        "CODE_SIGNING_ALLOWED=NO", "PRODUCT_BUNDLE_IDENTIFIER=" + HOST + ".safaritabs",
                        "build", "-quiet"], check=True)
        safari = Path(tmp) / "Release/SafariTabsExtension.appex"
        info_path = safari / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        if info["CFBundleIdentifier"] != HOST + ".safaritabs":
            parser.error("Safari extension has the wrong host identifier")
        info.update(CFBundleDisplayName="daddyrad Safari Tabs",
                    CFBundleVersion=host["CFBundleVersion"],
                    CFBundleShortVersionString=host["CFBundleShortVersionString"])
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", args.identity, "--options", "runtime",
                        "--timestamp=none" if args.identity == "-" else "--timestamp",
                        "--entitlements", str(ROOT / "SafariTabsExtension/Entitlements.plist"), str(safari)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(safari)], check=True)
        if args.identity != "-":
            packaging.validate_filter_signature(safari)
        safari_target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(safari, safari_target)
    if args.filter_extension:
        filter_target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(args.filter_extension, filter_target, symlinks=True)
        shutil.copy2(args.filter_host_profile, profile_target)


if __name__ == "__main__":
    main()
