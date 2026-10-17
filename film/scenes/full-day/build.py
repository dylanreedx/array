#!/usr/bin/env python3
"""Writes film/scenes/full-day/full-day.json, video 2 "A day in Array"
(.plans/68-launch-film/research/18-full-day/README.md has the beat sheet).

Each take is written as a sequence of beats on a cursor, so re-timing one beat moves
everything after it. `t.wait(n)` advances the cursor; every action lands at the cursor.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))


class Take:
    def __init__(self, name, clock=None, capture=True):
        self.name, self.clock, self.capture = name, clock, capture
        self.t, self.actions = 0, []

    def wait(self, n):
        self.t += n
        return self

    def do(self, verb, dur=None, mark=None, then=0, **rest):
        a = {'at': self.t, **verb, **rest}
        if dur:
            a['dur'] = dur
        if mark:
            a['mark'] = mark
        self.actions.append(a)
        self.t += then
        return self

    # Shorthands, each advancing the cursor past the gesture it makes.
    def point(self, to, dur=24, gap=4, **kw):
        return self.do({'pointer': {'to': to, **kw}}, dur=dur, then=dur + gap)

    def click(self, count=1, gap=10, mark=None):
        c = {'deliver': True}
        if count != 1:
            c['count'] = count
        return self.do({'click': c}, mark=mark, then=gap)

    def key(self, key, mods=None, gap=14, mark=None):
        v = {'key': key}
        if mods:
            v['mods'] = mods
        return self.do(v, mark=mark, then=gap)

    def type(self, text, per=2, gap=8):
        dur = max(6, len(text) * per)
        return self.do({'type': text}, dur=dur, then=dur + gap)

    def agent(self, key, gap=0, dur=None, mark=None, **verb):
        return self.do({'agent': key, **verb}, dur=dur, mark=mark, then=gap)

    def mark(self, name):
        return self.do({}, mark=name)

    def json(self):
        out = {'name': self.name, 'frames': self.t + 1, 'actions': self.actions}
        if self.clock:
            out['clock'] = self.clock
        if not self.capture:
            out['capture'] = False
        return out


def board_apply(card_id, tool_id, op, key, gap_done=14, **fields):
    """An array_board_apply call by the agent at the cursor, completing `gap_done` later."""
    return tool_id, {'id': tool_id, 'name': 'mcp__array_workspace__array_board_apply', 'input': {
        'op': op, 'boardId': '{board:board}', 'expectedRevision': 'auto', 'idempotencyKey': key, **fields}}


# Each captured take opens on a still hold the transition before it shows (the film's AFTER) and
# closes on one the transition after it keeps playing (BEFORE): videos/full-day/timeline.ts.
LEAD = {'01-morning': 140, '02-late': 160, '04-afternoon': 160, '06-ship': 0, '07-evening': 170}
TAIL = {'01-morning': 150, '02-late': 180, '06-ship': 170}


def lead(t):
    return t.wait(LEAD.get(t.name, 0))


def tail(t):
    return t.wait(TAIL.get(t.name, 0))


TICKETS = [
    ('darkmode', 'RST-41 Dark mode for the shop', 'Follow the system setting. The design tokens live in public/theme.css.'),
    ('cartbug', 'RST-42 Cart total is off by a cent', 'A 10% discount on two Autumn blends shows $32.39. It should be $32.40.'),
    ('subs', 'RST-43 Coffee subscriptions', 'Weekly or monthly beans, pause any time. Plan picker, checkout and renewal emails.'),
    ('hero', 'RST-44 Autumn blend hero copy', 'Shorter headline for the autumn launch.'),
]


def setup():
    t = Take('00-setup', clock='8:30', capture=False)
    t.do({'camera': {'tiles': ['emails'], 'padding': 160}})
    t.agent('emails', prompt='Send an email when an order is placed.')
    t.agent('emails', turn='start', ago=1500)
    t.agent('emails', say='Orders now send "Your coffee is on its way". The template and a test are in.', gap=2)
    t.agent('emails', turn='done', gap=30)
    return t


def morning():
    t = Take('01-morning', clock='8:45')
    # M1 · yesterday's finished agent, closed into History.
    t.do({'camera': {'tiles': ['emails'], 'padding': 170}})
    lead(t).wait(20).point({'tile': 'emails', 'at': 'close'}, dur=40, spring='soft', gap=8)
    t.click(mark='closed', gap=14)
    t.mark('filedLine').wait(110)
    # M2 · draw the Storefront zone: marquee, picker, rename, colour, resize.
    t.do({'camera': {'rect': [1580, -80, 1640, 1100]}}, dur=170, mark='toEmpty', then=174)
    t.point({'world': [1720, 30]}, dur=22, gap=6)
    t.do({'gesture': {'to': {'world': [2880, 840]}}}, dur=52, mark='marquee', then=60)
    t.point({'choice': 'roast-web'}, dur=26, gap=8)
    t.click(mark='picked', gap=10)
    t.do({'adopt': {'as': 'webZone', 'kind': 'zone'}}, then=4)
    t.point({'zone': 'webZone', 'at': 'header'}, dur=22, gap=6)
    t.click(count=2, mark='rename', gap=10)
    t.type('Storefront', per=3)
    t.key('Return', gap=10)
    t.point({'zone': 'webZone', 'at': 'overflow'}, dur=22, gap=4)
    t.click(mark='menu', gap=46)
    t.do({'menu': {'choose': ['Color', 'Orange']}}, mark='colour', then=12)
    t.point({'zone': 'webZone', 'at': 'right'}, dur=22, gap=6)
    t.do({'gesture': {'to': {'by': [260, 0]}}}, dur=40, mark='resize', then=50)
    t.mark('zoneLine').wait(100)
    # M3 · ⌘K: a board, then the Planner agent; auto-layout settles them and the zone grows.
    t.point({'zone': 'webZone', 'at': [0.35, 0.55]}, dur=20, gap=4)
    t.click(gap=10)
    t.key('k', ['cmd'], mark='palette', gap=16)
    t.type('board', per=3)
    t.key('Return', gap=12)
    t.do({'adopt': {'as': 'board', 'kind': 'kanban'}}, then=10)
    t.key('k', ['cmd'], gap=16)
    t.type('agent', per=3)
    t.key('Return', gap=16)
    t.key('Return', gap=12)
    t.do({'adopt': {'as': 'planner', 'kind': 'agent', 'name': 'Planner', 'workspaceTools': True}}, mark='grown', then=8)
    t.mark('growLine').wait(30)
    t.do({'camera': {'zone': 'webZone', 'padding': 40}}, dur=100, then=120)
    # M4 · the Planner fills the board from Jira.
    t.point({'tile': 'planner', 'at': 'composer'}, dur=22, gap=4)
    t.click(gap=6)
    t.type("What's on my plate today?", per=2)
    t.key('Return', mark='ask', gap=4)
    t.agent('planner', turn='start', gap=6)
    t.agent('planner', think='Check this sprint in Jira, then put today’s tickets on the board.', dur=24, gap=30)
    t.agent('planner', tool={'id': 'jira1', 'name': 'mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql',
                             'input': {'cloudId': 'roast.atlassian.net', 'jql': 'assignee = currentUser() AND sprint in openSprints() ORDER BY rank'},
                             'output': '\n'.join(title for _, title, _ in TICKETS)}, gap=28)
    t.agent('planner', toolDone='jira1', gap=8)
    for n, (key, title, body) in enumerate(TICKETS):
        tid, tool = board_apply(key, f'card{n}', 'create', key, columnId='{column:board/To Do}', title=title, body=body)
        tool['bind'] = key
        t.agent('planner', tool=tool, gap=12)
        t.agent('planner', toolDone=tid, gap=10)
    t.agent('planner', say='Four tickets for today. RST-43 is the big one, so it gets its own agent.', dur=40, mark='planned', gap=44)
    t.agent('planner', turn='done', gap=4)
    t.mark('planLine').wait(100)
    # M5 · a ticket's details.
    t.point({'card': 'subs'}, dur=24, gap=6)
    t.click(mark='details', gap=20)
    t.mark('detailsLine').wait(80)
    t.point({'window': [430, 90]}, dur=16, gap=4)
    t.click(gap=16)
    # M6 · a Codex agent; drop RST-42 on it; Send moves the card to Doing.
    t.do({'setting': {'agentHarness': 'codex'}})
    t.key('k', ['cmd'], gap=16)
    t.type('agent', per=3)
    t.key('Return', gap=16)
    t.key('Return', gap=12)
    t.do({'adopt': {'as': 'codex', 'kind': 'agent', 'name': 'Cart total', 'harness': 'codex'}}, then=16)
    # the zone grew downward around the new agent: frame it all before the drag
    t.do({'camera': {'zone': 'webZone', 'padding': 30}}, dur=90, then=94)
    t.point({'card': 'cartbug'}, dur=24, gap=6)
    t.do({'drag': {'card': 'cartbug', 'toAgent': 'codex'}}, dur=50, mark='drop', then=56)
    t.point({'tile': 'codex', 'at': 'send'}, dur=20, gap=4)
    t.click(mark='sendCart', gap=6)
    t.agent('codex', turn='start', gap=6)
    t.agent('codex', say='Each line is rounded before the discount, so a cent goes missing. I’ll round once, on the total.', dur=50, gap=4)
    t.mark('dropLine').wait(110)
    return tail(t)


def late_morning():
    """10:30. Claude joins Codex, takes its own ticket, then turns the shop dark beside a browser."""
    t = Take('02-late', clock='10:30')
    t.do({'camera': {'zone': 'webZone', 'padding': 30}})
    lead(t).wait(20)
    # L1 · a Claude agent next to Codex; it takes RST-41 itself.
    t.do({'setting': {'agentHarness': 'claude'}})
    t.key('k', ['cmd'], mark='palette2', gap=16)
    t.type('agent', per=3)
    t.key('Return', gap=16)
    t.key('Return', gap=12)
    t.do({'adopt': {'as': 'dark', 'kind': 'agent', 'name': 'Dark mode', 'workspaceTools': True}}, then=16)
    t.do({'camera': {'tiles': ['codex', 'dark'], 'padding': 60}}, dur=100, then=104)
    t.mark('sideLine').wait(90)
    t.point({'tile': 'dark', 'at': 'composer'}, dur=22, gap=4)
    t.click(gap=6)
    t.type('Take the dark mode ticket.', per=2)
    t.key('Return', mark='take', gap=4)
    t.agent('dark', turn='start', gap=6)
    t.agent('dark', think='RST-41 is on the Storefront board. Assign it to me and move it to Doing.', dur=24, gap=30)
    for n, (op, extra) in enumerate([('assign', {'assigneeAgentId': '{agent:dark}'}),
                                      ('move', {'columnId': '{column:board/Doing}'})]):
        tid, tool = board_apply('darkmode', f'take{n}', op, f'rst-41-{op}', cardId='{card:darkmode}', **extra)
        t.agent('dark', tool=tool, gap=14)
        t.agent('dark', toolDone=tid, gap=14)
    t.mark('ownLine').wait(100)
    # L2 · ⌘3 opens a browser on the shop; Claude opens the tokens beside itself and edits them.
    t.key('3', ['cmd'], mark='browserKey', gap=20)
    t.do({'adopt': {'as': 'site', 'kind': 'browser'}}, then=6)
    # ⌘3 focuses the page, not the address bar (BrowserTileNSView.acquireFocus); ⌘L is
    # production's own "focus the address bar" (selects it). Production needs the
    # scheme: "localhost:3000" alone parses as scheme "localhost" and loads nothing.
    t.point({'tile': 'site', 'at': 'address'}, dur=20, gap=4)
    t.key('l', ['cmd'], mark='addressKey', gap=10)
    t.type('localhost:3000', per=3)
    t.key('Return', gap=30)
    t.do({'camera': {'tiles': ['dark', 'site'], 'padding': 60}}, dur=100, then=104)
    t.mark('browserLine').wait(90)
    t.agent('dark', say='The colours are tokens in public/theme.css. I’ll add dark values behind prefers-color-scheme.', dur=40, gap=44)
    t.do({'agent': 'dark', 'open': {'path': 'public/theme.css', 'as': 'editor', 'toolId': 'open1'}}, dur=120, mark='open', then=126)
    t.agent('dark', tool={'id': 'edit1', 'kind': 'fileChange', 'title': 'Edit', 'path': 'public/theme.css', 'action': 'edit', 'added': 15, 'removed': 0}, gap=10)
    t.do({'write': {'project': 'web', 'path': 'public/theme.css', 'from': 'edits/theme.css'}}, mark='edit', then=20)
    t.agent('dark', toolDone='edit1', gap=6)
    t.do({'browser': {'tile': 'site', 'reload': True}}, mark='dark', then=30)
    t.mark('liveLine').wait(110)
    return tail(t)


def lunch():
    """Off camera, 12:20: both agents finish and move their own cards to Done."""
    t = Take('03-lunch', clock='12:20', capture=False)
    t.agent('codex', tool={'id': 'cx1', 'kind': 'fileChange', 'title': 'Edit', 'path': 'src/cart/total.ts', 'action': 'edit', 'added': 3, 'removed': 2}, gap=2)
    t.agent('codex', toolDone='cx1', gap=2)
    t.agent('codex', tool={'id': 'cx2', 'kind': 'commandExecution', 'title': 'Shell', 'command': 'npm test', 'output': '14 passing'}, gap=2)
    t.agent('codex', toolDone='cx2', gap=2)
    t.do({'board': {'move': 'cartbug', 'column': 'Done'}}, then=2)
    t.agent('codex', say='Fixed: the discount applies first and the total is rounded once. $32.40 now, and a test pins it.', dur=4, gap=6)
    t.agent('codex', turn='done', gap=4)
    t.agent('dark', say='Dark mode follows the system setting, and every token has a dark value.', dur=4, gap=6)
    tid, tool = board_apply('darkmode', 'done1', 'move', 'rst-41-done', cardId='{card:darkmode}', columnId='{column:board/Done}')
    t.agent('dark', tool=tool, gap=2)
    t.agent('dark', toolDone=tid, gap=2)
    t.agent('dark', turn='done', gap=10)
    return t


HELPERS = [('toolu_picker', 'Plan picker', 'Build the weekly/monthly plan picker on the product page.'),
           ('toolu_checkout', 'Subscription checkout', 'Add subscriptions to checkout and the cart total.'),
           ('toolu_emails', 'Renewal emails', 'Send a reminder email two days before each renewal.')]


def afternoon():
    """12:30. The board after lunch; RST-43 goes to an agent that brings helpers."""
    t = Take('04-afternoon', clock='12:30')
    t.do({'camera': {'tiles': ['board'], 'padding': 80}})
    lead(t)
    t.mark('closedLine').wait(110)
    t.key('k', ['cmd'], mark='palette3', gap=16)
    t.type('agent', per=3)
    t.key('Return', gap=16)
    t.key('Return', gap=12)
    t.do({'adopt': {'as': 'subs', 'kind': 'agent', 'name': 'Subscriptions', 'workspaceTools': True}}, then=16)
    t.do({'camera': {'tiles': ['board', 'subs'], 'padding': 60}}, dur=90, then=94)
    t.point({'card': 'subs'}, dur=24, gap=6)
    t.do({'drag': {'card': 'subs', 'toAgent': 'subs'}}, dur=50, mark='drop2', then=56)
    t.point({'tile': 'subs', 'at': 'send'}, dur=20, gap=4)
    t.click(mark='sendSubs', gap=6)
    t.agent('subs', turn='start', gap=6)
    t.agent('subs', think='Three separable parts: the plan picker, checkout, renewal emails.', dur=24, gap=30)
    t.agent('subs', say='This is three jobs. I’ll give each one to a helper and review what comes back.', dur=40, gap=44)
    for tid, desc, prompt in HELPERS:
        t.agent('subs', tool={'id': tid, 'name': 'Agent', 'input': {'description': desc, 'prompt': prompt, 'subagent_type': 'general-purpose'}}, gap=16)
    t.mark('helpersLine').wait(30)
    for tid, desc, _ in HELPERS:
        t.agent('subs', child=tid, say=f'Starting on the {desc.lower()}.', gap=8)
    t.wait(70)
    t.point({'chip': 'toolu_picker'}, dur=26, gap=6)
    t.click(mark='openHelper', gap=24)
    t.do({'adopt': {'as': 'picker', 'child': 'toolu_picker', 'of': 'subs'}}, then=6)
    t.do({'camera': {'tiles': ['subs', 'picker'], 'padding': 70}}, dur=90, then=94)
    t.point({'tile': 'picker', 'at': 'header'}, dur=24, gap=4)
    t.click(gap=12)
    t.do({'gesture': {'to': {'by': [180, 140]}}}, dur=60, mark='dragHelper', then=66)
    t.mark('moveLine').wait(110)
    return t


def busy():
    """The heads-down time-lapse source: a lot happens, fast. Played at up to 12x behind the clock."""
    t = Take('05-busy', clock='13:00')
    t.do({'camera': {'zone': 'webZone', 'padding': 30}})
    for n, (tid, desc, _) in enumerate(HELPERS):
        t.agent('subs', child=tid, tool={'id': f'r{n}', 'name': 'Read', 'input': {'file_path': 'src/cart/total.ts'}, 'output': 'export function cartTotal'}, gap=20)
        t.agent('subs', child=tid, toolDone=f'r{n}', gap=10)
    t.point({'chip': 'toolu_checkout'}, dur=20, gap=4)
    t.click(gap=20)
    t.do({'adopt': {'as': 'checkout', 'child': 'toolu_checkout', 'of': 'subs'}}, then=6)
    t.point({'chip': 'toolu_emails'}, dur=20, gap=4)
    t.click(gap=20)
    t.do({'adopt': {'as': 'emails2', 'child': 'toolu_emails', 'of': 'subs'}}, then=6)
    for n, (tid, desc, _) in enumerate(HELPERS):
        t.agent('subs', child=tid, tool={'id': f'w{n}', 'name': 'Write', 'input': {'file_path': f'src/subscriptions/{desc.split()[0].lower()}.ts', 'content': '// …'}}, gap=24)
        t.agent('subs', child=tid, toolDone=f'w{n}', gap=10)
    t.do({'camera': {'zone': 'apiZone', 'padding': 30}}, dur=120, then=124)
    t.do({'setting': {'agentHarness': 'codex'}})
    t.point({'zone': 'apiZone', 'at': [0.5, 0.5]}, dur=20, gap=4)
    t.click(gap=10)
    t.key('k', ['cmd'], gap=14)
    t.type('agent', per=2)
    t.key('Return', gap=14)
    t.key('Return', gap=12)
    t.do({'adopt': {'as': 'webhook', 'kind': 'agent', 'name': 'Renewal webhook', 'harness': 'codex'}}, then=10)
    t.agent('webhook', prompt='Add a renewal webhook that charges the saved card.', gap=4)
    t.agent('webhook', turn='start', gap=10)
    t.agent('webhook', say='Adding POST /subscriptions/renew, idempotent per billing period.', dur=30, gap=34)
    t.agent('webhook', tool={'id': 'wh1', 'kind': 'fileChange', 'title': 'Edit', 'path': 'src/subscriptions/renew.ts', 'action': 'write', 'added': 42}, gap=30)
    t.agent('webhook', toolDone='wh1', gap=10)
    t.do({'camera': {'zone': 'webZone', 'padding': 30}}, dur=120, then=124)
    for n, (tid, desc, _) in enumerate(HELPERS):
        t.agent('subs', child=tid, say=f'{desc} is done, with tests.', gap=20)
    t.agent('webhook', tool={'id': 'wh2', 'kind': 'commandExecution', 'title': 'Shell', 'command': 'npm test', 'output': '22 passing'}, gap=20)
    t.agent('webhook', toolDone='wh2', gap=10)
    # more of the afternoon racing by: both zones, every helper writing, the camera roaming
    t.do({'camera': {'all': True, 'padding': 60}}, dur=120, then=124)
    for round_ in range(3):
        for n, (tid, desc, _) in enumerate(HELPERS):
            t.agent('subs', child=tid, tool={'id': f'e{round_}{n}', 'name': 'Edit', 'input': {'file_path': f'src/subscriptions/{desc.split()[0].lower()}.ts', 'old_string': 'a', 'new_string': 'b'}}, gap=18)
            t.agent('subs', child=tid, toolDone=f'e{round_}{n}', gap=8)
        t.agent('webhook', tool={'id': f'wt{round_}', 'kind': 'commandExecution', 'title': 'Shell', 'command': 'npm test -- renew', 'output': f'{18 + round_} passing'}, gap=24)
        t.agent('webhook', toolDone=f'wt{round_}', gap=10)
        t.do({'camera': {'zone': ['webZone', 'apiZone', 'webZone'][round_], 'padding': 30}}, dur=110, then=114)
    t.agent('webhook', say='Webhook in, tests pass.', dur=20, gap=24)
    t.agent('webhook', turn='done', gap=30)
    for n, (tid, desc, _) in enumerate(HELPERS):
        t.agent('subs', child=tid, tool={'id': f't{n}', 'name': 'Bash', 'input': {'command': 'npm test', 'description': 'Run the tests'}, 'output': f'{9 + n} passing'}, gap=26)
        t.agent('subs', child=tid, toolDone=f't{n}', gap=10)
    t.do({'camera': {'zone': 'webZone', 'padding': 30}}, dur=110, then=140)
    return t


def late_afternoon():
    """3:00. The helpers are done; the parent tests, pushes and merges. Then the whole canvas."""
    t = Take('06-ship', clock='15:00')
    t.do({'camera': {'tiles': ['subs'], 'padding': 120}})
    for tid, _, _ in HELPERS:
        t.agent('subs', toolDone=tid, gap=6)
    t.wait(30)
    t.agent('subs', tool={'id': 'test1', 'name': 'Bash', 'input': {'command': 'npm test', 'description': 'Run the tests'}, 'output': '38 passing'}, gap=40)
    t.agent('subs', toolDone='test1', gap=10)
    t.agent('subs', tool={'id': 'push1', 'name': 'Bash', 'input': {'command': 'git push origin rst-43-subscriptions', 'description': 'Push the branch'},
                          'output': 'To github.com:roast/roast-web.git\n * [new branch]  rst-43-subscriptions -> rst-43-subscriptions'}, gap=36)
    t.agent('subs', toolDone='push1', mark='pushed', gap=60)
    t.agent('subs', tool={'id': 'merge1', 'name': 'Bash', 'input': {'command': 'git switch main && git merge --no-ff rst-43-subscriptions', 'description': 'Merge into main'},
                          'output': "Merge made by the 'ort' strategy."}, gap=36)
    t.agent('subs', toolDone='merge1', mark='merged', gap=20)
    tid, tool = board_apply('subs', 'done2', 'move', 'rst-43-done', cardId='{card:subs}', columnId='{column:board/Done}')
    t.agent('subs', tool=tool, gap=12)
    t.agent('subs', toolDone=tid, gap=8)
    t.agent('subs', say='Subscriptions are merged: plan picker, checkout and renewal emails. RST-43 is done.', dur=40, gap=44)
    t.agent('subs', turn='done', mark='subsDone', gap=10)
    t.mark('shipLine').wait(110)
    t.do({'camera': {'all': True, 'padding': 60}}, dur=280, mark='zoomOut', then=284)
    t.mark('canvasLine').wait(110)
    t.point({'window': [1100, 900]}, dur=24, gap=10)
    t.do({'hold': 'option'}, dur=110, mark='leader', then=50)
    # The letter production assigned the subs tile, pressed while ⌥ is still held;
    # its reveal glides over 70 frames.
    t.do({'jump': 'subs'}, dur=70, mark='jump', then=74)
    t.mark('jumpLine').wait(100)
    return tail(t)


def evening():
    """6:00. Close what's done, one tile at a time; History holds the day; two empty zones."""
    t = Take('07-evening', clock='18:00')
    t.do({'camera': {'zone': 'webZone', 'padding': 30}})
    lead(t).wait(20)
    for n, key in enumerate(['picker', 'checkout', 'emails2', 'subs', 'dark', 'editor', 'site', 'codex', 'planner', 'board']):
        t.point({'tile': key, 'at': 'close'}, dur=20, gap=4)
        t.click(mark='close0' if n == 0 else None, gap=10)
    t.mark('closeLine').wait(60)
    t.do({'camera': {'zone': 'apiZone', 'padding': 30}}, dur=120, then=124)
    t.point({'tile': 'webhook', 'at': 'close'}, dur=20, gap=4)
    t.click(gap=20)
    t.point({'sidebar': 'history'}, dur=30, gap=4)
    t.click(mark='historyOpen', gap=20)
    t.mark('historyLine').wait(90)
    t.do({'camera': {'all': True, 'padding': 120}}, dur=220, mark='emptyOut', then=224)
    t.mark('tomorrowLine').wait(150)
    return t


def scene():
    return {
        'schema': 'array.film.scene.v1',
        'id': 'full-day',
        'window': {'width': 1920, 'height': 1080},
        'sidebar': True,
        'sidebarWidth': 300,
        'cameraModel': 'v2',
        'autoLayout': True,
        'fps': 60,
        'video': 'prores',
        'png': 30,
        'closeUpMinZoom': 0.85,
        'site': {'project': 'web', 'path': 'public'},
        'catalog': [
            {'harness': 'claude', 'model': 'anthropic/claude-opus-5', 'displayName': 'Opus 5', 'contextWindow': 200000},
            {'harness': 'codex', 'model': 'openai-codex/gpt-5.5-codex', 'displayName': 'GPT-5.5 Codex'},
        ],
        'workspace': 'Roast',
        'projects': [
            {'key': 'api', 'name': 'roast-api', 'files': 'projects/roast-api', 'git': {}},
            {'key': 'web', 'name': 'roast-web', 'files': 'projects/roast-web', 'git': {}, 'placed': False},
        ],
        'zones': [
            {'key': 'apiZone', 'project': 'api', 'name': 'Roast API', 'rect': [0, 0, 1500, 1000], 'color': 'teal'},
        ],
        'tiles': [
            {'key': 'emails', 'kind': 'agent', 'zone': 'apiZone', 'frame': [80, 80, 640, 740], 'name': 'Order emails'},
        ],
        'takes': [t.json() for t in (setup(), morning(), late_morning(), lunch(), afternoon(), busy(), late_afternoon(), evening())],
    }


if __name__ == '__main__':
    path = os.path.join(HERE, 'full-day.json')
    with open(path, 'w') as f:
        json.dump(scene(), f, indent=1, ensure_ascii=False)
        f.write('\n')
    s = scene()
    for take in s['takes']:
        marks = {a['mark']: a['at'] for a in take['actions'] if 'mark' in a}
        print(f"{take['name']}: {take['frames']} frames ({take['frames'] / 60:.1f}s) marks {marks}")
