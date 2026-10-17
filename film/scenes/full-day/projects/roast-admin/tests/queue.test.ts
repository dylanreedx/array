import { queue } from "../src/queue/orders";
import { expect, test } from "vitest";

test("oldest order first", () => {
  const a = { id: "a", placedAt: new Date(1), items: [], pickup: "counter" as const, status: "new" as const };
  const b = { ...a, id: "b", placedAt: new Date(2) };
  expect(queue([b, a]).map((o) => o.id)).toEqual(["a", "b"]);
});
