export interface CompanionDownloadLinks {
  testFlightURL?: string;
  appStoreURL?: string;
}

function validatedAppleURL(value: string | undefined, hostname: string): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.hostname !== hostname) return undefined;
    return url.toString();
  } catch {
    return undefined;
  }
}

export function companionDownloadLinks(environment: Record<string, string | undefined>): CompanionDownloadLinks {
  return {
    testFlightURL: validatedAppleURL(environment.PUBLIC_ARRAY_TESTFLIGHT_URL, 'testflight.apple.com'),
    appStoreURL: validatedAppleURL(environment.PUBLIC_ARRAY_APP_STORE_URL, 'apps.apple.com'),
  };
}

export function pairingDeepLink(scheme: 'array' | 'continuum', hash: string): string | undefined {
  const invitation = hash.startsWith('#') ? hash.slice(1) : hash;
  if (!invitation) return undefined;
  return `${scheme}://pair#${invitation}`;
}
