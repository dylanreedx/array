# 04 — Drag-drop non-image files (md / pdf / xml / txt …)

Status: planned, not started. Dylan's ask (2026-08-10) + the load-bearing
design decision below.

## Problem

Composer drag-drop and paste are **image-only** today. Dropping a `.md`,
`.pdf`, `.xml`, `.txt` (or any non-image) does nothing — the decoder rejects
it. We want to attach those.

## The design decision (Dylan) — reference, don't embed

**"Pi should have the Read tool — we should be able to use it."** Do NOT read
the file's bytes into the prompt. Hand the agent a **path reference** and let
its own **Read tool** fetch the content. This is how images already flow to the
CLI (`AgentPromptImageAttachment.piPathReference` → `@/local/file`), except for
non-image files there's nothing to embed — the reference IS the whole payload.

Consequences:
- Images stay embedded (vision needs the bytes). Text/doc files become a bare
  `@/path` reference in the prompt; the agent Reads them on demand.
- No content ever enters `AgentRuntimeEvent`/the transcript/sync — only a path,
  same I5 posture as images' non-Codable file URL.
- Cheap: no thumbnailing, no byte copy into app-support, no size ceiling beyond
  "the file exists and is readable."

## Current state (where the image-only wall is)

- Registration: `ComposerTextView.swift:79`
  `registerForDraggedTypes([.fileURL, .png, .tiff, jpeg])`; drops handled at
  `performDragOperation`/`draggingEntered` (:145/:152).
- Filter: `ComposerImagePasteboardDecoder` — `init?(fileURL:)` rejects any URL
  whose `metadata.isSupportedImage` is false (`ComposerImagePasteboardDecoder.swift:114`).
- Attachment model: `AgentPromptImageAttachment` (Core, `AgentPrompt.swift`),
  `piPathReference = "@\(fileURL.path)"`; prompt argv via
  `PiAgentRunner.promptArgumentSegments` and `ClaudeAgentRunner.promptArgument`.
- Rail UI: `ComposerImageAttachmentRailView`, thumbnail pipeline, draft store
  attachments (`AgentComposerDraftStore`, `AgentComposerAttachmentStore`).

## Shape of the work (rough)

1. A non-image file attachment concept: either extend `AgentPromptImageAttachment`
   into a general `AgentPromptFileAttachment` (metadata + local fileURL, kind =
   image | fileReference) or add a sibling type. Reference kind carries NO bytes.
2. Composer accepts dropped/pasted file URLs for an allowlist (md, pdf, xml,
   txt, and likely more text/code types) in addition to images; a file chip in
   the rail (no thumbnail — an icon + filename).
3. Prompt assembly appends the `@/path` reference for reference-kind attachments
   (reuse the images' segment path). Verify each harness reads it:
   - **claude**: `@file` references + a Read tool that also parses PDFs. ✓ likely.
   - **pi**: has a Read tool; confirm `@/path` is honored in `-p` prompts.
   - **codex**: confirm Read/file support AND the sandbox — `sandbox_mode=workspace-write`
     may block reading a dropped file OUTSIDE the project dir (see open q).
4. Bound/validate: existence, safe path (no control chars), reasonable size cap
   for the reference (the file isn't copied, but reject absurd/binary junk).
5. Witnesses: decoder accepts md/pdf/xml/txt + rejects unknown/binary;
   prompt assembly includes the `@/path` segment; rail renders a file chip;
   I5 — no file content in any event.

## Open questions

- **PDF read parity**: claude's Read parses PDFs; pi's and codex's Read may not.
  For non-PDF text every Read tool works. Decide: allow PDFs only for harnesses
  that parse them, or attach the path and let the agent report if it can't.
- **codex sandbox**: `sandbox_mode=workspace-write` — a file dropped from
  OUTSIDE the agent's cwd may be unreadable by codex. Either restrict drops to
  in-project paths, widen the sandbox for referenced files, or surface the
  limitation. (claude/pi have no such restriction by default.)
- **Embed vs reference for tiny text**: Dylan's call is reference (use Read).
  Keep it; revisit only if a harness's Read is unreliable in `-p` mode.
- Reuse the image rail or a distinct file chip? (icon + name is enough.)
