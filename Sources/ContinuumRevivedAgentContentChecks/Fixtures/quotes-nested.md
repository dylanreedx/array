> The roll is not re-entrant, and both the ingest queue and the retention timer call it.
>
> - Ingest calls it on a byte-budget trip.
> - Retention calls it when the window closes.
>
> > Earlier note: this was safe when retention ran in-process on the ingest queue.
> > That stopped being true when retention moved to its own timer.

The quoted note is from the design review, not from the runtime.
