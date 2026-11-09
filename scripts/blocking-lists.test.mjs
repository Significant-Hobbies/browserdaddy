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
