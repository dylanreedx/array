# T15 — Zone tile bar customization: colors/backgrounds

Status: draft
Tag: tonight [zones] [visual]
Depends on: —

## Goal
Zones should be visually customizable from the tile bar, including zone color and background color, so zones become stronger spatial landmarks.

## Scope
- Add per-zone color settings: accent color, title/tile-bar background, optional canvas tint.
- Add UI in zone/tile bar to edit colors.
- Persist customization in workspace state.
- Ensure text contrast/readability.

## Acceptance criteria
- [ ] User can set zone accent color.
- [ ] User can set zone/tile-bar background color.
- [ ] Settings persist after restart.
- [ ] Defaults remain tasteful and readable.
- [ ] Contrast guard prevents unreadable foreground/background combinations or suggests fixes.

## Verification
- Manual: customize several zones, restart, verify colors.
- Add storage round-trip check for zone visual settings.

## TDD sketch
Model + contrast checks first.

```swift
var zone = ZoneVisualSettings(accent: "#7c3aed", titleBackground: "#111827", titleForeground: "#ffffff")
expect(zone.contrastRatio >= 4.5, "default/custom zone title colors remain readable")

zone.titleBackground = "#ffffff"
zone.titleForeground = "#eeeeee"
expect(!zone.isReadable, "low contrast customization is detected")
expect(zone.suggestedForeground(on: "#ffffff") == "#111111", "suggestion fixes contrast")
```

Round trip:

```swift
expect(try roundTrip(zone) == zone, "zone visual settings persist")
```
