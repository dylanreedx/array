// What each tab's session shows. Three CLIs (round 4): Cart total and Subscriptions run claude, Plan
// picker and Order export run codex, Dark mode and Renewal emails run pi; each is drawn in its own CLI's
// grammar (kit/tui: claude.tsx, codex.tsx, pi.tsx). Every step is the footage agent's history for that
// agent (HISTORY in .worktrees/film-harness/film/scenes/which-tab/build.py; prompts verbatim from
// .plans/68-launch-film/which-tab-r0/footage/notes.md), so each tab reads as the agent its tile shows.
// Each tab shows the state its status dot ends the hunt in (timeline.ts STATUS): Plan picker, Cart total
// and Subscriptions working; Dark mode done (its finished summary); Renewal emails waiting on a question;
// Order export failed (a failing test run, the turn stopped). Elapsed times are the tiles' at frame 0.
//
// claude: welcome box, ⏺ messages and tool calls, ⎿ results, ∴ thought, line-numbered diffs, the ✻ spinner
// with its verb, the bordered prompt.
import type { ClaudeRow, CliSession } from '../../kit/tui/types';
import type { TabKey } from './constants';

type Row = ClaudeRow;

const g: Row = { t: 'gap' };
/** Tag a block's rows (UNSTACK maps each tagged block onto its counterpart in the tile). */
const tag = (id: string, rows: Row[]): Row[] => rows.map((r) => ({ ...r, id }));
const say = (text: string): Row[] => [{ t: 'say', text }, g];
const think = (secs: number): Row[] => [{ t: 'thought', secs }, g];
const search = (pattern: string, path: string, found: string): Row[] => [{ t: 'tool', name: 'Search', arg: `pattern: "${pattern}", path: "${path}"` }, { t: 'out', text: found, first: true }, g];
const read = (path: string, n: number): Row[] => [{ t: 'tool', name: 'Read', arg: path }, { t: 'out', text: `Read ${n} lines (ctrl+r to expand)`, first: true }, g];
const update = (path: string, add: number, del: number, diff: [number, ' ' | '+' | '-', string][]): Row[] => [
  { t: 'tool', name: 'Update', arg: path },
  { t: 'out', text: `Updated ${path} with ${[add && `${add} addition${add > 1 ? 's' : ''}`, del && `${del} removal${del > 1 ? 's' : ''}`].filter(Boolean).join(' and ')}`, first: true },
  ...diff.map(([n, sign, text]) => ({ t: 'diff' as const, n, sign, text })),
  g,
];
const write = (path: string, lines: string[]): Row[] => [{ t: 'tool', name: 'Write', arg: path }, { t: 'out', text: `Wrote ${lines.length} lines to ${path}`, first: true },
  ...lines.map((text) => ({ t: 'out' as const, text })), g];
const bash = (cmd: string, outLines: string[], pending = false): Row[] => [{ t: 'tool', name: 'Bash', arg: cmd, pending },
  ...outLines.map((text, k) => ({ t: 'out' as const, text, first: k === 0 })), g];
const user = (text: string): Row[] => [{ t: 'user', text }, g];


export type Terminal = CliSession;

export const SESSIONS: Record<TabKey, Terminal> = {
  picker: {
    cli: 'codex',
    rows: [
      { t: 'user', text: 'Add a weekly or monthly plan picker to the product page.' },
      { t: 'explored', items: [['Search', 'price in index.html'], ['Read', 'index.html']] },
      { t: 'say', text: 'The product card has room under the price. A two-option toggle fits there: Weekly, Monthly.' },
      { t: 'edited', path: 'public/index.html', add: 4, del: 0, diff: [[42, ' ', '  <p class="price">$18</p>'], [43, '+', '  <fieldset class="plan">'], [44, '+', '    <label><input type="radio" name="plan" value="weekly" checked> Weekly</label>'], [45, '+', '    <label><input type="radio" name="plan" value="monthly"> Monthly</label>'], [46, '+', '  </fieldset>']] },
      { t: 'edited', path: 'public/theme.css', add: 5, del: 0, diff: [[31, '+', '.plan {'], [32, '+', '  display: flex;'], [33, '+', '  gap: var(--space-2);'], [34, '+', '  border: 0;'], [35, '+', '}'], [36, ' ', '.price {']] },
      { t: 'say', text: 'The toggle renders. Next: the monthly price, which is four weekly bags with 10% off.' },
      { t: 'ran', cmd: 'npm test -- picker', ok: true, out: ['✓ tests/picker.test.ts (3 tests)'] },
      { t: 'edited', path: 'public/plan.js', add: 3, del: 0, diff: [[1, '+', 'const PRICE = { weekly: 18, monthly: 64.8 }'], [2, '+', "document.querySelectorAll('.plan input').forEach((i) =>"], [3, '+', "  i.addEventListener('change', () => price.textContent = `$${PRICE[i.value]}`))"]] },
    ],
    working: { secs: 1980 },
    context: 64,
  },
  dark: {
    cli: 'pi',
    rows: [
      { t: 'user', text: 'Give the shop a dark mode that follows the system setting.' },
      { t: 'tool', verb: 'read', arg: 'public/theme.css' },
      { t: 'say', text: 'The colours are tokens in public/theme.css, so dark mode is one block of overrides.' },
      { t: 'tool', verb: 'grep', arg: '/#[0-9a-fA-F]{6}/ in public', out: ['public/index.html:12:  <a class="cart" style="color:#2b2118">'] },
      { t: 'tool', verb: 'edit', arg: 'public/index.html', diff: [[12, '-', '  <a class="cart" style="color:#2b2118">'], [12, '+', '  <a class="cart">']] },
      { t: 'tool', verb: 'edit', arg: 'public/theme.css', diff: [[6, ' ', '}'], [7, '+', ''], [8, '+', '@media (prefers-color-scheme: dark) {'], [9, '+', '  :root {'], [10, '+', '    --paper: #17130f;'], [11, '+', '    --ink: #f2ece4;'], [12, '+', '    --muted: #a59a8d;'], [13, '+', '    --line: #2e2721;'], [14, '+', '  }'], [15, '+', '}']] },
      { t: 'tool', verb: '$', arg: 'npx stylelint public/theme.css', out: ['No problems found.'] },
      { t: 'say', text: 'Dark mode is in. It follows the system setting, every colour is a token with a dark value, and the cart badge reads on both.' },
    ],
    status: { model: 'GPT-5.6 Sol', effort: 'medium', session: 88, up: '41k', down: '9.6k', cost: '$0.62' },
  },
  cart: {
    cli: 'claude',
    rows: [
      ...tag('user', user('The cart total is off by a cent: two Autumn blends with 10% off show $32.39, not $32.40.')),
      ...tag('think', think(4)),
      ...tag('explore', [...search('round\\(', 'src/cart', 'Found 1 file'), ...read('src/cart/total.ts', 41), ...read('src/cart/types.ts', 18), ...read('tests/cart.test.ts', 96)]),
      ...tag('say:rounded', say('Each line is rounded before the discount, so a cent goes missing. I’ll round once, on the total.')),
      ...tag('edit:total', update('src/cart/total.ts', 3, 1, [[13, ' ', 'export function cartTotal(lines: Line[], discount = 0) {'], [14, '-', '  return sum(lines.map((l) => round(l.price * l.qty * (1 - discount))))'],
        [14, '+', '  const subtotal = sum(lines.map((l) => l.price * l.qty))'], [15, '+', '  const total = subtotal * (1 - discount)'], [16, '+', '  return round(total)'], [17, ' ', '}']])),
      ...tag('edit:test', update('tests/cart.test.ts', 4, 0, [[92, '+', "  it('rounds once, on the total', () => {"], [93, '+', "    const autumn = { sku: 'autumn', price: 18, qty: 2 }"], [94, '+', '    expect(cartTotal([autumn], 0.1)).toBe(32.4)'], [95, '+', '  })'], [96, ' ', '})']])),
      ...tag('say:summary', say('The cart summary adds the lines up again on its own, so it drifts the same way. Pointing it at cartTotal.')),
      ...tag('edit:summary', update('src/cart/summary.ts', 1, 1, [[8, '-', '  const total = lines.reduce((s, l) => s + round(l.price * l.qty), 0)'], [8, '+', '  const total = cartTotal(lines, discount)']])),
      ...tag('edit:format', update('src/cart/format.ts', 1, 1, [[3, '-', 'export const money = (n: number) => `$${round(n).toFixed(2)}`'], [3, '+', 'export const money = (n: number) => `$${n.toFixed(2)}`']])),
      ...tag('run:tests', [{ t: 'tool', name: 'Bash', arg: 'npm test -- cart', pending: true }, { t: 'out', text: 'Running…', first: true }]),
    ],
    spin: { verb: 'Simmering', secs: 1260, tokens: '4.8k' },
  },
  subs: {
    cli: 'claude',
    rows: [
      ...user('Add a subscriptions API: create, pause and resume a plan.'),
      ...think(5),
      ...read('src/orders/routes.ts', 96),
      ...read('src/server.ts', 54),
      ...say('I’ll follow the orders routes: POST /subscriptions, then pause and resume.'),
      ...write('src/subscriptions/model.ts', ["export type Status = 'active' | 'paused'", '', 'export interface Subscription {', '  id: string', "  plan: 'weekly' | 'monthly'", '  status: Status', '  nextRenewal: string', '}']),
      ...update('src/server.ts', 1, 0, [[21, ' ', 'app.use("/orders", orders)'], [22, '+', 'app.use("/subscriptions", subscriptions)']]),
      ...bash('npx tsc --noEmit', ['src/server.ts(4,30): Cannot find module ./subscriptions/routes']),
      ...say('Expected: the routes file doesn’t exist yet. Writing it now.'),
      ...write('src/subscriptions/routes.ts', ['export const subscriptions = router()', '', 'subscriptions.post("/", create)', 'subscriptions.post("/:id/pause", pause)', 'subscriptions.post("/:id/resume", resume)']),
    ],
    spin: { verb: 'Stewing', secs: 2700, tokens: '7.2k' },
  },
  emails: {
    cli: 'pi',
    rows: [
      { t: 'user', text: 'Email customers two days before their subscription renews.' },
      { t: 'tool', verb: 'read', arg: 'src/emails/order.ts' },
      { t: 'say', text: 'The order email is a good template. The reminder needs the plan, the date and a skip link.' },
      { t: 'tool', verb: 'grep', arg: '/sendEmail/ in src', out: ['src/emails/order.ts:3:import { sendEmail } from "../http"'] },
      { t: 'tool', verb: 'write', arg: 'src/emails/renewal.ts', out: ['export function renewalEmail(sub: Subscription) {', '  return {', '    subject: `Your ${sub.plan} coffee ships ${weekday(sub.nextRenewal)}`,', '    skip: skipLink(sub),', '  }', '}'] },
      { t: 'tool', verb: '$', arg: 'npm test -- emails', out: ['✓ tests/emails.test.ts (11 tests)'] },
      { t: 'tool', verb: 'edit', arg: 'src/emails/order.ts', diff: [[8, '-', '  const footer = `Roast · ${order.shop}`'], [8, '+', '  const footer = shopFooter(order.shop)']] },
      { t: 'tool', verb: 'write', arg: 'src/emails/footer.ts', out: ['export const shopFooter = (shop: string) =>', '  `Roast · ${shop} · Manage your plan at roast.coffee/account`'] },
      { t: 'tool', verb: '$', arg: 'npm test -- emails', out: ['✓ tests/emails.test.ts (13 tests)'] },
      { t: 'say', text: 'The reminder is written and tested. One question before I schedule it: should it go out at 9 a.m. in the customer’s time zone, or at the shop’s 9 a.m.?' },
    ],
    status: { model: 'GPT-5.6 Sol', effort: 'medium', session: 93, up: '18k', down: '4.2k', cost: '$0.21' },
  },
  export: {
    cli: 'codex',
    rows: [
      { t: 'user', text: 'Export last month’s orders as a CSV for the accountant.' },
      { t: 'explored', items: [['Search', 'cursor in orders']] },
      { t: 'say', text: 'Orders are already paged by month. I’ll stream them to CSV so a big month never sits in memory.' },
      { t: 'edited', path: 'src/orders/csv.ts', add: 6, del: 0, diff: [[1, '+', 'export async function* ordersCsv(month: string) {'], [2, '+', '  yield "order,date,customer,total\\n"'], [3, '+', '  for await (const page of pages(month)) {'], [4, '+', '    for (const o of page) yield row(o)'], [5, '+', '  }'], [6, '+', '}']] },
      { t: 'edited', path: 'src/orders/routes.ts', add: 1, del: 0, diff: [[14, '+', 'router.get("/orders.csv", (req, res) => stream(res, ordersCsv(req.query.month)))']] },
      { t: 'say', text: 'A customer called “Smith, Jo” would split the row, so every field with a comma is quoted. Running the tests.' },
      { t: 'ran', cmd: 'npm test -- orders', ok: false, out: ['FAIL tests/orders.test.ts > ordersCsv > quotes names with commas', '  Expected: "1042,2026-09-14,\\"Smith, Jo\\",36.00"', '  Received: "1042,2026-09-14,Smith, Jo,36.00"', '', 'Tests  1 failed | 8 passed (9)'] },
      { t: 'failed', text: 'npm test -- orders exited with code 1' },
    ],
    context: 71,
  },
};
