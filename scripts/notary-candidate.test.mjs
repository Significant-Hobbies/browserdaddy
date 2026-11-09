import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const tag = 'v0.5.0-21';
const name = 'BrowserDaddy-0.5.0-21-universal.dmg';
const digest = 'a'.repeat(64);

function prepare(release, candidateTag = tag, hash = digest) {
  const dir = mkdtempSync(join(tmpdir(), 'browserdaddy-notary-'));
  try {
    const metadata = join(dir, 'release.json');
    writeFileSync(metadata, JSON.stringify(release));
    return spawnSync('python3', ['scripts/notary_candidate.py', '--release-json', metadata,
      '--tag', candidateTag, '--sha256', hash], { encoding: 'utf8' });
  } finally {
    rmSync(dir, { recursive: true });
  }
}

test('selects only the exact private candidate asset', () => {
  const result = prepare({ isDraft: true, tagName: tag, assets: [{ name }] });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), name);
});

for (const [label, release, candidateTag, hash] of [
  ['published release', { isDraft: false, tagName: tag, assets: [{ name }] }, tag, digest],
  ['wrong release', { isDraft: true, tagName: 'v0.4.8-17', assets: [{ name }] }, tag, digest],
  ['missing asset', { isDraft: true, tagName: tag, assets: [] }, tag, digest],
  ['duplicate asset', { isDraft: true, tagName: tag, assets: [{ name }, { name }] }, tag, digest],
  ['unsafe tag', { isDraft: true, tagName: '../bad', assets: [{ name }] }, '../bad', digest],
  ['missing digest', { isDraft: true, tagName: tag, assets: [{ name }] }, tag, ''],
]) {
  test(`rejects ${label} before downloading a candidate`, () => {
    assert.notEqual(prepare(release, candidateTag, hash).status, 0);
  });
}

test('rejects changed bytes before inspecting or executing the app', () => {
  const dir = mkdtempSync(join(tmpdir(), 'browserdaddy-notary-hash-'));
  try {
    const dmg = join(dir, 'candidate.dmg');
    writeFileSync(dmg, 'changed candidate');
    const result = spawnSync('python3', ['scripts/notary_candidate.py', '--dmg', dmg,
      '--app', join(dir, 'does-not-exist.app'), '--sha256', digest], { encoding: 'utf8' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Candidate digest changed/);
  } finally {
    rmSync(dir, { recursive: true });
  }
});
