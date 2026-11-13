# Workspace tool context accounting (gap 17)

Base: `0287b3c3`; isolated branch `array/gaps-tool-context`.

This is the expressly permitted accounting fallback, not a compact variant.
No tool descriptions, guidelines, schemas, operations, server instructions or
Pi extension resources were rewritten. Actual prompt cost, quality impact,
context reduction and paired live compliance/cost remain OPEN. There is no
claim of token savings, and no new feature is enabled in normal launches.

## What the host reports

Only when the MCP helper process has `ARRAY_WORKSPACE_TOOL_CONTEXT_FACTS=1`,
its `initialize.result._meta["array/toolContext"]` reports cached protocol
facts. Absent, `0`, or any other value keeps the existing initialization
content. The diagnostic is not added to tool descriptions or instructions;
clients may ignore it or display it. Enabling it adds metadata bytes and is
not an optimization. No app setting, personal file or project instruction is
changed. Counts are computed once in the separate helper process, only when
requested, from the already bundled catalog. No host UI event path is touched.

| Field | Exact meaning |
|---|---|
| `toolCount` | Actual offered `tools/list` entries, including conditional standards/chooser/collect entries. |
| `toolTextWords` / `toolTextUTF8Bytes` | Sum over actual MCP description strings, including their guideline header/bullets and collect-delivery note. Words split on Unicode whitespace. |
| `initializeInstructionsWords` / `initializeInstructionsUTF8Bytes` | The separate actual initialize instruction string. |
| `schemaDescriptionWords` | Words in description-valued strings within the offered input schemas. This is not every schema token. |
| `inputSchemaJSONUTF8Bytes` | Sum of input schemas serialized by the helper's JSON encoder. |
| `toolsListResultJSONUTF8Bytes` | Actual JSON-encoded tools/list result object, excluding the JSON-RPC envelope. |
| `tokenCount` | Always null: no tokenizer/provider estimate is presented as observation. |
| `compactVariant` | Always false. |

Byte categories overlap and must not be summed. JSON encoding includes
escaping/framing; raw text byte counts differ from JSON-string byte counts.
The scope explicitly excludes the diagnostic metadata itself, client
rendering, provider framing, Pi prompt assembly, and personal/project text.
No inference about billed tokens or a model's actual retained context follows.

## Why no compact text shipped

The 37 bundled tools contain 2,412 description words and 2,496 guideline words
before MCP formatting, with parameter descriptions additional. The observed
5,057 words below include guideline headers/bullets. Array already sends
serverInstructions separately in initialize; it does not append those global
instructions to each tool. A client may present both, but this patch does not
invent an Array duplication defect.

No equivalent, materially smaller full-catalog rewrite was established in
this bounded audit. Removing per-tool permission, identity, error recovery,
idempotency or delivery rules, or replacing them with a reference requiring
another tool turn, would not satisfy the assignment. A prose rewrite requires
its own meaning-retention review and paired live proof. This change supplies
exact protocol evidence to guide that work and does not close gap 17.

## Retention mapping

Every original description and every original guideline maps to the identical
text in both diagnostic modes. The protocol witness compares every listed
name, description, input schema, order and always-load metadata to the
unchanged full catalog contract. Nothing is summarized, truncated, hidden or
moved from a guideline into a less visible place. Operations remain the
catalog's original mapping. Per-tool source inventory:

| Tool | Operation | Description words | Guideline words | Retention |
|---|---|---:|---:|---|
| `array_workspace_context` | `workspace.context` | 53 | 36 | Identical full text/schema |
| `array_open_document` | `artifact.open` | 52 | 89 | Identical full text/schema |
| `array_find_agent` | `agent.find` | 73 | 55 | Identical full text/schema |
| `array_inspect_agent` | `agent.inspect` | 95 | 47 | Identical full text/schema |
| `array_canvas_query` | `canvas.query` | 58 | 61 | Identical full text/schema |
| `array_canvas_apply` | `canvas.apply` | 82 | 85 | Identical full text/schema |
| `array_board_query` | `board.query` | 49 | 53 | Identical full text/schema |
| `array_board_apply` | `board.apply` | 131 | 59 | Identical full text/schema |
| `array_board_manage` | `board.manage` | 130 | 79 | Identical full text/schema |
| `array_delegate` | `agent.delegate` | 87 | 154 | Identical full text/schema |
| `array_reveal_agent` | `agent.reveal` | 42 | 42 | Identical full text/schema |
| `array_get_operation` | `operation.get` | 146 | 28 | Identical full text/schema |
| `array_message_agent` | `agent.message` | 232 | 203 | Identical full text/schema |
| `array_update_agent` | `agent.update` | 109 | 171 | Identical full text/schema |
| `array_device_list` | `device.list` | 34 | 52 | Identical full text/schema |
| `array_device_open` | `device.open` | 63 | 108 | Identical full text/schema |
| `array_device_observe` | `device.observe` | 45 | 86 | Identical full text/schema |
| `array_device_act` | `device.act` | 50 | 154 | Identical full text/schema |
| `array_device_close` | `device.close` | 29 | 52 | Identical full text/schema |
| `array_device_build_run` | `device.build_run` | 61 | 172 | Identical full text/schema |
| `array_browser_open` | `browser.open` | 10 | 31 | Identical full text/schema |
| `array_browser_navigate` | `browser.navigate` | 44 | 31 | Identical full text/schema |
| `array_browser_snapshot` | `browser.snapshot` | 42 | 31 | Identical full text/schema |
| `array_browser_click` | `browser.click` | 42 | 55 | Identical full text/schema |
| `array_browser_type` | `browser.type` | 44 | 50 | Identical full text/schema |
| `array_browser_press_key` | `browser.press_key` | 41 | 72 | Identical full text/schema |
| `array_browser_scroll` | `browser.scroll` | 45 | 31 | Identical full text/schema |
| `array_browser_wait_for` | `browser.wait_for` | 44 | 31 | Identical full text/schema |
| `array_browser_take_screenshot` | `browser.take_screenshot` | 45 | 31 | Identical full text/schema |
| `array_browser_evaluate` | `browser.evaluate` | 45 | 31 | Identical full text/schema |
| `array_browser_console` | `browser.console` | 41 | 31 | Identical full text/schema |
| `array_browser_select` | `browser.select` | 62 | 27 | Identical full text/schema |
| `array_notify` | `agent.notify` | 120 | 105 | Identical full text/schema |
| `array_report` | `agent.report` | 30 | 36 | Identical full text/schema |
| `array_status` | `agent.status` | 14 | 21 | Identical full text/schema |
| `array_schedule_agent` | `agent.schedule` | 89 | 84 | Identical full text/schema |
| `array_standards` | `standards.read` | 33 | 12 | Identical full text/schema |

## Actual protocol observations

The check launches the built production `array-workspace-mcp`, submits real
initialize/tools-list/unknown-tool calls, and compares parsed protocol values
(JSON object key order is not significant). Missing and explicit-off modes
are identical. Diagnostic-on changes only the namespaced initialize metadata;
all tool-list content and unknown-tool rejection stay identical. Eight
configurations combine push/collect, standards absent/present and chooser
absent/present, with 24 real helper processes across the three diagnostic modes.

| Delivery | Standards | Chooser | Tools | Tool words | Tool UTF-8 bytes | Schema description words | Schema JSON bytes | Tools/list result JSON bytes |
|---|---|---|---:|---:|---:|---:|---:|---:|
| push | false | false | 36 | 5010 | 32264 | 983 | 21806 | 56594 |
| push | false | true | 37 | 5085 | 32781 | 1018 | 22482 | 57841 |
| push | true | false | 37 | 5057 | 32554 | 992 | 22083 | 57224 |
| push | true | true | 38 | 5132 | 33071 | 1027 | 22759 | 58471 |
| collect | false | false | 37 | 5195 | 33373 | 1000 | 22181 | 58141 |
| collect | false | true | 38 | 5270 | 33890 | 1035 | 22857 | 59388 |
| collect | true | false | 38 | 5242 | 33663 | 1009 | 22458 | 58771 |
| collect | true | true | 39 | 5317 | 34180 | 1044 | 23134 | 60018 |

Push initialize instructions: 282 words / 1,811 UTF-8 bytes. Collect: 264 words /
1,723 bytes. The 37-tool non-chooser push row includes standards; ordinary
push without standards offers 36 tools. Conditional catalog size is not tool
hiding or a new optimization; the existing policy is unchanged.

Claude and Codex receive this MCP protocol. The diagnostic does not measure
client rendering or provider framing. Pi continues to receive the full,
unchanged JSON/extension guidance; no Pi compact mode or prompt-cost facts are
claimed. Successful host tools, real grant transitions, live provider behavior
and model compliance are not exercised by this diagnostic witness; the actual
host dispatch and grant paths were not modified.

## Verification

- Fresh baseline helper and CoreChecks products rebuilt before belief.
- Real baseline RED: `--workspace-tool-context-check` exits 1 with
  `initialize lacks host-owned tool-context facts`.
- Production metadata added, helper and CoreChecks rebuilt; direct GREEN exits
  0 across all eight configurations. Unknown-tool error remains unchanged.
- Logs: `/tmp/gaps-tool-context-red.log`,
  `/tmp/gaps-tool-context-green.log`; build logs use the same prefix.
- New Core arm registered in full matrix and targeted
  `scripts/run-matrix.sh --tool-context`. Normal-lock run pending at this
  writing; final result appended below.
- Every build passed resource gate (<4 swift-build processes, >=25% free
  memory, >=20 GiB disk), with SDKROOT from xcrun. Documented Ghostty bootstrap
  ran in this bench. No active .build copied.
- Tests unset ARRAY_AGENT_ID/TMUX/TMUX_PANE, set TERM=xterm-256color and UI
  baseline skip, read stdin /dev/null, preserve managed crash marker, and use
  temporary fixture tokens only. No default tmux server or production app/state.

No compact switch was created or enabled. No token/cost/quality/context
reduction claim. Independent sibling review must check the accounting scope,
unchanged protocol/authorization paths, metadata default-off behavior and
meaning-preservation limitation before integration.

## Normal targeted gate result

`./scripts/run-matrix.sh --tool-context` ran under the normal lock and exited 0:

```
---- Tool context matrix (targeted): 15 leg(s) run ----
Tool context matrix (targeted) passed.
```

The summary includes the actual `--workspace-tool-context-check` arm, whose
wire-accounting PASS appears in the log. Both matrix builds passed the resource
preflight with 0 existing builds, 69% free memory and 49.3 GiB disk; SDKROOT set.
The neighboring `--workspace-mcp-check` also exited 0 (37 shared tools, Pi
parity, guidance/allowances/timeouts and token containment). No failure was
reclassified as KNOWN-RED and no baseline was updated. Inventory validation
passed while reporting growth to be regenerated on the combined branch.

Logs: `/tmp/gaps-tool-context-matrix.log`,
`/tmp/gaps-tool-context-neighbor.log`. This proves protocol accounting and
content preservation, not prompt reduction, billed cost, live quality, actual
host grant outcomes or provider rendering. Full/live/provider matrices unrun.
The diagnostic stays OFF. Gap 17 stays OPEN for real context reduction.
