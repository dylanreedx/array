export interface InteractionContractEntry {
  id: string;
  component: string;
  trigger: string;
  action: string;
  visibleFeedback: string;
  disabledReason?: string;
  accessibility: string;
  testCase: string;
}

const entry = (id: string, component: string, action: string): InteractionContractEntry => ({
  id, component, trigger: 'activate', action, visibleFeedback: action,
  accessibility: 'Named native control with visible focus', testCase: id
});

export const interactionContract = [
  entry('nav-logo', 'SiteHeader', 'Navigate home'), entry('theme-toggle', 'ThemeToggle', 'Switch theme'),
  entry('download-main', 'DownloadSplit', 'Download Mac DMG'), entry('download-trigger', 'DownloadSplit', 'Open product menu'), entry('download-mac', 'DownloadSplit', 'Download Mac DMG'),
  entry('hero-see-all', 'Hero', 'Reveal full demo'), entry('ready-enter', 'DemoReadyGate', 'Activate canvas'), entry('ready-continue', 'DemoReadyGate', 'Continue page scrolling'), entry('explore-workspace', 'Demo', 'Activate canvas'), entry('done-exploring', 'Demo', 'Release canvas'),
  entry('device-focus-mac', 'DeviceFocus', 'Focus Mac'), entry('device-focus-companion', 'DeviceFocus', 'Focus Companion'), entry('sidebar-toggle', 'MacWorkspace', 'Toggle sidebar'),
  entry('command-open', 'MacWorkspace', 'Open Command Center'), entry('command-new', 'MacWorkspace', 'Open creation commands'), entry('agent-search', 'AgentSidebar', 'Filter agents'), entry('agent-scope', 'AgentSidebar', 'Filter status'),
  entry('canvas-fit', 'Canvas', 'Fit all'), entry('canvas-zoom-in', 'Canvas', 'Zoom in'), entry('canvas-zoom-out', 'Canvas', 'Zoom out'), entry('canvas-tidy', 'Canvas', 'Tidy workspace'),
  entry('canvas-shuffle', 'Canvas', 'Shuffle workspace'), entry('canvas-new-zone', 'Canvas', 'Create zone'), entry('canvas-surface', 'Canvas', 'Pan and zoom workspace'), entry('reset-demo', 'Demo', 'Reset demo'), entry('toast-undo', 'Toast', 'Undo layout'),
  entry('approval-approve', 'Approval', 'Approve request'), entry('approval-deny', 'Approval', 'Deny request'), entry('companion-fit', 'CompanionCanvas', 'Fit all'), entry('companion-zoom-in', 'CompanionCanvas', 'Zoom in'), entry('companion-zoom-out', 'CompanionCanvas', 'Zoom out'),
  entry('companion-agent-back', 'CompanionAgent', 'Return to agents'), entry('companion-show-on-canvas', 'CompanionAgent', 'Show agent on read-only canvas'), entry('companion-canvas-pan-zoom', 'CompanionCanvas', 'Pan and zoom locally'),
  entry('command-search', 'CommandCenter', 'Search commands'), entry('command-close', 'CommandCenter', 'Close Command Center'), entry('command-back', 'CommandCenter', 'Return one step'), entry('command-backdrop', 'CommandCenter', 'Dismiss Command Center'),
  entry('browser-back', 'BrowserTile', 'Go back'), entry('browser-forward', 'BrowserTile', 'Go forward'), entry('browser-reload', 'BrowserTile', 'Reload local page'), entry('browser-address', 'BrowserTile', 'Navigate local fixture'), entry('browser-page', 'BrowserTile', 'Navigate local link'),
  entry('shell-input', 'ShellTile', 'Run scripted command'), entry('note-edit', 'Note', 'Edit note'), entry('note-preview', 'Note', 'Preview note'), entry('note-input', 'Note', 'Change note draft'), entry('note-check', 'Note', 'Toggle checklist'), entry('note-done', 'Note', 'Save note'), entry('note-cancel', 'Note', 'Cancel edit'),
  entry('workspace-overflow', 'MacWorkspace', 'Open workspace actions'), entry('workspace-fit', 'MacWorkspace', 'Fit canvas'), entry('workspace-tidy', 'MacWorkspace', 'Tidy workspace'), entry('footer-home', 'Footer', 'Navigate home'), entry('footer-release-feed', 'Footer', 'Open release feed')
] as const;

export const interactionIds = new Set(interactionContract.map((item) => item.id));

export const interactionPrefixes = [
  'agent-row-', 'agent-actions-', 'agent-restart-', 'agent-stop-', 'agent-close-', 'agent-provider-', 'agent-model-', 'agent-effort-', 'agent-transcript-', 'agent-composer-', 'agent-send-',
  'tile-reopen-', 'tile-drag-', 'tile-resize-', 'tile-overflow-', 'tile-close-', 'tile-focus-', 'tile-forward-', 'tile-zone-', 'tile-menu-close-',
  'zone-drag-', 'zone-resize-', 'zone-collapse-', 'zone-overflow-', 'zone-rename-', 'zone-color-', 'zone-tidy-', 'zone-close-',
  'command-item-', 'companion-tab-', 'companion-agent-', 'companion-tile-'
] as const;

export const isInteractionRegistered = (id: string) => interactionIds.has(id as never) || interactionPrefixes.some((prefix) => id.startsWith(prefix));
