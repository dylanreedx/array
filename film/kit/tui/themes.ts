// The CLIs' own colours. These are not a film look: they are what the real CLI draws, read off live
// captures, and they change only when the CLI or the terminal theme does.
//
// claude draws in truecolor (its dark theme), so the terminal theme does not change it. codex draws in the
// terminal's ANSI palette, so its colours ARE the terminal theme's (here Vesper, Dylan's Ghostty theme:
// green 2 #99ffe4, red 1 #ff8080, bright black 8). pi draws in 24-bit colours from its own theme.

export interface ClaudeTheme { text: string; dim: string; claude: string; success: string; error: string; border: string; addedBg: string; removedBg: string; addedWord: string; removedWord: string }
export interface CodexTheme { text: string; dim: string; green: string; red: string; cyan: string; userBand: string }
export interface PiTheme { text: string; reply: string; userBg: string; toolBg: string; path: string; muted: string; removed: string; added: string; rule: string; status: string }

/** Claude Code's dark theme (the purple "accept edits" mode line is left out: one less colour in the frame). */
export const CLAUDE_DARK: ClaudeTheme = {
  text: '#ffffff',
  dim: 'rgb(153,153,153)',
  claude: 'rgb(215,119,87)',
  success: 'rgb(78,186,101)',
  error: 'rgb(255,107,128)',
  border: 'rgb(136,136,136)',
  addedBg: 'rgb(34,92,43)',
  removedBg: 'rgb(122,41,54)',
  addedWord: 'rgb(56,166,96)',
  removedWord: 'rgb(179,89,107)',
};

/** codex under Ghostty's Vesper theme. */
export const CODEX_VESPER: CodexTheme = {
  text: '#ffffff',
  dim: 'rgba(255,255,255,0.5)',
  green: '#99ffe4',
  red: '#ff8080',
  cyan: '#99ffe4',
  userBand: 'rgba(255,255,255,0.07)',
};

/** pi 0.85 with Dylan's pi theme, read off a live capture. */
export const PI_DYLAN: PiTheme = {
  text: 'rgb(212,212,212)',
  reply: '#ffffff',
  userBg: 'rgb(52,53,65)',
  toolBg: 'rgb(40,50,40)',
  path: 'rgb(138,190,183)',
  muted: 'rgb(128,128,128)',
  removed: 'rgb(204,102,102)',
  added: 'rgb(181,189,104)',
  rule: 'rgb(129,162,190)',
  status: 'rgb(102,102,102)',
};
