# Recovery and scale teeth (piece C)

Recorded 30 October 2026 on `array/mp-recovery`. Each file is the PASS/FAIL
output of the witness run with one deliberate mutation applied. The source was
restored after every run, rebuilt, and the witness then passed.

| Receipt | Mutation | Witness that went RED |
| --- | --- | --- |
| `a-resend-after-commit.txt` | Pending-operation reconciliation ignores the duplicate receipt | relaunch after a commit with a lost reply resends |
| `a-lost-outbox.txt` | Current-schema local state decodes its outbox as empty | the intent of a process killed before send never lands |
| `a-blind-host-resend.txt` | Host dispatcher treats a crashed `attempting` attempt as fresh and re-arms it | the provider attempt is replayed instead of reported uncertain |
| `b-rebootstrap.txt` | Session drops its replica on a network error | outage loses the validated replica (re-bootstrap) |
| `c-partial.txt` | Session reports every bounded page as `connected` | a partial 1,500-event prefix is presented as shared state |
| `d-recovery-hold.txt` | Session's first read after a failure holds for 25s again | a session stays "reconnecting" after overload clears (overload leg in `ContinuumRevivedCollaborationChecks`) |
| `d-unbounded.txt` | Global held-read budget removed | the read past 1,024 is parked instead of refused |

Witnesses: `ContinuumRevivedCollaborationChecks --kill-relaunch-only` (a) and
`ContinuumRevivedCollaborationServiceChecks --recovery-scale-only` (b, c, d).
Both run inside the default invocations that `run-matrix.sh --collaboration`
already registers.
