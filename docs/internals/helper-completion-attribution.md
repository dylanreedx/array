# Helper completion message attribution

0.7.42 fixes delivered helper completion updates that appeared as raw
`<array-agent-message>` markup when the receiving lead was busy. Idle-lead
updates already used the established attributed message card.

The busy queue path introduced by `4fa6e039` sent a host-authored envelope
through composer admission. That admission deliberately inserts U+200B after
`<` when typed text resembles another agent's message, preventing sender
spoofing. The parser correctly kept the neutralized envelope as user prose.

Typed-envelope neutralization now happens at the public composer entry point.
Trusted helper completion updates enter the existing private admission path,
as shared teammate attribution already does. Queue admission, sharing checks,
persistence, recovery and draining still apply. The parser, card renderer,
message body, completion timing and notification policy are unchanged.

## Behavioral witness

`--helper-completion-check` exercises real completion ingestion and busy-parent
queue draining with an isolated fake Pi runner. With the new assertions alone
on `bf9099d8`, it failed with `busy helper completion lost structured agent
attribution`; after the fix it passed. The assertions check the actual queued
sender and body, idle/busy live-document message blocks, absence of envelope
prose, Claude/Codex/Pi session-reader replay, and the established card renderer
in light and dark appearances. `--agent-message-card-check` also passes,
including live typed-envelope spoof protection.

The targeted `scripts/run-matrix.sh --managed-mode` passed all 36 legs and
explicitly reported the completion witness. This was not a full matrix run.
Opt-in `CONTINUUM_AGENT_MESSAGE_CAPTURE=<directory>` captures the actual idle
and busy completion cards in both appearances; a fresh build and completion
check passed after adding capture-only instrumentation. All four PNGs were
visually inspected. Release evidence retains the RED/GREEN logs, matrix report
and captures in the gitignored `releases/0.7.42-evidence/` directory.

## Limits

Already persisted U+200B envelopes retain their presentation: recognizing them
globally would also accept typed spoofed messages. The long synthetic report
JSON remains unchanged inside its attributed card. Completion ingestion is
witnessed with the fake Pi runner; the other harnesses use their production
session readers. No live provider, full-canvas or previous-install update test
is claimed. Production app/state was not used for QA.


## Queued preview follow-up (0.7.43)

The 0.7.42 verification covered delivered transcript blocks and cards, not the
pending queue rail. Dylan's live screenshot after updating showed that the
separate `QueueRailItemRow` still flattened raw transport text. The earlier
confidence did not establish pending-preview behavior.

0.7.43 changes only queue-row presentation: the existing semantic envelope
parser supplies the sender and first nonempty body line, displayed using the
existing single-line row styling. Recognized shared-teammate attribution uses
the same path. Tooltips and accessibility labels use clean display text.
Ordinary typed text, including neutralized envelope examples, retains its
existing presentation. Durable queue bytes, transport, admissions, editing,
recovery and the 0.7.42 fix remain unchanged.

The existing matrix-reported `--helper-completion-check` now mounts the actual
production queue rail from a real busy lead's queue state before draining.
It asserts displayed sender/summary strings in light/dark and unchanged queued
transport and running state. It separately checks shared attribution and plain
or neutralized typed prompts. Test-only changes fail against 0.7.42 at `busy
queue preview must show sender and clean summary`; the preview fix passes.
`CONTINUUM_QUEUED_MESSAGE_CAPTURE=<directory>` and optional
`CONTINUUM_QUEUE_CAPTURE_PHASE=before` save actual queued-row PNGs in both
appearances. Before/after images are under the canonical project's
`output/raw-helper-message-previews/queued-{before,after}-{light,dark}.png`,
with logs retained in gitignored `releases/0.7.43-evidence/`.


## Per-helper attribution in a completion batch

The plain-text follow-up removes JSON and the batch heading at the write
boundary. Each helper status, summary, findings, attention checks, next step
and details path is stored as prose; the structured report stays on its record
and result-file channel.

Previously `flushHelperCompletions` joined all result bodies and wrapped them
with the first helper's identity. Every subsequent result therefore appeared
inside that helper's card and model-message envelope. The batched wake now
contains one independently attributed envelope per result, carried together in
one `<array-agent-messages>` host envelope and one runner prompt. A single
result retains the established single-message format. Each batch member names
its own UUID and display name; its UTF-8 body byte count preserves literal
closing tags and Unicode without escaping or rewriting report text.

The shared envelope parser recognizes the host batch; transcript projection
creates one existing agent-message card per member inside one user entry.
All three session readers reuse that projection on restore. No renderer or
card styling changes. The existing single-line queue preview shows the helper
count and first status, rather than attributing the whole batch to its first
helper. Typed batches pass through the same spoof neutralization as typed
single-message envelopes. Malformed batches stay user prose.

Both idle delivery and busy queue admission send this one prompt. Queue
persistence, recovery, admission and retry semantics remain in place. A failed
admission restores the entire batch for retry. Companion task lineage retains
its existing first-result run binding; it is separate from message authorship.
This change does not introduce a turn per helper or a new notification sender.
The existing SRC-01 notification-path note records the payload change.

### Witness and limits

The existing matrix-registered `--helper-completion-check` finishes three
helpers in one busy-lead batch. Before the attribution fix, its new assertion
failed: `three helper results must project as three separately attributed
messages in one prompt`. It checks each result's own sender and body, absence
of another member's result in that card, unchanged attribution in the runner
prompt and all three offline session-reader formats, and exactly one grouped
wake prompt. Existing idle delivery, light/dark cards and queue preview,
plain-text report retention and typed-envelope protection remain covered.
Unicode, literal envelope examples and malformed byte counts exercise batch
framing. Full matrix and live provider acceptance remain integration work;
no production-state or live Claude verification is claimed.
