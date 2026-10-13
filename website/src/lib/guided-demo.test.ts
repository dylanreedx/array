import { describe, expect, test } from 'vitest';
import { DEMO_TEXT, guidedSnapshot, STEPS } from './guided-demo';
const desktop = { width: 1440, height: 900 };
const mobile = { width: 390, height: 760 };

describe('seekable guided workspace', () => {
  test('direct jumps and reverse scrolling produce the same full visible state', () => {
    const expected = guidedSnapshot(.66, desktop);
    for (const p of [.95, .12, .82, .28, .66]) guidedSnapshot(p, desktop);
    expect(guidedSnapshot(.66, desktop)).toEqual(expected);
    expect(expected.status.verify).toBe('Needs approval');
    expect(expected.approval).toBe('waiting');
    expect(expected.camera.center.x).toBeGreaterThan(675);
    expect(expected.camera.center.x).toBeLessThan(710);
    expect(guidedSnapshot(.70, desktop).approval).toBe('approved');
    expect(guidedSnapshot(.32, desktop).approval).toBe('hidden');
  });
  test('typing seeks both ways without retaining later characters', () => {
    expect(guidedSnapshot(.37, desktop).typing.stabilize).toBe(DEMO_TEXT.stabilize);
    const earlier = guidedSnapshot(.33, desktop).typing.stabilize;
    expect(earlier.length).toBeGreaterThan(0);
    expect(earlier.length).toBeLessThan(DEMO_TEXT.stabilize.length);
    expect(DEMO_TEXT.stabilize.startsWith(earlier)).toBe(true);
    expect(guidedSnapshot(.1, desktop).typing).toEqual({ stabilize: '', verify: '', audit: '' });
  });
  test('scripted menus, press feedback, tools and completion have bounded beats', () => {
    expect(guidedSnapshot(.45, desktop).menu).toBe('toolbar');
    expect(guidedSnapshot(.49, desktop).menu).toBe('provider');
    expect(guidedSnapshot(.49, desktop).cursor.pressed).toBe(true);
    expect(guidedSnapshot(.52, desktop).menu).toBeNull();
    expect(guidedSnapshot(.84, desktop).tool).toContain('Running canvas checks');
    expect(guidedSnapshot(.94, desktop).status).toEqual({ stabilize: 'Complete', verify: 'Passed', audit: 'Complete' });
    expect(guidedSnapshot(.94, desktop).cursor.visible).toBe(false);
  });
  test('mobile follows readable subjects instead of shrinking the whole board', () => {
    const board = guidedSnapshot(.75, mobile);
    expect(board.camera.center).toEqual({ x: 210, y: 800 });
    expect(board.camera.scale).toBeGreaterThan(1);
    const editor = guidedSnapshot(.795, mobile);
    expect(editor.camera.center).toEqual({ x: 1085, y: 835 });
    expect(editor.camera.scale).toBeGreaterThan(1);
    expect(guidedSnapshot(.64, mobile).camera.scale).toBeGreaterThan(.9);
  });
  test('camera visibly moves within task and approval beats while remaining continuous', () => {
    for (const [a, b] of [[.32, .38], [.625, .69]]) {
      const first = guidedSnapshot(a, desktop).camera;
      const last = guidedSnapshot(b, desktop).camera;
      expect(Math.hypot(last.x - first.x, last.y - first.y)).toBeGreaterThan(15);
    }
    expect(guidedSnapshot(.75, desktop).camera.center).toEqual({ x: 460, y: 840 });
    expect(guidedSnapshot(.795, desktop).camera.center).toEqual({ x: 1190, y: 835 });
    expect(guidedSnapshot(.84, desktop).camera.center).toEqual({ x: 1510, y: 325 });
  });
  test('same six tile transforms seek reversibly and stay visible after landing', () => {
    const ids = ['audit', 'browser', 'note', 'shell', 'stabilize', 'verify'];
    for (const p of [.26, .5, .64, .75, .8, .95]) {
      const tiles = guidedSnapshot(p, desktop).tiles;
      expect(Object.keys(tiles).sort()).toEqual(ids);
      for (const tile of Object.values(tiles)) {
        expect(tile.opacity).toBe(1);
        expect(Math.abs(tile.x)).toBeLessThanOrEqual(12);
        expect(Math.abs(tile.y)).toBeLessThanOrEqual(20);
        expect(tile.scale).toBeGreaterThanOrEqual(1);
        expect(tile.scale).toBeLessThanOrEqual(1.025);
      }
    }
    expect(guidedSnapshot(.8, desktop).tiles.browser.emphasis).toBeGreaterThan(.8);
    expect(guidedSnapshot(.8, desktop).boardProgress).toBeGreaterThan(.5);
    expect(guidedSnapshot(.8, desktop).editorProgress).toBeGreaterThan(.5);
  });
  test('board detail belongs to its readable beat and disappears on reverse or later seeks', () => {
    expect(guidedSnapshot(.765, desktop).boardDetail).toBe(true);
    expect(guidedSnapshot(.75, desktop).boardDetail).toBe(false);
    expect(guidedSnapshot(.87, desktop).boardDetail).toBe(false);
    expect(guidedSnapshot(.765, { ...mobile, reducedMotion: true }).boardDetail).toBe(false);
    const detailCamera = guidedSnapshot(.765, mobile).camera;
    expect(detailCamera.center).toEqual({ x: 285, y: 800 });
    expect(detailCamera.scale * 430).toBeLessThan(mobile.width);
  });
  test('camera transitions are continuous at step boundaries', () => {
    for (const step of STEPS.slice(1)) {
      const before = guidedSnapshot(step.start - 1e-7, desktop).camera;
      const after = guidedSnapshot(step.start, desktop).camera;
      expect(Math.abs(after.x - before.x)).toBeLessThan(.01);
      expect(Math.abs(after.y - before.y)).toBeLessThan(.01);
      expect(after.scale).toBeCloseTo(before.scale, 3);
    }
  });
  test('hero clears before narration and chrome settles as floats land', () => {
    expect(guidedSnapshot(.18, desktop).heroOpacity).toBe(0);
    expect(guidedSnapshot(.10, desktop).chromeOpacity).toBe(0);
    expect(guidedSnapshot(.28, desktop).chromeOpacity).toBe(1);
    expect(guidedSnapshot(.26, desktop).step).toBe('landing');
  });
  test('reduced motion gives complete static content independent of seek', () => {
    const snapshot = guidedSnapshot(0, { ...mobile, reducedMotion: true });
    expect(snapshot).toEqual(guidedSnapshot(.66, { ...mobile, reducedMotion: true }));
    expect(snapshot.typing).toEqual(DEMO_TEXT);
    expect(snapshot.status.verify).toBe('Passed');
    expect(snapshot.cursor.visible).toBe(false);
    expect(snapshot.menu).toBeNull();
    for (const tile of Object.values(snapshot.tiles)) expect(tile).toEqual({ x: 0, y: 0, scale: 1, rotation: 0, opacity: 1, emphasis: 0 });
  });
  test('malformed and out-of-range progress cannot produce invalid transforms', () => {
    for (const value of [NaN, Infinity, -3, 4]) {
      const s = guidedSnapshot(value, desktop);
      expect(s.progress).toBeGreaterThanOrEqual(0);
      expect(s.progress).toBeLessThanOrEqual(1);
      expect(Number.isFinite(s.camera.x + s.camera.y + s.camera.scale)).toBe(true);
    }
  });
});
