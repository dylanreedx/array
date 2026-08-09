# CLAUDE.md

Hard rules for every agent session in this repo. Fuller references:
`RELEASE.md` (release runbook, repo root), `docs/VERSIONING.md` (scheme +
release ledger), `docs/38-tickets/95-go-live.md` (program history/rationale).

## Identity

- The app is **Array**, bundle id `dev.arrayapp.macos` (`Packaging/Info.plist`).
- Internal module names (`ContinuumRevived*`) are deliberately unchanged —
  never rename them. Legacy fixtures and historical docs keep saying
  Continuum; never a global find-replace.

## Versioning & releases (NON-NEGOTIABLE)

- Version scheme: marketing version `X.Y.Z` (`CFBundleShortVersionString`) +
  **monotonic integer build number** (`CFBundleVersion`). The build number is
  what Sparkle compares — it increases by exactly 1 every shipped release and
  is NEVER reused or decreased.
- `Packaging/Info.plist` stays at its dev defaults (0.1.0 / build 1) in the
  repo. Real versions are stamped at release time by
  `scripts/release-app.sh --set-version X.Y.Z --set-build N`. Never commit a
  version bump to `Packaging/Info.plist`.
- Releases follow `RELEASE.md` exactly.
- Every GitHub release on `dylanreedx/array-releases` uploads BOTH assets:
  `Array.dmg` (constant name — the site's latest-download URL depends on it)
  and `Array-X.Y.Z.dmg` (appcast permalink).
- After every release: `scripts/generate-appcast.sh` regenerates
  `website/public/appcast.xml`; commit it and push to `main` (Vercel deploys
  arrayapp.dev from `main`).
- NEVER commit: the Sparkle private EdDSA key (Keychain-only), `releases/`
  (gitignored DMG archive), `.env`, QA stores, signing material.
- Every release appends one row to the release-history table below and to the
  full table in `docs/VERSIONING.md`.

### Release history

| Version | Build | Date       | Notes |
|---------|-------|------------|-------|
| 0.1.0   | 1     | —          | Dev default in `Packaging/Info.plist`. Never shipped. |
| 0.2.0   | 2     | 2026-08-09 | First public release: notarized DMG, arrayapp.dev download. Pre-Sparkle — cannot self-update. |
| 0.2.1   | 3     | 2026-08-09 | First appcast-backed release: Sparkle auto-update live, thin-GUI-PATH fix, first-run Environment Setup panel, Help menu. |

## Git

- Work lands on `array/integration`, fast-forwards to `main`.
- Commits only under Dylan's identity. No AI-attribution trailers, no
  Co-Authored-By. No exceptions.
