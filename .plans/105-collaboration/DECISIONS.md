# Initial implementation decisions

29 October 2026. Dylan authorized starting multiplayer. These decisions guide
the offline foundation; deployed collaboration remains future work.

- Native Mac clients first. Workspace, zone and capture all produce a reviewed
  manifest for one portable shared area. Admission is explicit; dragging a
  private tile across an area boundary does not publish it.
- Use a dedicated shared scene first. Embedding a shared scene into the personal
  canvas can follow the same document contract. Source zones remain owned by
  their projects. A shared scene owns its internal geometry; local placement,
  camera, focus and checkout bindings stay private.
- Keep person, device and execution host separate. Shared source references are
  opaque IDs, never paths or runner records. Visibility, publication and host
  actions are separate grants. Joining or closing a view cannot create or stop
  a runner. Authentication and grant enforcement belong to the service and host,
  not to the document reducer.
- Start with server-ordered atomic commands and immutable context revisions.
  Require exact expected revisions initially; stale edits retain local drafts
  for explicit retry. Discussion appends do not automatically prompt an agent.
  Per-operation SHA-256 receipts distinguish retries from changed intent.
  Deletions reserve identities permanently within a document; compaction must
  retain them and receipt coverage. A text CRDT is not required for this slice.
- Initial publication supports managed-agent observations, immutable artifacts,
  human discussion and revisioned agreements. Terminal input, browser sessions,
  local preview forwarding and execution transfer are unsupported. Notes become
  explicit agreement content or immutable artifacts, never silently live-sync.
- Implement the first service as a trusted relay, with TLS and service-readable
  shared content. Preserve companion encryption unchanged. No E2EE claim.
  Before real content is published, implement encrypted storage/backups with
  deployment-managed keys, rotation/restore handling, redacted logs and explicit
  retention/deletion settings. Keep those operational gates in COL-20/22.
  Revocation stops future access, not copies already delivered. Real group E2EE
  would require a separate blocking key-admission/history/rotation design.
- Keep checkouts separate. Shared diffs show an immutable selected revision;
  code application is an explicit later operation. Token usage comes from
  provider-backed accounting and appears on collaborator hover/focus only.

Example: source world rectangles `(120, 300, 640, 520)` and
`(800, 340, 640, 520)` captured at `(120, 300)` become area rectangles
`(0, 0, 640, 520)` and `(680, 40, 640, 520)`. A receiving client's outer
anchor changes neither those values nor either source canvas. The shared JSON
contains area/object/placement/person/host IDs, source binding IDs and selected
content. It contains no checkout path, CLI auth, local project ID or viewport.

COL-01 is a decision record, not a runtime claim. COL-02 remains open until the
actual service routes, host adapters and mounted native scenes exist. The first
COL-03 witness covers the portable reducer only.
