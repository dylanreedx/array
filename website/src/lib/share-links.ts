// Share links: arrayapp.dev/s/<slug>?r=<relay>#<token>. The token stays in the
// fragment, so it never reaches this site; the page only hands the link to the
// Mac app. Prod answers array://, Dev builds answer array-dev://.

export const MAC_DOWNLOAD_URL = 'https://github.com/dylanreedx/array-releases/releases/latest/download/Array.dmg';

const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const TOKEN = /^[A-Za-z0-9_-]{16,128}$/;
const RELAY = /^[A-Za-z0-9.\-:_[\]][A-Za-z0-9.\-:/_[\]]{0,299}$/;

export function shareLinkSlug(pathname: string): string | undefined {
  const match = /^\/s\/([^/]+)\/?$/.exec(pathname);
  if (!match) return undefined;
  let slug: string;
  try { slug = decodeURIComponent(match[1]); } catch { return undefined; }
  return slug.length <= 64 && SLUG.test(slug) ? slug : undefined;
}

export function shareLinkDeepLink(pathname: string, search: string, hash: string, scheme: 'array' | 'array-dev' = 'array'): string | undefined {
  const slug = shareLinkSlug(pathname);
  const token = hash.startsWith('#') ? hash.slice(1) : hash;
  if (!slug || !TOKEN.test(token)) return undefined;
  const relays = new URLSearchParams(search).getAll('r');
  if (relays.length > 1) return undefined;
  const relay = relays[0];
  if (relay !== undefined && !RELAY.test(relay)) return undefined;
  const query = relay === undefined ? '' : `?r=${encodeURIComponent(relay).replace(/%3A/g, ':').replace(/%2F/g, '/')}`;
  return `${scheme}://s/${slug}${query}#${token}`;
}
