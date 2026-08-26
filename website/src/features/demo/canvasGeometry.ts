import type { CameraState, Frame, Tile, Zone } from './types';

const finite = (value: number, fallback = 0) => Number.isFinite(value) ? value : fallback;

export function workspaceBounds(tiles: Record<string, Tile>, zones: Record<string, Zone>): Frame | null {
  const frames = [
    ...Object.values(zones).map((zone) => zone.frame),
    ...Object.values(tiles).filter((tile) => tile.open && (!tile.zoneId || !zones[tile.zoneId])).map((tile) => tile.frame),
  ].filter((item) => item.width > 0 && item.height > 0);
  if (!frames.length) return null;
  const left = Math.min(...frames.map((item) => item.x));
  const top = Math.min(...frames.map((item) => item.y));
  const right = Math.max(...frames.map((item) => item.x + item.width));
  const bottom = Math.max(...frames.map((item) => item.y + item.height));
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export function clampCamera(camera: CameraState, viewport: { width: number; height: number }, bounds: Frame | null, visibleFloor = 120): CameraState {
  const zoom = Math.max(.35, Math.min(1.5, finite(camera.zoom, 1)));
  if (!bounds || viewport.width <= 0 || viewport.height <= 0) return { x: finite(camera.x), y: finite(camera.y), zoom };

  const clampAxis = (position: number, viewportSize: number, origin: number, size: number) => {
    const scaledSize = size * zoom;
    if (scaledSize + visibleFloor * 2 <= viewportSize) return (viewportSize - scaledSize) / 2 - origin * zoom;
    const minimum = visibleFloor - (origin + size) * zoom;
    const maximum = viewportSize - visibleFloor - origin * zoom;
    return Math.max(minimum, Math.min(maximum, finite(position)));
  };

  return {
    x: clampAxis(camera.x, viewport.width, bounds.x, bounds.width),
    y: clampAxis(camera.y, viewport.height, bounds.y, bounds.height),
    zoom,
  };
}

export function tidyLayout(tiles: Record<string, Tile>, zones: Record<string, Zone>) {
  const nextTiles = structuredClone(tiles);
  const nextZones = structuredClone(zones);
  const gap = 16;
  const horizontalPadding = 24;
  const topPadding = 54;
  const bottomPadding = 24;

  for (const zone of Object.values(nextZones)) {
    if (zone.collapsed) continue;
    const members = Object.values(nextTiles)
      .filter((tile) => tile.open && tile.zoneId === zone.id)
      .sort((a, b) => a.frame.y - b.frame.y || a.frame.x - b.frame.x || a.id.localeCompare(b.id));
    if (!members.length) continue;

    const usableWidth = Math.max(220, zone.frame.width - horizontalPadding * 2);
    let x = zone.frame.x + horizontalPadding;
    let y = zone.frame.y + topPadding;
    let rowHeight = 0;
    let furthestBottom = y;

    for (const tile of members) {
      const width = Math.min(tile.frame.width, usableWidth);
      if (x > zone.frame.x + horizontalPadding && x + width > zone.frame.x + zone.frame.width - horizontalPadding) {
        x = zone.frame.x + horizontalPadding;
        y += rowHeight + gap;
        rowHeight = 0;
      }
      tile.frame = { ...tile.frame, x: Math.round(x), y: Math.round(y), width: Math.round(width) };
      x += width + gap;
      rowHeight = Math.max(rowHeight, tile.frame.height);
      furthestBottom = Math.max(furthestBottom, y + tile.frame.height);
    }
    zone.frame.height = Math.max(zone.frame.height, Math.ceil(furthestBottom - zone.frame.y + bottomPadding));
  }

  return { tiles: nextTiles, zones: nextZones };
}
