import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker from './worker.mjs';

const env = {
  ASSETS: {
    fetch: async (request) => {
      const path = new URL(request.url).pathname;
      if (path === '/updates/appcast.xml') {
        return new Response('<enclosure url="https://browserdaddy.significanthobbies.com/updates/browserdaddy-0.3.1-build4-universal.dmg"/>', { status: 200 });
      }
      return new Response(`asset:${path}`, { status: 200 });
    },
  },
};

test('serves /updates/* on browser.daddyrad.com', async () => {
  const feed = await worker.fetch(new Request('https://browser.daddyrad.com/updates/appcast.xml'), env);
  assert.equal(feed.status, 200);
  assert.match(await feed.text(), /<enclosure url=/);
  assert.equal(feed.headers.get('X-Content-Type-Options'), 'nosniff');
});

test('legacy hostname keeps protected redirects on the app subdomain', async () => {
  for (const path of ['/', '/updates/appcast.xml', '/updates/x.dmg?v=1']) {
    const response = await worker.fetch(new Request(`https://browserdaddy.significanthobbies.com${path}`), env);
    assert.equal(response.status, 308, path);
    assert.equal(response.headers.get('location'), path === '/' ? 'https://daddyrad.com/browser/' : `https://browser.daddyrad.com${path}`);
  }
});

test('serves /download as the newest feed DMG', async () => {
  const response = await worker.fetch(new Request('https://browser.daddyrad.com/download'), env);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), 'asset:/updates/browserdaddy-0.3.1-build4-universal.dmg');
  assert.equal(response.headers.get('Content-Type'), 'application/x-apple-diskimage');
  assert.match(response.headers.get('Content-Disposition') ?? '', /browserdaddy-0\.3\.1-build4-universal\.dmg/);
  const head = await worker.fetch(new Request('https://browser.daddyrad.com/download', { method: 'HEAD' }), env);
  assert.equal(head.status, 200);
});

test('retains API proxy behavior on the Pages origin', async () => {
  const original = globalThis.fetch;
  let requested;
  globalThis.fetch = async (input) => { requested = input.url; return new Response('landing', { status: 200 }); };
  try {
    const response = await worker.fetch(new Request('https://browser.daddyrad.com/api/ai?a=1'), env);
    assert.equal(response.status, 200);
    assert.equal(requested, 'https://browserdaddy-landing.pages.dev/api/ai?a=1');
  } finally {
    globalThis.fetch = original;
  }
});

test('unknown hosts 404', async () => {
  const other = await worker.fetch(new Request('https://example.com/updates/appcast.xml'), env);
  assert.equal(other.status, 404);
});

test('rejects non-read methods', async () => {
  const response = await worker.fetch(new Request('https://browser.daddyrad.com/updates/appcast.xml', { method: 'POST' }), env);
  assert.equal(response.status, 405);
});

test('known web routes and legacy marketing links redirect directly with exact queries', async () => {
  const routes = [
    ['/', '/'], ['/index.html', '/'], ['/index.md', '/index.md'],
    ['/llms.txt', '/llms.txt'], ['/llms-full.txt', '/llms-full.txt'],
    ['/ai.txt', '/ai.txt'], ['/robots.txt', '/robots.txt'], ['/sitemap.xml', '/sitemap.xml'],
    ['/blog/rss.xml', '/blog/rss.xml'],
  ];
  for (const section of ['privacy', 'terms', 'support', 'accessibility', 'release', 'testflight', 'blog']) {
    routes.push([`/${section}`, `/${section}/`], [`/${section}/`, `/${section}/`],
      [`/${section}/index.html`, `/${section}/`], [`/${section}/index.md`, `/${section}/index.md`],
      [`/${section}.md`, `/${section}/index.md`]);
  }
  const query = '?utm_source=old&keep=a%2Fb&keep=%25';
  for (const host of ['browser.daddyrad.com', 'browserdaddy.significanthobbies.com']) {
    for (const method of ['GET', 'HEAD']) for (const [path, target] of routes) {
      const response = await worker.fetch(new Request('https://' + host + path + query, { method }), env);
      assert.equal(response.status, 308, `${method} ${host}${path}`);
      assert.equal(response.headers.get('location'), 'https://daddyrad.com/browser' + target + query);
      assert.equal(await response.text(), '');
    }
  }
});

test('API, metadata, static resources and unknown paths retain the existing proxy behavior', async () => {
  const original = globalThis.fetch;
  const query = '?keep=a%2Fb';
  let requested;
  let status;
  globalThis.fetch = async (request) => {
    requested = request;
    return new Response('upstream', { status, headers: { 'Content-Type': 'application/json' } });
  };
  try {
    for (const path of ['/api/ai', '/api/md', '/api/md/_catalog', '/openapi.json', '/release.json', '/downloads/missing.dmg', '/releases/missing.dmg', '/download/', '/assets/missing.png', '/missing', '/blog/missing/', '/blog/missing.md', '/blog/background-apps/']) {
      status = path.startsWith('/api/') || path === '/openapi.json' ? 200 : 404;
      for (const method of ['GET', 'HEAD']) {
        const response = await worker.fetch(new Request('https://browser.daddyrad.com' + path + query, { method }), env);
        assert.equal(response.status, status, `${method} ${path}`);
        assert.equal(response.headers.get('location'), null);
        assert.equal(requested.url, 'https://browserdaddy-landing.pages.dev' + path + query);
        assert.equal(requested.method, method);
        assert.equal(requested.headers.get('x-daddy-proxy'), '1');
      }
    }
  } finally {
    globalThis.fetch = original;
  }
  const missing = { ASSETS: { fetch: async () => new Response('missing', { status: 404 }) } };
  for (const path of ['/download', '/updates/missing.dmg']) {
    const response = await worker.fetch(new Request('https://browser.daddyrad.com' + path), missing);
    assert.equal(response.status, 404);
    assert.equal(response.headers.get('location'), null);
  }
});

test('protected legacy redirects and rejected methods retain their existing contracts', async () => {
  const query = '?keep=a%2Fb';
  for (const path of ['/download', '/updates/appcast.xml', '/release.json', '/releases/missing.dmg', '/api/ai', '/api/md', '/openapi.json']) {
    for (const method of ['GET', 'HEAD']) {
      const response = await worker.fetch(new Request('https://browserdaddy.significanthobbies.com' + path + query, { method }), env);
      assert.equal(response.status, 308);
      assert.equal(response.headers.get('location'), 'https://browser.daddyrad.com' + path + query);
    }
  }
  for (const host of ['browser.daddyrad.com', 'browserdaddy.significanthobbies.com']) {
    for (const path of ['/', '/release', '/release.json', '/api/ai', '/api/md']) {
      for (const method of ['POST', 'PUT', 'DELETE', 'OPTIONS']) {
        const response = await worker.fetch(new Request('https://' + host + path, { method }), env);
        assert.equal(response.status, 405);
        assert.equal(response.headers.get('allow'), 'GET, HEAD');
        assert.equal(response.headers.get('location'), null);
      }
    }
  }
});
