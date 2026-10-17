import { describe, expect, it } from 'vitest';
import { cartTotal } from '../src/cart/total';

describe('cartTotal', () => {
  it('adds line prices', () => {
    expect(cartTotal([{ sku: 'aut', name: 'Autumn blend', price: 18, quantity: 2 }])).toBe(36);
  });
});
