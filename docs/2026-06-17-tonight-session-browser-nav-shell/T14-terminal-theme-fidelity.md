# T14 — Terminal theme fidelity

Status: draft
Tag: tonight [terminal] [visual]
Depends on: —

## Goal
Shell tiles should match the user's expected terminal theme more closely. Reported: cursor smear shader is present, but background color differs and themes feel off.

## Scope
- Identify current theme source for embedded shells/Ghostty surface.
- Compare ANSI palette, background, foreground, cursor, selection, bold-bright behavior.
- Add explicit theme mapping or import path if needed.
- Ensure transparency/background blending is intentional.

## Acceptance criteria
- [ ] Document current theme pipeline and mismatch source.
- [ ] Background color matches configured terminal theme or app setting.
- [ ] ANSI 0–15 colors verified with a color test script.
- [ ] Cursor style/color matches or has explicit app override.

## Verification
- Run ANSI color chart in native Ghostty and Continuum shell tile; capture comparison.

## TDD sketch
Test theme mapping without requiring a real terminal.

```swift
let ghostty = GhosttyTheme(background: "#101010", foreground: "#f0f0f0", cursor: "#ffcc00", ansi: ansiFixture)
let mapped = TerminalThemeMapper.map(ghostty)

expect(mapped.background == NSColor(hex: "#101010"), "background maps exactly")
expect(mapped.foreground == NSColor(hex: "#f0f0f0"), "foreground maps exactly")
expect(mapped.cursor == NSColor(hex: "#ffcc00"), "cursor maps exactly")
expect(mapped.ansi[0] == NSColor(hex: ansiFixture[0]), "ANSI black maps")
expect(mapped.ansi[15] == NSColor(hex: ansiFixture[15]), "ANSI bright white maps")
```
