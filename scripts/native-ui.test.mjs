import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// A real native workload for tooling that supports node:test but not SwiftPM.
// XcodeBuildMCP remains the native executor. Never launch the app, capture host
// or opt-in installed-preferences probe from this automatic verification path.
test('native UI behavior contracts through XcodeBuildMCP', { timeout: 115_000 }, () => {
  const root = fileURLToPath(new URL('..', import.meta.url));
  const filter = 'HistoryModelTests|BlockingSchedulePresentationTests|BlockingControllerTests|CollectionConsentTests|BrowserUIResourcesTests|SharedMacUIReviewTests';
  const result = spawnSync('npx', ['--offline', 'xcodebuildmcp', 'swift-package', 'test',
    '--package-path', root, '--configuration', 'release', '--filter', filter], {
    cwd: root,
    env: { ...process.env, BROWSERDADDY_UI_REVIEW: '0', BROWSERDADDY_NATIVE_RULES_READ_ONLY_PROBE: '0' },
    encoding: 'utf8', timeout: 110_000, maxBuffer: 8 * 1024 * 1024,
  });
  process.stdout.write(result.stdout ?? '');
  process.stderr.write(result.stderr ?? '');
  assert.ifError(result.error);
  assert.equal(result.status, 0, 'The official native test command must pass');
  const summary = result.stdout.match(/(\d+) tests? passed, 0 failed, 1 skipped/);
  assert.ok(summary && Number(summary[1]) >= 48,
    'Require the selected native contracts and default-skipped capture host; an empty filter is not verification');
});
