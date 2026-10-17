// Read by `remotion studio|render|still`. scripts/render calls the Node API instead and sets the same
// options there.
import { Config } from '@remotion/cli/config';
import { bundlerOverride } from './legacy/lib/bundler';

Config.setEntryPoint('src/index.ts');
// `@website/*` for the reference films in legacy/ (types and the demo reducer); the kit never imports it.
Config.overrideWebpackConfig(bundlerOverride);
// Determinism and quality.
Config.setVideoImageFormat('png'); // lossless frames into the encoder; jpeg q95 bands on a dark ground
Config.setColorSpace('bt709');
Config.setChromiumOpenGlRenderer('angle'); // macOS default; set explicitly so every machine agrees
Config.setDelayRenderTimeoutInMilliseconds(120_000);
Config.setOverwriteOutput(true);
// Off port 3000: the film harness's browser tile serves its storefront there during captures.
Config.setStudioPort(3480);
Config.setRendererPort(3481);
// No setBrowserExecutable(): Remotion's pinned Chrome Headless Shell (`pnpm browser` downloads it).
