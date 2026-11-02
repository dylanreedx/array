---
title: "Workspace tools reference"
description: "The operations agents can use to work with Array’s canvas, browsers, and iOS previews."
section: "Reference"
order: 30
---

Array supplies these tools to managed agents when Workspace Tools is enabled. Claude Code and Codex use the `array_workspace` MCP server; Pi uses a bundled extension to call the same host operations. The shared catalog supplies the names, descriptions and input schemas below. Availability and approvals depend on the agent and session: `array_workspace_context` is the authority. See [Agents on the canvas](/docs/canvas-tools/) for permissions, grants, presentation and recovery.

Browser access to remote domains and user-owned browsers needs separate approval. A browser snapshot supplies element references for actions; use a screenshot to inspect appearance. iOS automation uses host-owned disposable simulators, not arbitrary existing simulator identifiers. Observations must be fresh for device actions.

These tools do not grant access to another project’s canvas, let an agent grant itself permission, or turn the workspace API into an operating-system sandbox. An agent cannot assume an unhydrated zone has no saved tiles. Presentation can be deferred or require the user to open a workspace; canvas edits do not move the camera.

## Operations

The descriptions below include operation-specific outcomes and refusals. Requests can also fail validation or permission checks. Query the current revision before canvas or board writes. For uncertain outcomes, recover the original operation before retrying; reuse the same idempotency key for the same request. Outcomes can be accepted, partial, committed, failed or expired.

### `array_workspace_context`

Return your own identity as Array sees it: agentId, checkoutHandle (your Home checkout), workspace/zone/tile ids, structural revision, hydration coverage, the operations you can call now (capabilities) and the ones that first ask the user (approvalRequired), and recentOperations (outcomes of your recent Array requests, including ones cancelled after they took effect). Read-only and cheap.

Inputs: none.

### `array_open_document`

Open or reveal a document as a tile on the Array canvas and return its real identity (tileId, artifactHandle, checkoutHandle, zone and world rect) plus what actually happened (document opened|existing|failed, relationship, presentation effects, draft preserved). Returns structured errors (not_found, target_conflict, permission_denied, scope_approval_required, presentation_required, unsupported, idempotency_conflict) instead of guessing. Never edits the file.

| Input | Meaning |
| --- | --- |
| `relativePath` | Optional. Path relative to the checkout root (the explicit checkoutHandle, or your Home checkout when omitted). |
| `checkoutHandle` | Optional. A checkout handle from array_workspace_context or a prior result. An explicit handle wins over your Home default. |
| `artifactHandle` | Optional. An artifactHandle Array returned earlier (ck_...:path). If it disagrees with checkoutHandle you get target_conflict. |
| `mode` | Optional.  Values: `openOrReveal`, `revealOnly`. |
| `line` | Optional. One-based line to scroll to. |
| `presentation` | Optional.  |
| `idempotencyKey` | Optional.  |

### `array_find_agent`

Rank the managed agents Array knows in your checkout (under Agent permissions Free, your whole project) for a free-text query (exact agentId or name first, then name/role/task/referenced-file matches, then same checkout, same zone, activity and recency). Each candidate carries agentId, displayName, role, harness, checkoutHandle, projectId, zoneId/tileId, parentAgentId, observed status + observedAt, matchReasons and evidenceAvailable. `ambiguous: true` means the top candidates tie — present them, never pick one. Metadata only; no transcript text. Read-only.

| Input | Meaning |
| --- | --- |
| `query` | Optional. Free text: an agentId, a name, task words or a file path. |
| `checkoutHandle` | Optional. Limit to one checkout handle you may read (default: your Home checkout). |
| `zoneId` | Optional. Limit to agents whose tile is in this zone. |
| `limit` | Optional.  |

### `array_inspect_agent`

Bounded, attributed evidence about ONE agent by agentId: identity, observed status, lastActivityAt, latestPromptAt/latestTurnAt, terminalOutcome, promptTitle, a byte-capped excerpt of its most recent transcript items ({kind, at, text}, newest last, `recentEventsTruncated` when cut), checkout-relative referencedFiles, evidenceSource and observedAt. Everything is a projection of what Array observed. `transcriptAvailable: false` with a note means Array holds no evidence — NOT that the agent did nothing. Inspecting yourself needs no approval. Inspecting another agent asks the user in Array, unless Agent permissions is Free and the agent is in your project. Read-only: never messages, interrupts or steers the agent.

| Input | Meaning |
| --- | --- |
| `agentId` | Required. The agentId from array_find_agent or array_workspace_context. |
| `maxEvents` | Optional. Most recent transcript items to include (default 12; ~4 KB text cap applies regardless). |

### `array_canvas_query`

List the zones and tiles of your own checkout's canvas with their WORLD rectangles, plus the structural revision and hydration coverage. Zones marked hydrated=false hold no tiles in this answer: an empty tile list NEVER proves such a zone is empty. Paginated (limit up to 50, cursor); a cursor stops working once the canvas changes structurally (cursor_expired). Read-only.

| Input | Meaning |
| --- | --- |
| `zoneId` | Optional. Restrict the answer to one zone of your project. |
| `limit` | Optional.  |
| `cursor` | Optional. The nextCursor from a previous page. |
| `checkoutHandle` | Optional. Another checkout handle you have been granted; your Home checkout when omitted. |

### `array_canvas_apply`

Move OR resize exactly one tile of your own checkout, in world coordinates, through the same route and undo history as the user's own drag. Requires expectedRevision from array_canvas_query and returns the ACTUAL rectangle after Array's layout and minimum-size rules, which may differ from what you asked for. Every conflict applies nothing: revision_conflict (the canvas changed), target_conflict (the user is dragging), unsupported zone_unhydrated, permission_denied, invalid_request. The first use asks the user for permission. Never moves the camera, focus, selection or armed zone.

| Input | Meaning |
| --- | --- |
| `op` | Required.  Values: `move`, `resize`. |
| `tileId` | Required. A tileId from array_canvas_query or an Array result. |
| `worldFrame` | Optional. The whole target rectangle. A move uses its origin; a resize its size (and its origin when given). |
| `origin` | Optional. Move shorthand. |
| `size` | Optional. Resize shorthand; below the tile kind's minimum it is clamped up and clamped=true is returned. |
| `expectedRevision` | Required. The revision object from array_canvas_query or array_workspace_context, verbatim. |
| `idempotencyKey` | Optional.  |

### `array_board_query`

List project boards with their ordered columns, or read one board's ordered tasks, revision, Markdown body, typed links, image metadata and assignee. Without boardId returns summaries suitable for choosing a board and destination column. Read-only and paginated.

| Input | Meaning |
| --- | --- |
| `checkoutHandle` | Optional.  |
| `boardId` | Optional.  |
| `cardId` | Optional.  |
| `limit` | Optional.  |
| `cursor` | Optional.  |

### `array_board_apply`

Create, edit, move, assign, unassign or delete one task in your project. Uses the same durable board reducer, live updates and Undo as Array's UI. Requires the board revision from array_board_query and a stable idempotencyKey. Create and anchored move can report rebased when concurrent board edits are safely absorbed; other stale writes apply nothing.

| Input | Meaning |
| --- | --- |
| `op` | Required.  Values: `create`, `edit`, `move`, `assign`, `unassign`, `delete`. |
| `checkoutHandle` | Optional.  |
| `boardId` | Required.  |
| `expectedRevision` | Required.  |
| `idempotencyKey` | Required.  |
| `cardId` | Optional.  |
| `columnId` | Optional.  |
| `title` | Optional.  |
| `body` | Optional.  |
| `links` | Optional.  |
| `assigneeAgentId` | Optional.  |
| `afterCardId` | Optional.  |
| `beforeCardId` | Optional.  |

### `array_delegate`

Create a child agent in Array, inheriting your checkout and, by default, harness and model, and place its tile beside you on the canvas. Returns the real childAgentId, tileId, per-step statuses (creation, attachment, durability, presentation) and childRunning. Requires an idempotencyKey: the same key with the same payload never creates a second child. Under Agent permissions Ask first, the first delegation in a session asks the user (scope_approval_required if declined); under Free it does not. Errors are structured (unsupported, permission_denied, idempotency_conflict, outcome_unknown); concurrent Managed helpers get separate worktrees.

| Input | Meaning |
| --- | --- |
| `task` | Required. The child's task — what it should do, in full. This becomes its first prompt. |
| `title` | Optional. Short human label for the child's tile. |
| `idempotencyKey` | Required. Stable key for this delegation. Reuse for transport retries; new attempts need a new key. |
| `harness` | Optional. Child CLI; omit to inherit yours. Must be installed and signed in. Values: `Claude Code`, `Codex`, `Pi`. |
| `retryOf` | Optional. Failed/stopped child of yours to continue; carries its brief, changed files and report. |
| `model` | Optional. Exact fully qualified id from the selected CLI catalogue. Omit to inherit on the same harness, or use a different harness's own default. |
| `placement` | Optional.  |
| `presentation` | Optional.  |

### `array_reveal_agent`

Present an EXISTING agent's tile on the canvas (yourself or one of your children). Creates nothing. Returns tileId, zone and world rect plus what presentation actually did. not_found when that agent has no tile; presentation_required when its tile lives in another workspace.

| Input | Meaning |
| --- | --- |
| `agentId` | Required. The agent's id (your own, or a childAgentId array_delegate returned). |
| `presentation` | Optional.  |

### `array_get_operation`

Recover the outcome of one of your earlier Array operations by operationId or idempotencyKey: status (accepted, partial, committed, failed, expired), per-step statuses, the child agentId and tileId when known, and childRunning (absent means unknown). Once a delegated child is idle, childResult carries its latest settled turn (status and final text). status 'expired' means Array no longer holds the outcome — that request must NOT be repeated.

| Input | Meaning |
| --- | --- |
| `operationId` | Optional.  |
| `idempotencyKey` | Optional.  |

### `array_message_agent`

Send one text message (a new user turn) to another agent in your project. Who you can reach depends on the user's Agent permissions setting: under Free (the default), any agent in your project — your children, your parent, a sibling, or one the user started; under Ask first, only agents you created and the agent that created you, and the first message asks the user. Never an agent in another project. Requires an idempotencyKey: the same key never delivers twice. Returns delivery ('delivered', 'queued' or 'refused'), childAgentId (the agent you messaged), parentAgentId (you), childRunning and, when the send path exposes one, queuePosition — plus refusalReason when it declined (an agent that is mid-turn is refused, never double-prompted). The ANSWER is NOT in this result. Errors are structured: permission_denied (out of reach, or the user declined), invalid_request (yourself, empty text, over 8 KB, or no key), idempotency_conflict (that key with different text), unsupported (the agent's harness or model is not ready, or a long chain of agent-to-agent turns with no prompt from the user). It never interrupts a turn and never moves the user's view unless you ask it to.

| Input | Meaning |
| --- | --- |
| `agentId` | Required. The agentId to message: a childAgentId array_delegate returned, or an id from array_find_agent or array_workspace_context. |
| `text` | Required. The message, delivered verbatim as the child's next user turn. Max 8 KB of UTF-8. |
| `idempotencyKey` | Required. Stable key for THIS message. Reuse it verbatim on any retry; a new message needs a new key. |
| `presentation` | Optional. Absent means preserve everything: a message must not steal the user's view. Ask to reveal only when the user wants to watch the child. |

### `array_update_agent`

Set an agent’s identity colour, its display name, its character, or any of them; omitted fields are left alone. Your own colour and name need no extra approval. Changing another agent in your checkout uses the canvas-write grant, which also permits tile moves and resizes; other checkouts/projects are refused. A rename states nameIntent: requested when the user or another agent explicitly asked for the name, proactive when you chose it yourself. A proactive rename is refused (target_conflict) on a name the user typed or one set on request. Returns operationId, agentId, actual identityColor, displayName, nameSource (user, requested, agent or automatic), character, revision and durability (committed or unchanged). Preserves presentation.

| Input | Meaning |
| --- | --- |
| `agentId` | Required.  |
| `identityColor` | Optional.  Values: `teal`, `blue`, `mint`, `purple`, `orange`, `yellow`, `red`, `None`. |
| `displayName` | Optional.  |
| `nameIntent` | Optional.  Values: `requested`, `proactive`. |
| `character` | Optional.  |
| `idempotencyKey` | Optional.  |

### `array_device_list`

List project iOS Preview tiles and device templates available in Xcode without connecting or booting. New agent previews use host-created disposable simulators; listing a human simulator does not grant control. Results explicitly report truncation.

| Input | Meaning |
| --- | --- |
| `checkoutHandle` | Required. Your explicit Home checkoutHandle from array_workspace_context. No active-project fallback. |

### `array_device_open`

Create a host-owned disposable simulator and canvas tile using zoneId plus templateId, or reconnect your owned tileId. Never adopts arbitrary existing simulator UUIDs. Preserves camera, workspace, focus and armed zone. Returns exact deviceId, sessionId and a 30-second idle budget. One active attachment per agent, two per app; managed-device inventory is capped at two per agent/eight per app. Existing human tiles cannot be adopted.

| Input | Meaning |
| --- | --- |
| `checkoutHandle` | Required. Your explicit Home checkoutHandle from array_workspace_context. No active-project fallback. |
| `tileId` | Optional. Your existing owned tile from array_device_list. |
| `zoneId` | Optional. Explicit already-mounted zone in your project, required for creation. |
| `deviceId` | Optional. An exact UUID constraint for an owned tile, or a receipt-owned device from managedDevices when restoring its tile. Arbitrary existing simulators cannot be adopted. |
| `allowBoot` | Optional. Explicit true is required to create/start a fresh disposable simulator, or restart a stopped owned simulator. |
| `idempotencyKey` | Optional. Reuse for the same creation intent; a changed payload conflicts. Persisted creation digests prevent duplicate tiles after restart. |
| `templateId` | Optional. A templateId returned by array_device_list; required when creating a fresh disposable simulator. |

### `array_device_observe`

Obtain a fresh upright screenshot of your exact device session. Returns one image block plus observationId, pixel dimensions, orientation, geometry generation and sequence. Waits for a helper emission after the request. Native capture age is unknown and reported as such. Observations expire after 30 seconds.

| Input | Meaning |
| --- | --- |
| `checkoutHandle` | Required. Your explicit Home checkoutHandle from array_workspace_context. No active-project fallback. |
| `sessionId` | Required. A sessionId returned by array_device_open; bound to your identity, checkout and exact simulator. |

### `array_device_act`

Perform one bounded tap, swipe, guest Unicode text, named key, Home or rotation using a fresh observation. Native completion is not application success: observe again. Swipe lasts 100–1500ms; text is at most 16384 UTF-8 bytes. Text uses only the guest pasteboard. No shell, eval, raw HID or Mac clipboard access.

| Input | Meaning |
| --- | --- |
| `checkoutHandle` | Required. Your explicit Home checkoutHandle from array_workspace_context. No active-project fallback. |
| `sessionId` | Required. A sessionId returned by array_device_open; bound to your identity, checkout and exact simulator. |
| `observationId` | Required.  |
| `kind` | Required.  Values: `tap`, `swipe`, `text`, `key`, `home`, `rotate`. |
| `x` | Optional. Pixel x in the upright observation image, less than image width. |
| `y` | Optional. Pixel y in the upright observation image, less than image height. |
| `idempotencyKey` | Required. Required retry identity. Same key and effective payload never repeat the input; a different payload conflicts. |
| `endX` | Optional. Swipe destination x in upright image pixels, less than width. |
| `endY` | Optional. Swipe destination y in upright image pixels, less than height. |
| `milliseconds` | Optional.  |
| `text` | Optional. Guest Unicode text, at most 16384 UTF-8 bytes. |
| `key` | Optional.  Values: `return`, `tab`, `backspace`, `escape`, `left`, `right`, `up`, `down`. |
| `orientation` | Optional.  Values: `1`, `2`, `3`, `4`. |

### `array_device_close`

Release your automation attachment. Leaves the running simulator/app and any human viewer intact. Does not delete the canvas tile, simulator, or ownership. Reopen the same tileId to reuse it.

| Input | Meaning |
| --- | --- |
| `checkoutHandle` | Required. Your explicit Home checkoutHandle from array_workspace_context. No active-project fallback. |
| `sessionId` | Required. A sessionId returned by array_device_open; bound to your identity, checkout and exact simulator. |

### `array_device_build_run`

Start or cancel a service-owned Debug iOS Simulator build/install/launch job on your exact preview session. Returns an operationId immediately; poll array_get_operation for tagged deviceBuild state and a bounded private log tail. Uses a fresh build directory, verifies one simulator app, and never installs after a failed or cancelled compilation. 900-second job budget; no archive, signing, upload, arbitrary argv/env, shell or eval.

| Input | Meaning |
| --- | --- |
| `checkoutHandle` | Required. Required on every call: your explicit Home checkoutHandle from array_workspace_context, including when sessionId is present. |
| `kind` | Required.  Values: `start`, `cancel`. |
| `sessionId` | Optional.  |
| `projectFile` | Optional.  |
| `scheme` | Optional.  |
| `operationId` | Optional.  |
| `idempotencyKey` | Optional.  |

### `array_browser_open`

Open an agent-owned browser tile beside you at a URL.

| Input | Meaning |
| --- | --- |
| `url` | Required.  |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_navigate`

Navigate a browser by URL, back, forward or reload.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `url` | Optional.  |
| `action` | Optional.  Values: `back`, `forward`, `reload`. |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_snapshot`

Read the page outline and element refs.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_click`

Click an element ref or CSS coordinates.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `ref` | Optional. Element ref from the latest snapshot. |
| `x` | Optional.  |
| `y` | Optional.  |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_type`

Type text into an element or the focused field.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `text` | Required.  |
| `ref` | Optional. Element ref from the latest snapshot. |
| `clear` | Optional.  |
| `submit` | Optional.  |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_press_key`

Send a named key or shortcut.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `keyName` | Required.  |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_scroll`

Scroll by CSS pixels or bring an element into view.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `ref` | Optional. Element ref from the latest snapshot. |
| `dx` | Optional.  |
| `dy` | Optional.  |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_wait_for`

Wait for text, an element ref, or page idle.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `condition` | Required.  Values: `textAppears`, `textGone`, `refAppears`, `refGone`, `idle`. |
| `value` | Optional.  |
| `timeout` | Optional.  |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_take_screenshot`

Take a PNG screenshot of the browser or an element.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `ref` | Optional. Element ref from the latest snapshot. |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_evaluate`

Evaluate JavaScript in the page and return its JSON value.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `script` | Required.  |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_browser_console`

Read page-supplied console messages and errors.

| Input | Meaning |
| --- | --- |
| `tileId` | Required. Explicit browser tile ID returned by Array. |
| `level` | Optional.  Values: `log`, `info`, `warn`, `error`, `debug`. |
| `idempotencyKey` | Optional. Reuse for a retry of the same action. |

### `array_notify`

Tell the user you need them (reason needs_input) or that your work is done (reason completed). It goes through Array's task policy, never around it: needs_input marks your task as needing the user, and your run then waits until someone sends you your next turn, which continues the same task. completed sends nothing by itself, because Array announces a task once, automatically, when it and every agent in it has finished; a child agent can never announce its parent's task. Your message stays in your transcript and is never shown on the lock screen. Returns operationId, agentId, reason, outcome (recorded, coalesced or unavailable), phoneDelivery (taskAlerts, noPairedPhone, relayWithoutTaskAlerts or unknown) and an explanation you can repeat to the user. Preserves presentation.

| Input | Meaning |
| --- | --- |
| `reason` | Required.  Values: `needs_input`, `completed`. |
| `message` | Required.  |
| `idempotencyKey` | Optional.  |

### `array_report`

File a short report on the work you just finished. If another agent delegated your task, it receives this with your result. Calling again replaces your report for this turn.

| Input | Meaning |
| --- | --- |
| `summary` | Required. The outcome, in 60 words or fewer. |
| `checks` | Optional.  |
| `findings` | Optional.  |
| `next` | Optional.  |
| `detailsPath` | Optional. A file with the full details. |

### `array_status`

Say what you are doing, in short lines Array shows as declared by you.

| Input | Meaning |
| --- | --- |
| `now` | Required.  |
| `next` | Optional.  |
| `needsYou` | Optional.  |
| `plan` | Optional. Lead plan; omission keeps it. Helper state is observed. |

### `wait_agents`

Wait for children created by `array_delegate` to finish their current turn. Pass their returned `operationId` values in `handles` (1–16). `timeoutSeconds` defaults to 600 and is capped at 3600. It returns each final answer, failure or refusal, or marks a child still running when the timeout passes. Wait again for a running child. This is a helper, not a separate host operation.
