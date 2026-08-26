import type { DemoState } from './types';

export const DOWNLOAD_URL = 'https://github.com/dylanreedx/array-releases/releases/latest/download/Array.dmg';

export const canonicalCopy = {
  headline: 'Keep every agent in view.',
  body: 'Launch agents and tools from anywhere. Array keeps everything they touch visible on one native workspace.',
  primary: 'Download for Mac',
  secondary: 'See all of it ↓',
  requirements: 'macOS 14+ · Apple silicon · Free during alpha'
} as const;

export function makeInitialState(): DemoState {
  return {
    zones: {
      runtime: { id: 'runtime', name: 'Canvas Runtime', color: 'mint', frame: { x: 72, y: 68, width: 760, height: 590 }, collapsed: false },
      companion: { id: 'companion', name: 'Companion', color: 'orange', frame: { x: 858, y: 140, width: 400, height: 570 }, collapsed: false }
    },
    tiles: {
      stabilize: { id: 'stabilize', kind: 'agent', title: 'Stabilize zone placement', zoneId: 'runtime', frame: { x: 112, y: 132, width: 330, height: 330 }, z: 5, open: true },
      browser: { id: 'browser', kind: 'browser', title: 'Canvas interaction spec', zoneId: 'runtime', frame: { x: 470, y: 116, width: 320, height: 230 }, z: 4, open: true },
      shell: { id: 'shell', kind: 'shell', title: 'Array build', zoneId: 'runtime', frame: { x: 470, y: 368, width: 320, height: 170 }, z: 3, open: true },
      note: { id: 'note', kind: 'note', title: '0.5 release checklist', zoneId: 'runtime', frame: { x: 112, y: 482, width: 330, height: 160 }, z: 2, open: true },
      verify: { id: 'verify', kind: 'agent', title: 'Verify approval handoff', zoneId: 'companion', frame: { x: 892, y: 208, width: 330, height: 300 }, z: 6, open: true },
      audit: { id: 'audit', kind: 'agent', title: 'Audit native tokens', zoneId: 'companion', frame: { x: 892, y: 532, width: 330, height: 150 }, z: 1, open: true }
    },
    agents: {
      stabilize: {
        id: 'stabilize', tileId: 'stabilize', name: 'Stabilize zone placement', branch: 'agent/zone-placement',
        provider: 'Codex', model: 'GPT-5', effort: 'High', status: 'working', summary: 'Verifying world and zone-local frames', draft: '',
        transcript: [
          { id: 's1', kind: 'user', text: 'Keep placement stable when the active zone changes.' },
          { id: 's2', kind: 'assistant', text: 'I am tracing the placement boundary and its persistence witness.' },
          { id: 's3', kind: 'tool', text: 'swift test · CanvasSceneEditTests', expanded: true },
          { id: 's4', kind: 'output', text: '18 checks passed · 0 regressions', expanded: true }
        ]
      },
      verify: {
        id: 'verify', tileId: 'verify', name: 'Verify approval handoff', branch: 'agent/companion-approval',
        provider: 'Claude Code', model: 'Claude Opus', effort: 'Medium', status: 'needsAttention', summary: 'Approval required for the iOS verification run', draft: '',
        transcript: [
          { id: 'v1', kind: 'assistant', text: 'The paired session is live. The simulator verification requires approval.' },
          { id: 'v2', kind: 'notice', text: 'Approval requested · xcodebuild CompanionUITests' }
        ]
      },
      audit: {
        id: 'audit', tileId: 'audit', name: 'Audit native tokens', branch: 'agent/token-audit', provider: 'Pi', model: 'Auto', effort: 'Low',
        status: 'done', summary: 'Native surface and text roles match', draft: '', transcript: [{ id: 'a1', kind: 'assistant', text: 'Token parity audit complete.' }]
      }
    },
    approval: { id: 'approval-ios', agentId: 'verify', title: 'Run the Companion verification?', detail: 'xcodebuild test · iPhone 16 Pro simulator', state: 'pending' },
    browser: { history: ['/canvas'], index: 0, addressDraft: '/canvas', loading: false },
    shell: {
      draft: '', history: [], historyIndex: 0, running: false,
      lines: [
        { id: 'l1', type: 'prompt', text: 'swift build' },
        { id: 'l2', type: 'success', text: 'Build complete! (2.4s)' },
        { id: 'l3', type: 'output', text: 'Ready for the next command.' }
      ]
    },
    note: {
      mode: 'preview',
      committed: '# Array 0.5\n\n- Verify zone placement\n- Approve Companion handoff\n- Run Safari motion pass',
      draft: '# Array 0.5\n\n- Verify zone placement\n- Approve Companion handoff\n- Run Safari motion pass',
      checks: [true, false, false]
    },
    macCamera: { x: 0, y: 0, zoom: 0.78 }, companionCamera: { x: 0, y: 0, zoom: 0.34 },
    selectedEntityId: 'stabilize', deviceFocus: 'mac', companionTab: 'agents', companionAgentId: null,
    sidebarOpen: true, agentQuery: '', agentScope: 'all', commandOpen: false, commandQuery: '', commandStep: 'root', pendingAgentModel: null, pendingAgentEffort: null,
    inputMode: 'page', undo: null, toast: null, operationGeneration: 0
  };
}
