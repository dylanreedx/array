// @ts-check
import { defineConfig } from 'astro/config';

import react from '@astrojs/react';
import tailwindcss from '@tailwindcss/vite';

// https://astro.build/config
export default defineConfig({
  site: 'https://arrayapp.dev',
  integrations: [react(), { name: 'hydrate-on-intent', hooks: { 'astro:config:setup': ({ addClientDirective }) => addClientDirective({ name: 'intent', entrypoint: './src/lib/hydrate-on-intent.ts' }) } }],
  build: {
    inlineStylesheets: 'always'
  },
  vite: {
    plugins: [tailwindcss()]
  }
});
