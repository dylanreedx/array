import { describe, expect, test } from 'vitest';
import { DEMO_TEXT, guidedSnapshot, STEPS } from './guided-demo';
const desktop = { width: 1440, height: 900 };
const mobile = { width: 390, height: 760 };

describe('native golden workspace flow', () => {
  test('five supporting tiles preexist; main birth follows both palette levels', () => {
    const initial = guidedSnapshot(.26, desktop);
    expect(initial.mainCreated).toBe(false);
    expect(initial.tileFrames.stabilize.visible).toBe(false);
    expect(Object.values(initial.tileFrames).filter(frame => frame.visible)).toHaveLength(5);
    expect(guidedSnapshot(.29, desktop)).toMatchObject({ creation: { stage: 'command', query: 'Agent' }, menu: 'toolbar', cursorTarget: 'command-agent' });
    expect(guidedSnapshot(.32, desktop)).toMatchObject({ creation: { stage: 'models', model: 'GPT-5.6 Sol' }, menu: 'models', mainCreated: false, cursorTarget: 'creation-model' });
    expect(guidedSnapshot(.35, desktop)).toMatchObject({ creation: { stage: 'spawning' }, mainCreated: true, selectedTile: 'stabilize' });
    expect(guidedSnapshot(.40, desktop)).toMatchObject({ creation: { stage: 'focused' }, focusedTile: 'stabilize', menu: null });
    expect(guidedSnapshot(.44, desktop)).toMatchObject({ creation: { stage: 'sent' }, status: { stabilize: 'Working' } });
  });
  test('camera and focus settle before each prompt, then hold while typing', () => {
    for (const [id, start, middle, end] of [
      ['stabilize', .38, .40, .425], ['verify', .51, .53, .55], ['audit', .56, .575, .595],
    ] as const) {
      const before = guidedSnapshot(start, desktop), during = guidedSnapshot(middle, desktop), complete = guidedSnapshot(end, desktop);
      expect(during.focusedTile).toBe(id);
      expect(during.camera).toEqual(before.camera);
      expect(complete.camera).toEqual(before.camera);
      const frame = during.tileFrames[id];
      expect(during.camera.center).toEqual({ x: frame.x + frame.width / 2, y: frame.y + frame.height / 2 });
      expect(during.typing[id].length).toBeGreaterThan(0);
      expect(during.typing[id].length).toBeLessThan(DEMO_TEXT[id].length);
      expect(complete.typing[id]).toBe(DEMO_TEXT[id]);
    }
    expect(guidedSnapshot(.38, desktop).typing.stabilize).toBe('');
  });
  test('reverse/direct jumps restore the entire creation and gesture state', () => {
    for (const point of [.29, .32, .4, .64, .885, .945]) {
      const expected = guidedSnapshot(point, desktop);
      for (const p of [.99, .2, .91, .47, point]) guidedSnapshot(p, desktop);
      expect(guidedSnapshot(point, desktop)).toEqual(expected);
    }
    expect(guidedSnapshot(.2, desktop).mainCreated).toBe(false);
    expect(guidedSnapshot(.2, desktop).typing.stabilize).toBe('');
  });
  test('Claude verification approval belongs to verify and resolves on the action', () => {
    const waiting = guidedSnapshot(.64, desktop);
    expect(waiting).toMatchObject({ focusedTile: 'verify', status: { verify: 'Needs approval' }, approval: 'waiting', cursorTarget: 'verify-allow' });
    expect(guidedSnapshot(.68, desktop).approval).toBe('approved');
    expect(guidedSnapshot(.58, desktop).approval).toBe('hidden');
    expect(guidedSnapshot(.90, desktop).status).toEqual({ stabilize: 'Complete', verify: 'Passed', audit: 'Complete' });
  });
  test('native drag moves the actual frame; snap ghost and neighbor reflow are separate', () => {
    const start = guidedSnapshot(.865, desktop), dragging = guidedSnapshot(.885, desktop), settled = guidedSnapshot(.915, desktop);
    expect(dragging.cursorTarget).toBe('stabilize-header');
    expect(dragging.tileFrames.stabilize.drag).toEqual({ active: true, lift: 0, rotation: 0, scaleX: 1, scaleY: 1 });
    expect(dragging.tileFrames.stabilize.x).toBeGreaterThan(start.tileFrames.stabilize.x);
    expect(dragging.snapPreview).toMatchObject({ tile: 'stabilize', x: 550, y: 95, scale: 1, opacity: 1 });
    expect(settled.snapPreview).toBeNull();
    expect(settled.tileFrames.verify.x).toBe(70);
    expect(settled.tileFrames.stabilize.x).toBe(start.tileFrames.verify.x);
    expect(settled.tileFrames.audit.x).toBe(start.tileFrames.audit.x);
    expect(settled.tileFrames.stabilize.drag.active).toBe(false);
  });
  test('drag pushes baseline neighbors before latching, and relaxes the cascade after swapping', () => {
    const baseline = guidedSnapshot(.865, desktop);
    for (const p of [.877, .880, .885]) {
      const frames = guidedSnapshot(p, desktop).tileFrames;
      expect(frames.stabilize.x + frames.stabilize.width / 2).toBeLessThan(550);
      expect(frames.verify.x).toBe(Math.max(550, frames.stabilize.x + frames.stabilize.width + 8));
      expect(frames.audit.x).toBe(Math.max(980, frames.verify.x + frames.verify.width + 8));
      expect(frames.shell.x).toBe(Math.max(1370, frames.audit.x + frames.audit.width + 8));
      for (const [left, right] of [['stabilize', 'verify'], ['verify', 'audit'], ['audit', 'shell']] as const) {
        expect(frames[right].x - (frames[left].x + frames[left].width)).toBeGreaterThanOrEqual(8 - 1e-9);
      }
    }
    const pushed = guidedSnapshot(.885, desktop);
    expect(pushed.tileFrames.verify.x).toBeGreaterThan(baseline.tileFrames.verify.x);
    expect(pushed.tileFrames.audit.x).toBeGreaterThan(baseline.tileFrames.audit.x);
    expect(pushed.tileFrames.shell.x).toBeGreaterThan(baseline.tileFrames.shell.x);
    const exchanged = guidedSnapshot(.915, desktop);
    expect(exchanged.tileFrames.verify).toMatchObject({ x: 70, y: 90 });
    expect(exchanged.tileFrames.audit.x).toBe(baseline.tileFrames.audit.x);
    expect(exchanged.tileFrames.shell.x).toBe(baseline.tileFrames.shell.x);
    // Retreat/direct seek recomputes from the gesture baseline, not last solve.
    guidedSnapshot(.915, desktop);
    expect(guidedSnapshot(.885, desktop)).toEqual(pushed);
  });
  test('editor reorganization and live resize commit varied frames and content dimensions', () => {
    const start = guidedSnapshot(.905, desktop), moved = guidedSnapshot(.925, desktop), resizing = guidedSnapshot(.945, desktop), final = guidedSnapshot(.97, desktop);
    expect(start.selectedTile).toBe('browser');
    expect(moved.tileFrames.browser.x).toBeGreaterThan(start.tileFrames.browser.x);
    expect(resizing.cursorTarget).toBe('editor-resize');
    expect(resizing.tileFrames.browser.width).toBeGreaterThan(moved.tileFrames.browser.width);
    expect(resizing.resizeReadout).toEqual({ width: Math.round(resizing.tileFrames.browser.width), height: Math.round(resizing.tileFrames.browser.height - 24) });
    expect(final.tileFrames.browser).toMatchObject({ x: 970, y: 690, width: 620, height: 390 });
    expect(final.resizeReadout).toBeNull();
    expect(final.tileFrames.stabilize).toMatchObject({ width: 430, height: 550 });
    expect(final.tileFrames.verify).toMatchObject({ width: 380, height: 470 });
    expect(final.tileFrames.audit).toMatchObject({ width: 340, height: 450 });
  });
  test('mobile editor sizing comes from the same resize state, without CSS overrides', () => {
    expect(guidedSnapshot(.92, mobile).tileFrames.browser.width).toBe(330);
    expect(guidedSnapshot(.945, mobile).tileFrames.browser.width).toBeGreaterThan(330);
    expect(guidedSnapshot(.97, mobile).tileFrames.browser.width).toBe(350);
    const detail = guidedSnapshot(.765, mobile);
    expect(detail.boardDetail).toBe(true);
    expect(detail.camera.center).toEqual({ x: 285, y: 860 });
    expect(detail.camera.scale * 430).toBeLessThan(mobile.width);
  });
  test('same six mounted identities remain visible after main creation', () => {
    const ids = ['audit', 'browser', 'note', 'shell', 'stabilize', 'verify'];
    for (const p of [.35, .64, .80, .885, .945, .99]) {
      const state = guidedSnapshot(p, desktop);
      expect(Object.keys(state.tileFrames).sort()).toEqual(ids);
      expect(Object.values(state.tileFrames).every(frame => frame.visible)).toBe(true);
      expect(Object.values(state.tiles).every(tile => tile.opacity === 1 && tile.rotation === 0 && tile.scale === 1)).toBe(true);
    }
  });
  test('camera transitions stay continuous at narrative boundaries', () => {
    for (const step of STEPS.slice(1)) {
      const before = guidedSnapshot(step.start - 1e-8, desktop).camera, after = guidedSnapshot(step.start, desktop).camera;
      expect(Math.abs(after.x - before.x)).toBeLessThan(.01);
      expect(Math.abs(after.y - before.y)).toBeLessThan(.01);
      expect(Math.abs(after.scale - before.scale)).toBeLessThan(.001);
    }
  });
  test('reduced motion is an ordinary complete scene with no active gesture', () => {
    const state = guidedSnapshot(0, { ...mobile, reducedMotion: true });
    expect(state).toEqual(guidedSnapshot(.64, { ...mobile, reducedMotion: true }));
    expect(state.mainCreated).toBe(true);
    expect(state.typing).toEqual(DEMO_TEXT);
    expect(state.cursor.visible).toBe(false);
    expect(state.menu).toBeNull();
    expect(state.snapPreview).toBeNull();
    expect(state.resizeReadout).toBeNull();
    expect(Object.values(state.tileFrames).every(frame => !frame.drag.active && frame.visible)).toBe(true);
  });
  test('hero clears before creation and malformed seeks remain finite', () => {
    expect(guidedSnapshot(.18, desktop).heroOpacity).toBe(0);
    expect(guidedSnapshot(.26, desktop).takeover).toBe(1);
    for (const p of [NaN, Infinity, -3, 4]) {
      const state = guidedSnapshot(p, desktop);
      expect(Number.isFinite(state.camera.x + state.camera.y + state.camera.scale)).toBe(true);
      expect(state.progress).toBeGreaterThanOrEqual(0);
      expect(state.progress).toBeLessThanOrEqual(1);
    }
  });
});
