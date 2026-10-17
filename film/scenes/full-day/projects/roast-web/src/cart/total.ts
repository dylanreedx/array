import type { CartLine } from './types';

/** The cart total in dollars, shown in the header and at checkout. */
export function cartTotal(lines: CartLine[], discount = 0): number {
  const subtotal = lines.reduce((sum, line) => sum + line.price * line.quantity, 0);
  return Math.round(subtotal * (1 - discount) * 100) / 100;
}
