import { useEffect, useMemo, useRef, useState } from 'react';
import type { Dispatch, PointerEvent as ReactPointerEvent, WheelEvent as ReactWheelEvent } from 'react';
import type { CameraState, DemoAction, DemoState, Tile } from '../../../features/demo/types';
import { COMPANION_WORLD, fitCompanionCamera, focusCompanionCamera, zoomCompanionCamera } from './companionGeometry';
import styles from './companion.module.css';
import { Glyph } from '../Glyph';

interface Props {
  state: DemoState;
  dispatch: Dispatch<DemoAction>;
  focusTileId?: string | null;
}

type Gesture =
  | { mode: 'pan'; pointerId: number; startX: number; startY: number; camera: CameraState }
  | { mode: 'pinch'; distance: number; centerX: number; centerY: number; camera: CameraState };

const tileGlyph: Record<Tile['kind'], string> = { agent: '◉', browser: '◫', shell: '›_', note: '≡' };

export function CompanionCanvas({ state, dispatch, focusTileId }: Props) {
  const surfaceRef = useRef<HTMLDivElement>(null);
  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const gesture = useRef<Gesture | null>(null);
  const previewRef = useRef(state.companionCamera);
  const [preview, setPreview] = useState(state.companionCamera);

  useEffect(() => {
    if (gesture.current) return;
    previewRef.current = state.companionCamera;
    setPreview(state.companionCamera);
  }, [state.companionCamera]);

  useEffect(() => {
    if (!focusTileId) return;
    const tile = state.tiles[focusTileId];
    const surface = surfaceRef.current;
    if (!tile || !surface) return;
    const next = focusCompanionCamera(tile.frame, surface.clientWidth, surface.clientHeight);
    previewRef.current = next;
    setPreview(next);
    dispatch({ type: 'SET_CAMERA', device: 'companion', camera: next });
  }, [dispatch, focusTileId, state.tiles]);

  const orderedTiles = useMemo(() => Object.values(state.tiles).filter((tile) => tile.open).sort((a, b) => a.z - b.z), [state.tiles]);

  const commit = (camera = previewRef.current) => dispatch({ type: 'SET_CAMERA', device: 'companion', camera });
  const updatePreview = (camera: CameraState) => { previewRef.current = camera; setPreview(camera); };

  const fit = () => {
    const surface = surfaceRef.current;
    if (!surface) return;
    const next = fitCompanionCamera(surface.clientWidth, surface.clientHeight);
    updatePreview(next);
    commit(next);
  };

  const zoomAtCenter = (factor: number) => {
    const surface = surfaceRef.current;
    if (!surface) return;
    const next = zoomCompanionCamera(previewRef.current, previewRef.current.zoom * factor, surface.clientWidth / 2, surface.clientHeight / 2);
    updatePreview(next);
    commit(next);
  };

  const startGesture = (event: ReactPointerEvent<HTMLDivElement>) => {
    if ((event.target as HTMLElement).closest('button')) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    const rect = event.currentTarget.getBoundingClientRect();
    pointers.current.set(event.pointerId, { x: event.clientX - rect.left, y: event.clientY - rect.top });
    const active = [...pointers.current.entries()];
    if (active.length === 1) {
      const [pointerId, point] = active[0];
      gesture.current = { mode: 'pan', pointerId, startX: point.x, startY: point.y, camera: previewRef.current };
    } else if (active.length === 2) {
      const first = active[0][1];
      const second = active[1][1];
      gesture.current = {
        mode: 'pinch',
        distance: Math.hypot(second.x - first.x, second.y - first.y),
        centerX: (first.x + second.x) / 2,
        centerY: (first.y + second.y) / 2,
        camera: previewRef.current
      };
    }
  };

  const moveGesture = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!pointers.current.has(event.pointerId) || !gesture.current) return;
    const rect = event.currentTarget.getBoundingClientRect();
    pointers.current.set(event.pointerId, { x: event.clientX - rect.left, y: event.clientY - rect.top });
    const active = [...pointers.current.values()];
    if (gesture.current.mode === 'pan' && active.length === 1) {
      const point = active[0];
      updatePreview({ ...gesture.current.camera, x: gesture.current.camera.x + point.x - gesture.current.startX, y: gesture.current.camera.y + point.y - gesture.current.startY });
    } else if (gesture.current.mode === 'pinch' && active.length >= 2) {
      const [first, second] = active;
      const distance = Math.max(1, Math.hypot(second.x - first.x, second.y - first.y));
      const centerX = (first.x + second.x) / 2;
      const centerY = (first.y + second.y) / 2;
      const scaled = zoomCompanionCamera(gesture.current.camera, gesture.current.camera.zoom * distance / Math.max(1, gesture.current.distance), gesture.current.centerX, gesture.current.centerY);
      updatePreview({ ...scaled, x: scaled.x + centerX - gesture.current.centerX, y: scaled.y + centerY - gesture.current.centerY });
    }
  };

  const endGesture = (event: ReactPointerEvent<HTMLDivElement>) => {
    pointers.current.delete(event.pointerId);
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
    const remaining = [...pointers.current.entries()];
    if (!remaining.length) {
      gesture.current = null;
      commit();
    } else {
      const [pointerId, point] = remaining[0];
      gesture.current = { mode: 'pan', pointerId, startX: point.x, startY: point.y, camera: previewRef.current };
    }
  };

  const onWheel = (event: ReactWheelEvent<HTMLDivElement>) => {
    event.preventDefault();
    const rect = event.currentTarget.getBoundingClientRect();
    const camera = event.ctrlKey || event.metaKey
      ? zoomCompanionCamera(previewRef.current, previewRef.current.zoom * Math.exp(-event.deltaY * 0.006), event.clientX - rect.left, event.clientY - rect.top)
      : { ...previewRef.current, x: previewRef.current.x - event.deltaX, y: previewRef.current.y - event.deltaY };
    updatePreview(camera);
    commit(camera);
  };

  return (
    <div className={styles.canvasShell}>
      <div className={styles.canvasToolbar} role="toolbar" aria-label="Companion canvas controls">
        <button type="button" aria-label="Zoom out" data-interaction-id="companion-zoom-out" onClick={() => zoomAtCenter(0.84)}><Glyph name="collapse" /></button>
        <button type="button" aria-label="Fit all" data-testid="companion-fit" data-interaction-id="companion-fit" onClick={fit}><Glyph name="fit" /></button>
        <button type="button" aria-label="Zoom in" data-interaction-id="companion-zoom-in" onClick={() => zoomAtCenter(1.19)}><Glyph name="expand" /></button>
      </div>
      <div
        className={styles.canvasViewport}
        ref={surfaceRef}
        data-testid="companion-canvas"
        data-interaction-id="companion-canvas-pan-zoom"
        onPointerDown={startGesture}
        onPointerMove={moveGesture}
        onPointerUp={endGesture}
        onPointerCancel={endGesture}
        onWheel={onWheel}
      >
        <div className={styles.canvasWorld} style={{ width: COMPANION_WORLD.width, height: COMPANION_WORLD.height, transform: `translate3d(${preview.x}px, ${preview.y}px, 0) scale(${preview.zoom})` }}>
          {Object.values(state.zones).map((zone) => (
            <section className={`${styles.mobileZone} ${styles[`zone_${zone.color}`]}`} style={{ left: zone.frame.x, top: zone.frame.y, width: zone.frame.width, height: zone.frame.height }} key={zone.id} aria-label={`${zone.name} zone`}>
              <header><strong>{zone.name}</strong><span>{Object.values(state.tiles).filter((tile) => tile.open && tile.zoneId === zone.id).length} surfaces</span></header>
            </section>
          ))}
          {orderedTiles.map((tile) => {
            const agent = tile.kind === 'agent' ? state.agents[tile.id] : undefined;
            return (
              <button
                className={`${styles.mobileTile} ${state.selectedEntityId === tile.id ? styles.mobileTileSelected : ''}`}
                style={{ left: tile.frame.x, top: tile.frame.y, width: tile.frame.width, height: tile.frame.height, zIndex: tile.z }}
                key={tile.id}
                type="button"
                data-companion-tile={tile.id}
                data-interaction-id={`companion-tile-select-${tile.id}`}
                onClick={() => dispatch({ type: 'SELECT_ENTITY', id: tile.id })}
              >
                <span className={styles.tileKind} aria-hidden="true">{tileGlyph[tile.kind]}</span>
                <strong>{tile.title}</strong>
                <small>{agent ? agent.status === 'needsAttention' ? 'Needs attention' : agent.status : tile.kind}</small>
              </button>
            );
          })}
        </div>
      </div>
      <p className={styles.canvasHint}>Pan to move · pinch to zoom · tap a tile to link it</p>
    </div>
  );
}
