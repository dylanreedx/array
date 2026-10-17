export interface CartLine {
  sku: string;
  name: string;
  /** Unit price in dollars. */
  price: number;
  quantity: number;
}
