import { describe, expect, test } from 'vitest';
import fixtures from './native-layout.fixtures.json';
import { clampIntoContent, contactPlacement, gapClear, isGapAdjacent, overlapsOrUnderGap, predictMove, pushAxis, resizeMembers, settleMembers, solveMemberMove, valid, type Frame, type Frames } from './native-layout';
interface NativeFixtureScenario {
  id: string; active: string; baseline: Frames; content?: Frame;
  moves: Record<string, { requested: Frame; snapped?: Frame | null; latchedInput: string | null; liveFrames: Frames; latch: string | null;
    releaseFrames: Frames; destination: Frame | null; passiveFrames: Frames; valid: boolean }>;
  resizes: Record<string, { active: string; requested: Frame; frames: Frames }>;
}
const nativeFixtures = fixtures as unknown as { provenance: { source: string }; gap: number; content: Frame; scenarios: NativeFixtureScenario[] };
const content = { x: 0, y: 0, width: 2000, height: 1200 };
const frame = (x: number, y = 0, width = 100, height = 100): Frame => ({ x, y, width, height });
const clear = (frames: Frames) => {
  for (const [id, f] of Object.entries(frames)) expect(valid(f, content, Object.entries(frames).filter(([other]) => other !== id).map(([, value]) => value), 8 - .26), id).toBe(true);
};
describe('native member move and rest magnetism port', () => {
  test('pointer stays owned while pushes cascade horizontally and retreat restores baseline', () => {
    const baseline = { a: frame(0), b: frame(130), c: frame(250) };
    const pushed = solveMemberMove(baseline, 'a', frame(50), content, 8);
    expect(pushed).toEqual({ latch: null, frames: { a: frame(50), b: frame(158), c: frame(266) } });
    expect(solveMemberMove(baseline, 'a', frame(0), content, 8).frames).toEqual(baseline);
    expect(baseline.b.x).toBe(130);
    clear(pushed.frames);
  });
  test('baseline lane locks vertical pushes even if current penetration favors horizontal', () => {
    const baseline = { a: frame(0), b: frame(0, 120) };
    expect(pushAxis(baseline.a, baseline.b, frame(90, 60), baseline.b, 8)).toBe('vertical');
    expect(solveMemberMove(baseline, 'a', frame(0, 30), content, 8).frames.b.y).toBe(138);
  });
  test('slot exchange preserves unequal sizes and release preview uses vacated passive geometry', () => {
    const baseline = { a: frame(0), b: frame(300, 0, 180) };
    const prediction = predictMove(baseline, 'a', frame(330), content, 8);
    expect(prediction.live.latch).toBe('b');
    expect(prediction.live.frames.b).toEqual(frame(0, 0, 180));
    expect(prediction.destination).toEqual(frame(300));
    expect(prediction.passiveFrames.b).toEqual(frame(112, 0, 180));
    expect(prediction.valid).toBe(true);
    expect(overlapsOrUnderGap(prediction.destination!, prediction.passiveFrames.b, 8)).toBe(false);
    expect(isGapAdjacent(prediction.destination!, prediction.passiveFrames.b, 8)).toBe(true);
    clear(prediction.releaseFrames);
    expect(gapClear(prediction.releaseFrames, 8)).toBe(true);
  });
  test('latch uses baseline slot, hysteresis, home release and alternate sibling', () => {
    const baseline = { a: frame(0), b: frame(200), c: frame(500) };
    expect(solveMemberMove(baseline, 'a', frame(160), content, 8).latch).toBe('b');
    expect(solveMemberMove(baseline, 'a', frame(270), content, 8, 'b').latch).toBe('b');
    expect(solveMemberMove(baseline, 'a', frame(300), content, 8, 'b').latch).toBeNull();
    expect(solveMemberMove(baseline, 'a', frame(0), content, 8, 'b').latch).toBeNull();
    expect(solveMemberMove(baseline, 'a', frame(460), content, 8, 'b').latch).toBe('c');
  });
  test('disconnected row magnetizes to real eight-point gaps without resizing', () => {
    const source = { a: frame(10, 20), b: frame(400, 20, 180), c: frame(800, 20, 70) };
    const result = settleMembers(source, content, 8);
    expect(result).toEqual({ a: frame(10, 20), b: frame(118, 20, 180), c: frame(306, 20, 70) });
    clear(result);
    expect(source.b.x).toBe(400);
  });
  test('existing contact costs zero and a just-moved tile joins last', () => {
    const source = { z: frame(0), a: frame(108), mover: frame(600) };
    const result = settleMembers(source, content, 8, 'mover');
    expect(result.z).toEqual(source.z);
    expect(result.a).toEqual(source.a);
    expect(result.mover).toEqual(frame(216));
    expect(settleMembers(result, content, 8, 'mover')).toEqual(result);
  });
  test('pinned release pushes residents and never moves its authoritative origin', () => {
    const source = { active: frame(50), resident: frame(130) };
    const result = settleMembers(source, content, 8, 'active', true);
    expect(result.active).toEqual(source.active);
    expect(result.resident).toEqual(frame(158));
    clear(result);
  });
  test('resize pressure cascades in baseline order across rows and grows beyond a zone wall', () => {
    const baseline = { a: frame(0), b: frame(108), c: frame(216), lower: frame(0, 108) };
    const result = resizeMembers(baseline, 'a', frame(0, 0, 180, 160), 8);
    expect(result).toEqual({ a: frame(0, 0, 180, 160), b: frame(188), c: frame(296), lower: frame(0, 168) });
    expect(resizeMembers(baseline, 'a', frame(0, 0, 50, 50), 8).b).toEqual(baseline.b);
    expect(baseline.lower.y).toBe(108);
  });
  test('left/top resizing pushes outward without reversing lanes or moving the active frame', () => {
    const baseline = { active: frame(200, 200), left: frame(92, 200), top: frame(200, 92), diagonal: frame(500, 500) };
    const requested = frame(150, 150, 150, 150);
    const result = resizeMembers(baseline, 'active', requested, 8);
    expect(result.active).toEqual(requested);
    expect(result.left.x).toBe(42);
    expect(result.top.y).toBe(42);
    expect(result.diagonal).toEqual(baseline.diagonal);
  });
  test('content wall clamping matches native bounded push without inventing reflow lanes', () => {
    const wall = { x: 0, y: 0, width: 240, height: 100 };
    const result = solveMemberMove({ a: frame(0), b: frame(130) }, 'a', frame(60), wall, 8);
    expect(result.frames.a).toEqual(frame(60));
    expect(result.frames.b).toEqual(frame(140));
    expect(result.frames.b.y).toBe(0);
    expect(valid(result.frames.a, wall, [result.frames.b], 8)).toBe(false);
    expect(clampIntoContent(frame(-20, 200), wall)).toEqual(frame(0));
  });
  test('nearest contact tie uses top then left and no-placement preserves a small-zone member', () => {
    expect(contactPlacement(frame(200, 0), [frame(0)], content, 8)).toEqual(frame(108));
    const tiny = { x: 0, y: 0, width: 100, height: 100 };
    expect(contactPlacement(frame(0), [frame(0)], tiny, 8)).toBeNull();
    expect(settleMembers({ a: frame(0), b: frame(0) }, tiny, 8)).toEqual({ a: frame(0), b: frame(0) });
    expect(settleMembers({ a: frame(0) }, { ...tiny, width: 0 }, 8)).toEqual({});
  });
});

describe('Swift-generated native parity', () => {
  test('fixture inventory is nonempty and generated from unchanged native bodies', () => {
    expect(nativeFixtures.scenarios.length).toBeGreaterThan(0);
    expect(nativeFixtures.provenance.source).toBe('Sources/ContinuumRevivedCore/CanvasAutoLayoutEngine.swift');
    expect(nativeFixtures.scenarios.reduce((n, s) => n + Object.keys(s.moves).length, 0)).toBeGreaterThanOrEqual(8);
    expect(nativeFixtures.scenarios.reduce((n, s) => n + Object.keys(s.resizes).length, 0)).toBe(3);
  });
  for (const scenario of nativeFixtures.scenarios) {
    for (const [name, move] of Object.entries(scenario.moves)) {
      test(`${scenario.id}/${name}: live and actual release wrapper agree with Swift`, () => {
        const result = predictMove(scenario.baseline, scenario.active, move.requested, scenario.content ?? nativeFixtures.content, nativeFixtures.gap, move.latchedInput, move.snapped ?? null);
        expect(result.live.frames).toEqual(move.liveFrames);
        expect(result.live.latch).toBe(move.latch);
        expect(result.releaseFrames).toEqual(move.releaseFrames);
        expect(result.destination).toEqual(move.destination);
        expect(result.passiveFrames).toEqual(move.passiveFrames);
        expect(result.valid).toBe(move.valid);
      });
    }
    for (const [name, resize] of Object.entries(scenario.resizes)) {
      test(`${scenario.id}/${name}: directional resize pressure agrees with Swift`, () => {
        expect(resizeMembers(scenario.baseline, resize.active, resize.requested, nativeFixtures.gap)).toEqual(resize.frames);
      });
    }
  }
  test('mouse-up re-solves snapped geometry before settle, relaxing raw pointer pushes', () => {
    const scene: Frames = {
      stabilize: frame(70, 90, 430, 550), verify: frame(550, 90, 380, 470),
      audit: frame(980, 90, 340, 450), shell: frame(1370, 90, 300, 470),
      note: frame(70, 680, 800, 430), browser: frame(920, 680, 560, 430),
    };
    const bounds = { x: 66, y: 79, width: 1970, height: 1230 };
    const arranged = settleMembers(scene, bounds, 8, 'stabilize', true);
    const raw = { ...arranged.stabilize, x: 260, y: 90 };
    const result = predictMove(arranged, 'stabilize', raw, bounds, 8, null, arranged.stabilize);
    expect(result.live.frames.verify.x).toBeGreaterThan(arranged.verify.x);
    expect(result.releaseFrames).toEqual(arranged);
    for (const id of ['stabilize', 'verify', 'audit', 'shell']) expect(result.releaseFrames[id].y).toBe(90);
    expect(result.valid).toBe(true);
  });
  test('honorSnap pins the supplied actual target before native settle', () => {
    const baseline = { a: frame(0), b: frame(300, 0, 180) };
    const snapped = frame(500, 50);
    const result = predictMove(baseline, 'a', frame(330), content, 8, null, snapped);
    expect(result.live.latch).toBe('b');
    expect(result.destination).toEqual(snapped);
    expect(result.destination?.x).not.toBe(baseline.b.x);
    expect(result.valid).toBe(true);
    expect(gapClear(result.releaseFrames, 8)).toBe(true);
  });
});
