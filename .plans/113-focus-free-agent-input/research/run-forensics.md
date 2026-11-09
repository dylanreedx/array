# Real session input forensics

Research date: 2026-11-05. Research only; no product edits, live tile operations, builds, tmux, matrix or UI checks.

## Evidence and limits

**MEASURED:** Searched 2,830 JSONL paths across ~/.claude/projects and ~/.codex/sessions/2026/{10,11}; 382 contained browser/device tool strings. Also searched Array agent-transcripts (192 matching files, including repeated backups) and read managed agent metadata to map names to sessions. Counts below use provider JSONL calls only, avoiding managed-backup duplication. Cutoff: 2026-10-15. Actual matched calls are concentrated November 3–5.

**MEASURED:** Extracted 1,165 direct tool-use records in 23 provider log files, all Claude Code. This is a reproducible lower bound, not a census of all browser usage: Codex can invoke tools inside functions.exec JavaScript rather than direct function calls, which this extraction does not count; managed snapshot blocks were not fully normalized. Sessions can contain several separate turns/runs. The task is therefore only partially exhaustive. No claim that every failed call across all harnesses was found.

**MEASURED:** 110 returned structured status=error replies in that subset. Intentional QA probes are included (notably two waits for zz-never-zz); do not call all 110 production defects. Errors are symptoms, not established root causes. Missing result timestamps prevent complete latency measurement.

## Main findings

**MEASURED:** Agents really do run long, mixed UI/API workflows on deployed remote apps, not just localhost screenshot checks. The four largest Selectus sessions contain 230, 217, 185 and 167 calls. Browser input failures can interrupt deployment sign-off and lead to API bypasses.

**MEASURED:** Eight replies explicitly mention control changing/takeover/expiry (7 access-or-control outcome_unknown, 1 user-took-control-or-expired target_conflict). Six other replies gate handover or JavaScript approval. The logs do not identify which user gesture caused these errors. No pointer/camera event log was found in the inspected transcript evidence. Dylan working in another tile is a plausible explanation, not measured causation.

**READ IN SOURCE:** Release d41dad04 BrowserAutomation.swift:620–649 monitors keyDown and mouseDown, resolves the first responder or hit-tested view to a browser engine, increments userInputCount and calls onUserInput. The intended ownership test is browser-local, not every click on the canvas. WorkspaceAPIService+Browser.swift captures and rechecks this counter throughout authorization/actions. A control-change error can represent several invalidations; its text does not prove an outside-tile click.

**MEASURED:** Native select interaction fails semantically even without an explicit tool error: type rejects comboboxes; a lead later says dropdowns do not respond and switches to direct saving. A green click/keypress reply alone does not demonstrate that an option was selected. Floating system menus are reported by Dylan but are not independently visible in these text logs.

## Usage and durations

**MEASURED: direct-call inventory**

| Tool | Calls |
|---|---:|
| array_browser_evaluate | 327 |
| array_browser_click | 164 |
| array_browser_navigate | 147 |
| array_browser_take_screenshot | 136 |
| array_browser_snapshot | 134 |
| array_browser_wait_for | 82 |
| array_browser_type | 70 |
| array_browser_open | 40 |
| array_browser_press_key | 38 |
| array_browser_scroll | 9 |
| array_device_observe | 8 |
| array_device_act | 6 |
| array_browser_console | 2 |
| array_device_list | 1 |
| array_device_open | 1 |

**MEASURED:** 486 call/result pairs have usable timestamps: median 0.950 seconds, 95th percentile 10.774 seconds, range 0.027–31.271 seconds. These are transcript elapsed times, including transport and wait behavior, not engine CPU time. Remaining 679 pairs lack a usable timestamp or result.

**MEASURED:** Session browser-call spans: Noah QA 20:58:45–21:16:24 Nov 4 (17m39s, 185 calls); Dylan-ticket QA 20:58:29–22:33:40 Nov 4 (1h35m11s, 217 calls, multiple turns); GMA QA 14:38:03–15:08:17 Nov 5 (30m14s, 133 calls); QA lead Nov 4 20:56:43 through Nov 5 13:45:57 (overnight multi-turn span, not continuous execution).

**MEASURED:** Both localhost (127.0.0.1/localhost dev servers), remote Selectus/Jira and file:// previews occur. Typical observed sequences are open/navigate → snapshot → click/type → wait_for → snapshot/screenshot; evaluate → evaluate polling → screenshot is also common. Evaluate is 327/1,165 calls (28.1%), greater than any other tool. It includes DOM inspection, selecting options, fetch/GraphQL and PDF probing; it is not solely a workaround.

## Interrupted runs and dropdowns

**MEASURED — Verify today’s tickets on staging, Claude Code, session/agent 1f09a201-c08e-4096-8b65-3dead5261f72:** source ~/.claude/projects/-Users-dylan-Documents-work-selectus/1f09a201-c08e-4096-8b65-3dead5261f72.jsonl. Nov 4 UTC:

- 20:59:19 navigate returns “Access or control changed while the browser action was in progress; it may have taken effect. Wait, then take a fresh snapshot.” (line 111). Retry at 20:59:36 returns “The user has not handed over this browser.” (125). At 21:00 the agent reports all tickets blocked and says it did not use curl or Playwright.
- 21:06:37 new instructions authorize using the Jira tile for Selectus. It proceeds through PDF inspection: navigate PDF → coordinate click → End/PageUp/PageDown/Arrow keys → screenshots (lines 646–717). These keys are PDF navigation, not dropdown evidence.
- 21:15:33 evaluate returns “The user took control or the request expired. Take a fresh snapshot.” (902). At 21:17:25 the lead says “Leave D7F2A202 alone; Dylan is using it” and assigns tile 09E1FBFC instead (925). This establishes shared-tile contention, not an observed outside-tile gesture.
- 21:19:16 wait_for reports access/control changed (982). By 21:20 the agent reports label-print failures, then tile closure during a retry; no label evidence captured. Those print failures are application/server symptoms, not proven focus failures.
- 22:33:40 first evaluate of a later turn is refused: “The user has not handed over this browser.” (1398). Agent reports blocked without creating/printing anything.

**MEASURED — Verify Noah’s shipped tickets on staging, Claude Code, 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:** same project-log directory. At Nov 4 21:11:18 type(ref=e438, text=NPK test) returns “combobox \"Switch Feeding Zone\" [ref=e438] is not a text field. Type into a textbox, or use press_key.” (555). It switches to evaluate setting select.value and dispatching change/input (559), takes snapshot (561), clicks Repeat Order (569), waits for text, inspects request logging, captures screenshot. This sequence proceeds successfully; final report says all five ticket checks passed as Admin. At 21:12 click number input → key 3 yields focused value 3; key 1 then 2 yields 12; Tab and screenshot verify persistence (661–701). Preserve actual focus/select-all input semantics in any replacement.

**MEASURED — QA today’s tickets on deployed develop, Claude Code, b617907b-669b-4774-98f8-6be1e3d301c0:** Nov 4 22:30:49 and a subsequent undated entry explicitly say “[Request interrupted by user]” (777, 781). Later 22:35:38 press_key uses argument key=Enter (898; other calls use keyName). At 22:37:50 evaluate sets select values (1008). At 22:38:20 agent states: “The new-chemical form’s dropdowns don’t respond to the browser tools, so I’m saving QA Nickel through the same save call the form makes, from your Selectus tile.” (1030). This is a concrete UI-to-API workaround. The interrupted-request marker alone does not identify an input collision or floating menu.

**MEASURED — Verify dynamic compound elements in GMA, Claude Code, 8acc328d-1e70-4116-8c89-4b8de89ac96d:** Nov 5 type resolves to link Create Order rather than textbox at 14:53:59 (470); navigation then gets access/control changed at 14:54:34 (539) and 15:01:06 (725). These are replay candidates for changing refs/control during navigation; user action is absent from the log.

**MEASURED — Harmony preview, Claude Code, 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:** Nov 5 19:14:35 navigation gets access/control changed (1008). At 19:25:50 navigation, reload and screenshot all return no live tile; reopening twice returns missing installed-tile permission error (1470–1517). Browser loss is distinct from a transient focus change.

**MEASURED:** A Harmony subagent a7d097974d47bd0c6 tries evaluate looping selectedIndex/change across source/table selectors; it times out after ~15 seconds at Nov 5 18:48:27–42. This is not proof the selection failed: reply explicitly says action may have taken effect.

## Ranked failure symptoms (110 structured errors)

**MEASURED:** Counts group exact returned messages; root-cause attribution would require instrumentation beyond these logs.

| Rank | Group | Calls |
|---|---|---:|
| 1 | Missing agent project/installed tile when opening | 32 |
| 2 | Action timeout or wait timeout | 22 |
| 3 | Page JavaScript exception | 18 |
| 4 | Control changed / takeover or expired | 8 |
| 5 | Stale element reference | 7 |
| 5 | No live browser tile | 7 |
| 7 | Handover/JavaScript approval missing | 6 |
| 8 | Browser owned by another agent | 4 |
| 9 | Wrong target kind (link/combobox typed into) | 2 |
| 9 | Destination forbidden | 2 |
| 11 | Evaluate result over 64 KB | 1 |
| 11 | Click covered by another element | 1 |

## Workarounds and replay requirements

**MEASURED:** Observed workarounds include evaluate(select.value + change/input), evaluate(click), authenticated in-page fetch/GraphQL/print requests, polling global variables, coordinate clicks, repeated snapshots and screenshots, plus reporting BLOCKED when no browser is available. Two staging agents explicitly decline curl/Playwright because their brief forbids fallback. No claim of an executed shell curl/Playwright fallback is made here; a string search also matches instructions and historical commentary.

**MEASURED:** Replay these recorded sequences while a human types/clicks in another canvas tile; that concurrent activity is a new test condition, not something the transcripts prove:

1. Remote authenticated form: snapshot → click field → type → click submit → wait/snapshot; retain login redirects and stale-ref recovery.
2. Native select: snapshot combobox → choose existing option → verify selected value, dependent request and visible state; avoid the observed type rejection/API-save bypass.
3. Numeric field: click existing 1 → key 3 → Tab → verify 3; click → keys 1,2 → Tab → verify 12.
4. PDF: navigate print URL → coordinate click → End/PageUp/PageDown/Arrow keys → screenshot; verify actual document viewport, not only key delivery.
5. Long evaluate: initiate fetch/print → poll without awaiting a long page promise → capture text/screenshot; timeout must communicate possible side effects.
6. Shared user-owned browser: authorize → navigate → control changes → snapshot/reacquire; distinguish deliberate user takeover from unrelated typing elsewhere.
7. Browser removed during wait: wait → no live tile → explicit recoverable state; no blind replay of potentially mutating requests.
8. Device observe → act → observe: preserve independent simulator targeting; only 16 device calls were found in this subset, insufficient to claim a device failure rate.

**GUESS:** Background input delivery should eliminate a class of collisions, but it cannot fix missing tile registration, stale DOM references, expired permissions, application 401/module errors or server-side print failures by itself.

## Complete structured-error ledger for the extracted subset

**MEASURED:** Each entry includes UTC timestamp, session stem, source line, tool and exact error message. Arguments and result bodies are omitted to avoid credentials and personal data. All Claude logs are under ~/.claude/projects; full source paths are listed below.

- 2026-11-03T21:05:34.425Z | 441ae298-0e59-490c-ac3f-5cafb4ca1d66:201 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-03T21:07:38.385Z | 98c4872d-cb82-43d6-88ba-eb2970ea30d4:304 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T14:25:04.082Z | fae90091-6d03-4bf4-b2d9-0d86d00e0a60:212 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T14:50:42.987Z | 0210e60e-3c57-422f-b337-d4d9c5b18c52:319 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T15:00:32.855Z | cb1ac63e-6e90-4254-bfc2-88e494ef4b4a:61 | array_browser_evaluate | outcome_unknown: Access or control changed while the browser action was in progress; it may have taken effect. Wait, then take a fresh snapshot.
- 2026-11-04T15:01:18.895Z | cb1ac63e-6e90-4254-bfc2-88e494ef4b4a:89 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T15:14:09.624Z | 36125c62-2f62-43bb-b19e-34d49c4b0dfe:68 | array_browser_take_screenshot | not_found: No live browser tile with that id in this agent's project.
- 2026-11-04T15:14:12.803Z | 36125c62-2f62-43bb-b19e-34d49c4b0dfe:75 | array_browser_snapshot | not_found: No live browser tile with that id in this agent's project.
- 2026-11-04T15:14:23.966Z | 36125c62-2f62-43bb-b19e-34d49c4b0dfe:93 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T15:31:33.359Z | a8ff0c68-7b1c-4ffd-9632-cecb58fc9648:595 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T20:58:21.955Z | a2c10723-b7fb-481b-bc74-973cbfc4f050:80 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T20:58:26.358Z | a2c10723-b7fb-481b-bc74-973cbfc4f050:99 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T20:58:29.595Z | 1f09a201-c08e-4096-8b65-3dead5261f72:65 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T20:58:32.274Z | 1f09a201-c08e-4096-8b65-3dead5261f72:75 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T20:58:45.267Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:97 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T20:58:52.145Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:107 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T20:58:56.600Z | 1f09a201-c08e-4096-8b65-3dead5261f72:92 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T20:59:15.082Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:142 | array_browser_navigate | scope_approval_required: The user has not handed over this browser.
- 2026-11-04T20:59:19.396Z | 1f09a201-c08e-4096-8b65-3dead5261f72:111 | array_browser_navigate | outcome_unknown: Access or control changed while the browser action was in progress; it may have taken effect. Wait, then take a fresh snapshot.
- 2026-11-04T20:59:33.444Z | 1f09a201-c08e-4096-8b65-3dead5261f72:118 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T20:59:34.956Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:152 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T20:59:36.277Z | 1f09a201-c08e-4096-8b65-3dead5261f72:125 | array_browser_navigate | scope_approval_required: The user has not handed over this browser.
- 2026-11-04T20:59:49.070Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:162 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T21:00:04.087Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:171 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T21:01:05.046Z | b617907b-669b-4774-98f8-6be1e3d301c0:178 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T21:01:24.701Z | b617907b-669b-4774-98f8-6be1e3d301c0:182 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T21:02:06.309Z | b617907b-669b-4774-98f8-6be1e3d301c0:221 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T21:02:26.279Z | b617907b-669b-4774-98f8-6be1e3d301c0:228 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T21:02:54.045Z | b617907b-669b-4774-98f8-6be1e3d301c0:236 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T21:03:25.519Z | b617907b-669b-4774-98f8-6be1e3d301c0:254 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T21:03:47.430Z | b617907b-669b-4774-98f8-6be1e3d301c0:278 | array_browser_evaluate | scope_approval_required: The user has not approved JavaScript in this browser.
- 2026-11-04T21:03:49.165Z | b617907b-669b-4774-98f8-6be1e3d301c0:279 | array_browser_evaluate | scope_approval_required: The user has not approved JavaScript in this browser.
- 2026-11-04T21:03:59.027Z | b617907b-669b-4774-98f8-6be1e3d301c0:285 | array_browser_navigate | outcome_unknown: Access or control changed while the browser action was in progress; it may have taken effect. Wait, then take a fresh snapshot.
- 2026-11-04T21:05:40.317Z | b617907b-669b-4774-98f8-6be1e3d301c0:408 | array_browser_navigate | not_found: No live browser tile with that id in this agent's project.
- 2026-11-04T21:06:51.277Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:217 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T21:07:09.378Z | 1f09a201-c08e-4096-8b65-3dead5261f72:184 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T21:09:04.459Z | 1f09a201-c08e-4096-8b65-3dead5261f72:330 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T21:11:12.446Z | 1f09a201-c08e-4096-8b65-3dead5261f72:488 | array_browser_evaluate | invalid_request: The page script failed: the result is 100002 bytes, over the 64 KB cap. Return less.
- 2026-11-04T21:11:18.450Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:555 | array_browser_type | target_conflict: combobox "Switch Feeding Zone" [ref=e438] is not a text field. Type into a textbox, or use press_key.
- 2026-11-04T21:11:43.812Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:600 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T21:11:56.668Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:623 | array_browser_click | target_conflict: e684 is no longer on the page. Take a fresh snapshot and use its tags.
- 2026-11-04T21:12:59.205Z | 1f09a201-c08e-4096-8b65-3dead5261f72:641 | array_browser_wait_for | outcome_unknown: Timed out waiting for the page to answer.
- 2026-11-04T21:14:59.864Z | 1f09a201-c08e-4096-8b65-3dead5261f72:833 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T21:15:28.836Z | 4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0:996 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T21:15:33.580Z | 1f09a201-c08e-4096-8b65-3dead5261f72:902 | array_browser_evaluate | target_conflict: The user took control or the request expired. Take a fresh snapshot.
- 2026-11-04T21:18:10.704Z | 1f09a201-c08e-4096-8b65-3dead5261f72:961 | array_browser_wait_for | outcome_unknown: Timed out waiting for text "zz-never-zz" to appear.
- 2026-11-04T21:18:36.429Z | 1f09a201-c08e-4096-8b65-3dead5261f72:969 | array_browser_wait_for | outcome_unknown: Timed out waiting for text "zz-never-zz" to appear.
- 2026-11-04T21:19:16.897Z | 1f09a201-c08e-4096-8b65-3dead5261f72:982 | array_browser_wait_for | outcome_unknown: Access or control changed while the browser action was in progress; it may have taken effect. Wait, then take a fresh snapshot.
- 2026-11-04T21:19:17.635Z | 1f09a201-c08e-4096-8b65-3dead5261f72:983 | array_browser_evaluate | not_found: No live browser tile with that id in this agent's project.
- 2026-11-04T21:20:34.321Z | b617907b-669b-4774-98f8-6be1e3d301c0:488 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-04T21:39:21.792Z | 1f09a201-c08e-4096-8b65-3dead5261f72:1268 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T22:28:32.878Z | b617907b-669b-4774-98f8-6be1e3d301c0:736 | array_browser_navigate | scope_approval_required: The user has not handed over this browser.
- 2026-11-04T22:33:40.570Z | 1f09a201-c08e-4096-8b65-3dead5261f72:1398 | array_browser_evaluate | scope_approval_required: The user has not handed over this browser.
- 2026-11-04T22:35:55.445Z | b617907b-669b-4774-98f8-6be1e3d301c0:916 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T22:35:56.748Z | b617907b-669b-4774-98f8-6be1e3d301c0:917 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T22:37:50.064Z | b617907b-669b-4774-98f8-6be1e3d301c0:1008 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T22:39:24.668Z | b617907b-669b-4774-98f8-6be1e3d301c0:1081 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T22:40:10.569Z | b617907b-669b-4774-98f8-6be1e3d301c0:1110 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T22:40:53.434Z | b617907b-669b-4774-98f8-6be1e3d301c0:1135 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-04T22:47:07.726Z | b617907b-669b-4774-98f8-6be1e3d301c0:1432 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-04T22:47:20.288Z | b617907b-669b-4774-98f8-6be1e3d301c0:1440 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-05T08:18:28.066Z | d2d1f3b6-6fb9-4b0a-9f69-137fa4d4a50a:259 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T08:25:36.254Z | 757e1f4b-820b-4463-9521-ba385759de30:185 | array_browser_open | permission_denied: That browser destination is not allowed.
- 2026-11-05T14:37:31.255Z | 223fef8e-4d82-473e-8b87-9bc23b9ff643:64 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T14:37:36.538Z | 223fef8e-4d82-473e-8b87-9bc23b9ff643:82 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T14:39:07.806Z | 7a78da94-6042-4131-abc0-55b856012513:125 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T14:39:14.882Z | 7a78da94-6042-4131-abc0-55b856012513:145 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T14:39:20.998Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:240 | array_browser_click | target_conflict: e10 is no longer on the page. Take a fresh snapshot and use its tags.
- 2026-11-05T14:39:21.611Z | 7a78da94-6042-4131-abc0-55b856012513:161 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T14:39:31.914Z | 7a78da94-6042-4131-abc0-55b856012513:172 | array_browser_navigate | permission_denied: This browser belongs to another agent.
- 2026-11-05T14:39:54.399Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:290 | array_browser_wait_for | outcome_unknown: Timed out waiting for text "1125326" to appear.
- 2026-11-05T14:41:01.296Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:365 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-05T14:53:59.710Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:470 | array_browser_type | target_conflict: link "Create Order" [ref=e13] is not a text field. Type into a textbox, or use press_key.
- 2026-11-05T14:54:01.695Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:474 | array_browser_click | target_conflict: e20 is no longer on the page. Take a fresh snapshot and use its tags.
- 2026-11-05T14:54:19.944Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:511 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-05T14:54:34.352Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:539 | array_browser_navigate | outcome_unknown: Access or control changed while the browser action was in progress; it may have taken effect. Wait, then take a fresh snapshot.
- 2026-11-05T15:01:06.929Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:725 | array_browser_navigate | outcome_unknown: Access or control changed while the browser action was in progress; it may have taken effect. Wait, then take a fresh snapshot.
- 2026-11-05T15:02:43.079Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:810 | array_browser_click | target_conflict: e2 is no longer on the page. Take a fresh snapshot and use its tags.
- 2026-11-05T15:02:52.737Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:829 | array_browser_click | target_conflict: button "Create" [ref=e71] is covered by main [ref=e10], so a click would land on that instead. Close or click the covering element first, or click by coordinates.
- 2026-11-05T15:03:05.326Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:840 | array_browser_type | target_conflict: e14 is no longer on the page. Take a fresh snapshot and use its tags.
- 2026-11-05T15:03:19.006Z | 8acc328d-1e70-4116-8c89-4b8de89ac96d:851 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-05T15:15:21.410Z | c4fce735-e920-4baa-b3e7-d69e04609542:437 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T15:15:28.174Z | c4fce735-e920-4baa-b3e7-d69e04609542:455 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T15:25:07.125Z | c4fce735-e920-4baa-b3e7-d69e04609542:599 | array_browser_type | target_conflict: e5 is no longer on the page. Take a fresh snapshot and use its tags.
- 2026-11-05T15:25:07.826Z | c4fce735-e920-4baa-b3e7-d69e04609542:601 | array_browser_click | target_conflict: e6 is no longer on the page. Take a fresh snapshot and use its tags.
- 2026-11-05T15:25:11.380Z | c4fce735-e920-4baa-b3e7-d69e04609542:608 | array_browser_wait_for | outcome_unknown: Timed out waiting for the page to answer.
- 2026-11-05T15:28:13.532Z | c4fce735-e920-4baa-b3e7-d69e04609542:756 | array_browser_wait_for | outcome_unknown: Timed out waiting for text "Feeding Zone Tanks" to appear.
- 2026-11-05T15:29:00.694Z | c4fce735-e920-4baa-b3e7-d69e04609542:788 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-05T15:29:01.997Z | c4fce735-e920-4baa-b3e7-d69e04609542:790 | array_browser_wait_for | outcome_unknown: Timed out waiting for text "Tank Settings" to appear.
- 2026-11-05T15:29:38.518Z | c4fce735-e920-4baa-b3e7-d69e04609542:816 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-05T15:35:40.447Z | c4fce735-e920-4baa-b3e7-d69e04609542:1388 | array_browser_wait_for | outcome_unknown: Timed out waiting for text "Majors" to appear.
- 2026-11-05T15:59:14.618Z | 852a1b02-423d-4855-8d8d-e00caa94a64c:177 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T16:13:32.795Z | 2aaa8042-aee9-450c-943f-997107734de8:51 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T16:13:37.612Z | 2aaa8042-aee9-450c-943f-997107734de8:79 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T18:48:14.734Z | agent-a7d097974d47bd0c6:33 | array_browser_evaluate | permission_denied: This browser belongs to another agent.
- 2026-11-05T18:48:20.438Z | agent-a7d097974d47bd0c6:40 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-05T18:48:27.261Z | agent-a7d097974d47bd0c6:47 | array_browser_evaluate | outcome_unknown: The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.
- 2026-11-05T19:07:55.303Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:407 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T19:08:00.406Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:425 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T19:08:03.934Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:430 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T19:08:20.118Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:463 | array_browser_evaluate | permission_denied: This browser belongs to another agent.
- 2026-11-05T19:08:21.069Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:465 | array_browser_evaluate | permission_denied: This browser belongs to another agent.
- 2026-11-05T19:08:59.339Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:563 | array_browser_evaluate | invalid_request: The page script failed: A JavaScript exception occurred
- 2026-11-05T19:14:20.293Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:981 | array_browser_navigate | permission_denied: That browser destination is not allowed.
- 2026-11-05T19:14:35.970Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:1008 | array_browser_navigate | outcome_unknown: Access or control changed while the browser action was in progress; it may have taken effect. Wait, then take a fresh snapshot.
- 2026-11-05T19:25:50.664Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:1470 | array_browser_navigate | not_found: No live browser tile with that id in this agent's project.
- 2026-11-05T19:25:51.961Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:1472 | array_browser_navigate | not_found: No live browser tile with that id in this agent's project.
- 2026-11-05T19:25:52.354Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:1474 | array_browser_take_screenshot | not_found: No live browser tile with that id in this agent's project.
- 2026-11-05T19:25:55.668Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:1485 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.
- 2026-11-05T19:26:30.565Z | 18d88fb1-ceb8-4dca-9e77-c55aeeb6210b:1514 | array_browser_open | permission_denied: The agent's project and installed tile are required to open a browser.

## Per-session inventory

**MEASURED:** Source, calls, first/last tool timestamp. These are session spans, not uninterrupted runs.

- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/b617907b-669b-4774-98f8-6be1e3d301c0.jsonl: 230 calls; 2026-11-04T20:56:43.945Z → 2026-11-05T13:45:57.587Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/1f09a201-c08e-4096-8b65-3dead5261f72.jsonl: 217 calls; 2026-11-04T20:58:29.595Z → 2026-11-04T22:33:40.570Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/4caf4e2e-b0c0-4bc0-bcff-4409af17ddf0.jsonl: 185 calls; 2026-11-04T20:58:45.267Z → 2026-11-04T21:16:24.740Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/c4fce735-e920-4baa-b3e7-d69e04609542.jsonl: 167 calls; 2026-11-05T15:15:21.410Z → 2026-11-05T15:38:06.535Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/8acc328d-1e70-4116-8c89-4b8de89ac96d.jsonl: 133 calls; 2026-11-05T14:38:03.381Z → 2026-11-05T15:08:17.860Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-harmony/18d88fb1-ceb8-4dca-9e77-c55aeeb6210b.jsonl: 111 calls; 2026-11-05T19:07:55.303Z → 2026-11-05T19:26:30.565Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-harmony/59c8aaaa-3b5b-4de8-8b46-40b65082ec60/subagents/agent-a7d097974d47bd0c6.jsonl: 34 calls; 2026-11-05T18:48:09.415Z → 2026-11-05T18:49:35.382Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/cb1ac63e-6e90-4254-bfc2-88e494ef4b4a.jsonl: 18 calls; 2026-11-04T14:59:54.441Z → 2026-11-04T15:01:39.633Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/a5a858c2-c8b6-4a36-b102-b32dc079467e.jsonl: 16 calls; 2026-11-05T16:12:50.521Z → 2026-11-05T16:13:43.639Z
- /Users/dylan/.claude/projects/-Users-dylan-array-scratch/11d10a19-1364-4933-8cf8-5942163a8fb1.jsonl: 16 calls; 2026-10-30T15:26:30.619Z → 2026-10-30T15:27:39.980Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-personal-Array/757e1f4b-820b-4463-9521-ba385759de30.jsonl: 13 calls; 2026-11-05T08:25:36.254Z → 2026-11-05T12:06:02.462Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/7a78da94-6042-4131-abc0-55b856012513.jsonl: 6 calls; 2026-11-05T14:39:07.806Z → 2026-11-05T14:39:32.305Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/36125c62-2f62-43bb-b19e-34d49c4b0dfe.jsonl: 6 calls; 2026-11-04T15:13:47.231Z → 2026-11-04T15:14:23.966Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/223fef8e-4d82-473e-8b87-9bc23b9ff643.jsonl: 2 calls; 2026-11-05T14:37:31.255Z → 2026-11-05T14:37:36.538Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/a2c10723-b7fb-481b-bc74-973cbfc4f050.jsonl: 2 calls; 2026-11-04T20:58:21.955Z → 2026-11-04T20:58:26.358Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/2aaa8042-aee9-450c-943f-997107734de8.jsonl: 2 calls; 2026-11-05T16:13:32.795Z → 2026-11-05T16:13:37.612Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-personal-Array--worktrees-street-street-sigils-index-page-99b235a5/d2d1f3b6-6fb9-4b0a-9f69-137fa4d4a50a.jsonl: 1 calls; 2026-11-05T08:18:28.066Z → 2026-11-05T08:18:28.066Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/98c4872d-cb82-43d6-88ba-eb2970ea30d4.jsonl: 1 calls; 2026-11-03T21:07:38.385Z → 2026-11-03T21:07:38.385Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/fae90091-6d03-4bf4-b2d9-0d86d00e0a60.jsonl: 1 calls; 2026-11-04T14:25:04.082Z → 2026-11-04T14:25:04.082Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/441ae298-0e59-490c-ac3f-5cafb4ca1d66.jsonl: 1 calls; 2026-11-03T21:05:34.425Z → 2026-11-03T21:05:34.425Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/852a1b02-423d-4855-8d8d-e00caa94a64c.jsonl: 1 calls; 2026-11-05T15:59:14.618Z → 2026-11-05T15:59:14.618Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/0210e60e-3c57-422f-b337-d4d9c5b18c52.jsonl: 1 calls; 2026-11-04T14:50:42.987Z → 2026-11-04T14:50:42.987Z
- /Users/dylan/.claude/projects/-Users-dylan-Documents-work-selectus/a8ff0c68-7b1c-4ffd-9632-cecb58fc9648.jsonl: 1 calls; 2026-11-04T15:31:33.359Z → 2026-11-04T15:31:33.359Z

## Verification left open

**MEASURED:** No behavioral check was run, by research-only instruction. No live state was changed. Codex nested functions.exec calls, all managed transcript revisions, exact retry detection across semantically equivalent calls, all project .array session stores, and exhaustive device timelines remain unnormalized/unverified. No vendor-doc claims are used. Source explanations refer to d41dad04 only; provider sessions may span app upgrades, so a release-by-release cause is not established.
