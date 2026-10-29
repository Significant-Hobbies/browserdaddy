// Shared update delivery only. Each app owns its routes, assets, and deployment.
export function createUpdateWorker({ canonicalHost, legacyHost, pagesHost }) {
  if (![canonicalHost, legacyHost, pagesHost].every((host) => typeof host === 'string' && /^[a-z0-9.-]+$/.test(host))) {
    throw new TypeError('Expected three explicit hostnames');
  }
  const canonical = `https://${canonicalHost}`;
  function secure(response) {
    const result = new Response(response.body, response);
    result.headers.set('X-Content-Type-Options', 'nosniff');
    result.headers.set('Referrer-Policy', 'no-referrer');
    result.headers.set('Content-Security-Policy', "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
    return result;
  }
  return {
    /** @param {Request} request @param {Env} env */
    async fetch(request, env) {
      if (!['GET', 'HEAD'].includes(request.method)) return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
      const url = new URL(request.url);
      if (url.hostname === legacyHost) {
        return Response.redirect(canonical + url.pathname + url.search, 308);
      }
      if (url.hostname !== canonicalHost) {
        return new Response('Not found', { status: 404 });
      }
      if (url.pathname === '/download') {
        const feedURL = new URL(request.url);
        feedURL.pathname = '/updates/appcast.xml';
        feedURL.search = '';
        const feed = await env.ASSETS.fetch(new Request(feedURL));
        const enclosure = feed.ok ? /<enclosure[^>]+url="[^"]*\/([^"/]+\.dmg)"/.exec(await feed.text()) : null;
        if (!enclosure) return new Response('Not found', { status: 404 });
        const assetURL = new URL(request.url);
        assetURL.pathname = `/updates/${enclosure[1]}`;
        assetURL.search = '';
        const response = await env.ASSETS.fetch(new Request(assetURL, request));
        const result = secure(response);
        if (response.ok) {
          result.headers.set('Content-Type', 'application/x-apple-diskimage');
          result.headers.set('Content-Disposition', `attachment; filename="${enclosure[1]}"`);
          result.headers.set('Cache-Control', 'private, no-store');
        }
        return result;
      }
      if (url.pathname.startsWith('/updates/')) {
        const response = await env.ASSETS.fetch(request);
        return secure(response);
      }
      const origin = new URL(request.url);
      origin.host = pagesHost;
      const upstream = new Request(origin, request);
      upstream.headers.set('x-daddy-proxy', '1');
      return fetch(upstream);
    },
  };
}
