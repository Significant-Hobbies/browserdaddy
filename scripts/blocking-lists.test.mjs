import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

const root = new URL('../Sources/BrowserDaddy/Resources/BlockingLists/', import.meta.url);

test('offline category data matches the pinned source manifest', async () => {
  const manifest = JSON.parse(await readFile(new URL('SOURCE.json', root), 'utf8'));
  assert.equal(manifest.source, 'https://github.com/ShadowWhisperer/BlockLists');
  assert.match(manifest.revision, /^[a-f0-9]{40}$/);
  assert.equal(manifest.license, 'Unlicense');
  for (const name of ['Adult.txt', 'Gambling.txt', 'LICENSE.txt']) {
    const data = await readFile(new URL(name, root));
    assert.equal(createHash('sha256').update(data).digest('hex'), manifest.files[name], name);
    assert.ok(data.length > 0, name);
  }
});

test('provider catalog binds exact domain sets and extension bundles the pinned resources', async () => {
  const core = await readFile(new URL('../Sources/BrowserCore/BlockingConfiguration.swift', import.meta.url), 'utf8');
  const project = await readFile(new URL('../FilterExtension/BrowserDaddyFilter.xcodeproj/project.pbxproj', import.meta.url), 'utf8');
  const manifest = JSON.parse(await readFile(new URL('SOURCE.json', root), 'utf8'));
  for (const [name, count] of [['Adult', 236454], ['Gambling', 9667]]) {
    const text = await readFile(new URL(`${name}.txt`, root), 'utf8');
    const hosts = new Set(text.split(/\r?\n/).map(line => line.split('#')[0].trim())
      .filter(Boolean).map(line => line.split(/\s+/).at(-1).toLowerCase()).filter(host => host !== 'localhost'));
    assert.equal(hosts.size, count, name);
    const canonical = [...hosts].sort().join('\n') + '\n';
    const digest = createHash('sha256').update(canonical).digest('hex');
    assert.ok(core.includes(`"${digest}"`), `${name} canonical set must match the producer's pinned identity`);
    assert.ok(core.includes(`"${manifest.files[`${name}.txt`]}"`), `${name} raw bytes must match the resolver's pinned identity`);
  }
  for (const name of ['Adult.txt', 'Gambling.txt', 'SOURCE.json', 'LICENSE.txt']) {
    assert.match(project, new RegExp(`${name.replace('.', '\\.')} in Resources`), `${name} must be in the compiled extension resources`);
  }
});
