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
    const start = guidedSnapshot(.873, desktop), dragging = guidedSnapshot(.884, desktop), settled = guidedSnapshot(.915, desktop);
    expect(dragging.cursorTarget).toBe('stabilize-header');
    expect(dragging.tileFrames.stabilize.drag).toEqual({ active: true, lift: 0, rotation: 0, scaleX: 1, scaleY: 1 });
    expect(dragging.tileFrames.stabilize.x).toBeGreaterThan(start.tileFrames.stabilize.x);
    expect(dragging.snapPreview).toMatchObject({ tile: 'stabilize', x: 550, y: 95, scale: expect.any(Number), opacity: expect.any(Number) });
    expect(settled.snapPreview).toMatchObject({ tile: 'browser' });
    expect(settled.tileFrames.verify.x).toBe(70);
    expect(settled.tileFrames.stabilize.x).toBe(start.tileFrames.verify.x);
    expect(settled.tileFrames.audit.x).toBe(988);
    expect(settled.tileFrames.stabilize.drag.active).toBe(false);
    expect(guidedSnapshot(.9025, desktop)).toMatchObject({ cursorTarget: 'stabilize-header', cursor: { pressed: false }, focusedTile: null });
  });
  test('move ghosts predict the committed destination before the dragged tile arrives', () => {
    for (const [start, early, middle, release, id] of [
      [.873, .875, .884, .902, 'stabilize'], [.909, .911, .916, .923, 'browser'],
    ] as const) {
      expect(guidedSnapshot(start - .001, desktop).snapPreview).toBeNull();
      const preview = guidedSnapshot(early, desktop), later = guidedSnapshot(middle, desktop), dropped = guidedSnapshot(release, desktop);
      const ghost = preview.snapPreview!;
      expect(ghost).not.toBeNull();
      expect(ghost.tile).toBe(id);
      expect(ghost.x).toBeGreaterThan(preview.tileFrames[id].x);
      expect(ghost).toMatchObject({ x: dropped.tileFrames[id].x, y: dropped.tileFrames[id].y, width: dropped.tileFrames[id].width, height: dropped.tileFrames[id].height });
      expect(later.snapPreview).toMatchObject({ tile: id, x: ghost.x, y: ghost.y });
      expect(preview.tiles[id].emphasis).toBe(0);
      expect(dropped.snapPreview).toBeNull();
      expect(guidedSnapshot(early, desktop)).toEqual(preview);
    }
  });
  test('drag pushes baseline neighbors before latching, and relaxes the cascade after swapping', () => {
    const baseline = guidedSnapshot(.873, desktop);
    for (const p of [.880, .883, .887]) {
      const frames = guidedSnapshot(p, desktop).tileFrames;
      expect(frames.stabilize.x + frames.stabilize.width / 2).toBeLessThan(550);
      expect(frames.verify.x).toBe(Math.max(550, frames.stabilize.x + frames.stabilize.width + 8));
      expect(frames.audit.x).toBe(Math.max(980, frames.verify.x + frames.verify.width + 8));
      expect(frames.shell.x).toBe(Math.max(1370, frames.audit.x + frames.audit.width + 8));
      for (const [left, right] of [['stabilize', 'verify'], ['verify', 'audit'], ['audit', 'shell']] as const) {
        expect(frames[right].x - (frames[left].x + frames[left].width)).toBeGreaterThanOrEqual(8 - 1e-9);
      }
    }
    const pushed = guidedSnapshot(.884, desktop);
    expect(pushed.tileFrames.verify.x).toBeGreaterThan(baseline.tileFrames.verify.x);
    expect(pushed.tileFrames.audit.x).toBeGreaterThan(baseline.tileFrames.audit.x);
    expect(pushed.tileFrames.shell.x).toBeGreaterThan(baseline.tileFrames.shell.x);
    const exchanged = guidedSnapshot(.915, desktop);
    expect(exchanged.tileFrames.verify).toMatchObject({ x: 70, y: 90 });
    expect(exchanged.tileFrames.audit.x).toBe(988);
    expect(exchanged.tileFrames.shell.x).toBe(baseline.tileFrames.shell.x);
    // Retreat/direct seek recomputes from the gesture baseline, not last solve.
    guidedSnapshot(.915, desktop);
    expect(guidedSnapshot(.884, desktop)).toEqual(pushed);
  });
  test('cursor approaches before selection, then holds through drag and each resize', () => {
    for (const [approach, press, target, tile] of [
      [.866, .878, 'stabilize-header', 'stabilize'], [.906, .915, 'editor-header', 'browser'],
      [.926, .94, 'editor-resize', 'browser'], [.953, .965, 'stabilize-resize', 'stabilize'],
      [.973, .981, 'shell-resize', 'shell'],
    ] as const) {
      const before = guidedSnapshot(approach, desktop), held = guidedSnapshot(press, desktop);
      expect(before.cursorTarget).toBe(target);
      expect(before.cursor.approach).toBeGreaterThan(0);
      expect(before.cursor.approach).toBeLessThan(1);
      expect(before.cursor.pressed).toBe(false);
      expect(before.cursor.fromTarget).not.toBeNull();
      expect(before.selectedTile).not.toBe(tile);
      expect(held.cursorTarget).toBe(target);
      expect(held.selectedTile).toBe(tile);
      expect(held.cursor.pressed).toBe(true);
      expect(held.cursor.approach).toBe(1);
      expect(held.cursor.fromTarget).toBeNull();
    }
    expect(guidedSnapshot(.986, desktop).cursor.visible).toBe(false);
  });
  test('three practical resizes enlarge the working surfaces with native body-height readouts', () => {
    for (const [p, tile, initialWidth] of [[.94, 'browser', 560], [.965, 'stabilize', 430], [.981, 'shell', 300]] as const) {
      const resizing = guidedSnapshot(p, desktop), frame = resizing.tileFrames[tile];
      expect(frame.width).toBeGreaterThan(initialWidth);
      expect(resizing.resizeReadout).toEqual({ tile, width: Math.round(frame.width), height: Math.round(frame.height - 24) });
    }
    const final = guidedSnapshot(.99, desktop);
    expect(final.tileFrames.browser).toMatchObject({ x: 970, y: 690, width: 800, height: 560 });
    expect(final.tileFrames.stabilize).toMatchObject({ x: 550, width: 550, height: 420 });
    expect(final.tileFrames.shell).toMatchObject({ x: 1456, width: 480, height: 560 });
    expect(final.resizeReadout).toBeNull();
    expect(guidedSnapshot(.99, mobile).tileFrames.browser).toMatchObject({ width: 470, height: 560 });
  });
  test('settled drag and every resize preserve the native eight-point row gap', () => {
    // The pointer-held slot-crossing interval is intentionally excluded;
    // pre-latch pushes have their own baseline-relative gap witness above.
    for (let p = .902; p <= .985; p += .001) {
      const frames = guidedSnapshot(p, desktop).tileFrames;
      for (const [left, right] of [['verify', 'stabilize'], ['stabilize', 'audit'], ['audit', 'shell']] as const) {
        expect(frames[right].x - (frames[left].x + frames[left].width), `gap ${left}/${right} at ${p}`).toBeGreaterThanOrEqual(8 - 1e-8);
      }
    }
    const beforeResize = guidedSnapshot(.957 - 1e-8, desktop).tileFrames.audit.x;
    const afterResize = guidedSnapshot(.957 + 1e-8, desktop).tileFrames.audit.x;
    expect(Math.abs(afterResize - beforeResize)).toBeLessThan(.001);
  });
  test('native resize pressure preserves all tile rectangles without collisions', () => {
    for (const options of [desktop, mobile]) for (let p = .93; p <= 1; p += .001) {
      const frames = Object.values(guidedSnapshot(p, options).tileFrames);
      for (let i = 0; i < frames.length; i++) for (let j = i + 1; j < frames.length; j++) {
        const a = frames[i], b = frames[j];
        const overlap = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x) > 1e-8
          && Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y) > 1e-8;
        expect(overlap, `overlap at ${p}`).toBe(false);
      }
    }
  });
  test('multiple resize direct seeks and reversals restore the exact committed state', () => {
    for (const p of [.866, .926, .94, .953, .965, .973, .981]) {
      const expected = guidedSnapshot(p, desktop);
      guidedSnapshot(1, desktop); guidedSnapshot(.2, desktop);
      expect(guidedSnapshot(p, desktop)).toEqual(expected);
    }
    const detail = guidedSnapshot(.765, mobile);
    expect(detail.boardDetail).toBe(true);
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
