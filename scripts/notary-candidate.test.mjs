import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
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

const signedEntitlements = {
  'com.apple.application-identifier': '8F7LXHTJZR.com.significanthobbies.browserdaddy',
  'com.apple.developer.team-identifier': '8F7LXHTJZR',
  'com.apple.developer.networking.networkextension': ['content-filter-provider-systemextension'],
  'com.apple.developer.system-extension.install': true,
};

function checkEntitlements(entitlements) {
  return spawnSync('python3', ['-c',
    "import sys,json;sys.path.insert(0,'scripts');from notary_candidate import validate_signed_entitlements;validate_signed_entitlements(json.load(sys.stdin),'com.significanthobbies.browserdaddy',host=True)"],
  { input: JSON.stringify(entitlements), encoding: 'utf8' });
}

test('accepts the provisioned host identity and required signed permissions', () => {
  const result = checkEntitlements(signedEntitlements);
  assert.equal(result.status, 0, result.stderr);
});

for (const [label, changes] of [
  ['debug signing', { 'com.apple.security.get-task-allow': true }],
  ['missing application identity', { 'com.apple.application-identifier': null }],
  ['wrong team', { 'com.apple.developer.team-identifier': 'OTHERTEAM' }],
  ['missing content filter', { 'com.apple.developer.networking.networkextension': [] }],
  ['missing extension installation', { 'com.apple.developer.system-extension.install': false }],
]) {
  test(`rejects ${label} even when a profile grants the permission`, () => {
    assert.notEqual(checkEntitlements({ ...signedEntitlements, ...changes }).status, 0);
  });
}

for (const status of ['Accepted', 'Invalid']) {
  test(`retains Apple's ${status} submission and retrieves rejection diagnostics`, () => {
    const workflow = readFileSync('.github/workflows/notarize-candidate.yml', 'utf8');
    const blocks = [...workflow.matchAll(/python3 - <<'PY'\n([\s\S]*?)\n          PY/g)];
    const block = blocks.find((match) => match[1].includes("result.get('status') != 'Accepted'"));
    assert.ok(block, 'Apple result handler exists in the executed workflow');
    const script = block[1].split('\n').map((line) => line.replace(/^          /, '')).join('\n');
    const dir = mkdtempSync(join(tmpdir(), 'browserdaddy-notary-result-'));
    try {
      mkdirSync(join(dir, 'candidate'));
      mkdirSync(join(dir, 'bin'));
      const tool = join(dir, 'bin', 'xcrun');
      writeFileSync(tool, '#!/bin/sh\nprintf "retrieved rejection log\\n"\n');
      chmodSync(tool, 0o700);
      writeFileSync(join(dir, 'candidate', 'notarization.json'), JSON.stringify({ id: 'submission-test', status }));
      const summary = join(dir, 'summary.md');
      const result = spawnSync('python3', ['-c', script], { encoding: 'utf8', env: {
        ...process.env, PATH: `${join(dir, 'bin')}:${process.env.PATH}`, RUNNER_TEMP: dir,
        GITHUB_STEP_SUMMARY: summary, CANDIDATE_SHA256: digest,
        NOTARY_KEY_ID: 'fixture', NOTARY_ISSUER_ID: 'fixture',
      } });
      assert.equal(result.status === 0, status === 'Accepted', result.stderr);
      assert.match(readFileSync(summary, 'utf8'), new RegExp(`Apple notarization result: ${status}`));
      assert.match(readFileSync(summary, 'utf8'), /Submission: submission-test/);
      if (status === 'Invalid') assert.match(result.stdout, /retrieved rejection log/);
    } finally {
      rmSync(dir, { recursive: true });
    }
  });
}
