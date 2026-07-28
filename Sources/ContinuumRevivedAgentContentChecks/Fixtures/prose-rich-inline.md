The failing path is `LedgerWriter.rollSegment(reason:)`, which is **not** re-entrant and is
called from two queues. The *shorter* fix is a serial queue; the durable fix is to make the
roll a state machine owned by the writer.

Details are in the [segment rollover notes](https://docs.example.com/atlas/rollover) and in
`Sources/Atlas/LedgerWriter.swift`.

This sentence continues on
the next source line, which is a soft break rather than a new paragraph.

This line ends with a hard break,  
so the following text belongs to the same paragraph.
