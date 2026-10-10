#!/usr/bin/env python3
"""Assemble and sign an isolated candidate. Never installs or publishes it."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sparkle_support

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run([str(value) for value in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path, required=True, help="Verified Release products directory")
    parser.add_argument("--output", type=Path, required=True, help="New output directory; never overwritten")
    parser.add_argument("--identity", required=True, help="Existing Developer ID Application identity")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    args = parser.parse_args()
    products = args.products.resolve()
    binary = products / "BrowserDaddy"
    resources = products / "BrowserDaddy_BrowserDaddy.bundle"
    ui_resources = products / "SaaSMakerUI_SaaSMakerUI.bundle"
    if products.name != "Release" or not binary.is_file() or not resources.is_dir():
        raise SystemExit("Expected existing Release binary and resource bundle")
    if not ui_resources.is_dir():
        raise SystemExit("Missing SaaSMakerUI_SaaSMakerUI.bundle in build products; rebuild before packaging")
    if args.build < 1 or not all(part.isdigit() for part in args.version.split(".")):
        raise SystemExit("Version must be numeric; build must be positive")
    sources = list((ROOT / "Sources").rglob("*.swift")) + [ROOT / "Package.swift"]
    if any(path.stat().st_mtime > binary.stat().st_mtime for path in sources):
        raise SystemExit("Source changed after the build; rebuild before packaging")
    expected = {"BrowserDaddyIcon.png", "BrowserDaddyScout.png"}
    built_assets = resources / "Contents/Resources"
    if {path.name for path in built_assets.iterdir()} != expected:
        raise SystemExit("Unexpected or missing resource assets; use a fresh build")
    for name in expected:
        if (built_assets / name).read_bytes() != (ROOT / "Sources/BrowserDaddy/Resources" / name).read_bytes():
            raise SystemExit("Built artwork is stale")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    stage = output / "image-contents"
    app = stage / "BrowserDaddy.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    shutil.copy2(binary, contents / "MacOS/BrowserDaddy")
    shutil.copytree(resources, contents / "Resources" / resources.name)
    shutil.copytree(ui_resources, contents / "Resources" / ui_resources.name)
    shutil.copy2(ROOT / "Support/BrowserDaddy.icns", contents / "Resources/BrowserDaddy.icns")
    shutil.copy2(ROOT / "Support/container-migration.plist",
                 contents / "Resources/container-migration.plist")
    info = plistlib.loads((ROOT / "Support/Info.plist").read_bytes())
    info.update(CFBundleIdentifier="com.significanthobbies.browserdaddy",
                CFBundleShortVersionString=args.version, CFBundleVersion=str(args.build),
                **sparkle_support.configuration())
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    sparkle_support.embed(app)
    sparkle_support.sign(app, args.identity)
    extension_project = ROOT / "SafariTabsExtension/SafariTabsExtension.xcodeproj"
    extension_products = output / "safari-extension-build"
    run("xcodebuild", "-project", extension_project,
        "-target", "SafariTabsExtension", "-configuration", "Release",
        f"SYMROOT={extension_products}", "ARCHS=arm64 x86_64",
        "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO", "build", "-quiet")
    built_extension = extension_products / "Release/SafariTabsExtension.appex"
    if not built_extension.is_dir():
        raise SystemExit("Safari Tabs extension build is missing")
    plugins = contents / "PlugIns"
    plugins.mkdir()
    extension = plugins / built_extension.name
    shutil.copytree(built_extension, extension)
    extension_info_path = extension / "Contents/Info.plist"
    extension_info = plistlib.loads(extension_info_path.read_bytes())
    extension_info.update(CFBundleShortVersionString=args.version,
                          CFBundleVersion=str(args.build))
    extension_info_path.write_bytes(plistlib.dumps(extension_info))
    run("codesign", "--force", "--sign", args.identity, "--timestamp",
        "--options", "runtime", "--entitlements",
        ROOT / "SafariTabsExtension/Entitlements.plist", extension)
    run("codesign", "--force", "--sign", args.identity, "--timestamp", "--options", "runtime",
        "--entitlements", ROOT / "Support/Release.entitlements", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    (stage / "Applications").symlink_to("/Applications")
    dmg = output / f"BrowserDaddy-{args.version}-{args.build}-universal.dmg"
    run("hdiutil", "create", "-volname", "BrowserDaddy", "-srcfolder", stage, "-format", "UDZO", dmg)
    run("codesign", "--sign", args.identity, "--timestamp", dmg)
    run("hdiutil", "verify", dmg)
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(f"{digest}  {dmg.name}\n")
    print(f"Signed candidate only; notarization and runtime qualification remain: {dmg}")


if __name__ == "__main__":
    main()
