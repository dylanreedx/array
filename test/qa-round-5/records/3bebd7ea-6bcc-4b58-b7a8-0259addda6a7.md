## TL;DR
Verdict: pass
- Gate: RED `test ! -d Tests` failed before the fix, and GREEN `test ! -d Tests` passed after the fix.

## What is broken
- The package declares executable products and executable check targets, but it declares no XCTest or swift-testing target for the empty `Tests/` directories. Package.swift:9 Package.swift:30
- The `Tests/ContinuumRevivedTests` and `Tests/ContinuumRevivedCoreTests` directories were empty, so they advertised a test suite that the package could not run. test/qa-round-5/records/3bebd7ea-6bcc-4b58-b7a8-0259addda6a7.md

## Why
- The real regression suite is the hand-rolled executable checks declared as package targets. Package.swift:30 Package.swift:32 Package.swift:36 Package.swift:40
- `ContinuumRevivedCoreChecks` uses `expect(...)` assertions inside a `main.swift` executable rather than XCTest discovery. Sources/ContinuumRevivedCoreChecks/main.swift:5
- Empty `Tests/` directories cannot add coverage, and wiring them as test targets would preserve a test facade without assertions. test/qa-round-5/records/3bebd7ea-6bcc-4b58-b7a8-0259addda6a7.md

## Fix
- Deleted the empty `Tests/ContinuumRevivedTests`, `Tests/ContinuumRevivedCoreTests`, and parent `Tests` directories so the repository only exposes the active executable check suite. test/qa-round-5/records/3bebd7ea-6bcc-4b58-b7a8-0259addda6a7.md
- Added manifest guidance that the executable checks are the regression suite and that empty test targets should not be added for suite-name discovery. Package.swift:30

## Proof
- RED: `test ! -d Tests` exited 1 before the fix because `Tests`, `Tests/ContinuumRevivedTests`, and `Tests/ContinuumRevivedCoreTests` existed.
- GREEN: `test ! -d Tests` exited 0 after the fix.
- GREEN: `swift build` passed after deleting the empty orphan directories.
- GREEN: `.build/debug/ContinuumRevivedCoreChecks` passed after deleting the empty orphan directories.
- GREEN: `.build/debug/ContinuumRevivedPaletteChecks` passed after deleting the empty orphan directories.
- GREEN: `.build/debug/ContinuumRevivedPerfChecks` passed after deleting the empty orphan directories.
- GREEN: `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` passed after deleting the empty orphan directories.
- Visual review: N/A for this package metadata cleanup, with the existing calibrated visual record at test/qa-round-5/atlas/51bce4c3-d258-4228-9eae-8787ac0985b6/review.md.
- Target fixture: test/qa-round-5/fixtures/fixture-file-text.
- Cross fixture: test/qa-round-5/fixtures/fixture-note-text.
- Visual sanity: test/qa-round-5/atlas/51bce4c3-d258-4228-9eae-8787ac0985b6/fixture-smoke-note-file/full-page.png and test/qa-round-5/atlas/51bce4c3-d258-4228-9eae-8787ac0985b6/fixture-smoke-note-file/bands/01.png.
- Readability: visual review is N/A for this package cleanup, and the cited atlas page still shows readable text with no clipping and no overlap.

## Gotchas
- Similar orphan suite problems can recur if directories under `Tests/` are created without matching `.testTarget` entries in the package manifest. Package.swift:13
- The domain knowledge gap is that this project intentionally uses executable check targets as the regression suite, so `swift test` discovery is not the source of truth here. Sources/ContinuumRevivedCoreChecks/main.swift:5
- The rejected alternative was adding empty test targets, because that would make `swift test` discover names without adding assertions or unique coverage. Package.swift:30
