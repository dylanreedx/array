import type { CameraState, Frame } from '../../../features/demo/types';

export const COMPANION_WORLD = { width: 1340, height: 720 } as const;
export const MIN_ZOOM = 0.16;
export const MAX_ZOOM = 0.9;

export function clampZoom(zoom: number): number {
  return Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom));
}

export function fitCompanionCamera(width: number, height: number, padding = 28): CameraState {
  const availableWidth = Math.max(1, width - padding * 2);
  const availableHeight = Math.max(1, height - padding * 2);
  const zoom = clampZoom(Math.min(availableWidth / COMPANION_WORLD.width, availableHeight / COMPANION_WORLD.height));
  return {
    x: (width - COMPANION_WORLD.width * zoom) / 2,
    y: (height - COMPANION_WORLD.height * zoom) / 2,
    zoom
  };
}

export function zoomCompanionCamera(
  camera: CameraState,
  nextZoom: number,
  anchorX: number,
  anchorY: number
): CameraState {
  const zoom = clampZoom(nextZoom);
  const worldX = (anchorX - camera.x) / camera.zoom;
  const worldY = (anchorY - camera.y) / camera.zoom;
  return { x: anchorX - worldX * zoom, y: anchorY - worldY * zoom, zoom };
}

export function focusCompanionCamera(frame: Frame, width: number, height: number): CameraState {
  const zoom = clampZoom(Math.min(0.62, (width * 0.62) / Math.max(frame.width, 1), (height * 0.5) / Math.max(frame.height, 1)));
  return {
    x: width / 2 - (frame.x + frame.width / 2) * zoom,
    y: height / 2 - (frame.y + frame.height / 2) * zoom,
    zoom
  };
}
