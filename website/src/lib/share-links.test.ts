import { describe, expect, test } from 'vitest';
import { shareLinkDeepLink, shareLinkSlug } from './share-links';

const token = 'Qm9vdHN0cmFwLXRva2VuLWZvci1zaGFyZS1saW5rcw';

describe('share link hand-off', () => {
  test('hands arrayapp.dev/s/<slug>?r=<relay>#<token> to array:// with the relay', () => {
    expect(shareLinkDeepLink('/s/checkout-redesign', '?r=relay.arrayapp.dev', `#${token}`))
      .toBe(`array://s/checkout-redesign?r=relay.arrayapp.dev#${token}`);
    expect(shareLinkDeepLink('/s/checkout-redesign/', '?r=127.0.0.1:8443', `#${token}`))
      .toBe(`array://s/checkout-redesign?r=127.0.0.1:8443#${token}`);
    expect(shareLinkDeepLink('/s/checkout-redesign', '', `#${token}`)).toBe(`array://s/checkout-redesign#${token}`);
  });

  test('offers Array Dev on its own scheme', () => {
    expect(shareLinkDeepLink('/s/team', '?r=relay.arrayapp.dev', `#${token}`, 'array-dev'))
      .toBe(`array-dev://s/team?r=relay.arrayapp.dev#${token}`);
  });

  test('refuses a link without a usable slug, token or relay', () => {
    expect(shareLinkDeepLink('/s/checkout-redesign', '', '')).toBeUndefined();
    expect(shareLinkDeepLink('/s/checkout-redesign', '', '#short')).toBeUndefined();
    expect(shareLinkDeepLink('/s/Checkout_Redesign', '', `#${token}`)).toBeUndefined();
    expect(shareLinkDeepLink('/s/a/b', '', `#${token}`)).toBeUndefined();
    expect(shareLinkDeepLink('/s/%E0%A4%A', '', `#${token}`)).toBeUndefined();
    expect(shareLinkDeepLink('/s/ok', '', `#${token}"><script>`)).toBeUndefined();
    expect(shareLinkDeepLink('/s/ok', '?r=evil.example%23x', `#${token}`)).toBeUndefined();
    expect(shareLinkDeepLink('/s/ok', '?r=a.example&r=b.example', `#${token}`)).toBeUndefined();
  });

  test('reads the slug for display', () => {
    expect(shareLinkSlug('/s/payment-retry')).toBe('payment-retry');
    expect(shareLinkSlug('/s/')).toBeUndefined();
  });
});
