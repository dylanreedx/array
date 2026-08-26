import { describe, expect, test } from 'vitest';
import { clampCamera, tidyLayout, workspaceBounds } from './canvasGeometry';
import { makeInitialState } from './fixture';

describe('canvas geometry', () => {
  test('keeps workspace content visible while panning', () => {
    const state = makeInitialState();
    const bounds = workspaceBounds(state.tiles, state.zones);
    const camera = clampCamera({ x: -9000, y: 9000, zoom: .78 }, { width: 900, height: 600 }, bounds);
    expect(camera.x).toBeGreaterThan(-9000);
    expect(camera.y).toBeLessThan(9000);
  });

  test('centers content smaller than the viewport', () => {
    const camera = clampCamera({ x: 0, y: 0, zoom: 1 }, { width: 800, height: 600 }, { x: 100, y: 100, width: 200, height: 100 });
    expect(camera).toEqual({ x: 200, y: 150, zoom: 1 });
  });

  test('tidy creates deterministic collision-free rows inside zones', () => {
    const state = makeInitialState();
    const first = tidyLayout(state.tiles, state.zones);
    const second = tidyLayout(state.tiles, state.zones);
    expect(first).toEqual(second);
    for (const tile of Object.values(first.tiles).filter((item) => item.open && item.zoneId)) {
      const zone = first.zones[tile.zoneId!];
      expect(tile.frame.x).toBeGreaterThanOrEqual(zone.frame.x);
      expect(tile.frame.y).toBeGreaterThanOrEqual(zone.frame.y);
      expect(tile.frame.x + tile.frame.width).toBeLessThanOrEqual(zone.frame.x + zone.frame.width);
      expect(tile.frame.y + tile.frame.height).toBeLessThanOrEqual(zone.frame.y + zone.frame.height);
    }
  });
});
