# Continuum Project Agent Rules

## iOS / TestFlight build numbers

- Use UTC date-prefixed build numbers: `YYYYMMDDNN` (example: `2026070802`).
- `YYYYMMDD` comes from `date -u +%Y%m%d`; `NN` is a two-digit sequence for uploads/archives on that UTC date, starting at `01`.
- Never reuse a build number that may have been uploaded to App Store Connect/TestFlight; increment `NN` instead.
- Bump iOS builds by editing `ios/project.yml` `settings.base.CURRENT_PROJECT_VERSION` only, then run `cd ios && xcodegen generate` so generated project files match.
- Do not change `MARKETING_VERSION` unless the user explicitly asks for a release/version bump.
- Any TestFlight/archive handoff must state the exact build number and whether it was only prepared locally, uploaded, processed, or installed.
