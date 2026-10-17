// The barista's order queue: everything paid and not yet picked up.
export type Order = { id: string; placedAt: Date; items: string[]; pickup: "counter" | "delivery"; status: "new" | "brewing" | "ready" };

export function queue(orders: Order[]): Order[] {
  return orders.filter((o) => o.status !== "ready").sort((a, b) => +a.placedAt - +b.placedAt);
}
