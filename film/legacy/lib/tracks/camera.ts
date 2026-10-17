// The website's Mac camera as a track. Moves are SET_CAMERA actions, so the reducer, the
// camera clamp (replay.settle) and the website's own canvas transform do the rest. Targets are
// framed against MAC_CANVAS, the canvas size lib/metrics.ts asserts on every render.
//
// The app CUTS between framings (setViewport, no tween); a camera move in a film is a liberty.
// The native-feeling version is the app's own pinch-momentum shape, an exponential approach,
// at a readable time constant: the app decays with a 55 ms half-life, the film uses tau 100 ms.
// Zoom stays inside the native 0.1-4.0 range (ZOOM_MIN/ZOOM_MAX), which the website clamps to.
import type { CameraState, DemoState, Frame } from '@website/features/demo/types';
import { expo, type Ease } from '../anim';
import { MAC_CANVAS } from '../formats';
import type { Track } from '../sheet';

/** Time constant (s) of every film camera glide. */
export const CAMERA_TAU = 0.1;

/** An exponential approach with tau CAMERA_TAU, normalised to land exactly on the target at `dur` (s). */
export const glide = (dur: number): Ease => expo(CAMERA_TAU, dur);

/** Camera that centres `r` (world px) in the canvas at `zoom`. */
export const centreOn = (r: Frame, zoom: number): CameraState => ({
  x: MAC_CANVAS.width / 2 - (r.x + r.width / 2) * zoom,
  y: MAC_CANVAS.height / 2 - (r.y + r.height / 2) * zoom,
  zoom,
});

/** Camera that fits `r` (world px) in the canvas with `pad` canvas px on the tighter axis. */
export const fitTo = (r: Frame, pad: number): CameraState =>
  centreOn(r, Math.min((MAC_CANVAS.width - 2 * pad) / r.width, (MAC_CANVAS.height - 2 * pad) / r.height));

// a*(1-t) + b*t lands exactly on b at t=1, so a loop that returns to its start camera is exact.
const lerp = (a: number, b: number, t: number) => a * (1 - t) + b * t;

/** Glide from the camera the track starts on to `target(state)`. `ease` is required: pass
 *  `glide(seconds)` with the track's own length, never the replay's default curve. */
export const cameraTrack = (id: string, from: number, to: number, target: (s: DemoState) => CameraState, ease: Ease): Track => ({
  id, from, to, ease,
  action: (t, s) => {
    const a = s.macCamera, b = target(s);
    return { type: 'SET_CAMERA', device: 'mac', camera: { x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), zoom: lerp(a.zoom, b.zoom, t) } };
  },
});
