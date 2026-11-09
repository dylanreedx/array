# Separate sidebar preview on 0.7.45

The sidebar preview merges `origin/array/integration` at `5e97ca92` (0.7.45, build 96). The only merge conflict was the matrix inventory: retain `--sidebar-indicator-settings-check` while accepting upstream removal of the obsolete `--sidebar-lifecycle-check` text pin. Settings code merged with both the Active agent choice and 0.7.45's Agent Icons page/update-channel control intact.

The separate app is `~/array-scratch/apps/Array Sidebar.app`, bundle ID `dev.arrayapp.macos.sidebar`. It uses `~/array-scratch-sidebar-0745` as its project root and `~/array-scratch-sidebar-0745-support` as its isolated app support. It never shares the Desktop preview's project or dev store. The existing `ARRAY_SIDEBAR_PREVIEW` mode presents two interactive production sidebars with sample agents in light and dark; a coloured lead opens with three expanded helpers. It starts no agent runners and acquires no project/store state. Duplex is selected in this app's own defaults domain.

Open the app with Finder or:

```sh
open "$HOME/array-scratch/apps/Array Sidebar.app"
```

Switch styles using **Array Sidebar → Settings…** (**⌘,**) → **Appearance → Sidebar → Active agent**. This presents the real Settings modal and changes both sample sidebars immediately through the normal setting event. It writes only this app's own defaults domain.

Quit with **⌘Q**, **Array Sidebar → Quit Array Sidebar**, or close both sample windows. The Desktop auto-layout app is a different bundle and remains independently usable.

Rebuild/relaunch from this bench when needed:

```sh
DEV_APP_PATH="$HOME/array-scratch/apps/Array Sidebar.app" \
DEV_PROJECT_ROOT="$HOME/array-scratch-sidebar-0745" \
DEV_APP_SUPPORT="$HOME/array-scratch-sidebar-0745-support" \
DEV_BUNDLE_ID=dev.arrayapp.macos.sidebar \
DEV_BUNDLE_NAME="Array Sidebar" \
scripts/dev-app.sh --env ARRAY_SIDEBAR_PREVIEW=1
```

For subsequent Finder opens, the bundle's sidebar identity enables the same sample mode. Targeted verification results are recorded alongside this guide after the merged build. No full matrix or push is part of this preview task.

## Verification on the merged preview

Builds: `swift build --product Array` and `swift build --product ContinuumRevivedCoreChecks` passed. 27 targeted app legs and 3 targeted Core legs passed. These cover the requested four flags, Classic/ownership/sort/shared-sidebar seams, 0.7.45 icon packs and their Settings/shared-menu/layout seams. No full matrix. Logs and per-leg results are under `qa-runs/sidebar-0745/verification.json`.

- `--sidebar-screenshot-check`: PASS
- `--inbox-parent-fold-check`: PASS
- `--sidebar-indicator-settings-check`: PASS
- `--agent-identity-color-check`: PASS
- `--sidebar-ownership-check`: PASS
- `--sidebar-sort-check`: PASS
- `--shared-agent-sidebar-check`: PASS
- `--sidebar-character-check`: PASS
- `--character-settings-check`: PASS
- `--character-size-check`: PASS
- `--found-character-themes-check`: PASS
- `--duckherd-theme-check`: PASS
- `--character-sounds-check`: PASS
- `--workspace-api-agent-character-check`: PASS
- `--character-themes-live-check`: PASS
- `--character-perf-check`: PASS
- `--lead-character-check`: PASS
- `--tile-character-check`: PASS
- `--transcript-character-check`: PASS
- `--character-sprite-check`: PASS
- `--shared-agent-chrome-check`: PASS
- `--settings-panel-check`: PASS
- `--settings-modal-check`: PASS
- `--settings-search-check`: PASS
- `--update-channel-check`: PASS
- `--agent-first-paint-check`: PASS
- `--agent-tile-fit-check`: PASS
- Core `--settings-schema-check`: PASS
- Core `--agent-character-theme-check`: PASS
- Core `--agent-character-pose-check`: PASS

Extended verification exposed a stale active-group cache when the open agent changed without table membership changing. The real Settings witness now closes/reopens its active lead and asserts the shared light follows it: RED before the ownership-slice refresh, GREEN after. It retains the actual mouse-event and fresh isolated preference reads.

The legacy ownership witness had two setup assumptions predating the preview defaults: an unspecified lead was expected folded, and helper tails were expected compact. It now explicitly folds that lead and chooses compact tails through real Show less controls. The expected row, rollup, timer and action assertions are unchanged. Initial failures and rerun results are retained in the verification report.

The separate preview uses only synthetic sample rows; it starts no agent sessions. The colour-picker bug remains unreproduced; passing the identity-colour leg is not a claim that the reported intermittent bug is fixed.
