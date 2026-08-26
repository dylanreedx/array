import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type Dispatch,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from 'react';
import type { Agent, DemoAction, DemoState, Frame, Tile, Zone } from '../../../features/demo/types';
import { clampCamera, workspaceBounds } from '../../../features/demo/canvasGeometry';
import styles from './MacWorkspace.module.css';
import { Glyph } from '../Glyph';
import { AgentGyro } from '../agent';
import { ProviderMark } from '../ProviderMark';

export interface MacTileRenderContext {
  tile: Tile;
  state: DemoState;
  dispatch: Dispatch<DemoAction>;
}

export interface MacWorkspaceProps {
  state: DemoState;
  dispatch: Dispatch<DemoAction>;
  renderTileContent?: (context: MacTileRenderContext) => ReactNode;
  className?: string;
  workspaceName?: string;
}

type DragState =
  | { kind: 'pan'; pointerId: number; clientX: number; clientY: number; cameraX: number; cameraY: number }
  | { kind: 'zone-create'; pointerId: number; worldX: number; worldY: number }
  | { kind: 'tile'; pointerId: number; id: string; worldX: number; worldY: number; frame: Frame }
  | { kind: 'resize'; pointerId: number; id: string; worldX: number; worldY: number; frame: Frame }
  | { kind: 'zone-resize'; pointerId: number; id: string; worldX: number; worldY: number; frame: Frame }
  | { kind: 'zone'; pointerId: number; id: string; worldX: number; worldY: number; frame: Frame; tileFrames: Record<string, Frame> };

const zoneColors: Record<Zone['color'], string> = {
  mint: '#39a878',
  blue: '#4b76d1',
  purple: '#8b62c7',
  orange: '#c77a35',
};

const kindGlyph: Record<Tile['kind'], string> = {
  agent: '✣',
  browser: '◎',
  shell: '›_',
  note: '▤',
};

const scopeLabel: Record<DemoState['agentScope'], string> = {
  all: 'All agents',
  working: 'Working',
  attention: 'Needs attention',
  done: 'Done',
};

const interactiveTarget = (target: EventTarget | null) =>
  target instanceof HTMLElement && Boolean(target.closest('button, input, select, textarea, a, [role="menu"]'));

const statusClass = (status: Agent['status']) => {
  if (status === 'working' || status === 'starting') return styles.stateWorking;
  if (status === 'needsAttention') return styles.stateAttention;
  if (status === 'done' || status === 'idle') return styles.stateDone;
  return styles.stateStopped;
};

const statusText = (status: Agent['status']) => {
  if (status === 'needsAttention') return 'Needs attention';
  if (status === 'starting') return 'Starting';
  return status[0].toUpperCase() + status.slice(1);
};

function centerOf(frame: Frame) {
  return { x: frame.x + frame.width / 2, y: frame.y + frame.height / 2 };
}

function contains(frame: Frame, point: { x: number; y: number }) {
  return point.x >= frame.x && point.x <= frame.x + frame.width && point.y >= frame.y && point.y <= frame.y + frame.height;
}

export default function MacWorkspace({
  state,
  dispatch,
  renderTileContent,
  className = '',
  workspaceName = 'Array website',
}: MacWorkspaceProps) {
  const canvasRef = useRef<HTMLDivElement>(null);
  const zoneDraftRef = useRef<HTMLDivElement>(null);
  const drag = useRef<DragState | null>(null);
  const keyboardEdit = useRef<{ id: string; kind: 'tile' | 'zone'; mode: 'move' | 'resize'; frame: Frame; tileFrames?: Record<string, Frame> } | null>(null);
  const [spaceHeld, setSpaceHeld] = useState(false);
  const [zoneMode, setZoneMode] = useState(false);
  const [manipulatingId, setManipulatingId] = useState<string | null>(null);
  const [boundaryPulse, setBoundaryPulse] = useState(false);
  const [menu, setMenu] = useState<{ type: 'tile' | 'zone' | 'workspace'; id?: string; x: number; y: number } | null>(null);
  const acceptsWorkspaceInput = state.inputMode === 'workspace' && state.deviceFocus === 'mac';

  const openTiles = useMemo(() => Object.values(state.tiles).filter((tile) => tile.open), [state.tiles]);
  const contentBounds = useMemo(() => workspaceBounds(state.tiles, state.zones), [state.tiles, state.zones]);
  const filteredAgents = useMemo(() => {
    const query = state.agentQuery.trim().toLowerCase();
    return Object.values(state.agents).filter((agent) => {
      const scopeMatches = state.agentScope === 'all'
        || (state.agentScope === 'working' && ['working', 'starting'].includes(agent.status))
        || (state.agentScope === 'attention' && agent.status === 'needsAttention')
        || (state.agentScope === 'done' && ['done', 'idle', 'stopped'].includes(agent.status));
      const queryMatches = !query || [agent.name, agent.branch, agent.provider, agent.model, agent.summary]
        .some((value) => value.toLowerCase().includes(query));
      return scopeMatches && queryMatches;
    });
  }, [state.agentQuery, state.agentScope, state.agents]);

  const screenToWorld = useCallback((clientX: number, clientY: number) => {
    const rect = canvasRef.current?.getBoundingClientRect();
    if (!rect) return { x: 0, y: 0 };
    return {
      x: (clientX - rect.left - state.macCamera.x) / state.macCamera.zoom,
      y: (clientY - rect.top - state.macCamera.y) / state.macCamera.zoom,
    };
  }, [state.macCamera]);

  const boundedCamera = useCallback((camera: DemoState['macCamera']) => {
    const canvas = canvasRef.current;
    if (!canvas) return camera;
    const next = clampCamera(camera, { width: canvas.clientWidth, height: canvas.clientHeight }, contentBounds);
    if (Math.abs(next.x - camera.x) > .5 || Math.abs(next.y - camera.y) > .5) {
      setBoundaryPulse(true);
      window.setTimeout(() => setBoundaryPulse(false), 520);
    }
    return next;
  }, [contentBounds]);

  const setZoom = useCallback((zoom: number, anchor?: { x: number; y: number }) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const nextZoom = Math.max(0.35, Math.min(1.5, zoom));
    const rect = canvas.getBoundingClientRect();
    const point = anchor ?? { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
    const worldX = (point.x - rect.left - state.macCamera.x) / state.macCamera.zoom;
    const worldY = (point.y - rect.top - state.macCamera.y) / state.macCamera.zoom;
    dispatch({
      type: 'SET_CAMERA',
      device: 'mac',
      camera: boundedCamera({
        x: point.x - rect.left - worldX * nextZoom,
        y: point.y - rect.top - worldY * nextZoom,
        zoom: nextZoom,
      }),
    });
  }, [boundedCamera, dispatch, state.macCamera]);

  const fitCanvas = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const items = [
      ...Object.values(state.zones).map((zone) => zone.frame),
      ...openTiles.filter((tile) => !tile.zoneId || !state.zones[tile.zoneId]).map((tile) => tile.frame),
    ];
    if (!items.length) return;
    const minX = Math.min(...items.map((item) => item.x));
    const minY = Math.min(...items.map((item) => item.y));
    const maxX = Math.max(...items.map((item) => item.x + item.width));
    const maxY = Math.max(...items.map((item) => item.y + item.height));
    const rect = canvas.getBoundingClientRect();
    const padding = 54;
    const zoom = Math.max(0.35, Math.min(1.1, Math.min((rect.width - padding * 2) / (maxX - minX), (rect.height - padding * 2) / (maxY - minY))));
    dispatch({ type: 'SET_CAMERA', device: 'mac', camera: boundedCamera({ x: padding - minX * zoom, y: padding - minY * zoom, zoom }) });
  }, [boundedCamera, dispatch, openTiles, state.zones]);

  const releasePointerCapture = useCallback((pointerId: number) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    [canvas, ...Array.from(canvas.querySelectorAll<HTMLElement>('*'))].forEach((element) => {
      if (element.hasPointerCapture?.(pointerId)) element.releasePointerCapture(pointerId);
    });
  }, []);

  const cancelPointerGesture = useCallback(() => {
    const gesture = drag.current;
    if (!gesture) return false;
    if (gesture.kind === 'pan') dispatch({ type: 'SET_CAMERA', device: 'mac', camera: { ...state.macCamera, x: gesture.cameraX, y: gesture.cameraY } });
    if (gesture.kind === 'tile') dispatch({ type: 'MOVE_TILE', id: gesture.id, frame: gesture.frame });
    if (gesture.kind === 'resize') dispatch({ type: 'RESIZE_TILE', id: gesture.id, frame: gesture.frame });
    if (gesture.kind === 'zone-resize') dispatch({ type: 'UPDATE_ZONE', id: gesture.id, patch: { frame: gesture.frame } });
    if (gesture.kind === 'zone') dispatch({ type: 'MOVE_ZONE', id: gesture.id, frame: gesture.frame, tileFrames: gesture.tileFrames });
    if (gesture.kind === 'zone-create') {
      if (zoneDraftRef.current) zoneDraftRef.current.hidden = true;
      setZoneMode(false);
    }
    releasePointerCapture(gesture.pointerId);
    drag.current = null;
    setManipulatingId(null);
    setMenu(null);
    return true;
  }, [dispatch, releasePointerCapture, state.macCamera]);

  const cancelKeyboardEdit = useCallback(() => {
    const edit = keyboardEdit.current;
    if (!edit) return false;
    if (edit.kind === 'tile') dispatch({ type: edit.mode === 'move' ? 'MOVE_TILE' : 'RESIZE_TILE', id: edit.id, frame: edit.frame });
    else if (edit.mode === 'move') dispatch({ type: 'MOVE_ZONE', id: edit.id, frame: edit.frame, tileFrames: edit.tileFrames ?? {} });
    else dispatch({ type: 'UPDATE_ZONE', id: edit.id, patch: { frame: edit.frame } });
    keyboardEdit.current = null;
    return true;
  }, [dispatch]);

  const releaseWorkspaceInput = useCallback(() => {
    cancelPointerGesture();
    cancelKeyboardEdit();
    setSpaceHeld(false);
    setZoneMode(false);
    setMenu(null);
    dispatch({ type: 'SET_INPUT_MODE', mode: 'page' });
  }, [cancelKeyboardEdit, cancelPointerGesture, dispatch]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!acceptsWorkspaceInput) return;
      if (event.key === 'Escape' && drag.current) {
        event.preventDefault();
        releaseWorkspaceInput();
        return;
      }
      if (event.code === 'Space' && !interactiveTarget(event.target)) setSpaceHeld(true);
      if (interactiveTarget(event.target)) {
        if (event.key === 'Escape') setMenu(null);
        return;
      }
      const command = event.metaKey || event.ctrlKey;
      if (command && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        dispatch({ type: 'OPEN_COMMAND', open: true });
      } else if (command && event.shiftKey && event.key.toLowerCase() === 's') {
        event.preventDefault();
        dispatch({ type: 'SET_SIDEBAR', open: !state.sidebarOpen });
      } else if (command && event.key.toLowerCase() === 'z' && !event.shiftKey) {
        event.preventDefault();
        dispatch({ type: 'UNDO' });
      } else if (command && (event.key === '=' || event.key === '+')) {
        event.preventDefault();
        setZoom(state.macCamera.zoom + 0.1);
      } else if (command && event.key === '-') {
        event.preventDefault();
        setZoom(state.macCamera.zoom - 0.1);
      } else if (command && event.key === '0') {
        event.preventDefault();
        fitCanvas();
      } else if (event.key.toLowerCase() === 'm' || event.key.toLowerCase() === 'r') {
        const id = state.selectedEntityId;
        const tile = id ? state.tiles[id] : undefined;
        const zone = id ? state.zones[id] : undefined;
        if (tile || zone) {
          event.preventDefault();
          keyboardEdit.current = { id: id!, kind: tile ? 'tile' : 'zone', mode: event.key.toLowerCase() === 'm' ? 'move' : 'resize', frame: { ...(tile ?? zone!).frame }, tileFrames: zone ? Object.fromEntries(Object.values(state.tiles).filter((item) => item.zoneId === zone.id).map((item) => [item.id, { ...item.frame }])) : undefined };
        }
      } else if (keyboardEdit.current && ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) {
        event.preventDefault();
        const edit = keyboardEdit.current;
        const amount = event.shiftKey ? 1 : 16;
        const dx = event.key === 'ArrowLeft' ? -amount : event.key === 'ArrowRight' ? amount : 0;
        const dy = event.key === 'ArrowUp' ? -amount : event.key === 'ArrowDown' ? amount : 0;
        if (edit.kind === 'tile') {
          const tile = state.tiles[edit.id];
          const frame = edit.mode === 'move' ? { ...tile.frame, x: tile.frame.x + dx, y: tile.frame.y + dy } : { ...tile.frame, width: Math.max(220, tile.frame.width + dx), height: Math.max(140, tile.frame.height + dy) };
          dispatch({ type: edit.mode === 'move' ? 'MOVE_TILE' : 'RESIZE_TILE', id: edit.id, frame });
        } else {
          const zone = state.zones[edit.id];
          if (edit.mode === 'move') {
            const tileFrames = Object.fromEntries(Object.values(state.tiles).filter((item) => item.zoneId === edit.id).map((item) => [item.id, { ...item.frame, x: item.frame.x + dx, y: item.frame.y + dy }]));
            dispatch({ type: 'MOVE_ZONE', id: edit.id, frame: { ...zone.frame, x: zone.frame.x + dx, y: zone.frame.y + dy }, tileFrames });
          } else dispatch({ type: 'UPDATE_ZONE', id: edit.id, patch: { frame: { ...zone.frame, width: Math.max(320, zone.frame.width + dx), height: Math.max(180, zone.frame.height + dy) } } });
        }
      } else if (keyboardEdit.current && event.key === 'Enter') {
        event.preventDefault(); keyboardEdit.current = null;
      } else if (event.key === 'Escape') {
        if (canvasRef.current?.contains(event.target as Node) || keyboardEdit.current || menu) {
          event.preventDefault();
          releaseWorkspaceInput();
        }
      } else if ((event.key === 'Backspace' || event.key === 'Delete') && state.selectedEntityId && state.tiles[state.selectedEntityId]?.open) {
        event.preventDefault();
        dispatch({ type: 'CLOSE_TILE', id: state.selectedEntityId });
      }
    };
    const onKeyUp = (event: KeyboardEvent) => { if (event.code === 'Space') setSpaceHeld(false); };
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
    };
  }, [acceptsWorkspaceInput, dispatch, fitCanvas, menu, releaseWorkspaceInput, setZoom, state.macCamera.zoom, state.selectedEntityId, state.sidebarOpen, state.tiles]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !acceptsWorkspaceInput) return;
    const handleWheel = (event: WheelEvent) => {
      event.preventDefault();
      event.stopPropagation();
      if (event.ctrlKey || event.metaKey) {
        setZoom(state.macCamera.zoom * Math.exp(-event.deltaY * 0.002), { x: event.clientX, y: event.clientY });
      } else {
        dispatch({ type: 'SET_CAMERA', device: 'mac', camera: boundedCamera({ ...state.macCamera, x: state.macCamera.x - event.deltaX, y: state.macCamera.y - event.deltaY }) });
      }
    };
    canvas.addEventListener('wheel', handleWheel, { passive: false });
    return () => canvas.removeEventListener('wheel', handleWheel);
  }, [acceptsWorkspaceInput, boundedCamera, dispatch, setZoom, state.macCamera]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const keepBounded = () => {
      const next = boundedCamera(state.macCamera);
      if (Math.abs(next.x - state.macCamera.x) > .5 || Math.abs(next.y - state.macCamera.y) > .5 || Math.abs(next.zoom - state.macCamera.zoom) > .001) {
        dispatch({ type: 'SET_CAMERA', device: 'mac', camera: next });
      }
    };
    const observer = new ResizeObserver(keepBounded);
    observer.observe(canvas);
    keepBounded();
    return () => observer.disconnect();
  }, [boundedCamera, dispatch, state.macCamera]);

  const beginPan = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!acceptsWorkspaceInput) return;
    const target = event.target instanceof HTMLElement ? event.target : null;
    const overEntity = Boolean(target?.closest(`.${styles.tile}, .${styles.zone}`));
    if (event.button !== 0 || (overEntity && !spaceHeld)) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    if (zoneMode && !spaceHeld) {
      const point = screenToWorld(event.clientX, event.clientY);
      drag.current = { kind: 'zone-create', pointerId: event.pointerId, worldX: point.x, worldY: point.y };
      if (zoneDraftRef.current) {
        zoneDraftRef.current.hidden = false;
        Object.assign(zoneDraftRef.current.style, { left: `${point.x}px`, top: `${point.y}px`, width: '1px', height: '1px' });
      }
      return;
    }
    drag.current = { kind: 'pan', pointerId: event.pointerId, clientX: event.clientX, clientY: event.clientY, cameraX: state.macCamera.x, cameraY: state.macCamera.y };
    dispatch({ type: 'SELECT_ENTITY', id: null });
    setMenu(null);
  };

  const beginTileDrag = (event: ReactPointerEvent, tile: Tile) => {
    if (!acceptsWorkspaceInput) return;
    if (event.button !== 0 || interactiveTarget(event.target)) return;
    event.stopPropagation();
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
    const point = screenToWorld(event.clientX, event.clientY);
    drag.current = { kind: 'tile', pointerId: event.pointerId, id: tile.id, worldX: point.x, worldY: point.y, frame: tile.frame };
    setManipulatingId(tile.id);
    dispatch({ type: 'SELECT_ENTITY', id: tile.id });
  };

  const beginResize = (event: ReactPointerEvent, tile: Tile) => {
    if (!acceptsWorkspaceInput) return;
    event.stopPropagation();
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
    const point = screenToWorld(event.clientX, event.clientY);
    drag.current = { kind: 'resize', pointerId: event.pointerId, id: tile.id, worldX: point.x, worldY: point.y, frame: tile.frame };
    setManipulatingId(tile.id);
    dispatch({ type: 'SELECT_ENTITY', id: tile.id });
  };

  const beginZoneDrag = (event: ReactPointerEvent, zone: Zone) => {
    if (!acceptsWorkspaceInput) return;
    if (event.button !== 0 || interactiveTarget(event.target)) return;
    event.stopPropagation();
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
    const point = screenToWorld(event.clientX, event.clientY);
    drag.current = {
      kind: 'zone', pointerId: event.pointerId, id: zone.id, worldX: point.x, worldY: point.y, frame: zone.frame,
      tileFrames: Object.fromEntries(Object.values(state.tiles).filter((tile) => tile.zoneId === zone.id).map((tile) => [tile.id, tile.frame])),
    };
    setManipulatingId(zone.id);
    dispatch({ type: 'SELECT_ENTITY', id: zone.id });
  };

  const beginZoneResize = (event: ReactPointerEvent, zone: Zone) => {
    if (!acceptsWorkspaceInput) return;
    event.stopPropagation();
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
    const point = screenToWorld(event.clientX, event.clientY);
    drag.current = { kind: 'zone-resize', pointerId: event.pointerId, id: zone.id, worldX: point.x, worldY: point.y, frame: zone.frame };
    setManipulatingId(zone.id);
    dispatch({ type: 'SELECT_ENTITY', id: zone.id });
  };

  const movePointer = (event: ReactPointerEvent<HTMLDivElement>) => {
    const active = drag.current;
    if (!active || active.pointerId !== event.pointerId) return;
    if (active.kind === 'pan') {
      dispatch({ type: 'SET_CAMERA', device: 'mac', camera: boundedCamera({ ...state.macCamera, x: active.cameraX + event.clientX - active.clientX, y: active.cameraY + event.clientY - active.clientY }) });
      return;
    }
    const point = screenToWorld(event.clientX, event.clientY);
    if (active.kind === 'zone-create') {
      const frame = { x: Math.min(active.worldX, point.x), y: Math.min(active.worldY, point.y), width: Math.abs(point.x - active.worldX), height: Math.abs(point.y - active.worldY) };
      if (zoneDraftRef.current) Object.assign(zoneDraftRef.current.style, { left: `${frame.x}px`, top: `${frame.y}px`, width: `${frame.width}px`, height: `${frame.height}px` });
      return;
    }
    const dx = point.x - active.worldX;
    const dy = point.y - active.worldY;
    if (active.kind === 'tile') {
      dispatch({ type: 'MOVE_TILE', id: active.id, frame: { ...active.frame, x: Math.round(active.frame.x + dx), y: Math.round(active.frame.y + dy) } });
    } else if (active.kind === 'resize') {
      dispatch({ type: 'RESIZE_TILE', id: active.id, frame: { ...active.frame, width: Math.max(180, Math.round(active.frame.width + dx)), height: Math.max(100, Math.round(active.frame.height + dy)) } });
    } else if (active.kind === 'zone-resize') {
      dispatch({
        type: 'UPDATE_ZONE',
        id: active.id,
        patch: { frame: { ...active.frame, width: Math.max(300, Math.round(active.frame.width + dx)), height: Math.max(180, Math.round(active.frame.height + dy)) } },
      });
    } else {
      const tileFrames = Object.fromEntries(Object.entries(active.tileFrames).map(([id, item]) => [id, { ...item, x: Math.round(item.x + dx), y: Math.round(item.y + dy) }]));
      dispatch({ type: 'MOVE_ZONE', id: active.id, frame: { ...active.frame, x: Math.round(active.frame.x + dx), y: Math.round(active.frame.y + dy) }, tileFrames });
    }
  };

  const endPointer = (event: ReactPointerEvent<HTMLDivElement>) => {
    const active = drag.current;
    if (!active || active.pointerId !== event.pointerId) return;
    if (active.kind === 'zone-create') {
      const point = screenToWorld(event.clientX, event.clientY);
      const frame = { x: Math.round(Math.min(active.worldX, point.x)), y: Math.round(Math.min(active.worldY, point.y)), width: Math.round(Math.abs(point.x - active.worldX)), height: Math.round(Math.abs(point.y - active.worldY)) };
      if (frame.width >= 120 && frame.height >= 100) dispatch({ type: 'CREATE_ZONE', zone: { id: `zone-${Date.now()}`, name: `New zone ${Object.keys(state.zones).length + 1}`, color: 'blue', frame, collapsed: false } });
      if (zoneDraftRef.current) zoneDraftRef.current.hidden = true;
      setZoneMode(false);
    }
    if (active.kind === 'tile') {
      const tile = state.tiles[active.id];
      if (tile) {
        const point = centerOf(tile.frame);
        const zone = Object.values(state.zones).find((candidate) => contains(candidate.frame, point));
        const zoneId = zone?.id ?? null;
        if (zoneId !== tile.zoneId) dispatch({ type: 'MOVE_TILE', id: tile.id, frame: tile.frame, zoneId });
      }
    }
    if (active.kind === 'resize') dispatch({ type: 'TIDY' });
    drag.current = null;
    setManipulatingId(null);
    if ((event.currentTarget as HTMLElement).hasPointerCapture(event.pointerId)) (event.currentTarget as HTMLElement).releasePointerCapture(event.pointerId);
  };

  const showMenu = (event: ReactPointerEvent | React.MouseEvent, next: typeof menu) => {
    event.stopPropagation();
    setMenu(next);
  };

  const renderPlaceholder = (tile: Tile) => (
    <div className={styles.placeholder} aria-hidden="true">
      <span>{tile.kind === 'agent' ? 'Managed agent content' : `${tile.kind} content`} plugs in here.</span>
    </div>
  );

  return (
    <section className={`${styles.workspace} ${className}`} aria-label="Array Mac workspace" data-mac-workspace>
      <header className={styles.topbar} data-assembly-chrome="topbar">
        <span className={styles.workspaceName}>{workspaceName}</span>
        <span className={styles.topMeta}>{Object.keys(state.zones).length} zones · {openTiles.length} tiles</span>
        <span className={styles.saveState}>Saved</span>
        <span className={styles.topSpacer} />
        <button type="button" className={`${styles.button} ${styles.commandButton}`} data-interaction-id="command-open" onClick={() => dispatch({ type: 'OPEN_COMMAND', open: true })}>
          Add or jump… <kbd>⌘K</kbd>
        </button>
        <button type="button" className={styles.button} data-interaction-id="command-new" onClick={() => dispatch({ type: 'OPEN_COMMAND', open: true, query: 'New' })}>New</button>
        <button type="button" className={styles.iconButton} aria-label={state.sidebarOpen ? 'Hide agent sidebar' : 'Show agent sidebar'} data-interaction-id="sidebar-toggle" onClick={() => dispatch({ type: 'SET_SIDEBAR', open: !state.sidebarOpen })}>☰</button>
        <button type="button" className={styles.iconButton} aria-label="Workspace menu" aria-haspopup="menu" data-interaction-id="workspace-overflow" onClick={(event) => showMenu(event, { type: 'workspace', x: event.clientX, y: event.clientY })}>•••</button>
      </header>

      <div className={`${styles.body} ${state.sidebarOpen ? '' : styles.bodySidebarClosed}`} data-assembly-chrome="body">
        <aside className={styles.sidebar} aria-hidden={!state.sidebarOpen} data-assembly-chrome="sidebar">
          <div className={styles.sidebarInner}>
            <h2 className={styles.sidebarTitle}>Agents</h2>
            <input className={styles.search} value={state.agentQuery} placeholder="Search agents" aria-label="Search agents" data-interaction-id="agent-search" onChange={(event) => dispatch({ type: 'SET_AGENT_QUERY', query: event.currentTarget.value })} />
            <select className={styles.scope} value={state.agentScope} aria-label="Agent scope" data-interaction-id="agent-scope" onChange={(event) => dispatch({ type: 'SET_AGENT_SCOPE', scope: event.currentTarget.value as DemoState['agentScope'] })}>
              {Object.entries(scopeLabel).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </select>
            <div className={styles.agentList} role="list" aria-label="Agents">
              {filteredAgents.map((agent) => {
                const tile = state.tiles[agent.tileId];
                const selected = state.selectedEntityId === agent.tileId;
                return (
                  <div key={agent.id} role="listitem">
                    <button
                      type="button"
                      className={`${styles.agentRow} ${selected ? styles.agentSelected : ''} ${tile?.open ? '' : styles.agentClosed}`}
                      data-interaction-id={`agent-row-${agent.id}`}
                      aria-current={selected ? 'true' : undefined}
                      onClick={() => dispatch({ type: 'SELECT_ENTITY', id: agent.tileId })}
                    >
                      <span className={styles.agentMark} aria-hidden="true">{agent.status === 'working' || agent.status === 'starting' ? <AgentGyro active /> : <Glyph name={agent.status === 'needsAttention' ? 'attention' : 'check'} />}</span>
                      <span className={styles.agentMain}>
                        <span className={styles.agentContext}><ProviderMark provider={agent.provider} />{agent.provider}</span>
                        <span className={styles.agentName}>{agent.name}</span>
                        <span className={styles.agentBranch}>⌁ {agent.branch}</span>
                        <span className={styles.agentSummary}>{agent.summary}</span>
                      </span>
                      <span className={`${styles.agentState} ${statusClass(agent.status)}`}>{statusText(agent.status)}</span>
                    </button>
                    {tile && !tile.open && <button type="button" className={styles.reopenButton} data-interaction-id={`tile-reopen-${tile.id}`} onClick={() => dispatch({ type: 'REOPEN_TILE', id: tile.id })}>Reopen tile</button>}
                  </div>
                );
              })}
              {!filteredAgents.length && <p className={styles.empty}>No agents matching this view.</p>}
            </div>
          </div>
        </aside>

        <div className={styles.canvasShell} role="region" aria-label="Mac canvas" data-assembly-chrome="canvas-shell">
          <div className={`${styles.canvasToolbar} ${boundaryPulse ? styles.canvasToolbarBoundary : ''}`} aria-label="Canvas controls">
            {acceptsWorkspaceInput && <button type="button" className={`${styles.button} ${styles.doneButton}`} data-interaction-id="done-exploring" onClick={releaseWorkspaceInput}>Done</button>}
            <button type="button" className={styles.button} data-interaction-id="canvas-fit" onClick={fitCanvas}>Fit</button>
            <button type="button" className={styles.iconButton} aria-label="Zoom out" data-interaction-id="canvas-zoom-out" onClick={() => setZoom(state.macCamera.zoom - 0.1)}><Glyph name="collapse" /></button>
            <button type="button" className={styles.iconButton} aria-label="Zoom in" data-interaction-id="canvas-zoom-in" onClick={() => setZoom(state.macCamera.zoom + 0.1)}><Glyph name="expand" /></button>
            <button type="button" className={styles.button} data-interaction-id="canvas-tidy" onClick={() => dispatch({ type: 'TIDY' })}>Tidy</button>
            <button type="button" className={styles.button} data-interaction-id="canvas-shuffle" onClick={() => dispatch({ type: 'SHUFFLE' })}>Shuffle</button>
            <button type="button" className={styles.button} aria-pressed={zoneMode} data-interaction-id="canvas-new-zone" onClick={() => setZoneMode((value) => !value)}>{zoneMode ? 'Draw zone' : 'New zone'}</button>
          </div>

          <div
            ref={canvasRef}
            className={`${styles.canvas} ${acceptsWorkspaceInput ? styles.canvasInputActive : ''} ${drag.current?.kind === 'pan' ? styles.canvasPanning : ''} ${zoneMode ? styles.canvasZoneMode : ''}`}
            data-interaction-id="canvas-surface"
            data-assembly-chrome="canvas"
            tabIndex={acceptsWorkspaceInput ? 0 : -1}
            aria-label={acceptsWorkspaceInput ? 'Workspace canvas. Drag to pan; Command-scroll to zoom. Press Escape to return to page scrolling.' : 'Workspace canvas preview'}
            onPointerDown={beginPan}
            onPointerMove={movePointer}
            onPointerUp={endPointer}
            onPointerCancel={endPointer}
            onDoubleClick={(event) => { if (event.target === event.currentTarget) fitCanvas(); }}
          >
            <div className={styles.world} data-assembly-chrome="world" style={{ transform: `translate(${state.macCamera.x}px, ${state.macCamera.y}px) scale(${state.macCamera.zoom})` }} aria-hidden="false">
              <div ref={zoneDraftRef} className={styles.zoneDraft} hidden aria-hidden="true" />
              {Object.values(state.zones).map((zone) => {
                const memberCount = openTiles.filter((tile) => tile.zoneId === zone.id).length;
                return (
                  <section
                    key={zone.id}
                    data-assembly-chrome={`zone-${zone.id}`}
                    className={`${styles.zone} ${state.selectedEntityId === zone.id ? styles.zoneSelected : ''} ${zone.collapsed ? styles.zoneCollapsed : ''} ${manipulatingId === zone.id ? styles.geometryDirect : ''}`}
                    style={{ left: zone.frame.x, top: zone.frame.y, width: zone.frame.width, height: zone.frame.height, '--zone-color': zoneColors[zone.color] } as CSSProperties}
                    aria-label={`${zone.name} zone, ${memberCount} tiles`}
                  >
                    <div className={styles.zoneHeader} data-interaction-id={`zone-drag-${zone.id}`} onPointerDown={(event) => beginZoneDrag(event, zone)} onClick={() => dispatch({ type: 'SELECT_ENTITY', id: zone.id })}>
                      <span className={styles.zoneDot} aria-hidden="true" />
                      <span className={styles.zoneName}>{zone.name}</span>
                      <span className={styles.zoneMeta}>{memberCount} tiles</span>
                      <button type="button" className={styles.zoneButton} aria-label={zone.collapsed ? `Expand ${zone.name}` : `Collapse ${zone.name}`} aria-expanded={!zone.collapsed} data-interaction-id={`zone-collapse-${zone.id}`} onClick={(event) => { event.stopPropagation(); dispatch({ type: 'UPDATE_ZONE', id: zone.id, patch: { collapsed: !zone.collapsed } }); }}><Glyph name={zone.collapsed ? 'forward' : 'chevronDown'} /></button>
                      <button type="button" className={styles.zoneButton} aria-label={`${zone.name} menu`} aria-haspopup="menu" data-interaction-id={`zone-overflow-${zone.id}`} onClick={(event) => showMenu(event, { type: 'zone', id: zone.id, x: event.clientX, y: event.clientY })}><Glyph name="more" /></button>
                    </div>
                    {!zone.collapsed && (
                      <div
                        role="slider"
                        aria-label={`Resize ${zone.name}`}
                        aria-valuemin={320}
                        aria-valuemax={1600}
                        aria-valuenow={Math.round(zone.frame.width)}
                        aria-orientation="horizontal"
                        tabIndex={0}
                        className={styles.zoneResizeHandle}
                        data-interaction-id={`zone-resize-${zone.id}`}
                        onPointerDown={(event) => beginZoneResize(event, zone)}
                      />
                    )}
                  </section>
                );
              })}

              {openTiles.map((tile) => {
                if (tile.zoneId && state.zones[tile.zoneId]?.collapsed) return null;
                return (
                  <article
                    key={tile.id}
                    data-assembly-surface={tile.id}
                    className={`${styles.tile} ${state.selectedEntityId === tile.id ? styles.tileSelected : ''} ${manipulatingId === tile.id ? styles.geometryDirect : ''}`}
                    style={{ left: tile.frame.x, top: tile.frame.y, width: tile.frame.width, height: tile.frame.height, zIndex: tile.z }}
                    aria-label={`${tile.title}, ${tile.kind} tile`}
                    onPointerDown={() => dispatch({ type: 'SELECT_ENTITY', id: tile.id })}
                  >
                    <div className={styles.tileHeader} data-interaction-id={`tile-drag-${tile.id}`} onPointerDown={(event) => beginTileDrag(event, tile)}>
                      <span className={styles.tileKind} aria-hidden="true">{kindGlyph[tile.kind]}</span>
                      <span className={styles.tileTitle}>{tile.title}</span>
                      <span className={styles.tileHeaderSpacer} />
                      <button type="button" className={styles.menuButton} aria-label={`${tile.title} menu`} aria-haspopup="menu" data-interaction-id={`tile-overflow-${tile.id}`} onClick={(event) => showMenu(event, { type: 'tile', id: tile.id, x: event.clientX, y: event.clientY })}><Glyph name="more" /></button>
                      <button type="button" className={styles.menuButton} aria-label={`Close ${tile.title}`} data-interaction-id={`tile-close-${tile.id}`} onClick={(event) => { event.stopPropagation(); dispatch({ type: 'CLOSE_TILE', id: tile.id }); }}><Glyph name="close" /></button>
                    </div>
                    <div className={styles.tileBody}>{renderTileContent?.({ tile, state, dispatch }) ?? renderPlaceholder(tile)}</div>
                    {manipulatingId === tile.id && drag.current?.kind === 'resize' && <output className={styles.resizeReadout}>{Math.round(tile.frame.width)} × {Math.round(tile.frame.height)}</output>}
                    <div role="slider" aria-label={`Resize ${tile.title}`} aria-orientation="horizontal" aria-valuemin={220} aria-valuemax={900} aria-valuenow={Math.round(tile.frame.width)} tabIndex={0} className={styles.resizeHandle} style={{ '--resize-hit': `${Math.max(22, 30 / state.macCamera.zoom)}px` } as CSSProperties} data-interaction-id={`tile-resize-${tile.id}`} onPointerDown={(event) => beginResize(event, tile)} />
                  </article>
                );
              })}
            </div>
          </div>

          <div className={styles.statusBar} aria-live="polite" data-assembly-chrome="status">
            <span>{Math.round(state.macCamera.zoom * 100)}%</span>
            <span>{state.selectedEntityId ? `Selected: ${state.selectedEntityId}` : 'Canvas'}</span>
          </div>
        </div>
      </div>

      {menu && (
        <div className={styles.popover} role="menu" aria-label={`${menu.type} actions`} style={{ left: Math.min(menu.x, window.innerWidth - 180), top: Math.min(menu.y + 6, window.innerHeight - 150) }} data-interaction-id={`${menu.type}-menu`}>
          {menu.type === 'workspace' && <>
            <button type="button" role="menuitem" className={styles.popoverItem} data-interaction-id="workspace-fit" onClick={() => { fitCanvas(); setMenu(null); }}>Fit canvas to all</button>
            <button type="button" role="menuitem" className={styles.popoverItem} data-interaction-id="workspace-tidy" onClick={() => { dispatch({ type: 'TIDY' }); setMenu(null); }}>Tidy workspace</button>
            <button type="button" role="menuitem" className={`${styles.popoverItem} ${styles.danger}`} data-interaction-id="reset-demo" onClick={() => { dispatch({ type: 'RESET' }); setMenu(null); }}>Reset demo</button>
          </>}
          {menu.type === 'tile' && menu.id && <>
            <button type="button" role="menuitem" className={styles.popoverItem} data-interaction-id={`tile-focus-${menu.id}`} onClick={() => { dispatch({ type: 'SELECT_ENTITY', id: menu.id! }); setMenu(null); }}>Focus tile</button>
            <button type="button" role="menuitem" className={styles.popoverItem} data-interaction-id={`tile-forward-${menu.id}`} onClick={() => { dispatch({ type: 'RAISE_TILE', id: menu.id! }); setMenu(null); }}>Bring forward</button>
            {Object.values(state.zones).map((zone) => <button key={zone.id} type="button" role="menuitem" className={styles.popoverItem} data-interaction-id={`tile-zone-${menu.id}-${zone.id}`} onClick={() => { const tile = state.tiles[menu.id!]; dispatch({ type: 'MOVE_TILE', id: menu.id!, frame: tile.frame, zoneId: zone.id }); setMenu(null); }}>Move to {zone.name}</button>)}
            <button type="button" role="menuitem" className={`${styles.popoverItem} ${styles.danger}`} data-interaction-id={`tile-menu-close-${menu.id}`} onClick={() => { dispatch({ type: 'CLOSE_TILE', id: menu.id! }); setMenu(null); }}>Close tile</button>
          </>}
          {menu.type === 'zone' && menu.id && <>
            <button type="button" role="menuitem" className={styles.popoverItem} data-interaction-id={`zone-rename-${menu.id}`} onClick={() => { const zone = state.zones[menu.id!]; const name = window.prompt('Rename zone', zone.name)?.trim(); if (name) dispatch({ type: 'UPDATE_ZONE', id: menu.id!, patch: { name } }); setMenu(null); }}>Rename zone</button>
            <button type="button" role="menuitem" className={styles.popoverItem} data-interaction-id={`zone-color-${menu.id}`} onClick={() => { const colors: Zone['color'][] = ['mint', 'blue', 'purple', 'orange']; const zone = state.zones[menu.id!]; dispatch({ type: 'UPDATE_ZONE', id: menu.id!, patch: { color: colors[(colors.indexOf(zone.color) + 1) % colors.length] } }); setMenu(null); }}>Change color</button>
            <button type="button" role="menuitem" className={styles.popoverItem} data-interaction-id={`zone-tidy-${menu.id}`} onClick={() => { dispatch({ type: 'TIDY' }); setMenu(null); }}>Tidy zone</button>
            <button type="button" role="menuitem" className={`${styles.popoverItem} ${styles.danger}`} data-interaction-id={`zone-close-${menu.id}`} onClick={() => { dispatch({ type: 'CLOSE_ZONE', id: menu.id! }); setMenu(null); }}>Close zone…</button>
          </>}
        </div>
      )}
    </section>
  );
}
