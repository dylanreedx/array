// Plate-to-live hand-off: a shared element (a card, a window, a label) that flies onto a tile of the real
// footage shows that tile's REAL pixels on its face, and the face must never be blank.
//
// Why a plate: while the live take's camera is still tight, most tiles are outside the captured frame, so a
// face cut from the live take is black (which-tab r5: faces went black mid-flight). The PLATE is a second
// take of the same run with the camera held wide for every frame: same content, same events, every tile in
// frame. A face is cut from the plate at the SAME take frame until (a) the tile is wholly inside the part of
// the live take the film shows and (b) the plate and live pixels of that tile agree (probes/plate-parity.py
// measures the frame); from then on it is cut from the live take, so the swap is invisible.
import { Freeze } from 'remotion';
import { Footage, type Take } from './footage';
import { within, type Rect } from './rect';

export interface FaceSource { take: Take; frame: number; rect: Rect }

export interface PlateHandoff<K extends string> {
  live: Take;
  liveTile: (key: K, i: number) => Rect;
  plate: Take;
  plateFrame: (i: number) => number;
  plateTile: (key: K, i: number) => Rect;
  /** per tile: the take frame from which plate and live pixels agree (0 = always) */
  from: Record<K, number>;
  /** is a live rect wholly inside the part of the live take the film shows? */
  inside: (r: Rect) => boolean;
}

/** Where tile `key`'s face comes from at take frame `tf`. */
export const faceSource = <K extends string>(h: PlateHandoff<K>, key: K, tf: number): FaceSource => {
  const live = h.liveTile(key, tf);
  if (tf >= h.from[key] && h.inside(live)) return { take: h.live, frame: tf, rect: live };
  const pf = h.plateFrame(tf);
  return { take: h.plate, frame: pf, rect: h.plateTile(key, pf) };
};

/** A crop's inside test: is `r` wholly within `crop`? */
export const insideCrop = (crop: Rect) => (r: Rect) => r.x >= crop.x && r.y >= crop.y && r.x + r.width <= crop.x + crop.width && r.y + r.height <= crop.y + crop.height;

/** A face: `region` (fractions of the tile, or the whole tile) of a face source, cut to fill width x height. */
export const Face: React.FC<{ source: FaceSource; region?: Rect | null; width: number; height: number; background: string }> = ({ source, region, width, height, background }) => (
  <Freeze frame={source.frame}><Footage take={source.take} from={0} keys={[{ at: 0, rect: region ? within(source.rect, region) : source.rect }]} banded={false} fit="cover" viewport={{ width, height }} background={background} /></Freeze>
);
