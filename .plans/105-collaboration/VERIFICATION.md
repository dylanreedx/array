# Verification and limits

29 October 2026. This records the initial documentation pass and the subsequent implementation-planning/board pass separately. No feature implementation or collaboration readiness is established.

## Research performed

The initial user-authorized twelve-agent pass investigated:

1. Local T3 source and cached branches.
2. T3 upstream releases, PRs and proposals.
3. Amp collaboration, shared execution and handoff.
4. Figma collaboration interactions.
5. Excalidraw source and room semantics.
6. Other infinite canvases.
7. Developer collaboration tools.
8. Array's architecture and ownership contracts.
9. Naming and positioning.
10. Teammate presence and usage.
11. Control, trust and concurrent inputs.
12. Product scenarios and fit with recent direction.

The documentation pass incorporated Dylan's subsequent preferences and private scenarios, inspected existing `.plans/` conventions, the docs index and the multi-selection contract, and re-read relevant agent identity, external ownership, project-lock, workspace API and companion wiring source. Read-only Git inspection reconfirmed the local T3 checkout and cached guest branch. The tagged T3 guest guide and current Amp/Warp guides were reopened on the web.

## Corrections retained

- Cached T3 branch behavior is older than the released guide. Branch presence alone does not prove shipment; upstream release/merge evidence supplies that distinction.
- Existing companion source wiring is more developed than the root orientation's blanket sync-disabled description. No live deployment was probed.
- Standalone shared-session-first was an assistant recommendation, not a user decision. Latest direction explores workspace, zone and captured-area sharing.
- Token hover is an explicit user preference, superseding the initial advice to keep tokens only in separate usage details.
- Shared visibility, remote host control, local file integration and execution transfer are different promises.

## Initial documentation actions and validation

- Created this research directory and linked it from the existing docs index, preserving pre-existing edits.
- Ran `scripts/benches.sh` at pickup and completion as a read-only inventory; created or removed no bench/worktree and performed no cleanup.
- Checked Markdown file links in the packet and its docs-index entry for existing targets, and ran scoped `git diff --check`.
- Reviewed the packet for explicit exploratory status, latest-preference consistency and separation of internal scenario details from proposed UI examples.
- Reviewed scoped Git status/diff. The repository and `docs/README.md` already had unrelated changes at pickup; they were not staged, reverted or rewritten.

The first custom validation found four Markdown hard-break lines with trailing spaces in the illustrative hover card. They were replaced with explicit blockquote paragraph breaks. The rerun checked eight Markdown files, 43 local links, the docs-index destination, whitespace and private-example placement; all passed. Scoped `git diff --check` passed. These checks validate document hygiene, not product behavior.

## Not run or established by the initial research

- No app launch, native UI preview, browser prototype or light/dark appearance verification.
- No Swift build, matrix, CoreChecks or competitor test suite. Documentation has no runtime behavior to witness.
- No live tmux inspection, provider invocation, credential access, companion relay connection or production state access.
- No Git fetch, checkout, stage, commit, push, merge, worktree creation/removal or dependency installation.
- No hands-on T3/Amp/Figma/Warp collaboration session, usability study or comparative performance test.
- No cross-machine session resume, remote code integration, conflict resolution, revocation, ordering, reconnect or usage aggregation test.
- No proof that all runners provide streaming usage, portable sessions, matching token categories or reliable remote control.
- No naming clearance, adoption evidence, cost estimate, implementation schedule or architecture approval.

Product sources describe supported behavior; source comments and tests inspected without running them describe intent and coverage. Proposed Array behavior needs production-path behavioral witnesses and matrix reporting if implementation is later authorized. New notification paths would also need classification in the maintained inventory; none is introduced by this research.

## Implementation-planning and board pass

At Dylan's explicit request, twelve additional agents inspected the domain, relay/transport, human identity, canvas, runners, context/discussion, usage, artifacts, persistence, security, validation and delivery. Their memos are in `implementation/`. The parent consolidated the findings into `IMPLEMENTATION-PLAN.md`, 26 ticket definitions in `TICKETS.md`/`tickets.json`, and a machine-readable `BOARD-RECEIPT.json`. Twenty-two tickets define the native coworker-alpha path; four are later scoped additions. Dependencies were checked for missing IDs and cycles.

Live workspace interaction was limited to user-authorized discovery and board updates through the Array workspace API. The parent resolved its agent tile and queried both board summaries/positions. Target `F54D4170-AB61-4595-A4D4-A400B76364A5` was empty at revision 0 and directly above this agent; the other identically titled board had 17 cards at revision 33. Only the target received mutation calls. Twenty-six sequential `create` operations used fresh board revisions, stable idempotency keys and explicit column IDs; each returned committed durability and registered Undo. No agents were assigned or messaged and no task execution was started through the board.

Readback verified exact titles, bodies, ordering and To Do placement for all 26 cards at target revision 26. The first whole-board verification correctly stopped on a truncated response rather than treating six returned cards as the complete board; following all five cursor pages completed verification. The other board still had 17 cards but advanced independently to revision 53 during parallel user/agent activity. We made zero write calls to it; no claim of an unchanged global workspace is made.

Official Yjs documentation and SwiftNIO's repository were consulted for narrow technical context. An Automerge index returned no readable content and was not used as supporting evidence. Some exploratory shell reads tried nonexistent candidate source paths and a glob with no matches; subsequent source/memo inspection used the actual file locations. No failed lookup was treated as evidence of absent functionality.

Validation covers all packet Markdown/local links, JSON parsing, exact ticket/receipt identities, phase totals, private-example placement, trailing whitespace and scoped `git diff --check`. The completion message reports the final outcome. These are documentation/API persistence checks, not runtime collaboration tests.

Final outcome: **PASS** for 23 Markdown documents and 165 local links; all twelve implementation memos are present; both JSON files parse; all 26 ticket definitions match committed receipt identities; dependencies form an acyclic graph; four cards are explicitly later scope; private originating names/domain details appear only in `ORIGIN.md`; scoped `git diff --check` is clean. The five-page live board readback establishes the exact persisted card contents and order independently from these local checks.

No product code, dependency, credential, default tmux server, production relay deployment or provider process was changed or launched. Existing unrelated working-tree edits were preserved. No Git mutations occurred. `scripts/benches.sh` was read at pickup and completion; no bench was created, removed or cleaned. Feature builds, matrix, native UI sweeps and multi-client runtime witnesses remain future ticket acceptance work.


## Authorized implementation start

See [progress](PROGRESS.md) for the first Core implementation, actual RED/GREEN
results, fixture failure correction, matrix report and remaining runtime limits.
The original no-implementation statements above describe the research task.
