import { describe, expect, test } from 'vitest';
import { ASSEMBLY_TIMELINE_END, READY_LANDING_POINT, assemblyProgressForScroll, presentationFor, surfacePointerPose } from './assembly-controller';
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
  test('gives detached surfaces independent depth-weighted pointer poses', () => {
    expect(surfacePointerPose('stabilize', 1, 1)).toEqual({ x: 9, y: 6, rotateX: .62, rotateY: .8 });
    expect(surfacePointerPose('browser', 1, 1)).toEqual({ x: -6.5, y: 5, rotateX: .48, rotateY: -.58 });
    expect(surfacePointerPose('shell', 1, 1, .5)).toEqual({ x: 2.25, y: -2, rotateX: -.17, rotateY: .21 });
  });
  test('clamps pointer input and ignores unknown settled surfaces', () => {
    expect(surfacePointerPose('note', 5, -5)).toEqual({ x: -4, y: 5.5, rotateX: .46, rotateY: -.38 });
    expect(surfacePointerPose('audit', 1, 1)).toEqual({ x: 0, y: 0, rotateX: 0, rotateY: 0 });
    expect(surfacePointerPose('verify', 1, 1, 0)).toEqual({ x: 0, y: -0, rotateX: -0, rotateY: 0 });
  });
});
