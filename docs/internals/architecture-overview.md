# Architecture overview

One page of orientation; the deep records live in the tickets
(`docs/38-tickets/`), which this page points into. Module map and glossary:
[AGENTS.md](../../AGENTS.md).

## The shape of the app

SwiftPM executable (`Array` product), no Xcode project. `ContinuumApp.main()`
first services every `--*-check` self-check flag (each exits), then boots
AppKit: PATH bootstrap (`ToolEnvironment`) → updater (gated,
`SPUStandardUpdaterController`) → registry load → project resolution →
`ZoneRuntimeController` → tile restore → main window → first-run onboarding
(gated). The bundle is hand-assembled by `scripts/make-app-bundle.sh`
(Sparkle.framework embedded, rpath fixed, channel stamped) — there is no Xcode
embed phase.

## Subsystems and their records

- **Canvas / tiles / zones** — `Sources/ContinuumRevived/Canvas/`,
  `TileSpawner`. Program: `docs/38-tickets/90-agent-ux/`,
  `91-agent-tile-ux/`.
- **Managed agents** — `AgentSupervisor` (event streams, 500-event replay
  cap, persistence gates, attach-time seams) driving `PiAgentRunner` (Core).
  Records: ticket 91 packets; context-window seams in the go-live doc.
- **Terminals** — GhosttyKit (`TerminalEngine/`), tmux persistence
  (`TmuxSession`, `TmuxLocator`), session names prefixed `array-`.
- **State** — `RegistryStore` (registry.json), `ProjectStore`, `AgentStore`;
  all root through `RegistryStore.defaultApplicationSupportDirectory()`,
  which is channel-aware (`AppChannel`).
- **Sync / companion** — `ContinuumRevivedSync`, CloudKit-gated
  (`CLOUDKIT_ENABLED`), off in the alpha. Relay program paused
  (`docs/38-tickets/92-small-team-relay/`).
- **Distribution** — Sparkle 2 (feed `arrayapp.dev/appcast.xml`, EdDSA),
  Developer ID + notarization pipeline (`scripts/release-app.sh`), channel
  split. Record: `docs/38-tickets/95-go-live.md`.

## Dependency directions (enforced by dedicated check targets)

Core → AgentContent, Core → AgentUI — never the reverse; AgentContent and
AgentUI link alone in their check executables so a violation fails to
compile. Sync depends on Core only. The app target is the only place AppKit,
GhosttyKit, and Sparkle appear.
