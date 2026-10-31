import { describe, expect, test } from 'vitest';
import { shareLinkDeepLink, shareLinkSlug } from './share-links';

const token = 'Qm9vdHN0cmFwLXRva2VuLWZvci1zaGFyZS1saW5rcw';

describe('share link hand-off', () => {
  test('hands arrayapp.dev/s/<slug>#<token> to array://s/<slug>#<token>', () => {
    expect(shareLinkDeepLink('/s/checkout-redesign', `#${token}`)).toBe(`array://s/checkout-redesign#${token}`);
    expect(shareLinkDeepLink('/s/checkout-redesign/', `#${token}`)).toBe(`array://s/checkout-redesign#${token}`);
  });

  test('refuses a link without a usable slug or token', () => {
    expect(shareLinkDeepLink('/s/checkout-redesign', '')).toBeUndefined();
    expect(shareLinkDeepLink('/s/checkout-redesign', '#short')).toBeUndefined();
    expect(shareLinkDeepLink('/s/Checkout_Redesign', `#${token}`)).toBeUndefined();
    expect(shareLinkDeepLink('/s/a/b', `#${token}`)).toBeUndefined();
    expect(shareLinkDeepLink('/s/%E0%A4%A', `#${token}`)).toBeUndefined();
    expect(shareLinkDeepLink('/s/ok', `#${token}"><script>`)).toBeUndefined();
  });

  test('reads the slug for display', () => {
    expect(shareLinkSlug('/s/payment-retry')).toBe('payment-retry');
    expect(shareLinkSlug('/s/')).toBeUndefined();
  });
});
