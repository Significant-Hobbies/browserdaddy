import { createUpdateWorker } from './worker-core.mjs';

export default createUpdateWorker({
  marketingMount: 'browser',
  canonicalHost: 'browser.daddyrad.com',
  legacyHost: 'browserdaddy.significanthobbies.com',
  pagesHost: 'browserdaddy-landing.pages.dev',
});
