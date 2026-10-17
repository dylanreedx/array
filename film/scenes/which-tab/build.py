#!/usr/bin/env python3
"""Writes film/scenes/which-tab/which-tab.json (and which-tab-bare.json, the same take with the
sidebar hidden): the real-app half of "Which tab was that?"
(.plans/68-launch-film/research/21-which-tab/brief.md, shots S4-S5).

One take, about 10 s. It opens tight on the bell agent (Cart total) while it runs its
tests, pulls back in one ease-in-out move to the whole Roast workspace (six agents
working, the shop in a browser, the sprint board), and holds on a slow drift while Cart
total finishes for real: its tile and its sidebar row go Done.

The terminal half of the film shows these same agents as Ghostty tabs, so AGENTS below
is the single source for names and prompts (copy them verbatim, never retype them).

    python3 film/scenes/which-tab/build.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'full-day'))
from build import Take  # noqa: E402

BELL = 'cart'

# key, zone, column, name, prompt (what the user asked, shown at the top of the tile)
AGENTS = [
    ('picker', 'web', 0, 'Plan picker', 'Add a weekly or monthly plan picker to the product page.'),
    ('dark', 'web', 1, 'Dark mode', 'Give the shop a dark mode that follows the system setting.'),
    ('cart', 'web', 2, 'Cart total', 'The cart total is off by a cent: two Autumn blends with 10% off show $32.39, not $32.40.'),
    ('subs', 'api', 0, 'Subscriptions', 'Add a subscriptions API: create, pause and resume a plan.'),
    ('emails', 'api', 1, 'Renewal emails', 'Email customers two days before their subscription renews.'),
    ('export', 'api', 2, 'Order export', 'Export last month’s orders as a CSV for the accountant.'),
]

# Geometry (world points). Two zones stacked; each row is three agents and one wide tool tile.
AGENT_W, AGENT_H, WIDE_W = 680, 600, 1000
GAP, TOP, PAD = 40, 80, 40
ZONE_W = PAD + 3 * AGENT_W + 3 * GAP + WIDE_W + PAD
ZONE_H = TOP + AGENT_H + PAD
ZONE_GAP = 100


def agent_frame(column):
    return [PAD + column * (AGENT_W + GAP), TOP, AGENT_W, AGENT_H]


WIDE_FRAME = [PAD + 3 * (AGENT_W + GAP), TOP, WIDE_W, AGENT_H]

# The Roast API board (a board belongs to its zone's project: an agent can only move
# cards on its own project's board, so this one holds the API zone's tickets).
CARDS = [
    ('rst50', 'To Do', 'RST-50 Rate limits for the public API', 'Per key, 60 requests a minute.'),
    ('rst51', 'To Do', 'RST-51 Retry failed webhooks', 'Back off, give up after a day.'),
    ('rst43', 'Doing', 'RST-43 Coffee subscriptions', 'Weekly or monthly beans, pause any time.'),
    ('rst49', 'Doing', 'RST-49 Renewal emails', 'Two days before each renewal.'),
    ('rst48', 'Doing', 'RST-48 Order export', 'A CSV of last month’s orders.'),
    ('rst40', 'Done', 'RST-40 Page the orders API', 'Cursor paging, 50 per page.'),
    ('rst39', 'Done', 'RST-39 Order confirmation email', '“Your coffee is on its way.”'),
]


# --- Harnesses, models, end states --------------------------------------------------------
#
# Each tab in the terminal half runs one CLI and flies to its own tile, so each agent is
# staged on that CLI's real harness. Model ids are what each CLI offered on 2026-10-16:
#   claude: the `initialize` handshake (`opus` -> claude-opus-5-5, "Opus 5.5")
#   codex:  `codex app-server` model/list (default gpt-6.1-sol, "GPT-6.1-Sol")
#   pi:     `pi --list-models` + ~/.pi/agent/models-store.json ("GPT-5.6 Sol", 272000),
#           the model Dylan's own pi agents run most
HARNESS = {'cart': 'claude', 'subs': 'claude', 'picker': 'codex', 'export': 'codex', 'dark': 'pi', 'emails': 'pi'}
CATALOG = [
    {'harness': 'claude', 'model': 'anthropic/claude-opus-5-5', 'displayName': 'Opus 5.5'},
    {'harness': 'codex', 'model': 'openai-codex/gpt-6.1-sol', 'displayName': 'GPT-6.1-Sol'},
    {'harness': 'pi', 'model': 'openai-codex/gpt-5.6-sol', 'displayName': 'GPT-5.6 Sol', 'contextWindow': 272000},
]

# Production pacing: deltas at 30 Hz (`streamHz`), text at about 150 characters a second.
CPS = 150


def dur_for(text, cps=CPS):
    return max(6, round(len(text) / cps * 60))


# --- Tool shapes, one per harness ---------------------------------------------------------

def edit(path, old, new):
    """A claude `Edit` call: the row's diff counts come from these strings (+lines −lines)."""
    return {'name': 'Edit', 'input': {'file_path': path, 'old_string': old, 'new_string': new}}


def bash(command, description, output):
    return {'name': 'Bash', 'input': {'command': command, 'description': description}, 'output': output}


def read(path, output):
    return {'name': 'Read', 'input': {'file_path': path}, 'output': output}


def grep(pattern, path, output):
    return {'name': 'Grep', 'input': {'pattern': pattern, 'path': path}, 'output': output}


def cx_run(command, output):
    """A codex `commandExecution` item (the app-server shape: command, exit code, output)."""
    return {'kind': 'commandExecution', 'title': command, 'command': command, 'output': output}


def cx_change(path):
    """A codex `fileChange` item: path and kind only (no live capture pins a diff body)."""
    return {'kind': 'fileChange', 'title': 'Edit', 'path': path, 'action': 'update'}


def pi_read(path, output):
    return {'name': 'read', 'input': {'path': path}, 'output': output}


def pi_edit(path, old, new):
    """pi's `edit` args as captured from pi 0.85: {path, edits: [{oldText, newText}]}."""
    return {'name': 'edit', 'input': {'path': path, 'edits': [{'oldText': old, 'newText': new}]}, 'output': 'Applied 1 edit.'}


def pi_write(path, content):
    return {'name': 'write', 'input': {'path': path, 'content': content}, 'output': f'Wrote {path}'}


def pi_bash(command, output):
    return {'name': 'bash', 'input': {'command': command}, 'output': output}


def pi_grep(pattern, path, output):
    return {'name': 'grep', 'input': {'pattern': pattern, 'path': path}, 'output': output}


# --- Off camera: each agent's work so far -------------------------------------------------
#
# (verb, value) in order. A tool is started and completed; ('fail', tool) completes it as
# failed. ('end', 'done' | 'failed') ends the agent's turn. Every transcript overflows its
# tile, so the spawn line is scrolled off at frame 0.
HISTORY = {
    'cart': [  # Claude Code, working; finishes live at frame 262
        ('think', 'The discount is applied per line and each line is rounded, so the cents drift.'),
        ('tool', grep('round\\(', 'src/cart', 'src/cart/total.ts:14:  return lines.map((l) => round(l.price * l.qty * (1 - discount)))')),
        ('tool', read('src/cart/total.ts', 'export function cartTotal(lines: Line[], discount = 0)')),
        ('tool', read('src/cart/types.ts', 'export interface Line { sku: string; price: number; qty: number }')),
        ('tool', read('tests/cart.test.ts', "describe('cartTotal', () => {")),
        ('say', 'Each line is rounded before the discount, so a cent goes missing. I’ll round once, on the total.'),
        ('tool', edit('src/cart/total.ts',
                      'export function cartTotal(lines: Line[], discount = 0) {\n  return sum(lines.map((l) => round(l.price * l.qty * (1 - discount))))\n}',
                      'export function cartTotal(lines: Line[], discount = 0) {\n  const subtotal = sum(lines.map((l) => l.price * l.qty))\n  const total = subtotal * (1 - discount)\n  return round(total)\n}')),
        ('tool', edit('tests/cart.test.ts', '})',
                      "  it('rounds once, on the total', () => {\n    const autumn = { sku: 'autumn', price: 18, qty: 2 }\n    expect(cartTotal([autumn], 0.1)).toBe(32.4)\n  })\n})")),
        ('say', 'The cart summary adds the lines up again on its own, so it drifts the same way. Pointing it at cartTotal.'),
        ('tool', edit('src/cart/summary.ts', '  const total = lines.reduce((s, l) => s + round(l.price * l.qty), 0)',
                      '  const total = cartTotal(lines, discount)')),
        ('tool', edit('src/cart/format.ts', 'export const money = (n: number) => `$${round(n).toFixed(2)}`',
                      'export const money = (n: number) => `$${n.toFixed(2)}`')),
    ],
    'subs': [  # Claude Code, working
        ('think', 'Three routes and a status column. Pausing must not lose the next renewal date.'),
        ('tool', read('src/orders/routes.ts', 'router.post("/orders"')),
        ('tool', read('src/server.ts', 'app.use("/orders", orders)')),
        ('say', 'I’ll follow the orders routes: POST /subscriptions, then pause and resume.'),
        ('tool', {'name': 'Write', 'input': {'file_path': 'src/subscriptions/model.ts',
                                             'content': "export type Status = 'active' | 'paused'\n\nexport interface Subscription {\n  id: string\n  plan: 'weekly' | 'monthly'\n  status: Status\n  nextRenewal: string\n}"}}),
        ('tool', edit('src/server.ts', 'app.use("/orders", orders)',
                      'app.use("/orders", orders)\napp.use("/subscriptions", subscriptions)')),
        ('tool', bash('npx tsc --noEmit', 'Type-check', 'src/server.ts(4,30): Cannot find module ./subscriptions/routes')),
        ('say', 'Expected: the routes file doesn’t exist yet. Writing it now.'),
        ('tool', {'name': 'Write', 'input': {'file_path': 'src/subscriptions/routes.ts',
                                             'content': 'export const subscriptions = router()\n\nsubscriptions.post("/", create)\nsubscriptions.post("/:id/pause", pause)\nsubscriptions.post("/:id/resume", resume)'}}),
    ],
    'picker': [  # Codex, working
        ('tool', cx_run('rg -n "price" public/index.html', 'public/index.html:42:  <p class="price">$18</p>')),
        ('tool', cx_run('sed -n 30,60p public/index.html', '<article class="product">\n  <h3>Autumn blend</h3>\n  <p class="price">$18</p>')),
        ('say', 'The product card has room under the price. A two-option toggle fits there: Weekly, Monthly.'),
        ('tool', cx_change('public/index.html')),
        ('tool', cx_change('public/theme.css')),
        ('say', 'The toggle renders. Next: the monthly price, which is four weekly bags with 10% off.'),
        ('tool', cx_run('npm test -- picker', '✓ tests/picker.test.ts (3 tests)')),
        ('tool', cx_change('public/plan.js')),
    ],
    'export': [  # Codex, failed: its test run failed and the turn ended failed
        ('tool', cx_run('rg -n "cursor" src/orders', 'src/orders/routes.ts:12:  const { cursor } = req.query')),
        ('say', 'Orders are already paged by month. I’ll stream them to CSV so a big month never sits in memory.'),
        ('tool', cx_change('src/orders/csv.ts')),
        ('tool', cx_change('src/orders/routes.ts')),
        ('say', 'A customer called “Smith, Jo” would split the row, so every field with a comma is quoted. Running the tests.'),
        ('fail', cx_run('npm test -- orders',
                        'FAIL tests/orders.test.ts > ordersCsv > quotes names with commas\n'
                        '  Expected: "1042,2026-09-14,\\"Smith, Jo\\",36.00"\n'
                        '  Received: "1042,2026-09-14,Smith, Jo,36.00"\n\n'
                        'Tests  1 failed | 8 passed (9)')),
        ('end', 'failed'),
    ],
    'dark': [  # Pi, done
        ('tool', pi_read('public/theme.css', ':root {\n  --paper: #f7f2ea;\n  --ink: #2b2118;')),
        ('say', 'The colours are tokens in public/theme.css, so dark mode is one block of overrides.'),
        ('tool', pi_grep('#[0-9a-fA-F]{6}', 'public', 'public/index.html:12:  <a class="cart" style="color:#2b2118">')),
        ('think', 'One hard-coded colour outside the tokens. Move it to a token first, or it stays brown on dark.'),
        ('tool', pi_edit('public/index.html', '<a class="cart" style="color:#2b2118">', '<a class="cart">')),
        ('tool', pi_edit('public/theme.css', '}',
                         '}\n\n@media (prefers-color-scheme: dark) {\n  :root {\n    --paper: #17130f;\n    --ink: #f2ece4;\n    --muted: #a59a8d;\n    --line: #2e2721;\n  }\n}')),
        ('tool', pi_bash('npx stylelint public/theme.css', 'No problems found.')),
        ('say', 'Dark mode is in. It follows the system setting, every colour is a token with a dark value, and the cart badge reads on both.'),
        ('end', 'done'),
    ],
    'emails': [  # Pi, needs input: it asked a question and its turn ended, waiting for the answer
        ('tool', pi_read('src/emails/order.ts', 'export function orderEmail(order: Order) {')),
        ('say', 'The order email is a good template. The reminder needs the plan, the date and a skip link.'),
        ('tool', pi_grep('sendEmail', 'src', 'src/emails/order.ts:3:import { sendEmail } from "../http"')),
        ('tool', pi_write('src/emails/renewal.ts',
                          'export function renewalEmail(sub: Subscription) {\n  return {\n    subject: `Your ${sub.plan} coffee ships ${weekday(sub.nextRenewal)}`,\n    skip: skipLink(sub),\n  }\n}')),
        ('tool', pi_bash('npm test -- emails', '✓ tests/emails.test.ts (11 tests)')),
        ('think', 'Two days before renewal is clear, but not what time. A 9 a.m. send lands at 3 a.m. for half the customers.'),
        ('tool', pi_edit('src/emails/order.ts', 'export function orderEmail(order: Order) {\n  const footer = `Roast · ${order.shop}`',
                         'export function orderEmail(order: Order) {\n  const footer = shopFooter(order.shop)')),
        ('tool', pi_write('src/emails/footer.ts', 'export const shopFooter = (shop: string) =>\n  `Roast · ${shop} · Manage your plan at roast.coffee/account`')),
        ('tool', pi_bash('npm test -- emails', '✓ tests/emails.test.ts (13 tests)')),
        ('say', 'The reminder is written and tested. One question before I schedule it: should it go out at 9 a.m. in the customer’s time zone, or at the shop’s 9 a.m.?'),
        ('end', 'done'),
    ],
}

# Turn start, back-dated: the working agents' "Working · Nm" at the start of the take.
AGO = {'picker': 1980, 'dark': 2460, 'cart': 1260, 'subs': 2700, 'emails': 1500, 'export': 1740}


def setup():
    """Off camera: every agent deep in its task; three of them already done, failed or asking."""
    t = Take('00-setup', clock='10:40', capture=False)
    t.do({'camera': {'all': True, 'padding': 60}})
    for key, _, _, _, prompt in AGENTS:
        t.agent(key, prompt=prompt)
        t.agent(key, turn='start', ago=AGO[key])
    t.wait(2)
    for key, steps in HISTORY.items():
        for n, (verb, value) in enumerate(steps):
            if verb in ('tool', 'fail'):
                tid = f'{key}-h{n}'
                t.agent(key, tool={'id': tid, **value}, gap=1)
                t.do({'agent': key, 'toolDone': tid, **({'status': 'failed'} if verb == 'fail' else {})}, then=1)
            elif verb == 'end':
                t.agent(key, turn=value, gap=1)
            else:
                t.agent(key, gap=1, **{verb: value})
    return t.wait(110)


def stream(t, key, verb, text, gap=0, cps=CPS):
    """A `say`/`think` at production pace; the cursor moves past it plus `gap`."""
    d = dur_for(text, cps)
    return t.agent(key, dur=d, gap=d + gap, **{verb: text})


def pullback():
    """S4-S5: tight on Cart total, one eased pull-back to the whole workspace, a slow drift."""
    t = Take('01-pullback')
    hold, pull, total = 48, 180, 600
    # The opening: Cart total fills the frame while its tests run.
    t.do({'camera': {'tiles': [BELL], 'padding': 24}}, mark='tight')
    t.agent('cart', tool={'id': 'c4', **bash('npm test -- cart', 'Run the cart tests',
                                             '✓ tests/cart.test.ts (14 tests)\n\n Test Files  1 passed (1)\n      Tests  14 passed (14)')})
    t.wait(hold)
    t.do({'camera': {'all': True, 'padding': 70}}, dur=pull, ease='inOut', mark='pullStart')
    t.wait(pull)
    t.do({}, mark='wide')
    # Then the camera holds perfectly still to the end. Round 4 drifted in here (3% over
    # 370 frames); every frame landed at a slightly different zoom, tiles, borders and text
    # snapped to whole pixels independently, and the wide shot shook.
    t.wait(1)
    t.do({}, mark='hold')

    # Cart total finishes on its own clock, after the wide view has landed (unchanged).
    t.t = 112
    t.agent('cart', toolDone='c4', gap=24)
    t.agent('cart', dur=70, say='Fixed: the discount applies first and the total is rounded once. $32.40 now, and a test pins it.', gap=76)
    t.wait(50)
    t.agent('cart', turn='done', mark='bell')
    # You click its title bar: production focuses the tile and the canvas's marching-ants
    # focus border lands on it (a real delivered click; the pointer itself is not in the pixels).
    t.t = 248
    t.point({'tile': BELL, 'at': 'header'}, dur=14, gap=2)
    t.click(mark='focus')

    # The two other working agents: streaming, thinking and running tools all the way through.
    # Dark mode (done), Order export (failed) and Renewal emails (asking) stay as they ended.
    t.t = 6
    stream(t, 'subs', 'say', 'Routes are in. Now the part that matters: pause keeps the plan and moves next_renewal forward, and resume never charges twice.', gap=8)
    t.agent('subs', tool={'id': 's2', **edit('src/subscriptions/routes.ts', 'subscriptions.post("/:id/resume", resume)',
                          'subscriptions.post("/:id/resume", async (req, res) => {\n  const sub = await resume(req.params.id)\n  res.json(sub)\n})')}, gap=40)
    t.agent('subs', toolDone='s2', gap=10)
    t.agent('subs', tool={'id': 's3', **bash('npm test -- subscriptions', 'Run the subscription tests',
                                             '✓ tests/subscriptions.test.ts (7 tests)')}, gap=130)
    t.agent('subs', toolDone='s3', gap=12)
    stream(t, 'subs', 'think', 'Seven pass. Still missing: a paused plan must not renew, and resuming the day before renewal must not double-ship.', gap=10)
    stream(t, 'subs', 'say', 'Adding two tests for the edges: a paused plan never renews, and a resume on renewal day ships once.', gap=10)
    t.agent('subs', tool={'id': 's4', 'name': 'Write', 'input': {'file_path': 'tests/subscriptions.pause.test.ts',
                          'content': "it('never renews a paused plan', async () => {\n  const sub = await pause(await create(weekly))\n  expect(await renewDue(sub.nextRenewal)).not.toContain(sub.id)\n})"}}, gap=40)
    t.agent('subs', toolDone='s4', gap=10)
    t.agent('subs', tool={'id': 's5', **bash('npm test -- subscriptions', 'Run the subscription tests',
                                             '✓ tests/subscriptions.test.ts (7 tests)\n✓ tests/subscriptions.pause.test.ts (2 tests)')})
    t.t = 0
    stream(t, 'picker', 'say', 'Wiring the toggle: each option carries its price, so switching plans updates the line without a round trip.', gap=10)
    t.agent('picker', tool={'id': 'p2', **cx_change('public/plan.js')}, gap=36)
    t.agent('picker', toolDone='p2', gap=10)
    t.agent('picker', tool={'id': 'p3', **cx_run('npm test -- picker', '✓ tests/picker.test.ts (5 tests)')}, gap=120)
    t.agent('picker', toolDone='p3', gap=12)
    stream(t, 'picker', 'say', 'Five tests pass, including the keyboard: arrow keys move between Weekly and Monthly and the price follows. Checking the focus ring in dark mode next.', gap=10)
    t.agent('picker', tool={'id': 'p4', **cx_run('rg -n "focus-visible" public/theme.css', 'public/theme.css:88:.plan input:focus-visible {')}, gap=60)
    t.agent('picker', toolDone='p4', gap=10)
    t.agent('picker', tool={'id': 'p5', **cx_change('public/theme.css')}, gap=40)
    t.agent('picker', toolDone='p5', gap=10)
    stream(t, 'picker', 'say', 'The focus ring uses the accent token now, so it shows in both themes. Running the whole suite.', gap=10)
    t.agent('picker', tool={'id': 'p6', **cx_run('npm test', 'Test Files  9 passed (9)\n     Tests  61 passed (61)')})
    t.t = total - 1
    return t


def scene(sidebar=True):
    zones = [
        {'key': 'web', 'project': 'web', 'name': 'Storefront', 'rect': [0, 0, ZONE_W, ZONE_H], 'color': 'orange'},
        {'key': 'api', 'project': 'api', 'name': 'Roast API', 'rect': [0, ZONE_H + ZONE_GAP, ZONE_W, ZONE_H], 'color': 'teal'},
    ]
    tiles = [{'key': key, 'kind': 'agent', 'zone': zone, 'frame': agent_frame(column), 'name': name, 'harness': HARNESS[key]}
             for key, zone, column, name, _ in AGENTS]
    tiles += [
        # The page's own <title>: what production writes into a browser tile's title once a page
        # loads (BrowserTileNSView.refresh). Staged up front, a staged tile keeps the stager's
        # default "Browser" in its header for the whole take.
        {'key': 'site', 'kind': 'browser', 'zone': 'web', 'frame': WIDE_FRAME, 'url': 'http://localhost:3000/',
         'title': 'Roast — coffee, roasted this morning'},
        {'key': 'board', 'kind': 'kanban', 'zone': 'api', 'frame': WIDE_FRAME, 'title': 'Roast sprint',
         'board': {'title': 'Roast sprint', 'columns': ['To Do', 'Doing', 'Done'],
                   'cards': [{'key': k, 'column': c, 'title': title, 'body': body} for k, c, title, body in CARDS]}},
    ]
    return {
        'schema': 'array.film.scene.v1',
        'id': 'which-tab' if sidebar else 'which-tab-bare',
        'window': {'width': 1920, 'height': 1080},
        'sidebar': sidebar,
        'sidebarWidth': 300,
        'cameraModel': 'v2',
        'fps': 60,
        'streamHz': 30,
        'settleToolDetails': True,
        'video': 'prores',
        'png': 'all',
        'closeUpMinZoom': 0.85,
        'site': {'project': 'web', 'path': 'public'},
        'catalog': CATALOG,
        'workspace': 'Roast',
        'projects': [
            {'key': 'web', 'name': 'roast-web', 'files': '../full-day/projects/roast-web', 'git': {}},
            {'key': 'api', 'name': 'roast-api', 'files': '../full-day/projects/roast-api', 'git': {}},
        ],
        'zones': zones,
        'tiles': tiles,
        'takes': [setup().json(), pullback().json()],
    }

def plate_scene():
    """The plate: the primary take (scene, content timeline, streaming, states, click) with the
    camera held on the primary's wide framing (`all`, padding 70: where the pull-back lands at
    frame 228) for all 600 frames, so every tile is whole on every frame. Camera actions become
    mark-only actions, so frames.json keeps the primary's marks."""
    s = scene(sidebar=False)
    s['id'] = 'which-tab-plate'
    # Off camera, at the end of setup, the plate flies the primary's exact camera path once:
    # the cut to Cart total, then the same 180-frame pull-back to the wide framing. Below
    # 0.86x the title bar's chrome floor takes height from each transcript, step by step as
    # the zoom falls, and a transcript that gets no new content keeps the scroll offset that
    # history leaves it with. Flying the same path gives the plate's finished tiles (Dark
    # mode, Renewal emails, Order export) the same offset as the primary's.
    setup_take = s['takes'][0]
    start = setup_take['frames']
    setup_take['actions'] += [{'at': start, 'camera': {'tiles': [BELL], 'padding': 24}},
                              {'at': start + 48, 'camera': {'all': True, 'padding': 70}, 'dur': 180, 'ease': 'inOut'}]
    setup_take['frames'] = start + 48 + 180 + 60
    # Those extra setup frames put the take later on the film clock; start every turn that
    # much later too, so each "Working · Nm Ns" reads exactly what the primary's reads.
    extra = (setup_take['frames'] - start) / 60
    for a in setup_take['actions']:
        if a.get('turn') == 'start':
            a['ago'] = a['ago'] - extra
    take = s['takes'][1]
    actions = []
    for a in take['actions']:
        if 'camera' in a:
            if 'mark' in a:
                actions.append({'at': a['at'], 'mark': a['mark']})
        else:
            actions.append(a)
    actions.insert(0, {'at': 0, 'camera': {'all': True, 'padding': 70}, 'mark': 'plate'})
    take['actions'] = actions
    return s


if __name__ == '__main__':
    for sidebar, name in ((True, 'which-tab.json'), (False, 'which-tab-bare.json')):
        s = scene(sidebar)
        path = os.path.join(HERE, name)
        with open(path, 'w') as f:
            json.dump(s, f, indent=1, ensure_ascii=False)
            f.write('\n')
        for take in s['takes']:
            marks = {a['mark']: a['at'] for a in take['actions'] if 'mark' in a}
            print(f"{name} {take['name']}: {take['frames']} frames ({take['frames'] / 60:.1f}s) marks {marks}")


def probe_scene(stream_hz):
    """Measurement only (not footage): the camera holds still on Subscriptions while it streams
    its first line of the take, at the same rate, with the word-per-frame stream (stream_hz
    None, every round before 4) or production's 30 Hz deltas. A frame diff of its transcript
    then sees text, not camera."""
    s = scene(sidebar=False)
    s['id'] = 'which-tab-probe-' + ('30hz' if stream_hz else 'word')
    if stream_hz:
        s['streamHz'] = stream_hz
    else:
        s.pop('streamHz', None)
    t = Take('01-probe')
    t.do({'camera': {'tiles': ['subs'], 'padding': 24}})
    t.t = 20
    stream(t, 'subs', 'say', 'Routes are in. Now the part that matters: pause keeps the plan and moves next_renewal forward, and resume never charges twice.')
    t.t = 119
    s['takes'] = [setup().json(), t.json()]
    return s


if __name__ == '__main__':
    plate = plate_scene()
    with open(os.path.join(HERE, 'which-tab-plate.json'), 'w') as f:
        json.dump(plate, f, indent=1, ensure_ascii=False)
        f.write('\n')
    print('wrote which-tab-plate.json')


if __name__ == '__main__' and 'probe' in sys.argv[1:]:
    for hz in (None, 30):
        probe = probe_scene(hz)
        with open(os.path.join(HERE, probe['id'] + '.json'), 'w') as f:
            json.dump(probe, f, indent=1, ensure_ascii=False)
            f.write('\n')
        print('wrote', probe['id'] + '.json')
