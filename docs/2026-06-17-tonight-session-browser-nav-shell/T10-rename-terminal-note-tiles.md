# T10 — Rename terminal and note tiles

Status: draft
Tag: tonight [tiles]
Depends on: —

## Goal
Terminal and note tiles should be renamable. Notes need explicit user labels; terminals need override labels on top of computed cwd/branch defaults.

## Scope
- Add persistent `displayName` or `customTitle` for terminal and note tiles.
- Add UI action: rename tile.
- Add command palette action: rename focused tile.
- Show custom name in tile bar; preserve type-specific metadata below or as tooltip if useful.

## Acceptance criteria
- [ ] User can rename a terminal tile.
- [ ] User can rename a note tile.
- [ ] Rename persists after restart.
- [ ] Clearing a terminal custom title returns to cwd/git default from T09.
- [ ] Empty/whitespace names are rejected or treated as clear.

## Verification
- Manual restart round-trip.
- Storage/model test for custom title persistence.

## TDD sketch
Storage/model first.

```swift
var terminal = TileMetadata(kind: .terminal, customTitle: nil, computedTitle: "repo · main")
expect(terminal.displayTitle == "repo · main")
terminal.rename(to: "API Server")
expect(terminal.displayTitle == "API Server", "custom title overrides computed title")
terminal.rename(to: "   ")
expect(terminal.displayTitle == "repo · main", "blank rename clears override")
```

Round trip:

```swift
let restored = try roundTrip(terminal)
expect(restored.customTitle == terminal.customTitle, "custom title persists")
```
