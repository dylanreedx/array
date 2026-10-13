import type { ClientDirective } from 'astro';

// The server-rendered scene needs no React work until a visitor explores it.
const hydrateOnIntent: ClientDirective = (load) => {
  let started = false;
  const hydrate = async () => {
    if (started) return;
    started = true;
    removeEventListener('scroll', hydrate);
    removeEventListener('pointerdown', hydrate);
    removeEventListener('keydown', hydrate);
    const run = await load();
    await run();
  };
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) void hydrate();
  else {
    addEventListener('scroll', hydrate, { passive: true });
    addEventListener('pointerdown', hydrate, { passive: true });
    addEventListener('keydown', hydrate);
  }
};
export default hydrateOnIntent;
