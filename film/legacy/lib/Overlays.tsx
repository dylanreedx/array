// Renders a sheet's overlays in OUTPUT space (crisp at any lens scale), anchored via the lens.
import { useCurrentFrame } from 'remotion';
import { Callout } from '../acts/edu/Callout';
import { Cursor } from '../acts/edu/Cursor';
import { KeyChip } from '../acts/edu/KeyChip';
import { E, mix, prog } from './anim';
import { FRAME_COMMAND_TOP } from './formats';
import { useLens } from './Lens';
import type { Overlay } from './sheet';

type CursorPath = Extract<Overlay, { kind: 'cursor' }>['path'];

/** The pointer glides between points (E.inOut), fades in and out over 6 frames, and dips on a press. */
const CursorOverlay: React.FC<{ path: CursorPath }> = ({ path }) => {
  const f = useCurrentFrame();
  const lens = useLens();
  const first = path[0], last = path[path.length - 1];
  if (!first || f < first.at || f > last.at) return null;
  const at = (p: CursorPath[number]) => {
    if (!p.anchor) return { x: p.x, y: p.y };
    if (p.anchor === 'frame') return { x: lens.box.x + lens.box.width / 2 + p.x * lens.uiScale, y: lens.box.y + FRAME_COMMAND_TOP * lens.box.height + p.y * lens.uiScale };
    const r = lens.outRect(p.anchor);
    return { x: r.x + p.x * r.width, y: r.y + p.y * r.height };
  };
  const i = Math.max(0, path.findIndex((p) => p.at > f) - 1);
  const a = path[i], b = path[Math.min(i + 1, path.length - 1)];
  const t = prog(f, a.at, b.at, E.inOut);
  const pa = at(a), pb = at(b);
  const press = Math.max(0, ...path.filter((p) => p.press).map((p) => 1 - Math.min(1, Math.abs(f - p.at) / 4)));
  const opacity = prog(f, first.at, first.at + 6, E.out) * (1 - prog(f, last.at - 6, last.at, E.in));
  return <Cursor x={mix(pa.x, pb.x, t)} y={mix(pa.y, pb.y, t)} press={press} opacity={opacity} />;
};

export const Overlays: React.FC<{ overlays: Overlay[] }> = ({ overlays }) => {
  const lens = useLens();
  const { width, height } = lens.output; // the output, not the composition: a contact-sheet cell is smaller
  return (
    <>
      {overlays.map((o, i) => {
        if (o.kind === 'callout') {
          const r = lens.outRect(o.anchor);
          return <Callout key={i} text={o.text} from={o.from} to={o.to} x={r.x + r.width / 2} y={r.y} />;
        }
        if (o.kind === 'key') {
          const r = o.anchor ? lens.outRect(o.anchor) : null;
          const { box } = lens;
          if (o.place === 'band') {
            const portrait = height > width, topBand = box.y > 0;
            const y = portrait ? box.y + box.height * 0.93 : topBand ? box.y / 2 : (box.y + box.height + height) / 2;
            return <KeyChip key={i} keys={o.keys} from={o.from} to={o.to} x={width * (portrait ? 0.84 : 0.9)} y={y} />;
          }
          return <KeyChip key={i} keys={o.keys} from={o.from} to={o.to} x={r ? r.x + r.width / 2 : width * (o.place?.x ?? 0.5)} y={r ? r.y : height * (o.place?.y ?? 0.42)} />;
        }
        return <CursorOverlay key={i} path={o.path} />;
      })}
    </>
  );
};
