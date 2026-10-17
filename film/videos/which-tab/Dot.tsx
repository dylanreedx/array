// A tab's status dot (round 4). Working: a quiet paper ring with a turning arc. Needs input / failed /
// done: a filled dot in amber / red / lime. A change pops the dot in (ease-out, no overshoot) and sends
// one halo out; a `nudge` sends another halo, the "still waiting" a viewer can't keep up with.
import { E, prog } from '../../kit/anim';
import { STATUS_COLOR, type Status } from './constants';

export const StatusDot: React.FC<{ state: Status; size: number; f: number; fps: number; since: number; halos: number[] }> = ({ state, size, f, fps, since, halos }) => {
  const c = STATUS_COLOR[state];
  const pop = prog(f, since, since + fps * 0.22, E.out);
  const r = size / 2;
  const box = size * 3; // room for the halo
  return (
    <span style={{ position: 'relative', display: 'inline-block', width: size, height: size, flex: 'none' }}>
      <svg width={box} height={box} viewBox={`${-box / 2} ${-box / 2} ${box} ${box}`} style={{ position: 'absolute', left: (size - box) / 2, top: (size - box) / 2, overflow: 'visible' }}>
        {halos.map((h, k) => {
          const t = prog(f, h, h + fps * 0.7, E.out);
          if (f < h || t >= 1) return null;
          return <circle key={k} r={r * (1 + 1.6 * t)} fill="none" stroke={c} strokeWidth={1.4} opacity={0.75 * (1 - t)} />;
        })}
        {state === 'working' ? (
          <g transform={`rotate(${((f / fps) * 300) % 360})`}>
            <circle r={r * 0.78} fill="none" stroke="rgba(242,240,233,0.22)" strokeWidth={size * 0.2} />
            <circle r={r * 0.78} fill="none" stroke={c} strokeWidth={size * 0.2} strokeLinecap="round" pathLength={1} strokeDasharray="0.3 0.7" />
          </g>
        ) : (
          <circle r={r * (0.55 + 0.45 * pop)} fill={c} />
        )}
      </svg>
    </span>
  );
};
