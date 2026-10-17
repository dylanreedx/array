// "Which tab was that?": see timeline.ts for the shot list, constants.ts for every shared name, and
// footage.ts for the real-footage half (the harness take; swapping it is one line).
//
// Layers, back to front: ink; the canvas footage under an ink veil (from the first landing); the tab windows
// as cards (one Ghostty window until S4, then UNSTACK); S5's finish mark; type.
// Rules for the seam: two layers of text are never at rest together (round 2); a card hands off to its
// real tile only in the fast part of its flight, under its motion blur, and at rest it IS the tile (round 3).
import { useMemo } from 'react';
import { AbsoluteFill, Freeze, useCurrentFrame, useVideoConfig } from 'remotion';
import { E, prog, tw } from '../../kit/anim';
import { BlurX, velocityBlur } from '../../kit/blur';
import { Footage, footageView } from '../../kit/footage';
import { Face, faceSource, type FaceSource } from '../../kit/handoff';
import { Lockup } from '../../kit/lockup';
import { alpha } from '../../kit/look';
import { smooth, type Rect as Frame } from '../../kit/rect';
import { defineVideo, type CueSheet } from '../../kit/sheet';
import { Headline } from '../../kit/type';
import { COPY, FINISH_MARK, GHOSTTY, HEADLINE, INK, K, LANDING, LIME, LOOK, PAPER, PAPER_DIM, TABS, TAB_H, TITLE_H, WINDOW, tabIndex, type TabKey } from './constants';
import { FACES, HANDOFF, PULLBACK, tileRadius } from './footage';
import { DISPLAY, MONO } from './fonts';
import { Card, DOT, ProviderMark, TAB_FONT, TabBar, WINDOW_BAR, type TabState } from './Ghostty';
import { StatusDot } from './Dot';
import { Terminal, terminalRects } from './Terminal';
import { CART_ROWS, TILE, WIN, cardAt, lerp, lerpBar, lerpRect, tileBar } from './geometry';
import { BPM, plan, statusOf, timeline, type Plan } from './timeline';

const W = 1920, H = 1080;
/** The desk under the footage (only ever seen where a take does not cover its box). */
const DESK = '#0b0d10';
/** The one headline slot: top left on the window's left edge, where the eye enters the frame. */
const HEAD = { size: HEADLINE.size, color: PAPER, x: HEADLINE.x, baseline: HEADLINE.baseline, family: DISPLAY, style: LOOK.headline, words: LOOK.words };

const tabState = (P: Plan, f: number, fps: number): TabState => {
  const weight = TABS.map((_, i) => (P.tabAt[i] < 0 ? 1 : prog(f, P.tabAt[i], P.tabAt[i] + fps * 0.3, E.native)));
  // ⌘N jumps: the native bar moves its selection at once; the content carries the motion (Body's blur).
  let active = 0;
  for (const w of P.switches) if (f >= w.at) active = w.to;
  return { weight, active };
};

/** The front window's terminal: the tab it shows, with a short smeared swap at each jump. */
const Body: React.FC<{ P: Plan; f: number; fps: number }> = ({ P, f, fps }) => {
  const draw = (i: number) => <Terminal tab={TABS[i].key} f={f} fps={fps} />;
  const k = P.switches.findIndex((w) => f >= w.at - 3 && f < w.at + 5);
  if (k < 0) {
    const last = [...P.switches].reverse().find((w) => f >= w.at + 5);
    return <div style={{ position: 'absolute', inset: 0 }}>{draw(last ? last.to : 0)}</div>;
  }
  const w = P.switches[k];
  const p = (f - (w.at - 3)) / 8; // 8 frames, ~0.13 s
  const amount = 10 * Math.sin(Math.PI * Math.min(1, Math.max(0, p)));
  const travel = 44;
  return (
    <div style={{ position: 'absolute', inset: 0 }}>
      <BlurX id={`swap-out-${k}`} amount={amount} style={{ opacity: 1 - smooth(0.2, 0.62, p), transform: `translateX(${-w.dir * travel * E.in(Math.min(1, p))}px)` }}>{draw(w.from)}</BlurX>
      <BlurX id={`swap-in-${k}`} amount={amount} style={{ opacity: smooth(0.38, 0.8, p), transform: `translateX(${w.dir * travel * (1 - E.out(Math.min(1, p)))}px)` }}>{draw(w.to)}</BlurX>
    </div>
  );
};

const Video: React.FC<{ sheet: CueSheet; viewport?: { width: number; height: number } }> = ({ viewport }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const P = useMemo(() => plan(fps), [fps]);
  const out = viewport ?? { width: W, height: H };
  const S = P.seam;
  const tabs = tabState(P, f, fps);
  const activeTab = TABS[Math.round(tabs.active)];

  // ---- the footage: one take, its pull-back played at 2x (Plan.takeAt) --------------------------------
  const box: Frame = { x: 0, y: 0, width: W, height: H };
  const keys = PULLBACK.keys(0, fps);
  const tf = P.takeAt(f);
  const view = footageView(PULLBACK.take, keys, 0, fps, box);
  const toOut = (r: Frame): Frame => ({ x: view.x + r.x * view.scale, y: view.y + r.y * view.scale, width: r.width * view.scale, height: r.height * view.scale });
  const take = (node: React.ReactNode) => <Freeze frame={tf}>{node}</Freeze>;

  // ---- status dots -------------------------------------------------------------------------------------------
  const dot = (key: TabKey, size: number) => { const st = statusOf(P, key, f); return <StatusDot state={st.state} since={st.since} halos={st.halos} size={size} f={f} fps={fps} />; };

  // ---- S4 UNSTACK ------------------------------------------------------------------------------------------
  // A card stays until its tile's plate and live pixels agree (HANDOFF), then the live take under it takes over.
  const cardUp = (key: TabKey) => f >= S.fan && (f < S.lift.to + 2 || tf < HANDOFF[key]);
  const unstacking = f >= S.fan && S.flights.some((x) => cardUp(x.key));
  const veil = 1 - prog(f, S.lift.from, S.lift.to, E.smooth);
  /**
   * A card's face source (round 5): the live pull-back once the tile is wholly inside the live frame (then the
   * card IS the footage under it), else the PLATE at the same take frame, where every tile is always in frame.
   * Never a cut from outside the capture, so a face is never blank.
   */
  const faceFor = (key: TabKey) => faceSource(FACES, key, tf);
  const cut = (fs: FaceSource, region: Frame | null, w: number, h: number) => <Face source={fs} region={region} width={w} height={h} background={DESK} />;
  const M = S.morph;

  const card = (key: TabKey) => {
    const now = cardAt(P, key, f, fps, toOut), before = cardAt(P, key, f - 1, fps, toOut);
    const r = now.rect, q = before.rect;
    // Directional motion blur from the card's velocity RELATIVE TO ITS TILE once it flies (centre travel plus
    // half the size change): the take's camera draws its own frames crisp, so a card riding its tile is sharp.
    const flying = now.e > 0;
    const ref = flying ? { now: toOut(PULLBACK.tileOf(key, P.takeAt(f))), before: toOut(PULLBACK.tileOf(key, P.takeAt(f - 1))) } : undefined;
    // In flight: the hunt's blur language. Unfurling: half as much, capped, so a pill's title stays readable
    // while it becomes its window (the viewer follows one tab from the bar to its tile).
    // round 5: the flight blur caps at 10 px (18 smeared the cards into streaks with nothing readable on them)
    const k = flying ? 0.26 : 0.1, cap = flying ? 10 : key === LANDING ? 0 : 6; // the front window steps back calmly, unblurred
    const blur = velocityBlur(r, q, k, cap, ref);
    const i = tabIndex(key);
    const front = key === LANDING;
    const fs = faceFor(key);

    // ---- the morph (round 5): terminal -> tile, through the elements both share ----
    // header: the title bar (once a tab) becomes the tile header; colour: terminal ink -> the tile's panel
    const hb = front ? prog(f, M.header, M.header + M.headerDur, E.smooth) : smooth(0.2, 0.7, now.e);
    const bar = lerpBar(now.bar, tileBar(r), hb);
    const sc = r.width / WINDOW.width;
    const rects = terminalRects(key, f, fps);
    // rows: Cart total maps block for block; the others map their composer + status line onto the tile's footer
    const rows = (front ? CART_ROWS : [{ tag: 'prompt', to: TILE.composer }])
      .filter((row) => rects[row.tag])
      .map((row) => ({ ...row, a: rects[row.tag] }))
      .sort((x, y) => x.to.y - y.to.y); // reform in the TILE's reading order, top to bottom
    const end = M.start + (rows.length - 1) * M.stagger + M.dur;
    const faceAlpha = front ? prog(f, end - 6, end + 8, E.smooth) : smooth(0.36, 0.62, now.e); // others: the body crosses under the flight blur
    // Cart total's own terminal body dissolves as soon as its rows begin to travel (early in the flight, under its
    // blur): from there the mapped rows carry the content, so no line is ever drawn twice.
    const contentAlpha = front ? 1 - smooth(0.02, 0.14, now.e) : 1;
    const terminal = front ? <Body P={P} f={f} fps={fps} /> : <Terminal tab={key} f={f} fps={fps} />;
    // Two stages for Cart total. WHERE a row is follows the flight: as the window grows into the tile, each
    // block slides to its slot in the tile (so the card fills top to bottom, nothing is ever an empty panel).
    // WHAT it shows reforms after landing, in place, top to bottom (rows never cross, so text never overlaps).
    const morphRows = rows.map((row, n) => {
      const m = front ? smooth(0.08 + 0.03 * n, 0.8 + 0.02 * n, now.e) : smooth(0.25, 0.75, now.e);
      // The reform is the hunt's own tab swap, per row: the terminal row leaves left under a horizontal blur
      // as the tile row arrives from the right. Two texts only ever share a pixel in motion, never at rest.
      const reform = front ? prog(f, M.start + n * M.stagger, M.start + n * M.stagger + M.dur, E.linear) : m;
      if (m <= 0 && !front) return null;
      const A: Frame = { x: row.a.x * sc, y: bar.h + row.a.y * sc, width: row.a.width * sc, height: row.a.height * sc };
      const B: Frame = { x: row.to.x * r.width, y: row.to.y * r.height, width: row.to.width * r.width, height: row.to.height * r.height };
      const box = lerpRect(A, B, m);
      const s = box.width / row.a.width;
      const swap = front, travel = 0.04 * box.width;
      const out = swap ? 1 - smooth(0.2, 0.62, reform) : 1 - smooth(0.3, 0.7, reform);
      const inn = swap ? smooth(0.38, 0.8, reform) : smooth(0.3, 0.7, reform);
      const smear = swap ? 9 * Math.sin(Math.PI * reform) : 0;
      // the source row alone, clipped to its own block (a taller box must never show the lines below it)
      const source = (
        <div style={{ position: 'absolute', left: 0, top: 0, width: box.width, height: row.a.height * s, overflow: 'hidden' }}>
          <div style={{ position: 'absolute', left: -row.a.x * s, top: -row.a.y * s, width: WINDOW.width, height: WINDOW.height - TITLE_H - TAB_H, transform: `scale(${s})`, transformOrigin: '0 0' }}>{terminal}</div>
        </div>
      );
      return (
        <div key={row.tag} style={{ position: 'absolute', left: box.x, top: box.y, width: box.width, height: box.height, overflow: 'hidden', borderRadius: 8 * sc * reform }}>
          {out > 0 && <BlurX id={`row-out-${key}-${n}`} amount={smear} style={{ opacity: out, transform: `translateX(${-travel * E.in(reform)}px)` }}>{source}</BlurX>}
          {inn > 0 && <BlurX id={`row-in-${key}-${n}`} amount={smear} style={{ opacity: inn, transform: `translateX(${swap ? travel * (1 - E.out(reform)) : 0}px)` }}>{cut(fs, row.to, box.width, box.height)}</BlurX>}
        </div>
      );
    });
    const step = prog(f, S.fan, S.fan + S.fanDur, E.smooth);
    const cli = TABS[i].cli;
    // the panel colour arrives with the flight: by the time a card is in its tile's place it wears the tile's colour
    const bgT = smooth(0.25, 0.85, now.e);
    return (
      <Card key={key} id={key} rect={r} rot={now.rot} title={TABS[i].title} dot={dot(key, DOT * (bar.font / TAB_FONT))} bar={bar} bodyTop={bar.h}
        icon={<ProviderMark provider={cli === 'claude' ? 'anthropic' : 'openai'} size={bar.font * 1.05} color={bar.color} />} prefix="Agent · "
        bg={bgT <= 0 ? GHOSTTY.bg : `color-mix(in srgb, ${GHOSTTY.bg}, ${TILE.bodyBg} ${Math.round(bgT * 100)}%)`}
        content={terminal} contentAlpha={contentAlpha} blur={blur} rest={now.e} tileRadius={tileRadius(toOut(PULLBACK.tileOf(key, tf)))}
        shadow={front ? 1 : prog(f, S.pillLift, S.pillLift + S.pillLiftDur, E.smooth)} faceAlpha={faceAlpha}
        face={faceAlpha > 0 ? cut(fs, null, r.width, r.height) : null}>
        {morphRows}
        {front && step < 1 && (
          <div style={{ position: 'absolute', left: 0, top: 0, transform: `scale(${sc})`, transformOrigin: '0 0' }}>
            <TabBar tabs={tabs} dots={(kk) => dot(kk, DOT)} fade={1 - prog(step, 0, 0.6, E.linear)} hidden={(kk) => kk !== LANDING} top={now.bar.h / sc} />
          </div>
        )}
      </Card>
    );
  };
  // Back to front: the other windows, Cart total, then any tab still a pill above it.
  const keysNow = S.flights.map((x) => x.key);
  const layers = unstacking ? [...keysNow].filter(cardUp).map((key) => ({ key, z: key === LANDING ? 10 : cardAt(P, key, f, fps, toOut).above ? 20 : 9 - S.flights.find((x) => x.key === key)!.order })) : [];

  // ---- S5 --------------------------------------------------------------------------------------------
  const finishOut = toOut(PULLBACK.finish(tf));
  const ringR = tileRadius(finishOut);
  const draw = prog(f, P.payoff.mark, P.payoff.mark + fps * 0.9, E.smooth);
  const tag = prog(f, P.payoff.tag, P.payoff.tag + fps * 0.4, E.outSoft);
  const payoffUp = FINISH_MARK === 'ring' && f >= P.payoff.mark && f < P.lockup + fps * 0.6;
  const ring = { x: finishOut.x - 7, y: finishOut.y - 7, width: finishOut.width + 14, height: finishOut.height + 14 };

  return (
    <AbsoluteFill style={{ background: INK, overflow: 'hidden' }}>
      {/* the canvas, under ink that lifts as the cards land */}
      {f >= S.lift.from && take(<Footage take={PULLBACK.take} from={0} keys={keys} banded={false} viewport={out} background={DESK} />)}
      {f >= S.lift.from && veil > 0 && <AbsoluteFill style={{ background: alpha(INK, veil) }} />}

      {/* S1-S3: the one Ghostty window, its tabs flicking */}
      {f < S.fan && (
        <Card id="front" rect={WIN} title={activeTab.title} bar={WINDOW_BAR} bodyTop={TITLE_H + TAB_H} content={<Body P={P} f={f} fps={fps} />}>
          <TabBar tabs={tabs} dots={(k) => dot(k, DOT)} fade={1} />
        </Card>
      )}
      {/* S4: the tabs come off the bar and unfurl into their windows, which fly to their tiles */}
      {[...layers].sort((a, b) => a.z - b.z).map((l) => card(l.key))}

      {/* S5, picture only: the finish mark and its small tag */}
      {payoffUp && (
        <>
          <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
            <rect x={ring.x} y={ring.y} width={ring.width} height={ring.height} rx={ringR + 7} fill="none" stroke={LIME} strokeWidth={3} pathLength={1} strokeDasharray={`${draw} 1`} />
          </svg>
          {tag > 0 && (
            <div style={{ position: 'absolute', right: W - (ring.x + ring.width) + 18, top: ring.y, transform: `translateY(calc(-50% + ${(1 - tag) * 6}px))`, opacity: tag,
              display: 'flex', alignItems: 'center', gap: 8, padding: '5px 10px 5px 9px', background: INK, border: `1.5px solid ${LIME}`, borderRadius: 999,
              font: `500 14px/1 ${MONO}`, color: PAPER, letterSpacing: '0.01em', whiteSpace: 'nowrap' }}>
              <span style={{ width: 7, height: 7, borderRadius: '50%', background: LIME }} />Cart total · done
            </div>
          )}
        </>
      )}

      {/* type */}
      <Headline {...HEAD} text={COPY.hook} f={f} fps={fps} from={0} out={P.beatAt} />
      {f >= P.beatAt && <Headline {...HEAD} text={COPY.beat} f={f} fps={fps} from={P.beatAt + Math.round(fps * 0.2)} out={S.headlineOut} />}
      <Lockup look={LOOK} f={f} fps={fps} from={P.lockup} line={COPY.payoff} url={COPY.url} width={W} height={H} />

      {PULLBACK.standIn && f >= S.fan && f < P.lockup && (
        <div style={{ position: 'absolute', right: 32, bottom: 28, padding: '8px 12px', border: `1px solid ${PAPER_DIM}`, borderRadius: 6, background: 'rgba(14,15,12,0.78)',
          font: `500 15px/1 ${MONO}`, color: PAPER_DIM, letterSpacing: '0.02em', opacity: tw(f, S.fan, S.fan + 20, 0, 1) }}>
          STAND-IN · scaled still · real pull-back pending
        </div>
      )}
    </AbsoluteFill>
  );
};

export default defineVideo({
  slug: 'which-tab',
  title: 'Which tab was that?',
  bpm: BPM,
  formats: ['landscape'],
  build: timeline,
  Component: Video,
});
