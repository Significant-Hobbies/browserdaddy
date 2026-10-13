"""Require packaged UI fonts and the actual window without build-path fallback."""
from pathlib import Path
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
