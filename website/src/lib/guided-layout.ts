import { contactPlacement, predictMove, resizeMembers, settleMembers, solveMemberMove, type Frame, type Frames } from './native-layout';

export const DEMO_GAP = 8;
const content = { x: 66, y: 79, width: 1970, height: 1230 };
const clamp = (v: number) => Math.max(0, Math.min(1, v));
const phase = (p: number, a: number, b: number) => clamp((p - a) / (b - a));
const smooth = (v: number) => v * v * (3 - 2 * v);
const mix = (a: number, b: number, t: number) => a + (b - a) * t;

// Authored input scene and pointer gestures. Every destination and passive tile
// placement below is produced by the native move/settle/resize port.
function initialFrames(mobile: boolean): Frames {
  return {
    stabilize: { x: 70, y: 90, width: 430, height: 550 },
    verify: { x: 550, y: 90, width: 380, height: 470 },
    audit: { x: 980, y: 90, width: 340, height: 450 },
    shell: { x: 1370, y: 90, width: 300, height: 470 },
    note: { x: 70, y: 680, width: 800, height: 430 },
    browser: { x: 920, y: 680, width: mobile ? 330 : 560, height: 430 },
  };
}
function movePrediction(baseline: Frames, active: string, requested: Frame) {
  const live = solveMemberMove(baseline, active, requested, content, DEMO_GAP);
  // A latched exchange takes the sibling's exact old origin. Before a swap,
  // preview the nearest clear contact; honorSnap pins that destination on release.
  const snapped = live.latch ? null : contactPlacement(requested,
    Object.entries(baseline).filter(([id]) => id !== active).map(([, frame]) => frame), content, DEMO_GAP);
  return predictMove(baseline, active, requested, content, DEMO_GAP, null, snapped);
}
const sources = [false, true].map(mobile => {
  const initial = initialFrames(mobile);
  const arranged = settleMembers(initial, content, DEMO_GAP, 'stabilize', true);
  const mainDrop = movePrediction(arranged, 'stabilize', { ...arranged.stabilize, x: arranged.verify.x, y: arranged.verify.y }).releaseFrames;
  const editorDrop = movePrediction(mainDrop, 'browser', { ...mainDrop.browser, x: mainDrop.browser.x + 50, y: mainDrop.browser.y + 10 }).releaseFrames;
  const editorResize = resizeMembers(editorDrop, 'browser', { ...editorDrop.browser, width: mobile ? 470 : 800, height: 560 }, DEMO_GAP);
  const agentResize = resizeMembers(editorResize, 'stabilize', { ...editorResize.stabilize, width: 550, height: 420 }, DEMO_GAP);
  // Widen the terminal and align its bottom with the original tall agent row.
  const final = resizeMembers(agentResize, 'shell', { ...agentResize.shell, width: 480, height: initial.stabilize.height }, DEMO_GAP);
  return { initial, arranged, mainDrop, editorDrop, editorResize, agentResize, final };
});
export interface LayoutPreview extends Frame { tile: 'stabilize' | 'browser'; opacity: number; scale: number }
export function guidedLayout(p: number, mobile: boolean): { frames: Frames; preview: LayoutPreview | null; moving: 'stabilize' | 'browser' | null } {
  const source = sources[mobile ? 1 : 0];
  let frames = source.initial;
  let preview: LayoutPreview | null = null;
  let moving: 'stabilize' | 'browser' | null = null;
  if (p >= .86 && p < .873) {
    const t = smooth(phase(p, .86, .873));
    frames = Object.fromEntries(Object.entries(source.initial).map(([id, a]) => {
      const b = source.arranged[id];
      return [id, { ...a, x: mix(a.x, b.x, t), y: mix(a.y, b.y, t) }];
    }));
  } else if (p >= .873 && p < .902) {
    moving = 'stabilize';
    const t = 1 - Math.pow(1 - phase(p, .873, .902), 3), original = source.arranged.stabilize;
    const requested = { ...original, x: mix(original.x, source.arranged.verify.x, t) };
    const prediction = movePrediction(source.arranged, moving, requested);
    frames = { ...prediction.passiveFrames, [moving]: requested };
    if (prediction.valid && prediction.destination) preview = { ...prediction.destination, tile: moving, opacity: smooth(phase(p, .873, .875)), scale: mix(.96, 1, smooth(phase(p, .873, .875))) };
  } else if (p >= .902 && p < .909) frames = source.mainDrop;
  else if (p >= .909 && p < .923) {
    moving = 'browser';
    const t = smooth(phase(p, .909, .923)), original = source.mainDrop.browser;
    const requested = { ...original, x: original.x + 50 * t, y: original.y + 10 * t };
    const prediction = movePrediction(source.mainDrop, moving, requested);
    frames = { ...prediction.passiveFrames, [moving]: requested };
    if (prediction.valid && prediction.destination) preview = { ...prediction.destination, tile: moving, opacity: smooth(phase(p, .909, .911)), scale: mix(.96, 1, smooth(phase(p, .909, .911))) };
  } else if (p >= .923 && p < .93) frames = source.editorDrop;
  else if (p >= .93 && p < .95) {
    const t = phase(p, .93, .95), a = source.editorDrop.browser, b = source.editorResize.browser;
    frames = resizeMembers(source.editorDrop, 'browser', { ...a, width: mix(a.width, b.width, t), height: mix(a.height, b.height, t) }, DEMO_GAP);
  } else if (p >= .95 && p < .957) frames = source.editorResize;
  else if (p >= .957 && p < .970) {
    const t = phase(p, .957, .970), a = source.editorResize.stabilize, b = source.agentResize.stabilize;
    frames = resizeMembers(source.editorResize, 'stabilize', { ...a, width: mix(a.width, b.width, t), height: mix(a.height, b.height, t) }, DEMO_GAP);
  } else if (p >= .970 && p < .976) frames = source.agentResize;
  else if (p >= .976 && p < .985) {
    const t = phase(p, .976, .985), a = source.agentResize.shell, b = source.final.shell;
    frames = resizeMembers(source.agentResize, 'shell', { ...a, width: mix(a.width, b.width, t), height: mix(a.height, b.height, t) }, DEMO_GAP);
  } else if (p >= .985) frames = source.final;
  return { frames, preview, moving };
}
