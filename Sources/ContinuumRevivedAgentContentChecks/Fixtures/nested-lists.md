Steps for the rollover fix:

1. Serialize the roll behind the writer's own queue.
   - Keep the byte-budget check on the caller's side.
   - Move only the segment swap inside.
2. Add a generation assertion.

   The assertion has to survive replay, so it belongs in the reader too.

   - Reader side: refuse a segment whose generation is not monotonic.
   - Writer side: refuse to publish a duplicate generation.
3. Backfill a check for the two-shard case.

Loose ends:

- Retention window is still hard-coded.
- Compaction is unimplemented.
