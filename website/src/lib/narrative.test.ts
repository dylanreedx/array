import { describe, expect, test } from 'vitest';
import { narrativeAt, STEPS } from './narrative';
describe('scroll story', () => {
  test('starts with an empty canvas and ends in overview', () => {
    expect(narrativeAt(0).step.id).toBe('canvas');
    expect(narrativeAt(1).step.id).toBe('overview');
  });
  test.each(STEPS.map((step, i) => [step.id, (i + .6) / STEPS.length] as const))('lands every beat including %s', (id, progress) => {
    const scene = narrativeAt(progress);
    expect(scene.step.id).toBe(id);
    expect(scene.camera.x).toBe(scene.step.x);
    expect(scene.camera.y).toBe(scene.step.y);
    expect(scene.camera.zoom).toBe(scene.step.zoom);
  });
  test('seeking backward restores precisely the earlier camera and cursor', () => {
    const early = narrativeAt(.34);
    narrativeAt(.92);
    expect(narrativeAt(.34)).toEqual(early);
  });
  test('malformed input never produces an invalid transform', () => {
    for (const value of [-1, NaN, Infinity, 22]) {
      const scene = narrativeAt(value);
      expect(Number.isFinite(scene.camera.zoom)).toBe(true);
      expect(scene.index).toBeGreaterThanOrEqual(0);
      expect(scene.index).toBeLessThan(STEPS.length);
    }
  });
});
