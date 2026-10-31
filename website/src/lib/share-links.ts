// Share links: arrayapp.dev/s/<slug>#<token>. The token stays in the fragment,
// so it never reaches this site; the page only hands it to the Mac app.

export const MAC_DOWNLOAD_URL = 'https://github.com/dylanreedx/array-releases/releases/latest/download/Array.dmg';

const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const TOKEN = /^[A-Za-z0-9_-]{16,128}$/;

export function shareLinkSlug(pathname: string): string | undefined {
  const match = /^\/s\/([^/]+)\/?$/.exec(pathname);
  if (!match) return undefined;
  let slug: string;
  try { slug = decodeURIComponent(match[1]); } catch { return undefined; }
  return slug.length <= 64 && SLUG.test(slug) ? slug : undefined;
}

export function shareLinkDeepLink(pathname: string, hash: string): string | undefined {
  const slug = shareLinkSlug(pathname);
  const token = hash.startsWith('#') ? hash.slice(1) : hash;
  if (!slug || !TOKEN.test(token)) return undefined;
  return `array://s/${slug}#${token}`;
}
