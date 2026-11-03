# Claude cron lifecycle fixture

Paired CronCreate/CronDelete tool-use and successful tool-result messages from
Claude Code 2.1.316, entrypoint sdk-cli, in the report-linked overnight Array
production session. Frame timestamps: 2026-11-03 03:04:52.224Z/.315Z (create),
04:31:20.442Z/.579Z (delete). Only these tool blocks are retained. The private
scheduled prompt is replaced by ARRAY_SCHEDULE_QA_ONLY. IDs and result payloads
are unchanged. The fixture is replayed through AgentSupervisor.productionRunner.

A new isolated capture on 2026-11-03 used the production stream-json argv with
an isolated cwd/session, restricted Cron tools and no MCP servers. It failed
before any tool call with the CLI's 429 five-hour usage limit. No successful new
stdout capture is claimed; the paired historical production frames are the
behavioral input. The replay fake adds its normal init/result envelope, as it
does for other production transcript fixtures.
