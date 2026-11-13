#!/usr/bin/env python3
"""Generate a standalone scene helper from exact UI sources, never product startup."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

repo = Path(__file__).resolve().parent.parent
output = Path(sys.argv[1]).resolve()
assert output.is_relative_to(repo / '.build') and not output.exists()
output.mkdir(parents=True)
source = output / 'Sources' / 'BrowserDaddySceneReview'
source.mkdir(parents=True)
runner = output / 'Sources' / 'SceneReviewRunner'
runner.mkdir(parents=True)
hashes = {}

def digest(data):
    return hashlib.sha256(data).hexdigest()

for path in sorted((repo / 'Sources' / 'BrowserDaddy').rglob('*')):
    if not path.is_file() or path.name == 'BrowserDaddyApp.swift':
        continue
    relative = path.relative_to(repo / 'Sources' / 'BrowserDaddy')
    target = source / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
    assert target.read_bytes() == path.read_bytes()
    hashes[str(path.relative_to(repo))] = digest(path.read_bytes())

app = (repo / 'Sources/BrowserDaddy/BrowserDaddyApp.swift').read_bytes()
boundary = b'enum Workspace: String, CaseIterable, Identifiable {'
assert app.count(boundary) == 1
tail = boundary + app.split(boundary, 1)[1]
imports = b'import SwiftUI\nimport AppKit\nimport BrowserCore\nimport SaaSMakerUI\n\n'
(source / 'ActualWorkspaceRoot.swift').write_bytes(imports + tail)
assert (source / 'ActualWorkspaceRoot.swift').read_bytes()[len(imports):] == tail
assert b'BrowserDaddyApp:' not in tail and b'AppStartup' not in tail and b'@main' not in tail

for name, destination in [('BrowserDaddySceneReview.swift', source), ('SceneReviewRunner.swift', runner)]:
    fixture = repo / 'scripts' / 'fixtures' / name
    shutil.copy2(fixture, destination / name)
    assert (destination / name).read_bytes() == fixture.read_bytes()
    hashes[str(fixture.relative_to(repo))] = digest(fixture.read_bytes())

resolved = json.loads((repo / 'Package.resolved').read_text())
ui = next(pin['state']['revision'] for pin in resolved['pins'] if pin['identity'] == 'ui-library')
assert ui == 'f45faf3eb04af08cff2022710c8b8157a60bf5fa'
manifest = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "BrowserDaddySceneReview",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "BrowserDaddySceneReview", targets: ["BrowserDaddySceneReview"]),
               .executable(name: "SceneReviewRunner", targets: ["SceneReviewRunner"])],
    dependencies: [.package(path: REPO),
                   .package(url: "https://github.com/sass-maker/ui-library", revision: UI),
                   .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [.executableTarget(name: "BrowserDaddySceneReview", dependencies: [
                .product(name: "BrowserCore", package: IDENTITY),
                .product(name: "SaaSMakerUI", package: "ui-library"),
                .product(name: "Sparkle", package: "Sparkle")],
                exclude: ["Resources/StorageDaddy.png", "Resources/PageDoodles.png"],
                resources: [.process("Resources")],
                linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
              .executableTarget(name: "SceneReviewRunner")]
)
'''.replace('REPO', json.dumps(str(repo))).replace('IDENTITY', json.dumps(repo.name.lower())).replace('UI)', json.dumps(ui) + ')')
(output / 'Package.swift').write_text(manifest)
provenance = {'originalAppSHA256': digest(app), 'workspaceRootTailSHA256': digest(tail),
              'workspaceRootTailByteIdentical': True, 'productionEntryStartupExcluded': True,
              'sharedUIRevision': ui, 'copiedSourceSHA256': hashes}
(output / 'source-provenance.json').write_text(json.dumps(provenance, indent=2, sort_keys=True))
print(json.dumps({'package': str(output), 'workspaceRootTailByteIdentical': True,
                  'productionEntryStartupExcluded': True, 'copiedSourceFiles': len(hashes)}))
