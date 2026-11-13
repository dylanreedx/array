# Lead checkout callback lifetime witness

The Nov 12 dev crashes entered `Stream.received` from FSEvents with an
unretained context holder. On base `dd972ea7`, the context retain/release
callbacks protect that holder and teardown drains the delivery queue.

`--lead-checkout-ledger-check` (already registered in `scripts/run-matrix.sh`)
now exercises the production FSEvents callback in its teardown section:

- 64 ownership arms retain a real native stream, stop it and remove the
  watch's holder reference. A weak reference must remain alive until native
  stream release; the real callback then appends an event on the delivery queue.
- 64 main-thread arms queue a blocked delivery, release it from a worker after
  50 ms, and destroy the watch on main. The delivery invokes the production
  callback while teardown drains it. A worker watchdog exits with failure if
  main cannot complete within two seconds. Neither delivery nor watchdog needs
  the main queue.
- 1,200 watches open and tear down while a writer changes a temporary Git repo.
  A callback counter requires real FSEvents delivery during this stress arm.
  Every arm checks that holder counts return to baseline.

RED was built with only the historical `retain: nil, release: nil` context
restored in a temporary scratch commit. It exited 1 with
`FSEvents callback holder freed before stream release`. This detects freed
memory before dereference, avoiding an intentional crash in the GUI host.
The scratch commit was removed and the retained context restored before GREEN.

Builds used `SDKROOT` from `xcrun --sdk macosx --show-sdk-path`, captured build
logs without pipelines, and exited 0. Each build preflight observed fewer than
four Xcode swift-build commands, at least 25% free memory and over 20 GiB free.
Checks use disposable project/app-support directories and disable tmux.
The full matrix was not run; no application bundle was launched or modified.

GREEN verification (2026-11-13): eight complete ledger runs exited 0.
Real callback counts by run: 933, 833, 963, 942, 871, 949, 823, 802.
This totals 9,600 stress teardowns and 512 bounded main-thread teardown arms.
`--workspace-api-delegation-check` and
`--managed-lead-context-transition-check` each exited 0.
`git diff --check` passed. `scripts/benches.sh` ran at pickup and before commit;
this existing shared bench is retained for the orchestration review branch.
