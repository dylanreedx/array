// The end card: a payoff line alone, then the mark + wordmark lockup alone, then the URL (research/22-end-
// cards: none of 14 measured launch films stacks headline + lockup + URL; each gets its own beat on an empty
// field, the lockup small, centred and tight). Every proportion is in H, the wordmark's cap height, and every
// gap is measured ink to ink from the look's font metrics (probes/lockup.py checks a render against them).
//
//   beat 1  the line alone, centred, word by word; holds; fades out; a short empty field
//   beat 2  the lockup alone, centred: fades in with a small rise, mark and word as ONE element (no scale, no
//           bounce); the URL a moment later, opacity only; then held still on whole pixels to the end
import { Img, staticFile } from 'remotion';
import { E, prog } from './anim';
import { alpha, type Look, type LockupStyle } from './look';
import { Word, wordIn } from './type';

export const lockupLayout = (L: LockupStyle, width: number, height: number) => {
  const u = height / 1080;
  const H = Math.round(L.cap * u);
  const fs = H / L.word.cap;
  const markH = Math.round(L.markOfH * H), markW = Math.round(markH * L.markAspect);
  const gap = Math.round(L.gapOfH * H);
  const wordInk = L.word.inkW * fs;
  const total = markW + gap + wordInk;
  const left = Math.round(width / 2 - total / 2);
  // the wordmark sits on a whole pixel; the cap centre is then wherever its caps actually land, and the mark
  // centres on THAT (rounding the two separately left the mark 1 px low)
  const wordTop = Math.round(height / 2 - H / 2 - L.word.capTop * fs);
  const capTop = wordTop + L.word.capTop * fs, baseline = capTop + H, capCentre = capTop + H / 2;
  const ufs = (L.url.ascOfH * H) / L.url.asc;
  const urlTop = baseline + L.url.topOfH * H;
  return {
    H, fs, gap,
    mark: { left, top: Math.round(capCentre - markH / 2), width: markW, height: markH },
    word: { left: Math.round(left + markW + gap - L.word.lsb * fs), top: wordTop },
    url: { fs: ufs, left: Math.round(width / 2 - (L.url.inkW * ufs) / 2 - L.url.lsb * ufs), top: Math.round(urlTop - L.url.ascTop * ufs) },
    capTop, baseline,
  };
};

/** Frame of each beat, given the frame the end card starts on. */
export const lockupBeats = (L: LockupStyle, words: number, wordStagger: number, wordDur: number, from: number, fps: number) => {
  const b = L.beats;
  const lineAt = from + Math.round(fps * b.lineDelay);
  const lineIn = lineAt + Math.round(fps * (wordStagger * (words - 1) + wordDur)); // the last word settles
  const lineOut = lineIn + Math.round(fps * b.lineHold);
  const lockAt = lineOut + Math.round(fps * (b.lineOut + b.gap));
  return { lineAt, lineOut, lockAt, urlAt: lockAt + Math.round(fps * b.urlDelay) };
};

export const Lockup: React.FC<{ look: Look; f: number; fps: number; from: number; line: string; url: string; width: number; height: number }> = ({ look, f, fps, from, line, url, width, height }) => {
  const L = look.lockup!;
  if (f < from) return null;
  const words = line.split(' ');
  const ground = prog(f, from, from + fps * L.beats.ground, E.smooth);
  const B = lockupBeats(L, words.length, look.words.stagger, look.words.dur, from, fps);
  const P = lockupLayout(L, width, height);
  const lineGone = prog(f, B.lineOut, B.lineOut + fps * L.beats.lineOut, E.linear);
  const lock = prog(f, B.lockAt, B.lockAt + fps * L.beats.lockIn, L.lockEase);
  const rise = Math.round(L.beats.rise * (height / 1080) * (1 - lock) * 100) / 100;
  const addr = prog(f, B.urlAt, B.urlAt + fps * L.beats.urlIn, E.linear);
  const lineSize = L.line * (height / 1080);
  const S = look.headline;
  return (
    <div style={{ position: 'absolute', inset: 0, background: alpha(look.color.ground, ground) }}>
      {lineGone < 1 && (
        <div style={{ position: 'absolute', left: 0, top: 0, width, height, display: 'flex', alignItems: 'center', justifyContent: 'center', opacity: 1 - lineGone }}>
          <div style={{ font: `${S.weight} ${lineSize}px/1 ${look.type.display}`, letterSpacing: S.tracking, color: look.color.text, whiteSpace: 'nowrap' }}>
            {words.map((w, n) => <Word key={n} m={look.words} text={w} size={lineSize} last={n === words.length - 1} t={wordIn(look.words, f, B.lineAt, n, fps)} />)}
          </div>
        </div>
      )}
      {lock > 0 && (
        <div style={{ position: 'absolute', left: 0, top: 0, width, height, opacity: lock, transform: rise ? `translateY(${rise}px)` : undefined }}>
          <Img src={staticFile(L.markSrc)} style={{ position: 'absolute', display: 'block', left: P.mark.left, top: P.mark.top, width: P.mark.width, height: P.mark.height, maxWidth: 'none' }} />
          <div style={{ position: 'absolute', left: P.word.left, top: P.word.top, font: `${L.word.weight} ${P.fs}px/1 ${L.word.family}`, letterSpacing: L.word.tracking, color: look.color.text, whiteSpace: 'nowrap' }}>{L.word.text}</div>
        </div>
      )}
      {addr > 0 && (
        <div style={{ position: 'absolute', left: P.url.left, top: P.url.top, font: `${L.url.weight} ${P.url.fs}px/1 ${L.url.family}`, color: look.color.text, opacity: L.url.opacity * addr, whiteSpace: 'nowrap' }}>{url}</div>
      )}
    </div>
  );
};
