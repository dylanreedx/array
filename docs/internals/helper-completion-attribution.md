# Helper completion message attribution

0.7.42 fixes helper completion updates that appeared as raw
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
