# Segment rollover

The writer rolls a segment when it exceeds its byte budget.

## Observed failure

Two queues call the roll concurrently, so two segments claim the same generation number.

### Reproduction

Run the indexer with two shards and a one-kilobyte budget.

---

## Proposed fix

Give the writer a single owner for the roll.
