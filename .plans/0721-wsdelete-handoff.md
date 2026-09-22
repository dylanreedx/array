# 0721 — "i can't delete a work space"

Bench: `.worktrees/0721-wsdelete`, branch `array/0721-wsdelete`, based on
`array/integration` at `2cec73ff`.

The report came with a screenshot nobody on this side could see, so this was
treated as "the delete affordance fails, and it fails without telling the user
why" rather than as one root cause. Six of the seven candidate failure modes
turned out to be reachable; each is listed below with how it was confirmed.

## What was confirmed, and how

Every confirmation is a RED from the new witness
(`--workspace-delete-failure-check`) with the fix reverted — the exact output is
quoted under "Teeth". The witness drives the production entry points
(`configureWorkspaceTopBar` → the real `deleteButton` action →
`deleteWorkspaceAndRelaunch`, and `reloadWorkspaceSidebar` → the scope menu's
Delete item), never a re-derivation of their logic.

### 2. Top-bar `currentWorkspaceId` nil while the button looks enabled — CONFIRMED (the prime suspect, and it is two defects)

`NSButton.isEnabled` defaults to `true`, and `WorkspaceTopBarView` never set it
otherwise until the first successful `reload(_:)`. `reloadWorkspaceTopBar()`
only pushed a model when `buildWorkspaceTopBarModel()` returned non-nil **and**
did not throw — and it threw whenever the current workspace's `canvas.json` was
missing or unreadable (`try store.load()`), with the error going only to
`fputs`. So the button drew live, `currentWorkspaceId` stayed nil, and
`deleteWorkspaceClicked` fell straight out of a bare `guard`: a button that does
nothing, permanently, for that user, with nothing on screen and nothing in the
UI to explain it. That is the closest match to the report.

Fixed in two places:

- `WorkspaceTopBarView` starts with Delete and Rename **disabled** and a tooltip
  that says the workspace has not loaded. Enablement is only ever raised by a
  model that really loaded.
- `buildWorkspaceTopBarModel` no longer throws on an unreadable document. The
  document is only the counts/save-state ornament on that model; the registry is
  what the verbs act on. A failed load degrades the ornament (zone count 0, save
  state `.saveFailed`), logs, and keeps the chrome loaded, so Delete still works.
- `reloadWorkspaceTopBar` surfaces a message on both the nil-model and the throw
  path instead of swallowing them.
- `deleteWorkspaceClicked` with no loaded workspace now sets a visible message.

### 3. `switchWorkspace` throws after the registry was already saved — CONFIRMED

The old order was: save registry → `switchWorkspace` → `deleteDocument` →
success message. `switchWorkspace` throws on `noCanvas`,
`documentNotFound` and `projectAppearsInBothWorkspaces`; the throw landed in the
catch, told the user "Delete workspace failed", skipped `deleteDocument()` — and
the workspace was already gone from `registry.json` and stayed gone on the next
launch.

Reproduced with a `WorkspaceRuntime` that never adopted a canvas (`noCanvas`,
the same class of throw as the other two):

```
FAIL: a delete that cannot switch away must leave the registry untouched and say the workspace was kept — workspaces=1 message='Delete workspace failed, so “this workspace” was kept: The operation couldn’t be completed. (ContinuumRevived.WorkspaceRuntime.WorkspaceSwitchError error 2.)'
```

`workspaces=1` is the bug: it reported failure over a delete that had happened.

### 1. Last-workspace rule — CONFIRMED as invisible, kept as a rule

Deleting the only workspace stays refused. The codebase's own semantics put the
rule in `Registry.deleteWorkspace` (`workspaces.count > 1`), not in the UI, and
"delete the last one by silently minting a replacement" would invent a workspace
the user did not ask for and move their `lastActiveWorkspaceId` onto it — a
larger semantic change than this bug warrants. **What changed is that the
refusal now explains itself**: the top bar's disabled Delete carries
`"Delete workspace — you can't delete your only workspace. Create another one
first."` as its tooltip, and the sidebar's greyed menu item renders as
`"Delete Workspace… — this is your only workspace — create another first"`. The
⌘K row, which no enablement gates, already produced a message and is asserted.

### 4. Scoped-inbox ambiguity greys the menu item — CONFIRMED as unexplained

Duplicate workspace names are legal, and a `.workspace(name)` scope matching two
of them correctly resolves to no target (P3.14 decided that deliberately, and
that decision is untouched). The item simply went grey with no reason. It now
renders `"Delete Workspace… — two workspaces are named “X”, so this one is
ambiguous — rename one first"`.

### 5. Sidebar tree collapses to empty on a registry read error — HARDENED, not reproduced

A `buildWorkspaceSidebarTree()` throw pushes an empty tree, which disables every
workspace verb while the app looks fine. No fixture was built that makes that
read throw through the app (it needs an `unknownFutureSchema` registry, which
would also break boot), so this is a defensive fix, not a reproduction: the
catch now sets a management message naming the load failure.

### 6. `guard let registryStore else { return false }` — CONFIRMED silent

No message, no log. It now sets a message. Witnessed.

### 7. Confirmation-provider trap — NOT CHANGED

`workspaceDeleteConfirmationProvider?(request) ?? confirmDeleteWorkspace(request)`
is already the documented safe shape (a nil provider does not decline, it falls
through to the alert), and the new check always answers it, so nothing presents
a modal under a `--*-check` run.

## The atomicity approach

`deleteWorkspaceAndRelaunch` now runs every step that can fail **before** the
registry is committed:

1. Load the registry, resolve the target, apply the last-workspace rule, confirm.
2. Apply `deleteWorkspace` to a **copy** (`pending`). That names the replacement
   workspace without committing anything, so a refusal costs nothing.
3. `switchWorkspace(to:)` — the only throwing step — is driven while
   `registry.json` on disk still holds every workspace. A throw leaves the file,
   the document directory and the mounted scene exactly as they were, and the
   message now says the workspace was kept.
4. Only then: re-read the registry (the switch saves it itself, to commit the
   selected workspace), re-apply the removal to that fresh copy, and save.
5. Past the commit point, the tmux kill and `deleteDocument()` are **cleanup**.
   A failure there is logged, never reported as a failed delete — reporting
   failure over a committed delete is the bug this ticket exists to remove.

This is the "do the things that can fail before committing" half of the brief
rather than a rollback-and-re-save; with the switch moved ahead of the save
there is nothing to roll back. Projects and project tile data are still never
deleted (`Registry.deleteWorkspace` only nils `projects[i].workspaceId`), and
the success message still says so.

## New witness

`--workspace-delete-failure-check` → `AppDelegate.runWorkspaceDeleteFailureSelfCheck()`,
artifact `qa-runs/<ts>/workspace-delete-failure/manifest.json`. Registered in
`scripts/run-matrix.sh` beside the workspace sidebar/top-bar block.

**Finding while registering it:** `--workspace-management-polish-check` — the
existing witness for the whole create/rename/delete path, including every delete
assertion P3.14 wrote — **was never a matrix leg**. Neither was
`--workspace-switch-polish-check`. The polish leg is now registered too; the
switch-polish leg is left alone as out of scope for this bug. This is exactly
the "a witness only counts if the gate reports it" hazard, and it is why these
defects survived: the delete path's own gate never ran.

`scripts/check-matrix-inventory.sh` passes — the new records read as inventory
GROWTH (which is allowed and prints). The committed inventory file is
regenerated only by `CONTINUUM_UPDATE_MATRIX_INVENTORY=1 ./scripts/run-matrix.sh`,
which this ticket was told not to run, so **the inventory file is deliberately
not updated here** and the next full matrix run should bless it.

### Teeth (RED before, GREEN after, on a rebuilt binary)

Each fix was reverted in isolation, the binary rebuilt, the leg re-run:

| Mutation | RED output |
| --- | --- |
| remove `deleteButton.isEnabled = false` | `FAIL: an unloaded top bar must not draw a live Delete — enabled=true tooltip='Delete workspace — unavailable until this workspace finishes loading'` |
| restore the silent `guard let currentWorkspaceId else { return }` | `FAIL: a Delete with nothing to act on must say so — message=''` |
| restore `document = try store.load()` (rethrow) | `FAIL: an unreadable canvas.json must not disarm the workspace verbs — enabled=false name='Workspace'` |
| restore the original save-then-switch ordering | `FAIL: a delete that cannot switch away must leave the registry untouched and say the workspace was kept — workspaces=1 message='Delete workspace failed, so “this workspace” was kept: The operation couldn’t be completed. (ContinuumRevived.WorkspaceRuntime.WorkspaceSwitchError error 2.)'` |
| drop the greyed-item reason suffix | `FAIL: the last-workspace refusal must be explained on both controls — tooltip='Delete workspace — you can't delete your only workspace. Create another one first.' menu='Delete Workspace…' message='Cannot delete the last workspace. Create another workspace first.'` |
| replace the ambiguity reason with the generic one | `FAIL: an ambiguous workspace scope must say why Delete is greyed — menu='Delete Workspace… — no workspace is selected'` |
| restore `guard let registryStore else { return false }` | `FAIL: a delete with no registry store must explain itself — message=''` |

## Verification

- `swift build` — clean.
- `swift run ContinuumRevivedCoreChecks` — exit 1 on the **documented KNOWN-RED**
  only: `FAIL: seed-1 regression (arm64-only): canonical byte count drifted from
  the pinned baseline (1639) to 1644`. Nothing in this change touches Core.
- App legs, all exit 0: `--workspace-delete-failure-check`,
  `--workspace-management-polish-check`, `--workspace-sidebar-actions-check`,
  `--workspace-top-bar-check`, `--workspace-switch-check`,
  `--workspace-switch-polish-check`, `--workspace-sidebar-live-status-check`,
  `--workspace-sidebar-default-visible-check`.
- `--empty-workspace-creation-check` is red and is listed in `MATRIX_KNOWN_RED`
  with a byte-for-byte reproduction note; not re-bisected.
- `scripts/check-matrix-inventory.sh` passes (growth only).
- Every leg was run with a disposable `TMUX_TMPDIR` and `TMUX`/`TMUX_PANE`
  unset. The full matrix was not run, the GUI was never launched, and nothing
  pointed at `/Applications/Array.app` or `~/Documents/personal`.

## Deliberately not changed

- The last-workspace rule itself, in `Registry.deleteWorkspace` and in the UI
  enablement. Refused, now explained.
- P3.14's decision that an ambiguous workspace scope has **no** target. It does
  not fall back to the open workspace; it now says why.
- `Registry.deleteWorkspace`'s three silent `false` returns. Every app-side
  caller now attaches a message, and changing the Core signature would touch the
  registry-level witness in `ContinuumRevivedCoreChecks` for no behavioural gain.
- The confirmation-provider seam, the relaunch/tmux-kill behaviour (only its
  position relative to the commit point moved), and `--workspace-switch-polish-check`'s
  absence from the matrix.

## Unverified

- Failure mode 5 (sidebar tree collapse on a registry read error) is hardened
  defensively; it was never reproduced through the app.
- No GUI run. The user-visible strings (tooltips, the greyed item's reason
  suffix, the management messages) are asserted on the real controls in the
  witness, but nobody has looked at them on screen, and the reason suffix makes
  the Delete item wider when it is greyed — if any committed UI baseline renders
  that menu open, it would need re-blessing. None was found, and the two
  baseline legs were not run.
- Whether the user's actual screenshot was mode 2, mode 3 or the last-workspace
  refusal is still unknown. All three are fixed or explained.
