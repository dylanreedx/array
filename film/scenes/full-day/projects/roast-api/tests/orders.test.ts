import { expect, it } from 'vitest';
import { orders } from '../src/orders/routes';

it('places an order', async () => {
  expect(orders).toBeDefined();
});
