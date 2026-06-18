# T09 — Terminal tile title defaults: cwd + git branch

Status: draft
Tag: tonight [terminal] [identity]
Depends on: —

## Goal
Terminal/shell tiles should have meaningful default titles. By default, show the current working directory and, when inside a git repo, the current branch.

## Scope
- Detect shell cwd for each terminal tile.
- Detect git branch or detached commit when cwd is inside a repo.
- Render compact title in the tile bar.
- Keep user rename override separate from computed default.

## Display draft
- `continuum-revived · main`
- `~/Documents/work/selectus · feature/qr-review`
- `~` when no repo/cwd detail is available.

## Acceptance criteria
- [ ] New terminal tiles show cwd-based title.
- [ ] Git branch appears when available.
- [ ] Title updates when shell changes directory.
- [ ] User rename from T10 overrides display but computed metadata remains available.

## Verification
- Manual: cd across directories and git repos, observe title updates.
- Add parser/unit checks for cwd/branch display formatting if shell telemetry is isolated.

## TDD sketch
Keep title formatting pure and shell telemetry separate.

```swift
expect(TerminalTitleFormatter.title(cwd: "/Users/dylan/Documents/personal/continuum-revived", branch: "main") == "continuum-revived · main")
expect(TerminalTitleFormatter.title(cwd: "/Users/dylan", branch: nil) == "~")
expect(TerminalTitleFormatter.title(cwd: "/tmp/build", branch: "detached@abc123") == "build · detached@abc123")
```

Update behavior:

```swift
var metadata = TerminalTileMetadata(cwd: "/a", gitBranch: nil, customTitle: nil)
metadata.applyShellTelemetry(cwd: "/repo", gitBranch: "feature/x")
expect(metadata.displayTitle == "repo · feature/x", "shell telemetry updates default title")
```
