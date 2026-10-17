// Frame -> DemoState, by replaying the website's own reducer.
//
// The state at frame f is a pure fold: start from the fixture (+ scene.json), apply every cue
// with at <= f and every track that has started (evaluated at its eased t for f), in time
// order. No React state, no effects, no timers: Remotion renders frames out of order across
// several tabs, so anything that accumulates between renders would differ per tab.
//
// Component-originated dispatches (MacWorkspace's ResizeObserver camera clamp, a stray
// setTimeout) are NOT applied. Each one is logged as `[film] component dispatch ignored`, and
// scripts/gate.ts (renderMedia + onBrowserLog) fails if any appear: each is a place where the
// website would have shown something the film did not. The SET_CAMERA detail string is
// diagnostic instrumentation for the open intermittent stray (report section 2.6).
import { useMemo } from 'react';
import { useCurrentFrame } from 'remotion';
import { demoReducer } from '@website/features/demo/reducer';
import { makeInitialState } from '@website/features/demo/fixture';
import { clampCamera, workspaceBounds } from '@website/features/demo/canvasGeometry';
import type { DemoAction, DemoState } from '@website/features/demo/types';
import { E, prog } from './anim';
import type { CueSheet } from './sheet';

type Step = { t: number; order: number; apply: (s: DemoState, frame: number) => DemoState };

/** scene.json: optional literal overrides, then setup actions in the website's own vocabulary. */
export interface Scene { state?: Partial<DemoState>; setup?: DemoAction[] }

export const initialState = (scene: Scene): DemoState => {
  const s: DemoState = {
    ...makeInitialState(),
    ...scene.state,
    inputMode: 'page', // never 'workspace': that installs window key/wheel listeners
  };
  return { ...(scene.setup ?? []).reduce(demoReducer, s), toast: null, undo: null };
};

const reduce = (s: DemoState, a: DemoAction | DemoAction[] | null): DemoState =>
  !a ? s : Array.isArray(a) ? a.reduce(demoReducer, s) : demoReducer(s, a);

export const compileSteps = (sheet: CueSheet): Step[] => {
  const steps: Step[] = [];
  sheet.cues.forEach((c, i) => {
    if (!c.action) return;
    const action = c.action;
    steps.push({ t: c.at, order: i, apply: (s) => reduce(s, typeof action === 'function' ? action(s) : action) });
  });
  sheet.tracks.forEach((tr, i) => {
    steps.push({ t: tr.from, order: 10_000 + i, apply: (s, f) => reduce(s, tr.action(prog(f, tr.from, tr.to, tr.ease ?? E.native), s)) });
  });
  return steps.sort((a, b) => a.t - b.t || a.order - b.order);
};

/** Pure: the state the website would hold at `frame`. Exported for tests and export-cues. */
export const stateAt = (steps: Step[], base: DemoState, frame: number): DemoState => {
  let s = base;
  for (const step of steps) {
    if (step.t > frame) break;
    s = step.apply(s, frame);
  }
  return s;
};

declare global { interface Window { __filmStrayDispatches?: { frame: number; action: DemoAction }[] } }

/**
 * The website's camera invariant, applied as the last step of every frame: "Every Mac camera
 * mutation passes through the shared camera clamp" (DESIGN_SYSTEM.md). MacWorkspace enforces it
 * with a ResizeObserver that dispatches SET_CAMERA; the film applies the same pure helper so
 * that effect finds nothing to correct (and the stray-dispatch gate stays at zero).
 */
export const settle = (s: DemoState, canvas: { width: number; height: number } | null): DemoState =>
  canvas ? { ...s, macCamera: clampCamera(s.macCamera, canvas, workspaceBounds(s.tiles, s.zones)) } : s;

export const useReplay = (sheet: CueSheet, scene: Scene, canvas: { width: number; height: number } | null) => {
  const frame = useCurrentFrame();
  const steps = useMemo(() => compileSteps(sheet), [sheet]);
  const base = useMemo(() => initialState(scene), [scene]);
  const state = useMemo(() => settle(stateAt(steps, base, frame), canvas), [steps, base, frame, canvas]);
  const dispatch = useMemo(() => (action: DemoAction) => {
    if (!canvas) return; // measuring pass: never screenshotted, and the stage remounts after it
    (window.__filmStrayDispatches ??= []).push({ frame, action });
    const detail = action.type === 'SET_CAMERA' ? ` ${JSON.stringify(action.camera)} vs film ${JSON.stringify(state.macCamera)} canvas ${JSON.stringify(canvas)} dom ${(() => { const el = document.querySelector<HTMLElement>('[data-film-stage] [data-interaction-id="canvas-surface"]'); return el ? `${el.clientWidth}x${el.clientHeight}` : '?'; })()} htmlOverflow=${document.documentElement.style.overflow || '-'} inner=${window.innerWidth}x${window.innerHeight} sidebarOpen=${state.sidebarOpen} grid=${(() => { const b = document.querySelector<HTMLElement>('[data-film-stage] [data-assembly-chrome=body]'); return b ? getComputedStyle(b).gridTemplateColumns : '?'; })()} stages=${document.querySelectorAll('[data-film-stage]').length} canvases=${document.querySelectorAll('[data-interaction-id=canvas-surface]').length}` : '';
    console.warn(`[film] component dispatch ignored at f${frame}: ${action.type}${detail}`);
  }, [frame, canvas, state]);
  return { state, dispatch, frame };
};
