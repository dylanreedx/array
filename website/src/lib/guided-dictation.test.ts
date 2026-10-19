import { describe, expect, test } from 'vitest';
import { DEMO_TEXT, guidedSnapshot } from './guided-demo';
import { DICTATION, DICTATION_BEAT, DICTATION_TINT, dictationSnapshot } from './guided-dictation';
import { TOOLBAR } from './guided-toolbar';
import { GUIDED_INSERTS, GUIDED_TRACK_SVH, guidedTimeline, scrollForProgress } from './guided-timeline';
const desktop = { width: 1160, height: 820 };
const mobile = { width: 390, height: 735 };
const AT = GUIDED_INSERTS.find(insert => insert.id === 'dictation')!.at;
const beat = (t: number) => ({ id: 'dictation' as const, t });
const during = (t: number, options = desktop) => guidedSnapshot(AT, { ...options, insert: beat(t) });

describe('the dictation beat is its own insert', () => {
  test('it is inserted at the audit prompt, and every authored beat keeps its scroll distance', () => {
    expect(AT).toBe(.565);
    const mid = guidedTimeline(scrollForProgress(AT, .5));
    expect(mid).toEqual({ progress: AT, insert: { id: 'dictation', t: expect.closeTo(.5, 9) } });
    const svh = (a: number, b: number) => (scrollForProgress(b) - scrollForProgress(a)) * GUIDED_TRACK_SVH;
    expect(GUIDED_TRACK_SVH).toBe(Math.round(970 * (1 + GUIDED_INSERTS.reduce((sum, insert) => sum + insert.length, 0))));
    expect(svh(.445, .595)).toBeCloseTo(.15 * 970 + GUIDED_INSERTS.find(insert => insert.id === 'dictation')!.length * 970, 0);
    expect(svh(.595, .73)).toBeCloseTo(.135 * 970, 0);
  });
  test('it narrates dictation, keeps the camera on the agent, and returns it where the story resumes', () => {
    expect(during(.4)).toMatchObject({ step: 'dictation', focusedTile: 'audit' });
    expect(during(.4).caption).toMatch(/talk/i);
    for (const options of [desktop, mobile]) {
      const near = (a: { x: number; y: number; scale: number }, b: typeof a) => {
        expect(Math.abs(a.x - b.x)).toBeLessThan(2);
        expect(Math.abs(a.y - b.y)).toBeLessThan(2);
        expect(Math.abs(a.scale - b.scale)).toBeLessThan(.002);
      };
      near(guidedSnapshot(AT - 1e-6, options).camera, during(0, options).camera);
      near(during(1, options).camera, guidedSnapshot(AT, options).camera);
      // The composer stays in view while it listens.
      const state = during(.4, options), tile = state.tileFrames.audit, camera = state.camera;
      expect(camera.x + tile.x * camera.scale).toBeGreaterThanOrEqual(-1);
      expect(camera.x + (tile.x + tile.width) * camera.scale).toBeLessThanOrEqual(options.width + 1);
      expect(camera.y + (tile.y + tile.height) * camera.scale).toBeLessThanOrEqual(options.height);
      // ...and clear of the canvas toolbar resting on the left edge.
      const bar = state.toolbar, barRight = bar.x + TOOLBAR.thickness * bar.scale / 2;
      expect(state.toolbar.edge).toBe('left');
      expect(camera.x + tile.x * camera.scale).toBeGreaterThan(barRight);
    }
  });
});

describe('the capsule follows ComposerDictationPillView', () => {
  test('the mic grows on the jelly spring, overshoots a little, settles, and folds back', () => {
    expect(dictationSnapshot(DICTATION_BEAT.open - .001)).toMatchObject({ state: 'idle', visible: false, growth: 0 });
    let peak = 0;
    for (let t = DICTATION_BEAT.open; t < DICTATION_BEAT.finish; t += .0025) peak = Math.max(peak, dictationSnapshot(t).growth);
    expect(peak).toBeGreaterThan(1.005);
    expect(peak).toBeLessThan(1.1);
    // About a third of a second to settle, like the app's spring (response .38, damping .74).
    const settled = DICTATION_BEAT.open + .6 / DICTATION_BEAT.seconds;
    expect(dictationSnapshot(settled).growth).toBeCloseTo(1, 2);
    expect(dictationSnapshot(.4)).toMatchObject({ state: 'listening', visible: true });
    expect(dictationSnapshot(DICTATION_BEAT.finish + .005)).toMatchObject({ state: 'finalizing', visible: true });
    expect(dictationSnapshot(DICTATION_BEAT.close + .002).growth).toBeLessThan(1);
    expect(dictationSnapshot(DICTATION_BEAT.close + .002).visible).toBe(true);
    expect(dictationSnapshot(DICTATION_BEAT.hidden + .001)).toMatchObject({ state: 'idle', visible: false });
  });
  test('the waveform scrolls at 20 bars a second, rests above zero, and stays within its 16 pt strip', () => {
    const at = (t: number) => dictationSnapshot(t).bars;
    expect(at(.4)).toHaveLength(DICTATION.bars);
    expect(Math.min(...at(.2))).toBeGreaterThanOrEqual(DICTATION.restingLevel);
    expect(Math.max(...at(.4))).toBeLessThanOrEqual(1);
    expect(Math.max(...at(.4))).toBeGreaterThan(.5); // speech fills most of the height
    // One bar per 50 ms: the history shifts left by exactly one bar.
    const tick = DICTATION.advance / DICTATION_BEAT.seconds;
    const a = at(.4), b = at(.4 + tick + 1e-9);
    expect(b.slice(0, -1)).toEqual(a.slice(1));
  });
  test('elapsed time counts whole seconds from when listening began', () => {
    expect(dictationSnapshot(DICTATION_BEAT.open + .001).elapsed).toBe('0:00');
    expect(dictationSnapshot(DICTATION_BEAT.open + 1.2 / DICTATION_BEAT.seconds).elapsed).toBe('0:01');
    expect(dictationSnapshot(DICTATION_BEAT.finish - .001).elapsed).toBe('0:04');
  });
  test('the capsule wears the agent’s colour', () => {
    expect(DICTATION_TINT).toEqual({ name: 'purple', color: '#bf5af2' });
  });
});

describe('words land at the caret, provisional first', () => {
  test('a hypothesis is drawn provisional, then settles; the composer ends with the prompt', () => {
    let sawProvisional = false, sawSettledWithProvisional = false, previous = '';
    for (let t = DICTATION_BEAT.open; t < DICTATION_BEAT.close; t += .002) {
      const state = dictationSnapshot(t);
      if (state.provisional) sawProvisional = true;
      if (state.provisional && state.settled) sawSettledWithProvisional = true;
      // Settled words are never taken back.
      expect(state.settled.startsWith(previous)).toBe(true);
      previous = state.settled;
    }
    expect(sawProvisional).toBe(true);
    expect(sawSettledWithProvisional).toBe(true);
    expect(dictationSnapshot(DICTATION_BEAT.close)).toMatchObject({ settled: DEMO_TEXT.audit, provisional: '' });
  });
  test('the composer shows the words while the agent is still ready; Send hands them to the agent', () => {
    const listening = during(.45);
    expect(listening.status.audit).toBe('Ready');
    expect(listening.typing.audit.length).toBeGreaterThan(0);
    expect(DEMO_TEXT.audit.toLowerCase()).toContain(listening.typing.audit.split(' ')[0].toLowerCase());
    expect(listening.dictation).toMatchObject({ agent: 'audit', state: 'listening', hint: true });
    const finished = during(DICTATION_BEAT.hidden + .01);
    expect(finished).toMatchObject({ status: { audit: 'Ready' }, typing: { audit: DEMO_TEXT.audit }, dictation: { state: 'idle', hint: false } });
    expect(finished.dictation.provisional).toBe('');
    const sent = during(DICTATION_BEAT.sent + .001);
    expect(sent.status.audit).toBe('Reviewing');
    expect(sent.typing.audit).toBe(DEMO_TEXT.audit);
    // After the beat the story resumes with the agent already working on it.
    expect(guidedSnapshot(AT, desktop)).toMatchObject({ status: { audit: 'Reviewing' }, typing: { audit: DEMO_TEXT.audit } });
    expect(guidedSnapshot(AT - .001, desktop).status.audit).toBe('Ready');
  });
  test('the hand clicks the mic, Return finishes, then the hand clicks Send', () => {
    expect(during(.05)).toMatchObject({ cursorTarget: 'audit-mic', cursor: { visible: true } });
    expect(during((DICTATION_BEAT.press[0] + DICTATION_BEAT.press[1]) / 2).cursor.pressed).toBe(true);
    expect(during(.4).cursor.pressed).toBe(false);
    expect(during(DICTATION_BEAT.finish).keyHud).toBe(1);
    expect(during(DICTATION_BEAT.finish).keyHudKeys).toEqual(['↩']);
    expect(during(.4).keyHud).toBe(0);
    expect(during((DICTATION_BEAT.sendPress[0] + DICTATION_BEAT.sendPress[1]) / 2)).toMatchObject({ cursorTarget: 'audit-send', cursor: { pressed: true } });
    // The hand leaves Send where the authored story picks it up.
    expect(guidedSnapshot(AT, desktop).cursor).toMatchObject({ fromTarget: 'audit-send', approach: 0 });
  });
  test('reduced motion and the other agents never show a live capsule', () => {
    expect(guidedSnapshot(AT, { ...desktop, reducedMotion: true, insert: beat(.4) }).dictation.state).toBe('idle');
    expect(guidedSnapshot(.53, desktop).dictation).toMatchObject({ state: 'idle', visible: false });
  });
});
