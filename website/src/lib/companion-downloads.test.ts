import { describe, expect, test } from 'vitest';
import { companionDownloadLinks, pairingDeepLink } from './companion-downloads';

describe('companion download configuration', () => {
  test('accepts only the official HTTPS Apple destinations', () => {
    expect(companionDownloadLinks({
      PUBLIC_ARRAY_TESTFLIGHT_URL: 'https://testflight.apple.com/join/example',
      PUBLIC_ARRAY_APP_STORE_URL: 'https://apps.apple.com/ca/app/array/id123456789',
    })).toEqual({
      testFlightURL: 'https://testflight.apple.com/join/example',
      appStoreURL: 'https://apps.apple.com/ca/app/array/id123456789',
    });
  });

  test('fails closed for missing, malformed, or non-Apple configuration', () => {
    expect(companionDownloadLinks({})).toEqual({ testFlightURL: undefined, appStoreURL: undefined });
    expect(companionDownloadLinks({ PUBLIC_ARRAY_TESTFLIGHT_URL: 'javascript:alert(1)' }).testFlightURL).toBeUndefined();
    expect(companionDownloadLinks({ PUBLIC_ARRAY_APP_STORE_URL: 'https://example.com/app' }).appStoreURL).toBeUndefined();
  });
});

describe('pairing deep links', () => {
  test('preserves the opaque invitation fragment byte-for-byte', () => {
    expect(pairingDeepLink('array', '#v1.payload%2Bvalue')).toBe('array://pair#v1.payload%2Bvalue');
    expect(pairingDeepLink('continuum', 'legacy-token')).toBe('continuum://pair#legacy-token');
  });

  test('does not create a deep link without an invitation', () => {
    expect(pairingDeepLink('array', '')).toBeUndefined();
    expect(pairingDeepLink('array', '#')).toBeUndefined();
  });
});
