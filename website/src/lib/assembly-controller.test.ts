import { describe, expect, test } from 'vitest';
import { ASSEMBLY_TIMELINE_END, READY_LANDING_POINT, assemblyProgressForScroll, presentationFor } from './assembly-controller';
describe('assembly progress model', () => {
  test.each([[0, 'glimpse'], [.18, 'opening'], [.36, 'assembly'], [.72, 'mac'], [.84, 'companion'], [.94, 'ready'], [1, 'ready']] as const)('%s selects %s', (progress, phase) => expect(presentationFor(progress).phase).toBe(phase));
  test('reduced motion settles immediately', () => expect(presentationFor(0, true)).toMatchObject({ progress: 1, phase: 'ready', reducedMotion: true }));
  test('clamps malformed endpoints', () => {
    expect(presentationFor(-10).progress).toBe(0);
    expect(presentationFor(Number.NaN).progress).toBe(0);
    expect(presentationFor(10).progress).toBe(1);
  });
  test('finishes the visual sequence before the sticky track ends', () => {
    expect(assemblyProgressForScroll(0)).toBe(0);
    expect(assemblyProgressForScroll(ASSEMBLY_TIMELINE_END)).toBe(1);
    expect(assemblyProgressForScroll(READY_LANDING_POINT)).toBe(1);
    expect(READY_LANDING_POINT).toBeGreaterThan(ASSEMBLY_TIMELINE_END);
  });
});
