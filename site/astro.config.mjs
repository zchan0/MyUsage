import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Project page deployment: served from https://zchan0.github.io/MyUsage/
// `site` is the canonical origin (used in sitemap + canonical tags); `base`
// is the URL prefix (since this isn't a *.github.io user/org page).
export default defineConfig({
  site: 'https://zchan0.github.io',
  base: '/MyUsage',
  trailingSlash: 'never',
  output: 'static',
  integrations: [
    sitemap({
      filter: (page) => !page.includes('/_'),
    }),
  ],
  build: {
    format: 'directory',
  },
});
