# Public documentation

The website serves `/docs/` and `/docs/<slug>/` as static pages. The source is
`docs/user/*.md`, loaded by `website/src/content.config.ts`. Do not maintain a
second copy of user documentation in the website. Markdown links use public
`/docs/<slug>/` URLs so they work in the shipped site.

Each guide requires YAML frontmatter: `title`, `description`, `section`
(`Start here`, `Workspace`, `Agents`, or `Reference`), and numeric `order`.
The filename becomes its URL. Preserve existing URLs or provide a redirect
when renaming. Use H2 sections; the page title and outline are generated.

The shared docs layout provides full-text search over the guides, navigation,
previous/next links, metadata, theme support, and a desktop page outline. It is
static HTML with a small local search script; no hosted search service or
account is needed. Search is progressive enhancement; ordinary navigation
works without JavaScript.

## Content verification

Explain what the feature does, a concrete way to use it, what owns its state,
and material availability limits. Distinguish a persisted model kind from an
exposed creation command. Do not turn old plans into shipped-product claims.

The initial content was checked against these authorities on 2026-10-16, and rechecked against 0.7.28 (build 79) on 2026-10-19:

| Topic | Source |
| --- | --- |
| All 12 persisted tile kinds | `Sources/ContinuumRevivedCore/CanvasState.swift`, `TileKind` |
| Terminal launch profiles | `Sources/ContinuumRevivedCore/LaunchProfileRegistry.swift` |
| Navigation and shortcuts | `Sources/ContinuumRevivedCore/NavKeymap.swift`, `ShortcutCatalog.swift` |
| Settings, defaults, and application timing | `Sources/ContinuumRevivedCore/SettingsSchema.swift`; `Sources/ContinuumRevived/App/SettingsPanel.swift` |
| Managed CLI transports and compaction | `Sources/ContinuumRevivedCore/AgentProviders/{ClaudeAgentRunner,CodexAgentRunner,PiRpcAgentRunner}.swift` |
| Canvas tools, descriptions, prompting | `Sources/ContinuumRevivedCore/Resources/PiExtensions/array-workspace-tools.json`; `WorkspaceAPI/WorkspaceMCPToolCatalog.swift`, `WorkspaceMCPConfiguration.swift` |
| Workspace tools opt-in and revocation | `WorkspaceAPI/WorkspaceAPIContracts.swift`, `WorkspaceToolsConfig`; `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`, `makeWorkspaceToolsMenuItems`; `App/AgentSupervisor.swift`, `setWorkspaceToolsEnabled` |
| MCP host transport and identity | `Sources/ContinuumRevived/App/WorkspaceMCPHost.swift` |
| Board content, images, and persistence | `Sources/ContinuumRevivedCore/KanbanBoard.swift`, `BoardTaskContent.swift`, `ProjectStore.swift` |
| Project and workspace paths | `Sources/ContinuumRevivedCore/ProjectStore.swift`, `WorkspaceStore.swift` |
| Companion (coming soon; the page claims nothing else) | `Sources/ContinuumRevivedCore/SettingsSchema.swift` (`iPhone` pane) |
| Composer dictation | `Sources/ContinuumRevived/Canvas/AgentComposer/ComposerDictation*.swift`, `AgentComposerView.swift`, `SettingsSchema.swift` (`agents.dictation`) |
| Agent identity colour | `ManagedAgentTileNSView.swift` (`Color` menu), `BuiltInSettingRegistry.swift` (palette, style), `docs/internals/workspace-agent-colour.md` |

Provider policy statements link to current official sources in the public CLI
guide. Re-check those sources when updating claims; another app's architecture
does not establish policy approval. Keep credential handling distinct from
execution permissions.

## Verification and serving

From `website/`, run `npm run build` and `npm run check`. Focused browser checks
are in `tests/docs.spec.ts`: rendered links and anchors, full-text search,
keyboard reset, mobile overflow, themes, and accessibility. Run with
`pnpm exec playwright test tests/docs.spec.ts` using the existing test server
configuration. The tests exercise the generated site rather than matching
source strings.

`npm run dev -- --host 127.0.0.1` previews the site locally. Production remains
the existing Vercel deployment from `main`; no additional hosting service or
publish step is introduced. Preparing this change locally does not deploy it.
