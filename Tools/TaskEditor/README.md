# Local task editor

Tiptap 3 is bundled into the app's TaskEditor resource directory. The installed
app needs no Node runtime, CDN, or network access. Task Markdown remains canonical;
unsupported imported HTML and tables are displayed as literal source blocks.

After changing source: `npm ci && npm run build && npm test` in this directory.
Commit the source, lockfile, and generated resources together. The matrix runs
`npm test --prefix Tools/TaskEditor`; install the locked dev dependencies first.

Images use a native scheme restricted to the open board's attachment IDs. Original
bytes remain in the project store; editor previews use the bounded thumbnail
pipeline. CSP disables network access and remote embedded images.
