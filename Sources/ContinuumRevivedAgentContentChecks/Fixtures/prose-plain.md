The ledger writer in the Atlas indexer keeps one open segment per shard and rolls it
whenever the segment passes its byte budget. Reads never block on that roll because the
reader holds the previous segment open until the new one is durable.

There is no compaction thread yet. Segments accumulate until the retention window closes
them, which is fine for the current shard count and will not be fine at ten times that.
