# Data Model And Storage

## Goals

- Project state should live with the project.
- State should be inspectable and recoverable.
- Notes should be ordinary markdown files.
- The app should still open quickly through a central recent-project registry.
- Writes should be atomic.
- Migrations should be explicit.
- iCloud sync quirks should not silently corrupt work.

## Storage Locations

### Central Registry

Location:

```text
~/Library/Application Support/continuum-revived/registry.json
```

Purpose:

- Recent workspaces.
- Recent projects.
- Last active workspace/project.
- User-level settings.
- Global launch profile overrides.
- Editor detection cache.

The registry is an index. It is not the source of truth for a project's canvas.

### Project-Local State

Location:

```text
<project-root>/.continuum-revived/
```

Initial structure:

```text
.continuum-revived/
  project.json
  canvas.json
  sessions/
    <session-id>.json
  browser/
    tiles.json
  notes/
    index.json
    *.md
  backups/
    canvas.<timestamp>.json
    project.<timestamp>.json
```

MVP writes:

- `project.json`
- `canvas.json`
- `sessions/*.json`
- `browser/tiles.json`

Post-MVP writes:

- `notes/index.json`
- `notes/*.md`

## Project Model

`project.json` stores identity and app-specific project settings.

Shape:

```json
{
  "schemaVersion": 1,
  "id": "project_01HX...",
  "name": "continuum-revived",
  "rootPath": "/Users/dylan/Library/Mobile Documents/com~apple~CloudDocs/personal/continuum-revived",
  "createdAt": "2026-05-07T00:00:00Z",
  "updatedAt": "2026-05-07T00:00:00Z",
  "defaultLaunchProfileId": "shell",
  "editorPreference": "auto",
  "settings": {
    "restorePolicy": "restoreDescriptors",
    "browserStoragePolicy": "perProject",
    "terminalClosePolicy": "askWhenRunning"
  }
}
```

Rules:

- `rootPath` is informational and may be repaired if the folder moved.
- `id` is stable after creation.
- `schemaVersion` is required.
- Unknown fields should be preserved if practical or ignored safely.

## Canvas Model

`canvas.json` stores spatial state.

Shape:

```json
{
  "schemaVersion": 1,
  "viewport": {
    "x": 0,
    "y": 0,
    "zoom": 1
  },
  "tiles": [
    {
      "id": "tile_01HX...",
      "kind": "terminal",
      "title": "Claude Code",
      "frame": {
        "x": 80,
        "y": 80,
        "width": 900,
        "height": 620
      },
      "zIndex": 10,
      "runtimeRef": {
        "kind": "terminalSession",
        "id": "session_01HX..."
      },
      "metadata": {
        "launchProfileId": "claude",
        "projectRelativeCwd": "."
      }
    }
  ],
  "groups": [
    {
      "id": "group_01HX...",
      "title": "Feature Build",
      "tileIds": ["tile_01HX..."],
      "color": "blue",
      "collapsed": false
    }
  ],
  "lastActiveTileId": "tile_01HX..."
}
```

Rules:

- Canvas stores descriptors and references, not live process state.
- `runtimeRef` can point to terminal session metadata, browser tile metadata, note metadata, or future file tree metadata.
- Tile frame is in world coordinates.
- Canvas coordinates are stable across window sizes.
- Runtime failures should not delete tile descriptors.

## Terminal Session Metadata

Location:

```text
.continuum-revived/sessions/<session-id>.json
```

Shape:

```json
{
  "schemaVersion": 1,
  "id": "session_01HX...",
  "tileId": "tile_01HX...",
  "launchProfileId": "claude",
  "command": "claude",
  "args": [],
  "cwd": "/Users/dylan/Library/Mobile Documents/com~apple~CloudDocs/personal/continuum-revived",
  "env": {},
  "title": "Claude Code",
  "createdAt": "2026-05-07T00:00:00Z",
  "lastStartedAt": "2026-05-07T00:00:00Z",
  "lastExit": null
}
```

Rules:

- This is a restart descriptor, not a guarantee that a process is still alive.
- Later versions may add scrollback snapshots or tmux attachment metadata.
- MVP should clearly display exited sessions and offer restart.

## Browser Metadata

Location:

```text
.continuum-revived/browser/tiles.json
```

Shape:

```json
{
  "schemaVersion": 1,
  "tiles": [
    {
      "id": "browser_01HX...",
      "tileId": "tile_01HX...",
      "url": "http://localhost:3000",
      "title": "Local App",
      "storageGroupId": "project-default",
      "createdAt": "2026-05-07T00:00:00Z",
      "updatedAt": "2026-05-07T00:00:00Z"
    }
  ]
}
```

Browser profile storage policy:

- Browser profiles are app-local persistent `WKWebsiteDataStore` identities, not Chrome/Safari profile import.
- The central registry owns the profile list so profiles span projects.
- A built-in `Default` profile is bootstrapped idempotently on first use; its `dataStoreIdentifier` is a stable UUID string passed to `WKWebsiteDataStore(forIdentifier:)`.
- Existing browser tile `storageGroupId` values remain a compatibility field for already-persisted tiles.

## Notes Model

Deferred but planned.

Location:

```text
.continuum-revived/notes/
```

Rules:

- Notes are markdown files.
- `index.json` maps note IDs to filenames, canvas tile IDs, titles, colors, and external file references.
- Dropped external `.md`, `.markdown`, or `.txt` files should remain at their original location and be referenced.

## Registry Model

`registry.json` shape:

```json
{
  "schemaVersion": 1,
  "lastActiveWorkspaceId": "workspace_01HX...",
  "lastActiveProjectId": "project_01HX...",
  "workspaces": [
    {
      "id": "workspace_01HX...",
      "name": "Personal",
      "projectIds": ["project_01HX..."],
      "createdAt": "2026-05-07T00:00:00Z",
      "updatedAt": "2026-05-07T00:00:00Z"
    }
  ],
  "projects": [
    {
      "id": "project_01HX...",
      "name": "continuum-revived",
      "rootPath": "/Users/dylan/Library/Mobile Documents/com~apple~CloudDocs/personal/continuum-revived",
      "workspaceId": "workspace_01HX...",
      "lastOpenedAt": "2026-05-07T00:00:00Z",
      "pinned": true
    }
  ],
  "settings": {
    "preferredEditor": "auto",
    "zoomModifier": "command",
    "openLastProjectOnLaunch": true,
    "browserProfiles": [
      {
        "id": "B0000000-0000-4000-8000-000000000001",
        "name": "Default",
        "dataStoreIdentifier": "B0000000-0000-4000-8000-000000000002",
        "createdAt": "1970-01-01T00:00:00Z"
      }
    ],
    "defaultBrowserProfileId": "B0000000-0000-4000-8000-000000000001"
  }
}
```

## Atomic Write Policy

For every JSON write:

1. Serialize to memory.
2. Validate it can parse back into the expected model.
3. Write to sibling temp file: `<name>.tmp`.
4. `fsync` temp file if practical.
5. Copy existing file to timestamped backup before replace.
6. Atomic rename temp file to final path.
7. Keep a small rolling backup count.

Failure behavior:

- If temp write fails, keep existing state.
- If final parse fails after write, restore previous backup.
- If current file is corrupt on launch, try newest valid backup.
- If no valid backup exists, open an empty canvas and show a clear recovery message.

## Migration Policy

Rules:

- Every persisted top-level file has `schemaVersion`.
- Migrations are pure transformations from old data to current data.
- Migrations never launch processes.
- Migrations write backups before replacing data.
- Migration failures are surfaced to the user with the path and error.

Initial migration table:

```text
1 -> current: no-op
unknown future version: read-only warning, do not overwrite without user confirmation
missing version: attempt legacy import only for known Continuum-compatible files if explicitly requested later
```

## iCloud Considerations

The project target lives under iCloud Drive. This affects storage:

- Writes may race with sync.
- Files may be evicted or temporarily unavailable.
- Hidden folders are synced unless excluded by policy.
- File coordination may be needed for robust macOS behavior.

MVP policy:

- Use atomic local writes.
- Detect missing/unavailable project-local state and show recovery UI.
- Avoid many tiny high-frequency writes. Coalesce canvas persistence.
- Keep backups.
- Do not store large terminal scrollback in MVP.

## Security And Privacy

- No telemetry.
- No cloud sync beyond whatever the user's filesystem/iCloud already does.
- Do not store secrets intentionally.
- Environment variables in session descriptors should default to empty overrides, not full inherited environment dumps.
- Browser cookies/storage follow WKWebView storage policy and are not exported into JSON.

