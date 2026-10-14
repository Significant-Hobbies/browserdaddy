"""Require packaged UI fonts and the actual window without build-path fallback."""
from pathlib import Path
import argparse
import hashlib
import shutil
import subprocess
import uuid

UI_BUNDLE = "SaaSMakerUI_SaaSMakerUI.bundle"


def check_startup(binary: Path, app: Path, app_name: str) -> None:
    bundle = binary.parent / UI_BUNDLE
    if not bundle.is_dir():
        raise SystemExit(f"Missing required font resource bundle: {bundle}")
    held = bundle.with_name(f".{bundle.name}.startup-check-{uuid.uuid4().hex}")
    bundle.rename(held)
    try:
        executable = app.resolve() / "Contents/MacOS" / app_name
        for flag, marker in (("--check-ui-resources", f"{app_name} UI resources loaded"),
                             ("--check-app-startup", f"{app_name} app startup verified")):
            result = subprocess.run([str(executable), flag], check=True, timeout=30,
                                    capture_output=True, text=True)
            if marker not in result.stdout.splitlines():
                raise RuntimeError(f"Packaged app did not complete {flag}")
            print(marker)
    finally:
        held.rename(bundle)


def bundle_hashes(bundle: Path) -> dict[str, str]:
    hashes = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink():
            raise SystemExit(f"Resource bundle symlink is not allowed: {path}")
        if path.is_file():
            hashes[path.relative_to(bundle).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not hashes:
        raise SystemExit(f"Empty SwiftPM resource bundle: {bundle}")
    return hashes


def stage_universal_fonts(root: Path, destination: Path) -> None:
    """Extend the pinned universal builder's app-only resource copy locally."""
    bundles = []
    for architecture in ("arm64", "x86_64"):
        scratch = root / ".build" / f"daddy-release-{architecture}"
        matches = [path for path in scratch.rglob(UI_BUNDLE)
                   if path.is_dir() and path.parent.name.lower() == "release"]
        if len(matches) != 1:
            raise SystemExit(f"Expected one {architecture} Release {UI_BUNDLE} in {scratch}")
        bundles.append(matches[0])
    hashes = bundle_hashes(bundles[0])
    if hashes != bundle_hashes(bundles[1]):
        raise SystemExit("SaaSMakerUI Release resource bundles differ between architectures")
    target = destination / UI_BUNDLE
    shutil.copytree(bundles[0], target)
    if bundle_hashes(target) != hashes:
        raise SystemExit("Copied SaaSMakerUI Release resources do not match the verified source")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Stage matching universal font resources")
    parser.add_argument("--universal-root", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    stage_universal_fonts(args.universal_root, args.destination)
