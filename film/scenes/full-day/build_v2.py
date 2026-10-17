#!/usr/bin/env python3
"""Writes film/scenes/full-day/full-day-v2.json, video 2 "A day in Array", v2
(.plans/68-launch-film/research/19-full-day-v2/README.md has the beat sheet and why).

The rule of v2: every agent that finishes gets an ending on camera (a follow-up, a close, or
left on purpose), and every jump in the clock is explained by what finished meanwhile.

Same cursor model as build.py: `t.wait(n)` advances the cursor; every action lands at it. The
verbs the v2 harness added (hover, zone jumps, Settings, the close nudge, the bulk bar, click
modifiers) are wrapped in the small functions below, so their syntax lives in one place.
"""
import json
import os

from build import HERE, Take, board_apply

# --- the v2 verbs, in one place ------------------------------------------------------------

def hover(t, target, hold=70, dur=24):
    """Glide to `target` with mouse-moved events and dwell there (the sidebar hover card)."""
    return t.do({'pointer': {'to': target, 'hover': True, 'dwell': hold}}, dur=dur, then=dur + hold + 4)


def glide_click(t, dur=70, mark=None, gap=8):
    """A delivered click whose navigation (a sidebar row's reveal) glides over `dur`."""
    t.do({'click': {'deliver': True}}, dur=dur, mark=mark, then=dur + gap)
    return t


def zone_jump(t, zone, mark=None):
    """Hold ⌥, press the digit production gave `zone`, glide there."""
    t.do({'hold': 'option'}, dur=126, then=40)
    t.do({'jumpZone': zone}, dur=110, mark=mark, then=114)
    return t


def tile_jump(t, tile, mark=None):
    """Hold ⌥, press the tile's letter (tinted by its agent's state), glide there."""
    t.do({'hold': 'option'}, dur=126, then=46)
    t.do({'jump': tile}, dur=100, mark=mark, then=104)
    return t


def new_agent(t, key, name, harness='claude', tools=False, settle=12):
    """⌘K "agent", Return twice: a managed agent in the armed zone."""
    t.do({'setting': {'agentHarness': harness}})
    t.key('k', ['cmd'], gap=14)
    t.type('agent', per=2)
    t.key('Return', gap=14)
    t.key('Return', gap=settle)
    adopt = {'as': key, 'kind': 'agent', 'name': name}
    if tools:
        adopt['workspaceTools'] = True
    if harness != 'claude':
        adopt['harness'] = harness
    return t.do({'adopt': adopt}, then=10)


def send_card(t, card, agent, drag=46, mark=None):
    """Drag a board card onto an agent and press its Send: the card moves to Doing."""
    t.point({'card': card}, dur=20, gap=4)
    t.do({'drag': {'card': card, 'toAgent': agent}}, dur=drag, then=drag + 6)
    t.point({'tile': agent, 'at': 'send'}, dur=18, gap=4)
    return t.click(mark=mark, gap=6)


def follow_up(t, agent, text, mark=None):
    """Type into a finished agent's composer and send: its next turn."""
    t.point({'tile': agent, 'at': 'composer'}, dur=22, gap=4)
    t.click(gap=6)
    t.type(text, per=2)
    return t.key('Return', mark=mark, gap=6)


def close(t, tile, mark=None, gap=16):
    t.point({'tile': tile, 'at': 'close'}, dur=22, gap=4)
    return t.click(mark=mark, gap=gap)


def reveal_row(t, agent, mark=None, hold=0, dur=70):
    """Point at an agent's sidebar row (optionally dwelling for its hover card), then click it."""
    if hold:
        hover(t, {'sidebar': agent}, hold=hold)
    else:
        t.point({'sidebar': agent}, dur=26, gap=4)
    return glide_click(t, dur=dur, mark=mark)


# --- the story -----------------------------------------------------------------------------

# Each captured take opens on the hold its transition shows (AFTER) and closes on the one the
# next transition keeps playing (BEFORE): videos/full-day/timeline.ts.
LEAD = {'01-morning': 140, '02-late': 160, '04-afternoon': 160, '06-ship': 0, '07-evening': 170}
TAIL = {'01-morning': 150, '02-late': 180, '04-afternoon': 160, '06-ship': 170}


def lead(t):
    return t.wait(LEAD.get(t.name, 0))


def tail(t):
    return t.wait(TAIL.get(t.name, 0))


# Ten tickets from Jira. The four with keys get agents in the morning; subs after lunch; the API
# and Admin ones fire off before heads-down; RST-44 is left for tomorrow on purpose.
TICKETS = [
    ('cartbug', 'RST-42 Cart total is off by a cent', 'A 10% discount on two Autumn blends shows $32.39. It should be $32.40.'),
    ('darkmode', 'RST-41 Dark mode for the shop', 'Follow the system setting. The design tokens live in public/theme.css.'),
    ('cards', 'RST-45 Softer product cards', 'The shop looks sharp and dated. Rounder cards and buttons; try a warmer heading face.'),
    ('hero', 'RST-46 Autumn blend hero copy', 'Shorter headline for the autumn launch.'),
    ('subs', 'RST-43 Coffee subscriptions', 'Weekly or monthly beans, pause any time. Plan picker, checkout and renewal emails.'),
    ('export', 'RST-48 Order export as CSV', 'Finance wants last month’s orders as a CSV from the API.'),
    ('filters', 'RST-49 Barista queue filters', 'Filter the order queue by pickup or delivery.'),
    ('applepay', 'RST-50 Apple Pay in the iOS app', 'Checkout with Apple Pay on iPhone.'),
    ('deploy', 'RST-51 Preview deploys for the storefront', 'A preview URL on every pull request.'),
    ('autumn', 'RST-44 Autumn blend landing page', 'A page for the autumn launch. Copy from marketing next week.'),
]

HELPERS = [('toolu_picker', 'Plan picker', 'Build the weekly/monthly plan picker on the product page.'),
           ('toolu_checkout', 'Subscription checkout', 'Add subscriptions to checkout and the cart total.'),
           ('toolu_emails', 'Renewal emails', 'Send a reminder email two days before each renewal.')]


def setup():
    t = Take('00-setup', clock='8:30', capture=False)
    t.do({'camera': {'tiles': ['emails'], 'padding': 160}})
    t.agent('emails', prompt='Send an email when an order is placed.')
    t.agent('emails', turn='start', ago=1500)
    t.agent('emails', say='Orders now send "Your coffee is on its way". The template and a test are in.', gap=2)
    t.agent('emails', turn='done', gap=30)
    return t


def morning():
    """8:45. Plan the day, then fan out: four tickets, four agents, before coffee."""
    t = Take('01-morning', clock='8:45')
    # M1 · yesterday's finished agent, closed into History.
    t.do({'camera': {'tiles': ['emails'], 'padding': 170}})
    lead(t).wait(20).point({'tile': 'emails', 'at': 'close'}, dur=40, spring='soft', gap=8)
    t.click(mark='closed', gap=14)
    t.mark('filedLine').wait(100)
    # M2 · draw the Storefront zone: marquee, picker, rename, colour, resize.
    t.do({'camera': {'rect': [1580, -80, 1640, 1100]}}, dur=150, mark='toEmpty', then=154)
    t.point({'world': [1720, 30]}, dur=22, gap=6)
    t.do({'gesture': {'to': {'world': [2880, 840]}}}, dur=48, mark='marquee', then=56)
    t.point({'choice': 'roast-web'}, dur=24, gap=8)
    t.click(mark='picked', gap=10)
    t.do({'adopt': {'as': 'webZone', 'kind': 'zone'}}, then=4)
    t.point({'zone': 'webZone', 'at': 'header'}, dur=20, gap=6)
    t.click(count=2, mark='rename', gap=10)
    t.type('Storefront', per=3)
    t.key('Return', gap=10)
    t.point({'zone': 'webZone', 'at': 'overflow'}, dur=20, gap=4)
    t.click(mark='menu', gap=44)
    t.do({'menu': {'choose': ['Color', 'Orange']}}, mark='colour', then=12)
    t.point({'zone': 'webZone', 'at': 'right'}, dur=20, gap=6)
    t.do({'gesture': {'to': {'by': [260, 0]}}}, dur=40, mark='resize', then=48)
    t.mark('zoneLine').wait(90)
    # M3 · ⌘K: a board, then the Planner; auto-layout settles them and the zone grows.
    t.point({'zone': 'webZone', 'at': [0.35, 0.55]}, dur=20, gap=4)
    t.click(gap=10)
    t.key('k', ['cmd'], mark='palette', gap=16)
    t.type('board', per=3)
    t.key('Return', gap=12)
    t.do({'adopt': {'as': 'board', 'kind': 'kanban'}}, then=10)
    new_agent(t, 'planner', 'Planner', tools=True, settle=12)
    t.mark('growLine').wait(30)
    t.do({'camera': {'zone': 'webZone', 'padding': 40}}, dur=100, then=110)
    # M4 · the Planner fills the board from Jira: ten tickets.
    t.point({'tile': 'planner', 'at': 'composer'}, dur=22, gap=4)
    t.click(gap=6)
    t.type("What's on my plate today?", per=2)
    t.key('Return', mark='ask', gap=4)
    t.agent('planner', turn='start', gap=6)
    t.agent('planner', think='Check this sprint in Jira, then put today’s tickets on the board.', dur=24, gap=28)
    t.agent('planner', tool={'id': 'jira1', 'name': 'mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql',
                             'input': {'cloudId': 'roast.atlassian.net', 'jql': 'assignee = currentUser() AND sprint in openSprints() ORDER BY rank'},
                             'output': '\n'.join(title for _, title, _ in TICKETS)}, gap=24)
    t.agent('planner', toolDone='jira1', gap=6)
    for n, (key, title, body) in enumerate(TICKETS):
        tid, tool = board_apply(key, f'card{n}', 'create', key, columnId='{column:board/To Do}', title=title, body=body)
        tool['bind'] = key
        t.agent('planner', tool=tool, gap=7)
        t.agent('planner', toolDone=tid, gap=5)
    t.agent('planner', say='Ten tickets today across four projects. RST-43 is the big one; give it its own agent.', dur=40, mark='planned', gap=44)
    t.agent('planner', turn='done', gap=4)
    t.mark('planLine').wait(60)
    # Read it: a click on the Planner (the film app is never frontmost, so watching it finish
    # does not count as seen). Its Close nudge after lunch depends on this.
    t.point({'tile': 'planner', 'at': 'body'}, dur=22, gap=4)
    t.click(gap=30)
    # M4b · make room: the board narrower and taller; its neighbours reflow around it.
    t.point({'tile': 'board', 'at': 'bottomRight'}, dur=24, gap=6)
    t.do({'gesture': {'to': {'by': [-180, 260]}}}, dur=60, mark='roomy', then=70)
    t.mark('roomLine').wait(80)
    # M5 · fan out: one ticket, one agent, four times, faster each time.
    fan = [('cartbug', 'cart', 'Cart total', 'codex',
            'Each line is rounded before the discount, so a cent goes missing. I’ll round once, on the total.'),
           ('darkmode', 'dark', 'Dark mode', 'claude', 'The colours are tokens in theme.css. Adding dark values behind prefers-color-scheme.'),
           ('cards', 'cardsAgent', 'Softer cards', 'claude', 'Starting with the radius token; every card and button reads it.'),
           ('hero', 'hero', 'Hero copy', 'claude', 'Three shorter headlines, then the best one in place.')]
    for n, (card, key, name, harness, line) in enumerate(fan):
        new_agent(t, key, name, harness=harness, tools=harness == 'claude', settle=10)
        if n == 0:
            t.do({'camera': {'zone': 'webZone', 'padding': 30}}, dur=90, then=94)
        else:
            t.do({'camera': {'zone': 'webZone', 'padding': 30}}, dur=60, then=60)
        send_card(t, card, key, drag=[46, 40, 34, 30][n], mark=f'send{n}')
        t.agent(key, turn='start', gap=4)
        t.agent(key, say=line, dur=30, gap=[50, 26, 18, 14][n])
        if n == 0:
            t.mark('oneLine').wait(40)
    t.mark('fanLine').wait(110)
    return tail(t)


def mid_morning():
    """Off camera, 10:20: Softer cards' first pass lands (radius 10px) and it finishes, unseen."""
    t = Take('01b-midmorning', clock='10:20', capture=False)
    t.agent('cardsAgent', tool={'id': 'cd1', 'kind': 'fileChange', 'title': 'Edit', 'path': 'public/theme.css', 'action': 'edit', 'added': 2, 'removed': 1}, gap=2)
    t.do({'write': {'project': 'web', 'path': 'public/theme.css', 'from': 'edits/design-1.css'}}, then=2)
    t.agent('cardsAgent', toolDone='cd1', gap=2)
    t.agent('cardsAgent', say='Cards and buttons now share a 10px radius from one token, --radius. Have a look.', dur=4, gap=4)
    t.agent('cardsAgent', turn='done', gap=10)
    return t


def late_morning():
    """10:30. Review, follow up, see it live; then close what's done."""
    t = Take('02-late', clock='10:30')
    t.do({'camera': {'zone': 'webZone', 'padding': 30}})
    lead(t).wait(20)
    # L1 · a green Done row in the sidebar; its hover card says what it did; a click takes you there.
    reveal_row(t, 'cardsAgent', mark='reveal', hold=90)
    t.mark('lookLine').wait(60)
    # L2 · open the shop beside it and make the browser big; the zone's tiles make room.
    t.key('3', ['cmd'], mark='browserKey', gap=20)
    t.do({'adopt': {'as': 'site', 'kind': 'browser'}}, then=6)
    t.point({'tile': 'site', 'at': 'address'}, dur=20, gap=4)
    t.key('l', ['cmd'], gap=10)
    t.type('localhost:3000', per=3)
    t.key('Return', gap=24)
    t.do({'camera': {'tiles': ['cardsAgent', 'site'], 'padding': 50}}, dur=90, then=94)
    t.point({'tile': 'site', 'at': 'bottomRight'}, dur=22, gap=6)
    t.do({'gesture': {'to': {'by': [220, 160]}}}, dur=60, mark='bigger', then=70)
    t.do({'camera': {'tiles': ['cardsAgent', 'site'], 'padding': 50}}, dur=80, then=84)
    t.mark('reviewLine').wait(60)
    # Round 1: rounder, and a serif.
    follow_up(t, 'cardsAgent', 'Rounder corners, and try a serif for the headings.', mark='ask1')
    t.agent('cardsAgent', turn='start', gap=6)
    t.agent('cardsAgent', think='Raise --radius and swap --font-heading to the system serif.', dur=20, gap=24)
    t.do({'agent': 'cardsAgent', 'open': {'path': 'public/theme.css', 'as': 'editor', 'toolId': 'open1'}}, dur=90, mark='open', then=96)
    t.do({'camera': {'tiles': ['cardsAgent', 'editor', 'site'], 'padding': 40}}, dur=90, then=94)
    t.agent('cardsAgent', tool={'id': 'ed2', 'kind': 'fileChange', 'title': 'Edit', 'path': 'public/theme.css', 'action': 'edit', 'added': 5, 'removed': 4}, gap=8)
    t.do({'write': {'project': 'web', 'path': 'public/theme.css', 'from': 'edits/design-2.css'}}, mark='edit2', then=14)
    t.agent('cardsAgent', toolDone='ed2', gap=4)
    t.do({'browser': {'tile': 'site', 'reload': True}}, mark='live1', then=24)
    t.agent('cardsAgent', say='24px corners and New York for headings.', dur=24, gap=30)
    t.agent('cardsAgent', turn='done', gap=4)
    t.mark('liveLine').wait(70)
    # Round 2: a little less.
    follow_up(t, 'cardsAgent', 'A little less. 14px.', mark='ask2')
    t.agent('cardsAgent', turn='start', gap=6)
    t.agent('cardsAgent', tool={'id': 'ed3', 'kind': 'fileChange', 'title': 'Edit', 'path': 'public/theme.css', 'action': 'edit', 'added': 1, 'removed': 1}, gap=8)
    t.do({'write': {'project': 'web', 'path': 'public/theme.css', 'from': 'edits/design-3.css'}}, mark='edit3', then=14)
    t.agent('cardsAgent', toolDone='ed3', gap=4)
    t.do({'browser': {'tile': 'site', 'reload': True}}, mark='live2', then=24)
    t.agent('cardsAgent', say='14px everywhere.', dur=14, gap=20)
    t.agent('cardsAgent', turn='done', gap=4)
    t.mark('againLine').wait(50)
    follow_up(t, 'cardsAgent', 'Ship it.', mark='ship')
    t.agent('cardsAgent', turn='start', gap=6)
    t.agent('cardsAgent', tool={'id': 'cm1', 'name': 'Bash', 'input': {'command': 'git commit -am "Softer cards and serif headings (RST-45)"', 'description': 'Commit'},
                                'output': '[rst-45 4c1e2a9] Softer cards and serif headings (RST-45)'}, gap=20)
    t.agent('cardsAgent', toolDone='cm1', gap=6)
    tid, tool = board_apply('cards', 'cdone', 'move', 'rst-45-done', cardId='{card:cards}', columnId='{column:board/Done}')
    t.agent('cardsAgent', tool=tool, gap=10)
    t.agent('cardsAgent', toolDone=tid, gap=6)
    t.agent('cardsAgent', say='Committed, and RST-45 is in Done.', dur=16, gap=20)
    t.agent('cardsAgent', turn='done', mark='shipped', gap=30)
    # L3 · done with it: close the agent and its editor; the zone closes the gap.
    close(t, 'editor', gap=12)
    close(t, 'cardsAgent', mark='closeCards', gap=20)
    t.mark('closeLine').wait(110)
    return tail(t)


def lunch():
    """Off camera, 12:50: Hero copy finishes unseen; Cart total and Dark mode are near done."""
    t = Take('03-lunch', clock='12:50', capture=False)
    t.agent('hero', tool={'id': 'h1', 'kind': 'fileChange', 'title': 'Edit', 'path': 'public/index.html', 'action': 'edit', 'added': 1, 'removed': 1}, gap=2)
    t.agent('hero', toolDone='h1', gap=2)
    tid, tool = board_apply('hero', 'hdone', 'move', 'rst-46-done', cardId='{card:hero}', columnId='{column:board/Done}')
    t.agent('hero', tool=tool, gap=2)
    t.agent('hero', toolDone=tid, gap=2)
    t.agent('hero', say='New headline: "Roasted this morning. At your door tomorrow." RST-46 is in Done.', dur=4, gap=4)
    t.agent('hero', turn='done', gap=4)
    t.agent('cart', tool={'id': 'cx1', 'kind': 'fileChange', 'title': 'Edit', 'path': 'src/cart/total.ts', 'action': 'edit', 'added': 3, 'removed': 2}, gap=2)
    t.agent('cart', toolDone='cx1', gap=2)
    t.agent('dark', tool={'id': 'dk1', 'kind': 'fileChange', 'title': 'Edit', 'path': 'public/theme.css', 'action': 'edit', 'added': 15, 'removed': 0}, gap=2)
    t.agent('dark', toolDone='dk1', gap=10)
    return t


def afternoon():
    """13:00. Dylan's triage: start the big one, then work through what finished while it runs."""
    t = Take('04-afternoon', clock='13:00')
    t.do({'camera': {'zone': 'apiZone', 'padding': 40}})
    lead(t).wait(10)
    # A1 · navigation first: ⌥ and Storefront's digit; a new agent; the big ticket; helpers.
    zone_jump(t, 'webZone', mark='toWeb')
    t.point({'zone': 'webZone', 'at': [0.5, 0.5]}, dur=18, gap=4)
    t.click(gap=8)
    new_agent(t, 'subs', 'Subscriptions', tools=True, settle=12)
    t.do({'camera': {'tiles': ['board', 'subs'], 'padding': 60}}, dur=140, then=144)
    send_card(t, 'subs', 'subs', drag=44, mark='sendSubs')
    t.agent('subs', turn='start', gap=6)
    t.agent('subs', think='Three separable parts: the plan picker, checkout, renewal emails.', dur=20, gap=24)
    t.agent('subs', say='This is three jobs. I’ll give each one to a helper and review what comes back.', dur=36, gap=40)
    for tid, desc, prompt in HELPERS:
        t.agent('subs', tool={'id': tid, 'name': 'Agent', 'input': {'description': desc, 'prompt': prompt, 'subagent_type': 'general-purpose'}}, gap=14)
    t.mark('helpersLine').wait(20)
    for tid, desc, _ in HELPERS:
        t.agent('subs', child=tid, say=f'Starting on the {desc.lower()}.', gap=8)
    t.wait(30)
    # A2 · a second later, Cart total finishes at the corner of the zone. ⌥: its letter is green.
    t.agent('cart', tool={'id': 'cx2', 'kind': 'commandExecution', 'title': 'Shell', 'command': 'npm test', 'output': '14 passing'}, gap=4)
    t.agent('cart', toolDone='cx2', gap=2)
    t.agent('cart', say='Fixed: the discount applies first and the total is rounded once. $32.40 now, and a test pins it.', dur=8, gap=4)
    t.agent('cart', turn='done', mark='cartDone', gap=40)
    t.do({'camera': {'zone': 'webZone', 'padding': 30}}, dur=120, then=124)
    t.mark('doneLine').wait(30)
    tile_jump(t, 'cart', mark='toCart')
    t.mark('readLine').wait(60)
    follow_up(t, 'cart', 'Also cover the 3-for-2 promo.', mark='ask3')
    t.agent('cart', turn='start', gap=6)
    t.agent('cart', say='Adding a 3-for-2 case to the tests and checking the rounding holds.', dur=24, gap=10)
    t.mark('followLine').wait(30)
    # A3 · Dark mode finishes; its sidebar row turns green. One look, and it's done: close it.
    t.agent('dark', say='Dark mode follows the system setting; every token has a dark value. RST-41 is in Done.', dur=8, gap=2)
    tid, tool = board_apply('darkmode', 'ddone', 'move', 'rst-41-done', cardId='{card:darkmode}', columnId='{column:board/Done}')
    t.agent('dark', tool=tool, gap=2)
    t.agent('dark', toolDone=tid, gap=2)
    t.agent('dark', turn='done', mark='darkDone', gap=40)
    reveal_row(t, 'dark', mark='toDark')
    t.wait(50)
    close(t, 'dark', mark='closeDark', gap=24)
    t.mark('oneShotLine').wait(30)
    # A4 · Hero copy finished over lunch: same again.
    reveal_row(t, 'hero', mark='toHero', dur=110)
    t.wait(40)
    close(t, 'hero', mark='closeHero', gap=24)
    # A4b · the Planner, read this morning, offers to close itself (the nudge).
    t.point({'sidebar': 'planner', 'at': 'nudge'}, dur=28, gap=10)
    t.mark('nudgeLine').wait(40)
    t.click(mark='nudgeClose', gap=30)
    # A5 · Cart total's follow-up lands; check it, close it. The big one is still working.
    t.agent('cart', tool={'id': 'cx3', 'kind': 'commandExecution', 'title': 'Shell', 'command': 'npm test', 'output': '15 passing'}, gap=4)
    t.agent('cart', toolDone='cx3', gap=2)
    t.agent('cart', say='3-for-2 is covered, 15 passing.', dur=8, gap=4)
    t.agent('cart', turn='done', mark='cartDone2', gap=30)
    reveal_row(t, 'cart')
    t.wait(30)
    close(t, 'cart', mark='closeCart', gap=24)
    t.mark('cookingLine').wait(40)
    # Back to the helpers: open one, move it; the ants follow.
    t.do({'camera': {'tiles': ['subs'], 'padding': 120}}, dur=130, then=134)
    t.point({'chip': 'toolu_picker'}, dur=24, gap=6)
    t.click(mark='openHelper', gap=24)
    t.do({'adopt': {'as': 'picker', 'child': 'toolu_picker', 'of': 'subs'}}, then=6)
    t.do({'camera': {'tiles': ['subs', 'picker'], 'padding': 70}}, dur=80, then=84)
    t.point({'tile': 'picker', 'at': 'header'}, dur=22, gap=4)
    t.click(gap=12)
    t.do({'gesture': {'to': {'by': [180, 140]}}}, dur=56, mark='dragHelper', then=62)
    t.mark('moveLine').wait(90)
    # A6 · more tickets: ⌥ to the API and Admin zones, an agent each.
    zone_jump(t, 'apiZone', mark='toApi')
    t.point({'zone': 'apiZone', 'at': [0.5, 0.5]}, dur=18, gap=4)
    t.click(gap=8)
    new_agent(t, 'export', 'Order export', harness='codex', settle=10)
    follow_up(t, 'export', 'RST-48: last month’s orders as a CSV endpoint.', mark='sendExport')
    t.agent('export', turn='start', gap=30)
    zone_jump(t, 'adminZone', mark='toAdmin')
    t.point({'zone': 'adminZone', 'at': [0.5, 0.5]}, dur=18, gap=4)
    t.click(gap=8)
    new_agent(t, 'filters', 'Queue filters', settle=10)
    follow_up(t, 'filters', 'RST-49: filter the queue by pickup or delivery.', mark='sendFilters')
    t.agent('filters', turn='start', gap=10)
    t.mark('moreLine').wait(90)
    return tail(t)


def fire_next(t, zone, key, name, prompt, harness='claude'):
    """Arm the zone just tidied, start a fresh agent in it and send its first prompt."""
    t.point({'zone': zone, 'at': [0.5, 0.5]}, dur=16, gap=4)
    t.click(gap=6)
    new_agent(t, key, name, harness=harness, settle=8)
    follow_up(t, key, prompt)
    t.agent(key, turn='start', gap=10)
    if harness == 'codex':
        tool = {'id': f'{key}0', 'kind': 'fileChange', 'title': 'Edit', 'path': f'src/{key}.ts', 'action': 'write', 'added': 18}
    else:
        tool = {'id': f'{key}0', 'name': 'Read', 'input': {'file_path': f'src/{key}.ts'}, 'output': 'export'}
    t.agent(key, tool=tool, gap=10)
    return t.agent(key, toolDone=f'{key}0', gap=6)


def busy():
    """The heads-down time-lapse source, 13:30 → 15:30: the glove keeps working through it."""
    t = Take('05-busy', clock='13:30')
    t.do({'camera': {'zone': 'adminZone', 'padding': 30}})
    t.wait(20)
    for n, (tid, desc, _) in enumerate(HELPERS):
        t.agent('subs', child=tid, tool={'id': f'r{n}', 'name': 'Read', 'input': {'file_path': 'src/cart/total.ts'}, 'output': 'export function cartTotal'}, gap=8)
        t.agent('subs', child=tid, toolDone=f'r{n}', gap=4)
    # iOS and Infra get their agents.
    zone_jump(t, 'iosZone')
    t.point({'zone': 'iosZone', 'at': [0.5, 0.5]}, dur=16, gap=4)
    t.click(gap=6)
    new_agent(t, 'applepay', 'Apple Pay', harness='codex', settle=8)
    follow_up(t, 'applepay', 'RST-50: Apple Pay at checkout.')
    t.agent('applepay', turn='start', gap=10)
    zone_jump(t, 'infraZone')
    t.point({'zone': 'infraZone', 'at': [0.5, 0.5]}, dur=16, gap=4)
    t.click(gap=6)
    new_agent(t, 'deploy', 'Preview deploys', settle=8)
    follow_up(t, 'deploy', 'RST-51: a preview URL on every pull request.')
    t.agent('deploy', turn='start', gap=10)
    for n, (tid, desc, _) in enumerate(HELPERS):
        t.agent('subs', child=tid, tool={'id': f'w{n}', 'name': 'Write', 'input': {'file_path': f'src/subscriptions/{desc.split()[0].lower()}.ts', 'content': '// …'}}, gap=10)
        t.agent('subs', child=tid, toolDone=f'w{n}', gap=4)
    # Finishes come in; the glove reads each from the sidebar and closes it or follows up.
    t.agent('filters', say='Pickup and delivery filters are in, with tests.', dur=6, gap=2)
    t.agent('filters', turn='done', gap=20)
    reveal_row(t, 'filters')
    t.wait(24)
    close(t, 'filters', gap=14)
    # Close one, fire the next: these two are still working at 18:00, left overnight on purpose.
    fire_next(t, 'adminZone', 'ready', 'Order ready', 'Tell the customer when their order is ready.')
    t.agent('export', say='GET /orders/export.csv?month=2026-09, streamed.', dur=6, gap=2)
    t.agent('export', turn='done', gap=20)
    reveal_row(t, 'export')
    t.wait(20)
    follow_up(t, 'export', 'Add the refund column too.')
    t.agent('export', turn='start', gap=20)
    for round_ in range(2):
        for n, (tid, desc, _) in enumerate(HELPERS):
            t.agent('subs', child=tid, tool={'id': f'e{round_}{n}', 'name': 'Edit', 'input': {'file_path': f'src/subscriptions/{desc.split()[0].lower()}.ts', 'old_string': 'a', 'new_string': 'b'}}, gap=10)
            t.agent('subs', child=tid, toolDone=f'e{round_}{n}', gap=4)
        t.agent('applepay', tool={'id': f'ap{round_}', 'kind': 'fileChange', 'title': 'Edit', 'path': 'Roast/Checkout/ApplePay.swift', 'action': 'edit', 'added': 30 + round_ * 12}, gap=10)
        t.agent('applepay', toolDone=f'ap{round_}', gap=4)
        t.agent('deploy', tool={'id': f'dp{round_}', 'kind': 'fileChange', 'title': 'Edit', 'path': 'deploy/preview.yml', 'action': 'write', 'added': 22}, gap=10)
        t.agent('deploy', toolDone=f'dp{round_}', gap=4)
    t.agent('export', say='Refund column added.', dur=6, gap=2)
    t.agent('export', turn='done', gap=16)
    reveal_row(t, 'export')
    t.wait(16)
    close(t, 'export', gap=14)
    fire_next(t, 'apiZone', 'ratelimit', 'Rate limits', 'Rate-limit the public orders API.', harness='codex')
    for n, (tid, desc, _) in enumerate(HELPERS):
        t.agent('subs', child=tid, say=f'{desc} is done, with tests.', gap=10)
    t.do({'camera': {'zone': 'webZone', 'padding': 30}}, dur=150, then=170)
    return t


def ship():
    """15:30. You'll know when it lands: pick the sounds, then the push and the merge. Then the tour."""
    t = Take('06-ship', clock='15:30')
    t.do({'camera': {'tiles': ['subs'], 'padding': 120}})
    # Settings → Agents → Sounds: tick Pushed and Merged, preview each.
    t.key(',', ['cmd'], mark='settings', gap=30)
    t.point({'settings': 'section.Agents'}, dur=24, gap=4)
    t.click(gap=20)
    # The Sounds rules sit below the fold: scroll the detail pane under the pointer.
    t.point({'window': [900, 520]}, dur=16, gap=2)
    t.do({'scroll': {'by': [0, -480]}}, dur=24, then=34)
    for kind, mark in (('gitPushSucceeded', 'pickPush'), ('gitMergeSucceeded', 'pickMerge')):
        t.point({'settings': f'agentSounds.{kind}.enabled'}, dur=24, gap=4)
        t.click(mark=mark, gap=14)
        t.point({'settings': f'agentSounds.{kind}.preview'}, dur=20, gap=4)
        t.click(mark=mark + 'Preview', gap=40)
    t.mark('soundsLine').wait(60)
    t.key(',', ['cmd'], gap=30)
    for tid, _, _ in HELPERS:
        t.agent('subs', toolDone=tid, gap=6)
    t.wait(20)
    t.agent('subs', tool={'id': 'test1', 'name': 'Bash', 'input': {'command': 'npm test', 'description': 'Run the tests'}, 'output': '38 passing'}, gap=36)
    t.agent('subs', toolDone='test1', gap=10)
    t.agent('subs', tool={'id': 'push1', 'name': 'Bash', 'input': {'command': 'git push origin rst-43-subscriptions', 'description': 'Push the branch'},
                          'output': 'To github.com:roast/roast-web.git\n * [new branch]  rst-43-subscriptions -> rst-43-subscriptions'}, gap=36)
    t.agent('subs', toolDone='push1', mark='pushed', gap=60)
    t.agent('subs', tool={'id': 'merge1', 'name': 'Bash', 'input': {'command': 'git switch main && git merge --no-ff rst-43-subscriptions', 'description': 'Merge into main'},
                          'output': "Merge made by the 'ort' strategy."}, gap=36)
    t.agent('subs', toolDone='merge1', mark='merged', gap=20)
    tid, tool = board_apply('subs', 'done2', 'move', 'rst-43-done', cardId='{card:subs}', columnId='{column:board/Done}')
    t.agent('subs', tool=tool, gap=10)
    t.agent('subs', toolDone=tid, gap=6)
    t.agent('subs', say='Subscriptions are merged: plan picker, checkout and renewal emails. RST-43 is done.', dur=36, gap=40)
    t.agent('subs', turn='done', mark='subsDone', gap=10)
    t.mark('shipLine').wait(90)
    # The tour: the whole canvas for the first time, then each project by its digit.
    t.do({'camera': {'all': True, 'padding': 60}}, dur=240, mark='zoomOut', then=244)
    t.mark('canvasLine').wait(100)
    for zone in ('iosZone', 'apiZone', 'webZone', 'adminZone', 'infraZone'):
        zone_jump(t, zone, mark=f'tour:{zone}')
        t.wait(40)
    return tail(t)


def dusk():
    """Off camera, 17:50: everything still running finishes, so the evening can archive it."""
    t = Take('06b-dusk', clock='17:50', capture=False)
    for key, line in (('applepay', 'Apple Pay works in the simulator; tests pass.'),
                      ('deploy', 'Every pull request now gets a preview URL.')):
        t.agent(key, say=line, dur=4, gap=2)
        t.agent(key, turn='done', gap=4)
    return t


def evening():
    """18:00. Close the day in one click: select the finished rows, Archive. History holds the day."""
    t = Take('07-evening', clock='18:00')
    t.do({'camera': {'all': True, 'padding': 60}})
    lead(t).wait(20)
    # A plain click reveals Rate limits, still working (it stays tonight), and makes it the
    # route-active row; ⌘-clicking the route-active row does not add it to the selection, so the
    # six finished rows are ⌘-clicked after it. Archiving a parent leaves its subagents' rows
    # (P2D.6), so the three helpers are picked too. (⇧-click loses its anchor to the reveal.)
    t.point({'sidebar': 'ratelimit'}, dur=26, gap=4)
    glide_click(t, dur=60, gap=12)
    rows = ['deploy', 'applepay', 'subs', 'subs/toolu_emails', 'subs/toolu_checkout', 'picker']
    for i, key in enumerate(rows):
        t.point({'sidebar': key}, dur=18, gap=3)
        t.do({'click': {'deliver': True, 'mods': ['cmd']}}, mark='range' if i == len(rows) - 1 else None, then=12)
    t.wait(12)
    t.point({'bulk': 'menu'}, dur=26, gap=4)
    t.click(gap=20)
    t.point({'bulk': 'archive'}, dur=20, gap=4)
    t.click(mark='archived', gap=40)
    t.mark('archiveLine').wait(100)
    t.point({'sidebar': 'history'}, dur=30, gap=4)
    t.click(mark='historyOpen', gap=20)
    t.mark('historyLine').wait(90)
    t.do({'camera': {'all': True, 'padding': 120}}, dur=360, mark='emptyOut', then=364)
    t.mark('tomorrowLine').wait(150)
    return t


def scene():
    return {
        'schema': 'array.film.scene.v1',
        'id': 'full-day-v2',
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
            {'key': 'admin', 'name': 'roast-admin', 'files': 'projects/roast-admin', 'git': {}},
            {'key': 'ios', 'name': 'roast-ios', 'files': 'projects/roast-ios', 'git': {}},
            {'key': 'infra', 'name': 'roast-infra', 'files': 'projects/roast-infra', 'git': {}},
        ],
        # Storefront is drawn at world (1720, 30) and grows right and down as the day fills it;
        # the bottom row sits low enough that it is never pushed.
        'zones': [
            {'key': 'apiZone', 'project': 'api', 'name': 'Roast API', 'rect': [0, 0, 1500, 1000], 'color': 'teal'},
            {'key': 'iosZone', 'project': 'ios', 'name': 'Roast iOS', 'rect': [-2600, 0, 2200, 1000], 'color': 'blue'},
            {'key': 'adminZone', 'project': 'admin', 'name': 'Barista Admin', 'rect': [0, 3400, 2200, 1000], 'color': 'purple'},
            {'key': 'infraZone', 'project': 'infra', 'name': 'Infra', 'rect': [-2600, 3400, 2200, 1000], 'color': 'mint'},
        ],
        'tiles': [
            {'key': 'emails', 'kind': 'agent', 'zone': 'apiZone', 'frame': [80, 80, 640, 740], 'name': 'Order emails'},
        ],
        'takes': [t.json() for t in (setup(), morning(), mid_morning(), late_morning(), lunch(), afternoon(),
                                     busy(), ship(), dusk(), evening())],
    }


if __name__ == '__main__':
    path = os.path.join(HERE, 'full-day-v2.json')
    s = scene()
    with open(path, 'w') as f:
        json.dump(s, f, indent=1, ensure_ascii=False)
        f.write('\n')
    total = 0
    for take in s['takes']:
        marks = {a['mark']: a['at'] for a in take['actions'] if 'mark' in a}
        if take.get('capture', True):
            total += take['frames']
        print(f"{take['name']}: {take['frames']} frames ({take['frames'] / 60:.1f}s) marks {list(marks)}")
    print(f'captured: {total} frames ({total / 60:.0f}s)')
