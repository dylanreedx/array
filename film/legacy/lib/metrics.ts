// Measures where the website's canvas surface sits in the stage and how big it is, once per
// tab. Both feed pure math: the lens (subject rects) and the replay (the website's own camera
// clamp, which MacWorkspace applies on mount through a ResizeObserver). offsetLeft/offsetTop
// ignore CSS transforms, so the lens scale never pollutes the measurement.
import { useEffect, useLayoutEffect, useState, type RefObject } from 'react';
import { continueRender, delayRender } from 'remotion';
import { MAC_CANVAS } from './formats';

export interface StageMetrics { origin: { x: number; y: number }; size: { width: number; height: number } }

export const useStageMetrics = (root: RefObject<HTMLDivElement | null>): StageMetrics | null => {
  const [metrics, setMetrics] = useState<StageMetrics | null>(null);
  const [handle] = useState(() => delayRender('measure website canvas'));
  useLayoutEffect(() => {
    const stage = root.current?.querySelector<HTMLElement>('[data-film-stage]');
    const canvas = stage?.querySelector<HTMLElement>('[data-interaction-id="canvas-surface"]');
    if (!stage || !canvas) throw new Error('film: website canvas not found; did MacWorkspace markup change?');
    let x = 0, y = 0, el: HTMLElement | null = canvas;
    while (el && el !== stage) { x += el.offsetLeft; y += el.offsetTop; el = el.offsetParent as HTMLElement | null; }
    const size = { width: canvas.clientWidth, height: canvas.clientHeight };
    // Timelines frame the Mac camera against MAC_CANVAS (Node-side, before anything renders);
    // a different measured canvas would frame every subject off-centre, so the gate fails on it.
    if (size.width !== MAC_CANVAS.width || size.height !== MAC_CANVAS.height) console.warn(`[film] website canvas measured ${size.width}x${size.height}, MAC_CANVAS says ${MAC_CANVAS.width}x${MAC_CANVAS.height}`);
    setMetrics({ origin: { x, y }, size });
  }, [root]);
  useEffect(() => { if (metrics) continueRender(handle); }, [metrics, handle]);
  return metrics;
};
