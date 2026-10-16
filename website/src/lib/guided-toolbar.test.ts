import { describe, expect, test } from 'vitest';
import { guidedSnapshot } from './guided-demo';
import { GUIDED_INSERTS, GUIDED_TRACK_SVH, guidedTimeline, scrollForProgress } from './guided-timeline';
import { TOOLBAR, TOOLBAR_LAYOUT, TOOLBAR_TOUR } from './guided-toolbar';
const desktop = { width: 1160, height: 820 };
const mobile = { width: 390, height: 735 };
const toolbarBeat = (t: number) => ({ id: 'toolbar' as const, t });
const terminalBeat = (t: number) => ({ id: 'terminal' as const, t });

/** The capsule's four corners in canvas pixels, from centre, angle and scale. */
function capsuleBounds(bar: { x: number; y: number; angle: number; scale: number }) {
  const r = bar.angle * Math.PI / 180, hl = TOOLBAR_LAYOUT.length * bar.scale / 2, ht = TOOLBAR.thickness * bar.scale / 2;
  const xs = [-1, 1].flatMap(a => [-1, 1].map(b => bar.x + Math.cos(r) * hl * a - Math.sin(r) * ht * b));
  const ys = [-1, 1].flatMap(a => [-1, 1].map(b => bar.y + Math.sin(r) * hl * a + Math.cos(r) * ht * b));
  return { left: Math.min(...xs), right: Math.max(...xs), top: Math.min(...ys), bottom: Math.max(...ys) };
}

describe('inserted beats keep the authored story intact', () => {
  test('scroll maps through each insert and back', () => {
    for (const q of [0, .1, .26, .5, .8, .9, 1]) expect(guidedTimeline(scrollForProgress(q)).progress).toBeCloseTo(q, 9);
    for (const insert of GUIDED_INSERTS) {
      const mid = guidedTimeline(scrollForProgress(insert.at, .5));
      expect(mid).toEqual({ progress: insert.at, insert: { id: insert.id, t: expect.closeTo(.5, 9) } });
    }
    expect(guidedTimeline(0)).toEqual({ progress: 0, insert: null });
    expect(guidedTimeline(1)).toEqual({ progress: 1, insert: null });
  });
  test('every authored beat keeps its original 970svh scroll distance', () => {
    const svh = (a: number, b: number) => (scrollForProgress(b) - scrollForProgress(a)) * GUIDED_TRACK_SVH;
    expect(GUIDED_TRACK_SVH).toBe(1125);
    expect(svh(.38, .445)).toBeCloseTo(.065 * 970, 0);
    expect(svh(.86, .985)).toBeCloseTo(.125 * 970, 0);
  });
});

describe('the canvas toolbar', () => {
  test('rests on the bottom edge until the toolbar beat, then on the left edge', () => {
    for (const options of [desktop, mobile]) {
      const before = guidedSnapshot(.2, options).toolbar, after = guidedSnapshot(.5, options).toolbar;
      expect(before).toMatchObject({ edge: 'bottom', angle: 0, x: options.width / 2 });
      expect(capsuleBounds(before).bottom).toBeCloseTo(options.height - TOOLBAR.margin, 6);
      expect(after).toMatchObject({ edge: 'left', angle: 90, y: options.height / 2 });
      expect(capsuleBounds(after).left).toBeCloseTo(TOOLBAR.margin, 6);
    }
  });
  test('the tour hovers Zone, Agent, then Terminal, each with its label pill', () => {
    const seen: string[] = [];
    for (let t = 0; t < TOOLBAR_TOUR.press; t += .005) {
      const state = guidedSnapshot(.27, { ...desktop, insert: toolbarBeat(t) });
      expect(state.creation.stage).toBe('absent');
      expect(state.step).toBe('toolbar');
      if (state.toolbar.hovered) {
        expect(state.toolbar.pill).toBe(state.toolbar.hovered);
        if (seen.at(-1) !== state.toolbar.hovered) seen.push(state.toolbar.hovered);
      }
    }
    expect(seen).toEqual(['zone', 'agent', 'terminal']);
    expect(guidedSnapshot(.27, { ...desktop, insert: toolbarBeat(.15) })).toMatchObject({ cursorTarget: 'toolbar-zone', cursor: { visible: true } });
  });
  test('dragging turns the bar upright, springs it to the edge, and never leaves the canvas', () => {
    for (const options of [desktop, mobile]) {
      let previousAngle = 0, overshoot = false;
      for (let t = TOOLBAR_TOUR.drag[0]; t <= 1; t += .0025) {
        const bar = guidedSnapshot(.27, { ...options, insert: toolbarBeat(t) }).toolbar;
        const bounds = capsuleBounds(bar);
        expect(bounds.left, `left at ${t}`).toBeGreaterThanOrEqual(0);
        expect(bounds.top, `top at ${t}`).toBeGreaterThanOrEqual(0);
        expect(bounds.right).toBeLessThanOrEqual(options.width);
        expect(bounds.bottom).toBeLessThanOrEqual(options.height);
        expect(Math.abs(bar.angle - previousAngle), `angle step at ${t}`).toBeLessThan(12);
        previousAngle = bar.angle;
        if (t > TOOLBAR_TOUR.drag[1] && bounds.left < TOOLBAR.margin - .5) overshoot = true;
      }
      // The landing carries a little past the edge and settles: the jelly spring.
      expect(overshoot).toBe(true);
      const landed = guidedSnapshot(.27, { ...options, insert: toolbarBeat(1) }).toolbar;
      const rest = guidedSnapshot(.5, options).toolbar;
      expect(landed.angle).toBeCloseTo(90, 0);
      expect(Math.hypot(landed.x - rest.x, landed.y - rest.y)).toBeLessThan(1);
    }
  });
  test('the hand lets go where the next beat picks it up, and ⌘K opens the palette', () => {
    const released = guidedSnapshot(.27, { ...desktop, insert: toolbarBeat(1) }).cursor.screen;
    const after = guidedSnapshot(.27, desktop);
    expect(after.cursor.fromScreen).toEqual(released);
    expect(after.cursor.approach).toBe(0);
    expect(after.creation.stage).toBe('command');
    expect(guidedSnapshot(.278, desktop).keyHud).toBe(1);
    expect(guidedSnapshot(.3, desktop).keyHud).toBe(0);
  });
  test('the terminal comes from the toolbar menu', () => {
    const hover = guidedSnapshot(.815, { ...desktop, insert: terminalBeat(.22) });
    expect(hover).toMatchObject({ cursorTarget: 'toolbar-terminal', toolbar: { hovered: 'terminal', pill: 'terminal', menu: null } });
    const choosing = guidedSnapshot(.815, { ...desktop, insert: terminalBeat(.52) });
    expect(choosing).toMatchObject({ cursorTarget: 'toolbar-menu-shell', toolbar: { active: 'terminal', menu: { kind: 'terminal', open: true, highlighted: 'Shell' } } });
    expect(choosing.tileFrames.shell.visible).toBe(false);
    const arriving = guidedSnapshot(.815, { ...desktop, insert: terminalBeat(.7) });
    expect(arriving.tileFrames.shell.visible).toBe(true);
    expect(arriving.toolbar.menu?.open).toBe(false);
    expect(arriving.tiles.shell.scale).toBeLessThan(1);
    const settled = guidedSnapshot(.815, desktop);
    expect(settled.tiles.shell).toMatchObject({ scale: 1, opacity: 1 });
    expect(settled).toMatchObject({ cursorTarget: 'shell-input', cursor: { fromTarget: 'toolbar-menu-shell', approach: 0 } });
  });
  test('the camera stays continuous through both inserted beats', () => {
    for (const options of [desktop, mobile]) {
      for (const [at, beat] of [[.27, toolbarBeat], [.815, terminalBeat]] as const) {
        const near = (a: { x: number; y: number; scale: number }, b: typeof a) => {
          expect(Math.abs(a.x - b.x)).toBeLessThan(2);
          expect(Math.abs(a.y - b.y)).toBeLessThan(2);
          expect(Math.abs(a.scale - b.scale)).toBeLessThan(.002);
        };
        near(guidedSnapshot(at - 1e-6, options).camera, guidedSnapshot(at, { ...options, insert: beat(0) }).camera);
        near(guidedSnapshot(at, { ...options, insert: beat(1) }).camera, guidedSnapshot(at, options).camera);
        // Per unit of scroll, the reveal pans no faster than the story's own pans.
        const scrollStep = GUIDED_INSERTS.find(insert => insert.at === at)!.length * .01;
        let authored = 0;
        for (let q = .69; q < .86; q += scrollStep) {
          const a = guidedSnapshot(q, options).camera, b = guidedSnapshot(q + scrollStep, options).camera;
          authored = Math.max(authored, Math.hypot(b.x - a.x, b.y - a.y));
        }
        let previous = guidedSnapshot(at, { ...options, insert: beat(0) }).camera;
        for (let t = .01; t <= 1; t += .01) {
          const camera = guidedSnapshot(at, { ...options, insert: beat(t) }).camera;
          expect(Math.hypot(camera.x - previous.x, camera.y - previous.y), `camera step at ${at}/${t}`).toBeLessThanOrEqual(authored * 1.05);
          previous = camera;
        }
      }
    }
    // The terminal is in view, and settled, before the command is typed.
    const typing = guidedSnapshot(.82, desktop);
    const shell = typing.tileFrames.shell, camera = typing.camera;
    expect(camera.x + shell.x * camera.scale).toBeGreaterThanOrEqual(0);
    expect(camera.x + (shell.x + shell.width) * camera.scale).toBeLessThanOrEqual(desktop.width);
  });
});
