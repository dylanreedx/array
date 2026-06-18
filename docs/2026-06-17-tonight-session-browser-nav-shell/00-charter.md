# Tonight session — Browser, navigation, shell polish, theming

Status: draft planning

## Mission
Turn Continuum into a stronger daily-driver canvas by improving browser depth, camera-like navigation, tile naming/identity, terminal usability, zone customization, and background theming.

## Non-negotiables
- Do not use or store pasted API keys. The exposed OpenAI key must be revoked/rotated by the owner.
- Browser password work must not attempt to exfiltrate Chrome secrets. Prefer explicit import/export or OS keychain-backed app storage.
- Each ticket should be independently reviewable with checks or instrumentation.
- UX changes should be observable: record before/after clips or screenshots where relevant.

## Ticket index
- T01 Browser tab model + tile bar current tab
- T02 Browser inspect element / devtools
- T03 Browser session restore for tabs and navigation state
- T04 Password/autofill research spike and safe implementation decision
- T05 Chrome profile sync feasibility spike
- T06 Camera-aware jump indicators for partially visible tiles
- T07 Jump-to-tile focus zoom and framing
- T08 Back navigation to previous tile / zone
- T09 Terminal tile title defaults: cwd + git branch
- T10 Rename terminal and note tiles
- T11 Agent-running tile status/title experiment
- T12 Ghostty/shell zoom-pan flicker investigation
- T13 Shell scroll ergonomics and tmux copy-mode escape hatch
- T14 Terminal theme fidelity
- T15 Zone tile bar customization: colors/backgrounds
- T16 Zone navigation and scale/readability metrics
- T17 Background theme presets configuration
- T18 AI-generated background preset spike
- T19 Cmd-K fundamentals overhaul
- T20 Top session bar
- T21 Sidebar workspace glimpse
- T22 Defer global overview / Mission Control


## Workspace/session UX decision
Near-term workspace UX should be three surfaces, not a full overview yet:
- **Cmd-K**: primary habit-forming command center — recents, switch, jump, create, command.
- **Top session bar**: compact glimpse and one-click switching across active/recent sessions.
- **Sidebar**: expandable workspace/zone/tile context, including glimpses into other workspaces.

A separate Mission Control/global overview is explicitly deferred until dogfooding shows what information is missing.
