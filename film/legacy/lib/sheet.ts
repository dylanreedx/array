// The cue sheet: one video as data. timeline.ts in each video folder returns one of these
// from a Clock, so the same video can be laid out at 60 fps (masters) or 30 fps (loops)
// without re-authoring. Picture (useReplay), captions (export-srt), chapters and the
// soundtrack (export-cues -> soundtrack.py) all read this one object.
import type { DemoAction, DemoState, Frame } from '@website/features/demo/types';
import type { Clock } from './clock';
import type { Ease } from './anim';

/** Sound vocabulary. The three state sounds are the motif: blue working, amber attention, green done. */
export type Sfx =
  // State sounds are DERIVED from the reducer by scripts/export-cues.ts; author them only when a
  // scene starts in that state (no transition to detect).
  | 'hum.on' | 'hum.off'   // working (blue #5fa8ff): a low hum follows the count of working agents
  | 'ping'                 // needs attention (amber #ffb347): two-note ping, up a fourth
  | 'chime'                // done (green #4fd07a): resolving chime onto the tonic
  | 'bloom'                // an agent finished its turn: the app's own bloom.wav, verbatim, in every score
  | 'resolve'              // an approval answered: the ping's fourth, falling back to the tonic
  | 'bell'                 // the lockup: one low tonic bell
  | 'key' | 'click' | 'whoosh' | 'thud' | 'tick'
  | 'pop'                  // the cursor's caption bubble opens or changes line: a short bright blip
  | 'swish'                // a hand pan or a pinch: a light filtered air move, shorter than a whoosh
  | 'orbit' | 'prism'      // the app's own 'pushed' and 'merged' sounds (AgentSoundRules), verbatim
  // 'tabs' score (which-tab): a soft tick per tab, a drone under the hunt (drone.on/off), a breath on
  // the beat, a lift into the pull-back
  | 'tab' | 'drone.on' | 'drone.off' | 'breath' | 'lift'
  // ...and its status dots (round 4): a tab needs input, fails, finishes, or nudges again
  | 'dot.input' | 'dot.failed' | 'dot.done' | 'dot.nudge';

export interface Act { from: number; dur: number; name: string }

/** A discrete reducer step at one frame. `action` may read the state it lands on. */
export interface Cue {
  id: string;
  at: number;
  action?: DemoAction | ((state: DemoState) => DemoAction);
  sfx?: Sfx;
  /** -1 left .. 1 right, for the mix */
  pan?: number;
}

/** A continuous change, re-evaluated every frame from t in [0,1] (camera glides, tile drags, typing). */
export interface Track {
  id: string;
  from: number;
  to: number;
  ease?: Ease;
  action: (t: number, state: DemoState) => DemoAction | DemoAction[] | null;
}

/**
 * What the film lens frames: a tile or zone by id (resolved from state), a rect in canvas WORLD
 * coordinates (resolved through the current Mac camera, so a camera cut under it is invisible),
 * or a stage rect.
 */
export type FocusTarget = { tile: string } | { zone: string } | { world: Frame } | { rect: Frame } | { whole: true };
/**
 * One lens framing. `focus` may be a function of the output size, so one timeline frames 16:9 and
 * 1:1 differently. The move INTO this key from the previous one lasts `dur` frames (default 0.9 s)
 * on `ease` (default E.cam), and lands exactly on this key's framing.
 */
export interface LensKey { at: number; focus: FocusTarget | ((output: { width: number; height: number }) => FocusTarget); pad?: number; ease?: Ease; dur?: number }

/** One caption / voiceover line. `vo` names a recorded or synthesised clip in public/vo/. */
export interface Line {
  id: string; from: number; to: number; text: string; vo?: string;
  /** 'hook' sets the line larger (the first 2 s and the lockup); 'lockup' lines are drawn by the lockup act, not the band */
  size?: 'hook';
  /**
   * 'cursor' lines are spoken by the pointer: drawn in the bubble attached to it (acts/edu/Bubble.tsx),
   * kept for lines whose subject IS the cursor. 'tile' lines pin a static tag to the tile they are about
   * (acts/edu/Tag.tsx); they need `pin`.
   */
  place?: 'band' | 'lockup' | 'cursor' | 'tile';
  /** tile lines: where the tag pins (see LinePin) */
  pin?: LinePin;
  /** reveal word by word instead of the whole line at once */
  words?: boolean;
  /** cursor and tile lines: the pill takes this state colour for the line (default: the pointer's own colour) */
  tone?: 'amber' | 'green' | 'blue';
  /**
   * cursor and tile lines: an icon leading the text, in the line's ink, at cap height (acts/edu/Icon.tsx).
   * Icons can also sit inside `text` as `{name}` tokens: "{claude} Claude and {codex} Codex, side by side."
   */
  icon?: CaptionIcon;
}
/** The caption icon set: the two provider marks (white, from website/public) and line icons in the clock chip's style. */
export const CAPTION_ICONS = ['claude', 'codex', 'branch', 'push', 'merge', 'sound', 'check', 'ticket', 'eye', 'keyboard', 'wand', 'tidy', 'board', 'sidebar'] as const;
export type CaptionIcon = (typeof CAPTION_ICONS)[number];
/**
 * A tile tag's anchor, resolved ONCE from the pointer track's rect at the line's `from` frame (window
 * points) and carried each frame through the video's map, so a punch-in moves it with the content.
 */
export interface LinePin {
  /** a key of the track's `rects`: a tile key, `card:<key>`, `sidebar`, `sidebar:<agentKey>` */
  rect: string;
  /** which edge the tag sits against, its notch facing the tile (default 'top': above the top edge) */
  side?: 'top' | 'bottom' | 'left' | 'right' | 'inside-top';
  /** where along that edge (default 'start': the left/top end) */
  align?: 'start' | 'center' | 'end';
  /** nudge in window points */
  dx?: number;
  dy?: number;
}
export interface Chapter { id: string; at: number; title: string }

/** Overlay furniture for educational videos, placed in stage coordinates or on a tile. */
export type Overlay =
  /**
   * Placed at the top centre of `anchor`, else at `place` (fractions of the output; 'band' = the right
   * end of the caption band, or the box's bottom right in portrait, where the band is a caption's
   * full width), else centred at 42% height.
   */
  | { kind: 'key'; from: number; to: number; keys: string[]; anchor?: FocusTarget; place?: { x: number; y: number } | 'band' }
  | { kind: 'callout'; from: number; to: number; text: string; anchor: FocusTarget; side?: 'top' | 'right' | 'bottom' | 'left' }
  /**
   * x/y are output px, or fractions of the anchor's output rect when `anchor` is a FocusTarget, or,
   * with anchor 'frame', app UI px from the top centre of the Command Center's panel as
   * <Film commandCenter="frame"/> lays it out (FRAME_COMMAND_TOP below the frame's top), at the
   * Mac camera's zoom. Visible from the first point to the last.
   */
  | { kind: 'cursor'; path: { at: number; x: number; y: number; press?: boolean; anchor?: FocusTarget | 'frame' }[] };

export interface CueSheet {
  slug: string;
  title: string;
  clock: Clock;
  durationInFrames: number;
  acts: Record<string, Act>;
  cues: Cue[];
  tracks: Track[];
  lens: LensKey[];
  lines: Line[];
  chapters: Chapter[];
  overlays: Overlay[];
  /** frames where a seamless loop may cut (hero loop): first frame must equal frame `loopTo` */
  loop?: { from: number; to: number };
  /**
   * the score under the sound design (scripts/soundtrack.py): 'bed' (default) a quiet pad, 'pop' a bright
   * groove, 'app' a groove built from Array's own bundled sounds (public/sfx/app), which also maps every
   * sfx kind onto those sounds
   */
  music?: 'bed' | 'pop' | 'app' | 'day' | 'tabs';
}

export interface VideoDefinition {
  slug: string;
  title: string;
  bpm: number;
  /** Formats this video ships in; see lib/formats.ts */
  formats: readonly import('./formats').FormatId[];
  build: (clock: Clock) => CueSheet;
  /** Initial state: the website fixture + scene.json overrides and setup actions. */
  scene: import('./replay').Scene;
  /** viewport overrides the composition size (contact-sheet cells render the film small) */
  Component: React.FC<{ sheet: CueSheet; viewport?: { width: number; height: number }; format?: import('./formats').FormatId }>;
  /** The `site` format's sheet, when it differs from the master's (a trimmed, uncaptioned cut). */
  site?: (clock: Clock) => CueSheet;
}

export const defineVideo = (v: VideoDefinition) => v;
