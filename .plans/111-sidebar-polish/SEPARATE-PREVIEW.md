# Separate sidebar preview on 0.7.45

The sidebar preview merges `origin/array/integration` at `5e97ca92` (0.7.45, build 96). The only merge conflict was the matrix inventory: retain `--sidebar-indicator-settings-check` while accepting upstream removal of the obsolete `--sidebar-lifecycle-check` text pin. Settings code merged with both the Active agent choice and 0.7.45's Agent Icons page/update-channel control intact.

The separate app is `~/array-scratch/apps/Array Sidebar.app`, bundle ID `dev.arrayapp.macos.sidebar`. It uses `~/array-scratch-sidebar-0745` as its project root and `~/array-scratch-sidebar-0745-support` as its isolated app support. It never shares the Desktop preview's project or dev store. The existing `ARRAY_SIDEBAR_PREVIEW` mode presents two interactive production sidebars with sample agents in light and dark; a coloured lead opens with three expanded helpers. It starts no agent runners and acquires no project/store state. Duplex is selected in this app's own defaults domain.

Open the app with Finder or:

```sh
open "$HOME/array-scratch/apps/Array Sidebar.app"
```

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
