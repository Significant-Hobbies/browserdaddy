#!/usr/bin/env python3
"""Package only the standalone review child and runner; never install or launch."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

repo = Path(__file__).resolve().parent.parent

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def copy(source, destination):
    subprocess.run(['ditto', str(source), str(destination)], check=True)

require(len(sys.argv) == 3, 'Supply the generated package and a fresh output directory')
package = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
require(package.is_relative_to(repo / '.build') and package.is_dir(), 'Use the owned generated package')
require(not output.exists(), 'Use a fresh output directory')
proof = json.loads((package / 'source-provenance.json').read_text())
sources = package / 'Sources/BrowserDaddySceneReview'
for name, sha in proof['copiedSourceSHA256'].items():
    original = repo / name
    generated = (package / 'Sources/SceneReviewRunner/SceneReviewRunner.swift'
                 if original.name == 'SceneReviewRunner.swift' else
                 sources / (original.name if name.startswith('scripts/') else str(original.relative_to(repo / 'Sources/BrowserDaddy'))))
    require(digest(original) == sha and digest(generated) == sha, 'A generated input changed after preparation')
app_source = (repo / 'Sources/BrowserDaddy/BrowserDaddyApp.swift').read_bytes()
require(hashlib.sha256(app_source).hexdigest() == proof['originalAppSHA256'], 'Product app source changed')
boundary = b'enum Workspace: String, CaseIterable, Identifiable {'
tail = boundary + app_source.split(boundary, 1)[1]
generated_root = (sources / 'ActualWorkspaceRoot.swift').read_bytes()
require(generated_root.endswith(tail) and hashlib.sha256(tail).hexdigest() == proof['workspaceRootTailSHA256'],
        'Actual Workspace/RootView tail changed')
resolved = json.loads((package / 'Package.resolved').read_text())
require(next(pin['state']['revision'] for pin in resolved['pins'] if pin['identity'] == 'ui-library')
        == proof['sharedUIRevision'], 'Resolved UI revision differs')

products = package / '.build/out/Products/Release'
app = output / 'BrowserDaddy Scene Review.app'
(app / 'Contents/MacOS').mkdir(parents=True)
(app / 'Contents/Resources').mkdir()
(app / 'Contents/Frameworks').mkdir()
(output / 'Home').mkdir(mode=0o700)
copy(products / 'BrowserDaddySceneReview', app / 'Contents/MacOS/BrowserDaddySceneReview')
copy(products / 'Sparkle.framework', app / 'Contents/Frameworks/Sparkle.framework')
for name in ['BrowserDaddySceneReview_BrowserDaddySceneReview.bundle', 'SaaSMakerUI_SaaSMakerUI.bundle']:
    copy(products / name, app / 'Contents/Resources' / name)
# DaddyArtwork resolves its established resource name. These are built product
# assets, never the installed app or user data.
copy(repo / '.build/out/Products/Release/BrowserDaddy_BrowserDaddy.bundle',
     app / 'Contents/Resources/BrowserDaddy_BrowserDaddy.bundle')
shutil.copy2(products / 'SceneReviewRunner', output / 'SceneReviewRunner')
identifier = 'com.significanthobbies.browserdaddy.scene-review.' + uuid.uuid4().hex
info = {'CFBundleIdentifier': identifier, 'CFBundleName': 'BrowserDaddy Scene Review',
        'CFBundleDisplayName': 'BrowserDaddy Scene Review', 'CFBundleExecutable': 'BrowserDaddySceneReview',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.0.1',
        'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '15.0'}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                             check=True, capture_output=True).stdout
require(not entitlements.strip() or plistlib.loads(entitlements) == {}, 'Fixture must have no entitlements')
entries = {}
for path in sorted(app.rglob('*')):
    name = str(path.relative_to(app))
    if path.is_symlink():
        entries[name] = {'symlink': str(path.readlink())}
    elif path.is_file():
        entries[name] = {'sha256': digest(path), 'mode': path.stat().st_mode & 0o7777}
bundle_sha = hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()
manifest = {**proof, 'privateBundleIdentifier': identifier, 'noEntitlements': True,
            'binarySHA256': digest(app / 'Contents/MacOS/BrowserDaddySceneReview'),
            'runnerSHA256': digest(output / 'SceneReviewRunner'), 'bundleSHA256': bundle_sha,
            'bundleFilesAndSymlinks': entries, 'strictSignatureVerified': True}
(output / 'source-proof.json').write_text(json.dumps(manifest, indent=2, sort_keys=True))
(output / 'README.txt').write_text('''Standalone arm64 macOS15+ SwiftUI scene fixture. No user data is included.
The dedicated bundle has no entitlements/app group/filter capabilities. Actual
Workspace/RootView tail and other product inputs are byte-checked. Production
entry/startup is excluded. Every fixture content action, including navigation,
is disabled. Native window controls remain native. The title intentionally says
BrowserDaddy · Standalone SwiftUI fixture rather than the production app title.

Create fresh writable private-home and output directories inside the guest. Run:
./SceneReviewRunner "/guest/BrowserDaddy Scene Review.app" "/guest/private-home" "/guest/output"
The runner sets CFFIXED_USER_HOME only for the child; HOME is unchanged. Child
validates its actual private home and bundle id before any model construction.
Wait for output/ready.json; capture exactly its PID/nativeWindowNumber once.
Default content is1240x800. Touch output/done to finish. Child deadline120seconds,
runner130seconds plus bounded termination. Timeouts fail. Reused sentinels fail.

Require actual runner exit0 plus output/finished.json: successful, sceneReady,
isolationVerified, previewStateConfirmed and fixtureCleanupCompleted alltrue;
nativePreferencesLoads/Applies both0, blockingEnabled=false. Preference counters
are regression tripwires, not comprehensive security proof. Source exclusion,
private identity/home, disabled content and capability-free fixture provide
the isolation boundary. The runner prints Standalone scene child exit and
isolation verified only after actual child exit0 and terminal checks.
''')
print(json.dumps({'output': str(output), 'privateBundleIdentifier': identifier,
                  'helperSHA256': manifest['binarySHA256'], 'runnerSHA256': manifest['runnerSHA256']}))
