// One bundler override shared by remotion.config.ts and any script that calls bundle().
// It points `@website/*` at the real website source and forces every bare import made from
// website files (react, react-dom, @base-ui/react) to resolve from film/node_modules, so
// there is exactly one React in the bundle. website/node_modules is never read.
import path from 'node:path';
import type { BundlerConfiguration } from '@remotion/bundler';

const FILM = process.cwd();
export const WEBSITE = path.resolve(process.env.ARRAY_WEBSITE ?? path.join(FILM, '..', 'website'));
const mod = (name: string) => path.join(FILM, 'node_modules', name);

export const bundlerOverride = <C extends BundlerConfiguration>(c: C): C => ({
  ...c,
  resolve: {
    ...c.resolve,
    // Root-relative CSS urls in website modules (ProviderMark: url('/provider-openai.svg'))
    // resolve against website/public, exactly as Astro serves them.
    roots: [path.join(WEBSITE, 'public')],
    modules: [path.join(FILM, 'node_modules'), 'node_modules'],
    alias: {
      ...(c.resolve?.alias ?? {}),
      '@website': path.join(WEBSITE, 'src'),
      '@website-public': path.join(WEBSITE, 'public'),
      react: mod('react'),
      'react-dom': mod('react-dom'),
      '@base-ui/react': mod('@base-ui/react'),
    },
  },
}) as C;
