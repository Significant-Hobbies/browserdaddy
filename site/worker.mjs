import { marketingLocation } from './marketing-redirect.mjs';
import { createUpdateWorker } from './worker-core.mjs';

const updates = createUpdateWorker({
  canonicalHost: 'browser.daddyrad.com',
  legacyHost: 'browserdaddy.significanthobbies.com',
  pagesHost: 'browserdaddy-landing.pages.dev',
});

export default {
  /** @param {Request} request @param {Env} env */
  async fetch(request, env) {
    if (['GET', 'HEAD'].includes(request.method)) {
      const url = new URL(request.url);
      if (['browser.daddyrad.com', 'browserdaddy.significanthobbies.com'].includes(url.hostname)) {
        const marketing = marketingLocation(url.pathname, url.search, 'browser');
        if (marketing) return Response.redirect(marketing, 308);
      }
    }
    return updates.fetch(request, env);
  },
};
