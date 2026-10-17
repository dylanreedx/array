// What a CLI session shows, as data. A video writes its sessions (what each agent is doing, in that CLI's
// own vocabulary); the kit draws them in each CLI's real grammar. Truth rule: every model id, verb and
// layout here was read off the real CLI (versions in each renderer's header). Never invent a state.

// ---- claude (Claude Code) ------------------------------------------------------------------------------
export type ClaudeRow = (
  | { t: 'user'; text: string }
  | { t: 'say'; text: string }
  | { t: 'thought'; secs: number }
  | { t: 'tool'; name: string; arg: string; pending?: boolean }
  | { t: 'out'; text: string; first?: boolean }
  | { t: 'diff'; n: number; sign: '+' | '-' | ' '; text: string }
  | { t: 'gap' }) & { id?: string };

export interface ClaudeSession {
  cli: 'claude';
  rows: ClaudeRow[];
  /** the spinner line: one of Claude Code's real verbs, elapsed seconds at film frame 0, tokens */
  spin: { verb: string; secs: number; tokens: string };
}

// ---- codex ---------------------------------------------------------------------------------------------
export type CodexRow =
  | { t: 'user'; text: string }
  | { t: 'say'; text: string }
  | { t: 'explored'; items: [string, string][] }
  | { t: 'ran'; cmd: string; out: string[]; ok: boolean }
  | { t: 'edited'; path: string; add: number; del: number; diff: [number, ' ' | '+' | '-', string][] }
  | { t: 'worked'; secs: number }
  /** a turn that ended failed: codex's red ■ error line */
  | { t: 'failed'; text: string };
export interface CodexSession { cli: 'codex'; rows: CodexRow[]; working?: { secs: number }; context: number }

// ---- pi ------------------------------------------------------------------------------------------------
export type PiRow =
  | { t: 'user'; text: string }
  | { t: 'say'; text: string }
  | { t: 'tool'; verb: 'read' | 'edit' | 'write' | 'grep' | '$'; arg: string; out?: string[]; diff?: [number, ' ' | '+' | '-', string][] };
/** `model` is the display name pi's own status line shows for the model id (pi --list-models). */
export interface PiSession { cli: 'pi'; rows: PiRow[]; status: { model: string; effort: string; session: number; up: string; down: string; cost: string } }

export type CliSession = ClaudeSession | CodexSession | PiSession;
export type Cli = CliSession['cli'];
