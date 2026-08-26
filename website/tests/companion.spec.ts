import { expect, test } from '@playwright/test';
import { fitCompanionCamera, zoomCompanionCamera } from '../src/components/demo/companion/companionGeometry';
import { makeInitialState } from '../src/features/demo/fixture';
import { demoReducer } from '../src/features/demo/reducer';

test.describe('Companion state boundaries', () => {
  test('fit produces a finite centered Companion camera', () => {
    const camera = fitCompanionCamera(320, 500);
    expect(camera.zoom).toBeGreaterThan(0);
    expect(camera.zoom).toBeLessThanOrEqual(0.9);
    expect(Number.isFinite(camera.x)).toBe(true);
    expect(Number.isFinite(camera.y)).toBe(true);
  });

  test('pointer-anchored zoom preserves the world point under the pointer', () => {
    const initial = { x: -80, y: 22, zoom: 0.34 };
    const anchor = { x: 140, y: 210 };
    const worldBefore = { x: (anchor.x - initial.x) / initial.zoom, y: (anchor.y - initial.y) / initial.zoom };
    const next = zoomCompanionCamera(initial, 0.55, anchor.x, anchor.y);
    expect((anchor.x - next.x) / next.zoom).toBeCloseTo(worldBefore.x, 8);
    expect((anchor.y - next.y) / next.zoom).toBeCloseTo(worldBefore.y, 8);
  });

  test('Companion camera actions never mutate the Mac camera', () => {
    const initial = makeInitialState();
    const macBefore = structuredClone(initial.macCamera);
    const next = demoReducer(initial, { type: 'SET_CAMERA', device: 'companion', camera: { x: 42, y: -18, zoom: 0.5 } });
    expect(next.macCamera).toEqual(macBefore);
    expect(next.companionCamera).toEqual({ x: 42, y: -18, zoom: 0.5 });
  });

  test('approval completion updates the paired agent atomically', () => {
    const initial = makeInitialState();
    const resolving = demoReducer(initial, { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'start' });
    const completed = demoReducer(resolving, { type: 'RESOLVE_APPROVAL', decision: 'accept', phase: 'complete' });
    expect(resolving.approval.state).toBe('resolving');
    expect(completed.approval.state).toBe('accepted');
    expect(completed.agents.verify.status).toBe('working');
    expect(completed.toast).toBe('Approved on Companion');
  });
});
