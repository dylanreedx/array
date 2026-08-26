import { makeInitialState } from './fixture';
import { tidyLayout } from './canvasGeometry';
import type { DemoAction, DemoState, Frame, ShellLine, Tile } from './types';

const cloneLayout = (state: DemoState) => ({ tiles: structuredClone(state.tiles), zones: structuredClone(state.zones) });
const withUndo = (state: DemoState, label: string): DemoState => ({ ...state, undo: { label, snapshot: cloneLayout(state), expiresAt: Date.now() + 6000 } });
const frame = (x: number, y: number, width: number, height: number): Frame => ({ x, y, width, height });

function shuffledTiles(state: DemoState, seed: number): Record<string, Tile> {
  let value = seed || 41;
  const random = () => ((value = (value * 1664525 + 1013904223) >>> 0) / 4294967296);
  return Object.fromEntries(Object.values(state.tiles).map((tile, index) => [tile.id, {
    ...tile,
    frame: { ...tile.frame, x: 90 + index * 155 + Math.round(random() * 70), y: 110 + (index % 3) * 175 + Math.round(random() * 50) },
    zoneId: index < 4 ? 'runtime' : 'companion'
  }]));
}

export function demoReducer(state: DemoState, action: DemoAction): DemoState {
  switch (action.type) {
    case 'SET_INPUT_MODE': return { ...state, inputMode: action.mode };
    case 'SET_DEVICE_FOCUS': return { ...state, deviceFocus: action.focus };
    case 'SET_COMPANION_TAB': return { ...state, companionTab: action.tab, companionAgentId: null };
    case 'OPEN_COMPANION_AGENT': return { ...state, companionAgentId: action.agentId };
    case 'SET_SIDEBAR': return { ...state, sidebarOpen: action.open };
    case 'SET_AGENT_QUERY': return { ...state, agentQuery: action.query };
    case 'SET_AGENT_SCOPE': return { ...state, agentScope: action.scope };
    case 'SELECT_ENTITY': return { ...state, selectedEntityId: action.id };
    case 'SET_CAMERA': return action.device === 'mac' ? { ...state, macCamera: action.camera } : { ...state, companionCamera: action.camera };
    case 'MOVE_TILE': return { ...state, tiles: { ...state.tiles, [action.id]: { ...state.tiles[action.id], frame: action.frame, zoneId: action.zoneId === undefined ? state.tiles[action.id].zoneId : action.zoneId } }, selectedEntityId: action.id };
    case 'RESIZE_TILE': return { ...state, tiles: { ...state.tiles, [action.id]: { ...state.tiles[action.id], frame: action.frame } } };
    case 'CLOSE_TILE': return { ...state, tiles: { ...state.tiles, [action.id]: { ...state.tiles[action.id], open: false } }, selectedEntityId: state.selectedEntityId === action.id ? null : state.selectedEntityId };
    case 'REOPEN_TILE': return { ...state, tiles: { ...state.tiles, [action.id]: { ...state.tiles[action.id], open: true, z: Math.max(...Object.values(state.tiles).map((tile) => tile.z)) + 1 } }, selectedEntityId: action.id };
    case 'RAISE_TILE': return { ...state, tiles: { ...state.tiles, [action.id]: { ...state.tiles[action.id], z: Math.max(...Object.values(state.tiles).map((tile) => tile.z)) + 1 } }, selectedEntityId: action.id };
    case 'MOVE_ZONE': return { ...state, zones: { ...state.zones, [action.id]: { ...state.zones[action.id], frame: action.frame } }, tiles: Object.fromEntries(Object.entries(state.tiles).map(([id, tile]) => [id, action.tileFrames[id] ? { ...tile, frame: action.tileFrames[id] } : tile])) };
    case 'UPDATE_ZONE': return { ...state, zones: { ...state.zones, [action.id]: { ...state.zones[action.id], ...action.patch } } };
    case 'CREATE_ZONE': return { ...state, zones: { ...state.zones, [action.zone.id]: action.zone }, selectedEntityId: action.zone.id, toast: 'Zone created' };
    case 'CLOSE_ZONE': return { ...withUndo(state, 'Close zone'), zones: Object.fromEntries(Object.entries(state.zones).filter(([id]) => id !== action.id)), tiles: Object.fromEntries(Object.entries(state.tiles).map(([id, tile]) => [id, tile.zoneId === action.id ? { ...tile, zoneId: null } : tile])), toast: 'Zone closed · tiles moved to canvas' };
    case 'TIDY': {
      const next = withUndo(state, 'Tidy workspace');
      const layout = tidyLayout(state.tiles, state.zones);
      return { ...next, ...layout, toast: `Auto layout arranged ${Object.values(state.tiles).filter((tile) => tile.open).length} items` };
    }
    case 'SHUFFLE': return { ...withUndo(state, 'Shuffle workspace'), tiles: shuffledTiles(state, action.seed ?? 41), toast: 'Workspace shuffled' };
    case 'UNDO': return state.undo ? { ...state, tiles: state.undo.snapshot.tiles, zones: state.undo.snapshot.zones, undo: null, toast: 'Layout restored' } : state;
    case 'SET_AGENT_DRAFT': return { ...state, agents: { ...state.agents, [action.id]: { ...state.agents[action.id], draft: action.draft } } };
    case 'SEND_AGENT_MESSAGE': return { ...state, operationGeneration: action.operation, agents: { ...state.agents, [action.id]: { ...state.agents[action.id], draft: '', status: 'starting', summary: 'Starting a new turn', transcript: [...state.agents[action.id].transcript, { id: `user-${action.operation}`, kind: 'user', text: action.message }] } } };
    case 'ADVANCE_AGENT': if (action.operation !== state.operationGeneration) return state; else return { ...state, agents: { ...state.agents, [action.id]: { ...state.agents[action.id], status: action.status, summary: action.entry?.text ?? state.agents[action.id].summary, transcript: action.entry ? [...state.agents[action.id].transcript, action.entry] : state.agents[action.id].transcript } } };
    case 'SET_AGENT_CONFIG': return { ...state, agents: { ...state.agents, [action.id]: { ...state.agents[action.id], [action.field]: action.value } } };
    case 'STOP_AGENT': return { ...state, agents: { ...state.agents, [action.id]: { ...state.agents[action.id], status: 'stopped', summary: 'Agent stopped from the demo' } }, toast: 'Agent stopped' };
    case 'RESTART_AGENT': return { ...state, agents: { ...state.agents, [action.id]: { ...state.agents[action.id], status: 'working', summary: 'Agent restarted' } }, toast: 'Agent restarted' };
    case 'RESOLVE_APPROVAL': {
      if (action.phase === 'start') return { ...state, approval: { ...state.approval, state: 'resolving' } };
      if (action.phase === 'error') return { ...state, approval: { ...state.approval, state: 'error' }, toast: 'Approval response unavailable' };
      const status = action.decision === 'accept' ? 'working' : 'done';
      return { ...state, approval: { ...state.approval, state: action.decision === 'accept' ? 'accepted' : 'declined' }, agents: { ...state.agents, verify: { ...state.agents.verify, status, summary: action.decision === 'accept' ? 'Running the approved iOS verification' : 'Verification request declined' } }, toast: action.decision === 'accept' ? 'Approved on Companion' : 'Request denied' };
    }
    case 'BROWSER_DRAFT': return { ...state, browser: { ...state.browser, addressDraft: action.value } };
    case 'BROWSER_NAVIGATE': {
      const history = [...state.browser.history.slice(0, state.browser.index + 1), action.path];
      return { ...state, browser: { ...state.browser, history, index: history.length - 1, addressDraft: action.path } };
    }
    case 'BROWSER_HISTORY': {
      const index = Math.min(state.browser.history.length - 1, Math.max(0, state.browser.index + action.direction));
      return { ...state, browser: { ...state.browser, index, addressDraft: state.browser.history[index] } };
    }
    case 'BROWSER_RELOAD': return { ...state, browser: { ...state.browser, loading: action.loading } };
    case 'SHELL_DRAFT': return { ...state, shell: { ...state.shell, draft: action.value } };
    case 'SHELL_EXECUTE': {
      const prompt: ShellLine = { id: `prompt-${action.operation}`, type: 'prompt', text: action.command };
      return { ...state, operationGeneration: action.operation, shell: { ...state.shell, draft: '', lines: action.command === 'clear' ? [] : [...state.shell.lines, prompt], history: action.command === 'clear' ? state.shell.history : [...state.shell.history, action.command], historyIndex: -1, running: action.command !== 'clear' } };
    }
    case 'SHELL_COMPLETE': if (action.operation !== state.operationGeneration) return state; else return { ...state, shell: { ...state.shell, lines: [...state.shell.lines, ...action.lines], running: false } };
    case 'SHELL_HISTORY': {
      const history = state.shell.history;
      if (!history.length) return state;
      const current = state.shell.historyIndex < 0 ? history.length : state.shell.historyIndex;
      const historyIndex = Math.max(0, Math.min(history.length - 1, current + action.direction));
      return { ...state, shell: { ...state.shell, historyIndex, draft: history[historyIndex] } };
    }
    case 'NOTE_MODE': return { ...state, note: { ...state.note, mode: action.mode } };
    case 'NOTE_DRAFT': return { ...state, note: { ...state.note, draft: action.value } };
    case 'NOTE_COMMIT': return { ...state, note: { ...state.note, committed: state.note.draft, mode: 'preview' }, toast: 'Note saved' };
    case 'NOTE_CANCEL': return { ...state, note: { ...state.note, draft: state.note.committed, mode: 'preview' } };
    case 'NOTE_CHECK': return { ...state, note: { ...state.note, checks: state.note.checks.map((value, index) => index === action.index ? !value : value) } };
    case 'OPEN_COMMAND': return { ...state, commandOpen: action.open, commandQuery: action.query ?? '', commandStep: 'root', pendingAgentModel: null, pendingAgentEffort: null };
    case 'SET_COMMAND_QUERY': return { ...state, commandQuery: action.query };
    case 'SET_COMMAND_STEP': return { ...state, commandStep: action.step, pendingAgentModel: action.step === 'effort' ? action.value ?? state.pendingAgentModel : state.pendingAgentModel, pendingAgentEffort: action.step === 'root' ? null : state.pendingAgentEffort };
    case 'SPAWN_AGENT': {
      const id = `agent-${Object.keys(state.agents).length + 1}`;
      return { ...state, agents: { ...state.agents, [id]: { id, tileId: id, name: 'New agent', branch: 'agent/new-task', provider: 'Codex', model: action.model, effort: action.effort, status: 'idle', summary: 'Ready for a prompt', draft: '', transcript: [] } }, tiles: { ...state.tiles, [id]: { id, kind: 'agent', title: 'New agent', zoneId: 'runtime', frame: frame(250, 220, 330, 260), z: 20, open: true } }, commandOpen: false, commandStep: 'root', selectedEntityId: id, toast: 'New agent added' };
    }
    case 'SET_TOAST': return { ...state, toast: action.message };
    case 'RESET': return { ...makeInitialState(), inputMode: state.inputMode, deviceFocus: state.deviceFocus, operationGeneration: state.operationGeneration + 1, toast: 'Demo reset' };
  }
}
