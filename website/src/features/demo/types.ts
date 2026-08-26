export type ID = string;
export type DeviceFocus = 'mac' | 'companion';
export type WorkspaceInputMode = 'page' | 'workspace';
export type AgentStatus = 'idle' | 'starting' | 'working' | 'needsAttention' | 'stopped' | 'done';
export type CompanionTab = 'agents' | 'canvas' | 'approvals' | 'settings';
export type TileKind = 'agent' | 'browser' | 'shell' | 'note';

export interface Frame { x: number; y: number; width: number; height: number }
export interface CameraState { x: number; y: number; zoom: number }
export interface Zone { id: ID; name: string; color: 'mint' | 'blue' | 'purple' | 'orange'; frame: Frame; collapsed: boolean }
export interface Tile { id: ID; kind: TileKind; title: string; zoneId: ID | null; frame: Frame; z: number; open: boolean }
export interface TranscriptEntry { id: ID; kind: 'user' | 'assistant' | 'tool' | 'output' | 'notice'; text: string; expanded?: boolean }
export interface Agent {
  id: ID; tileId: ID; name: string; branch: string; provider: string; model: string; effort: string;
  status: AgentStatus; summary: string; draft: string; transcript: TranscriptEntry[];
}
export interface Approval { id: ID; agentId: ID; title: string; detail: string; state: 'pending' | 'resolving' | 'accepted' | 'declined' | 'error' }
export interface BrowserState { history: string[]; index: number; addressDraft: string; loading: boolean }
export interface ShellLine { id: ID; type: 'prompt' | 'output' | 'success' | 'error'; text: string }
export interface ShellState { draft: string; lines: ShellLine[]; history: string[]; historyIndex: number; running: boolean }
export interface NoteState { mode: 'edit' | 'preview'; draft: string; committed: string; checks: boolean[] }
export interface UndoState { label: string; snapshot: Pick<DemoState, 'tiles' | 'zones'>; expiresAt: number }

export interface DemoState {
  zones: Record<ID, Zone>;
  tiles: Record<ID, Tile>;
  agents: Record<ID, Agent>;
  approval: Approval;
  browser: BrowserState;
  shell: ShellState;
  note: NoteState;
  macCamera: CameraState;
  companionCamera: CameraState;
  selectedEntityId: ID | null;
  deviceFocus: DeviceFocus;
  companionTab: CompanionTab;
  companionAgentId: ID | null;
  sidebarOpen: boolean;
  agentQuery: string;
  agentScope: 'all' | 'working' | 'attention' | 'done';
  commandOpen: boolean;
  commandQuery: string;
  commandStep: 'root' | 'model' | 'effort';
  pendingAgentModel: string | null;
  pendingAgentEffort: string | null;
  inputMode: WorkspaceInputMode;
  undo: UndoState | null;
  toast: string | null;
  operationGeneration: number;
}

export type DemoAction =
  | { type: 'SET_INPUT_MODE'; mode: WorkspaceInputMode }
  | { type: 'SET_DEVICE_FOCUS'; focus: DeviceFocus }
  | { type: 'SET_COMPANION_TAB'; tab: CompanionTab }
  | { type: 'OPEN_COMPANION_AGENT'; agentId: ID | null }
  | { type: 'SET_SIDEBAR'; open: boolean }
  | { type: 'SET_AGENT_QUERY'; query: string }
  | { type: 'SET_AGENT_SCOPE'; scope: DemoState['agentScope'] }
  | { type: 'SELECT_ENTITY'; id: ID | null }
  | { type: 'SET_CAMERA'; device: DeviceFocus; camera: CameraState }
  | { type: 'MOVE_TILE'; id: ID; frame: Frame; zoneId?: ID | null }
  | { type: 'RESIZE_TILE'; id: ID; frame: Frame }
  | { type: 'CLOSE_TILE'; id: ID }
  | { type: 'REOPEN_TILE'; id: ID }
  | { type: 'RAISE_TILE'; id: ID }
  | { type: 'MOVE_ZONE'; id: ID; frame: Frame; tileFrames: Record<ID, Frame> }
  | { type: 'UPDATE_ZONE'; id: ID; patch: Partial<Pick<Zone, 'name' | 'color' | 'collapsed' | 'frame'>> }
  | { type: 'CREATE_ZONE'; zone: Zone }
  | { type: 'CLOSE_ZONE'; id: ID }
  | { type: 'TIDY' }
  | { type: 'SHUFFLE'; seed?: number }
  | { type: 'UNDO' }
  | { type: 'SET_AGENT_DRAFT'; id: ID; draft: string }
  | { type: 'SEND_AGENT_MESSAGE'; id: ID; message: string; operation: number }
  | { type: 'ADVANCE_AGENT'; id: ID; status: AgentStatus; entry?: TranscriptEntry; operation: number }
  | { type: 'SET_AGENT_CONFIG'; id: ID; field: 'provider' | 'model' | 'effort'; value: string }
  | { type: 'STOP_AGENT'; id: ID }
  | { type: 'RESTART_AGENT'; id: ID }
  | { type: 'RESOLVE_APPROVAL'; decision: 'accept' | 'decline'; phase: 'start' | 'complete' | 'error' }
  | { type: 'BROWSER_DRAFT'; value: string }
  | { type: 'BROWSER_NAVIGATE'; path: string }
  | { type: 'BROWSER_HISTORY'; direction: -1 | 1 }
  | { type: 'BROWSER_RELOAD'; loading: boolean }
  | { type: 'SHELL_DRAFT'; value: string }
  | { type: 'SHELL_EXECUTE'; command: string; operation: number }
  | { type: 'SHELL_COMPLETE'; lines: ShellLine[]; operation: number }
  | { type: 'SHELL_HISTORY'; direction: -1 | 1 }
  | { type: 'NOTE_MODE'; mode: NoteState['mode'] }
  | { type: 'NOTE_DRAFT'; value: string }
  | { type: 'NOTE_COMMIT' }
  | { type: 'NOTE_CANCEL' }
  | { type: 'NOTE_CHECK'; index: number }
  | { type: 'OPEN_COMMAND'; open: boolean; query?: string }
  | { type: 'SET_COMMAND_QUERY'; query: string }
  | { type: 'SET_COMMAND_STEP'; step: DemoState['commandStep']; value?: string }
  | { type: 'SPAWN_AGENT'; model: string; effort: string }
  | { type: 'SET_TOAST'; message: string | null }
  | { type: 'RESET' };
