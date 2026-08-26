import { describe, expect, test, vi } from 'vitest';
import { makeInitialState } from './fixture';
import { demoReducer } from './reducer';
import type { DemoAction, DemoState } from './types';

const finiteLayout = (state: DemoState) => {
  for (const item of [...Object.values(state.tiles), ...Object.values(state.zones)]) {
    expect(Object.values(item.frame).every(Number.isFinite)).toBe(true);
    expect(item.frame.width).toBeGreaterThan(0);
    expect(item.frame.height).toBeGreaterThan(0);
  }
  expect(state.browser.index).toBeGreaterThanOrEqual(0);
  expect(state.browser.index).toBeLessThan(state.browser.history.length);
};

describe('demo reducer', () => {
  test('canonical reset is a deep independent fixture', () => {
    const initial = makeInitialState();
    const changed = demoReducer(initial, { type: 'SET_AGENT_DRAFT', id: 'stabilize', draft: 'changed' });
    const reset = demoReducer(changed, { type: 'RESET' });
    expect(reset.agents.stabilize.draft).toBe('');
    expect(reset.tiles).not.toBe(initial.tiles);
  });

  test('tidy, shuffle, and undo preserve complete layout snapshots', () => {
    vi.setSystemTime(new Date('2026-08-24T12:00:00Z'));
    const initial = makeInitialState();
    const shuffledA = demoReducer(initial, { type: 'SHUFFLE', seed: 77 });
    const shuffledB = demoReducer(initial, { type: 'SHUFFLE', seed: 77 });
    expect(shuffledA.tiles).toEqual(shuffledB.tiles);
    const tidy = demoReducer(shuffledA, { type: 'TIDY' });
    expect(demoReducer(tidy, { type: 'UNDO' }).tiles).toEqual(shuffledA.tiles);
  });

  test('stale asynchronous operations cannot complete', () => {
    const initial = makeInitialState();
    const started = demoReducer(initial, { type: 'SEND_AGENT_MESSAGE', id: 'stabilize', message: 'test', operation: 3 });
    const stale = demoReducer(started, { type: 'ADVANCE_AGENT', id: 'stabilize', status: 'done', operation: 2 });
    expect(stale).toBe(started);
  });

  test('approval resolves once across both projections', () => {
    const initial = makeInitialState();
    const resolving = demoReducer(initial, { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'start' });
    const complete = demoReducer(resolving, { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'complete' });
    expect(complete.approval.state).toBe('accepted');
    expect(complete.agents.verify.status).toBe('working');
  });

  const actions: Array<[string, DemoAction]> = [
    ['activate', { type: 'SET_INPUT_MODE', mode: 'workspace' }], ['device focus', { type: 'SET_DEVICE_FOCUS', focus: 'companion' }], ['companion tab', { type: 'SET_COMPANION_TAB', tab: 'canvas' }], ['companion detail', { type: 'OPEN_COMPANION_AGENT', agentId: 'verify' }],
    ['sidebar', { type: 'SET_SIDEBAR', open: false }], ['agent query', { type: 'SET_AGENT_QUERY', query: 'zone' }], ['agent scope', { type: 'SET_AGENT_SCOPE', scope: 'working' }], ['selection', { type: 'SELECT_ENTITY', id: 'browser' }],
    ['camera', { type: 'SET_CAMERA', device: 'mac', camera: { x: 1, y: 2, zoom: .8 } }], ['move tile', { type: 'MOVE_TILE', id: 'browser', frame: { x: 1, y: 2, width: 300, height: 200 } }], ['resize tile', { type: 'RESIZE_TILE', id: 'browser', frame: { x: 1, y: 2, width: 340, height: 240 } }],
    ['close tile', { type: 'CLOSE_TILE', id: 'browser' }], ['reopen tile', { type: 'REOPEN_TILE', id: 'browser' }], ['raise tile', { type: 'RAISE_TILE', id: 'browser' }], ['move zone', { type: 'MOVE_ZONE', id: 'runtime', frame: { x: 1, y: 2, width: 700, height: 600 }, tileFrames: {} }],
    ['update zone', { type: 'UPDATE_ZONE', id: 'runtime', patch: { name: 'Runtime' } }], ['create zone', { type: 'CREATE_ZONE', zone: { id: 'new', name: 'New', color: 'blue', collapsed: false, frame: { x: 1, y: 2, width: 300, height: 200 } } }], ['close zone', { type: 'CLOSE_ZONE', id: 'companion' }],
    ['tidy', { type: 'TIDY' }], ['shuffle', { type: 'SHUFFLE', seed: 2 }], ['agent draft', { type: 'SET_AGENT_DRAFT', id: 'stabilize', draft: 'hello' }], ['agent config', { type: 'SET_AGENT_CONFIG', id: 'stabilize', field: 'effort', value: 'Low' }],
    ['stop agent', { type: 'STOP_AGENT', id: 'stabilize' }], ['restart agent', { type: 'RESTART_AGENT', id: 'stabilize' }], ['browser draft', { type: 'BROWSER_DRAFT', value: '/agents' }], ['browser navigate', { type: 'BROWSER_NAVIGATE', path: '/agents' }],
    ['browser history', { type: 'BROWSER_HISTORY', direction: 1 }], ['browser reload', { type: 'BROWSER_RELOAD', loading: true }], ['shell draft', { type: 'SHELL_DRAFT', value: 'help' }], ['shell execute', { type: 'SHELL_EXECUTE', command: 'help', operation: 4 }],
    ['shell history', { type: 'SHELL_HISTORY', direction: -1 }], ['note mode', { type: 'NOTE_MODE', mode: 'edit' }], ['note draft', { type: 'NOTE_DRAFT', value: '# Array' }], ['note commit', { type: 'NOTE_COMMIT' }], ['note cancel', { type: 'NOTE_CANCEL' }], ['note check', { type: 'NOTE_CHECK', index: 1 }],
    ['open command', { type: 'OPEN_COMMAND', open: true }], ['command query', { type: 'SET_COMMAND_QUERY', query: 'new' }], ['command step', { type: 'SET_COMMAND_STEP', step: 'model' }], ['spawn agent', { type: 'SPAWN_AGENT', model: 'GPT-5', effort: 'High' }], ['toast', { type: 'SET_TOAST', message: 'Done' }],
  ];
  test.each(actions)('%s action preserves invariants', (_name, action) => finiteLayout(demoReducer(makeInitialState(), action)));
});
