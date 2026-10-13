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
    expect(expected.camera.center).toEqual({ x: 620, y: 285 });
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
    expect(guidedSnapshot(.77, desktop).tool).toContain('Running canvas checks');
    expect(guidedSnapshot(.94, desktop).status).toEqual({ stabilize: 'Complete', verify: 'Passed', audit: 'Complete' });
    expect(guidedSnapshot(.94, desktop).cursor.visible).toBe(false);
  });
  test('each mobile beat centers its semantic subject at a readable scale', () => {
    for (const step of STEPS.slice(1, -1)) {
      const snapshot = guidedSnapshot(step.start + .05, mobile);
      expect(snapshot.camera.center).toEqual(step.focus);
      expect(snapshot.camera.scale).toBeGreaterThan(1);
      expect(snapshot.camera.x + step.focus.x * snapshot.camera.scale).toBeCloseTo(mobile.width / 2);
      expect(snapshot.camera.y + step.focus.y * snapshot.camera.scale).toBeCloseTo(mobile.height / 2);
    }
  });
  test('camera transitions are continuous at step boundaries', () => {
    for (const step of STEPS.slice(1)) {
      const before = guidedSnapshot(step.start - 1e-7, desktop).camera;
      const after = guidedSnapshot(step.start, desktop).camera;
      expect(after.x).toBeCloseTo(before.x, 3);
      expect(after.y).toBeCloseTo(before.y, 3);
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
