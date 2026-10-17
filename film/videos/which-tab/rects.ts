// UNSTACK's card rects (output px) for film frames [from, to], from the film's own geometry: the input
// probes/blank-faces.py reads. Usage: npx tsx videos/which-tab/rects.ts 400 540 > rects.json
import { footageView, toOutput } from '../../kit/footage';
import { PULLBACK } from './footage';
import { cardAt } from './geometry';
import { plan } from './timeline';

const [from, to] = process.argv.slice(2).map(Number);
const P = plan(60);
const toOut = toOutput(footageView(PULLBACK.take, PULLBACK.keys(0, 60), 0, 60, { x: 0, y: 0, width: 1920, height: 1080 }));
const rects: Record<number, Record<string, { x: number; y: number; width: number; height: number; e: number }>> = {};
for (let f = from; f <= to; f++) {
  rects[f] = {};
  for (const fl of P.seam.flights) { const c = cardAt(P, fl.key, f, 60, toOut); rects[f][fl.key] = { ...c.rect, e: c.e }; }
}
console.log(JSON.stringify({ until: P.seam.lift.to, rects }));
