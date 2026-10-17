#!/usr/bin/env python3
"""Writes film/scenes/v2-day-check/v2-day-check.json: the `--film-scene-check` scene for the v2 verbs
(.plans/68-launch-film/research/19-full-day-v2). Not a film: every beat exists to be
asserted (FilmRunV2Checks.swift).

Five projects, four staged zones and one drawn in a take; agents that finish unseen; a
hover card; sidebar clicks and ⌥ jumps that glide; a follow-up through the composer;
the “✓ All set?” settle nudge after a clock jump; a ⌘-click multi-select settled from the
bulk bar; a History row as a target. (No Settings take: see the note above lunch().)
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))


class Take:
    def __init__(self, name, clock=None):
        self.name, self.clock, self.t, self.actions = name, clock, 0, []

    def wait(self, n):
        self.t += n
        return self

    def do(self, verb, dur=None, then=0, **rest):
        a = {'at': self.t, **verb, **rest}
        if dur:
            a['dur'] = dur
        self.actions.append(a)
        self.t += then
        return self

    def point(self, to, dur=20, gap=4, **kw):
        return self.do({'pointer': {'to': to, **kw}}, dur=dur, then=dur + kw.get('dwell', 0) + gap)

    def click(self, gap=10, dur=None, mods=None):
        c = {'deliver': True}
        if mods:
            c['mods'] = mods
        return self.do({'click': c}, dur=dur, then=max(dur or 0, 5) + gap)

    def key(self, key, mods=None, gap=12):
        v = {'key': key}
        if mods:
            v['mods'] = mods
        return self.do(v, then=gap)

    def agent(self, key, gap=0, dur=None, **verb):
        return self.do({'agent': key, **verb}, dur=dur, then=gap)

    def json(self):
        out = {'name': self.name, 'frames': self.t + 1, 'actions': self.actions}
        if self.clock:
            out['clock'] = self.clock
        return out


def morning():
    t = Take('01-morning', clock='8:45')
    t.do({'camera': {'zone': 'apiZone', 'padding': 40}})
    for key, text in [('cart', 'Fix the cart total.'), ('dark', 'Dark mode for the shop.'), ('deploy', 'Ship the staging deploy.')]:
        t.agent(key, prompt=text)
        t.agent(key, turn='start', ago=900)
    t.agent('ios1', turn='start', ago=600, gap=4)
    t.agent('cart', say='Rounded once, on the total.', dur=12, gap=14)
    t.agent('cart', turn='done', gap=2)
    t.agent('dark', say='Every token has a dark value.', dur=12, gap=14)
    t.agent('dark', turn='done', gap=2)
    t.agent('deploy', say='Staging is green.', dur=10, gap=12)
    t.agent('deploy', turn='done', gap=20)
    # Hover: the card opens after the 0.15 s dwell, on the film clock.
    t.point({'sidebar': 'cart'}, dur=24, hover=True, dwell=30)
    # A sidebar click reveals the agent: its jump glides over the click's dur.
    t.point({'sidebar': 'dark'}, dur=20)
    t.click(dur=60, gap=8)
    t.point({'sidebar': 'cart'}, dur=20)
    t.click(dur=60, gap=8)
    # A follow-up on a finished agent through its own composer.
    t.point({'tile': 'cart', 'at': 'composer'}, dur=20)
    t.click(gap=6)
    t.do({'type': 'Also cover the 3-for-2 promo.'}, dur=40, then=48)
    t.point({'tile': 'cart', 'at': 'send'}, dur=16)
    t.click(gap=8)
    t.agent('cart', turn='start', gap=6)
    t.agent('cart', say='The promo is covered, with a test.', dur=14, gap=16)
    t.agent('cart', turn='done', gap=30)
    return t


# No Settings take (2026-10-17). Integration's in-window SwiftUI Settings modal (4552acdc)
# has no AppKit controls the recorder can point at, and it writes the app's real
# defaults (the old panel's writes went to a throwaway film suite), so a check must not
# drive it. The former 02-settings take (Agents -> Sounds, two ticks, two Previews)
# returns once the recorder can target the form through ARRAY_FILM-only code.


def lunch():
    """13:00: dark was read hours ago, so its row asks to be closed."""
    t = Take('03-lunch', clock='13:00')
    t.wait(6).point({'sidebar': 'dark', 'at': 'nudge'}, dur=24)
    t.click(gap=24)
    return t


def zones():
    """13:30: draw the fifth project's zone, then ⌥ jumps between zones and to a tile."""
    t = Take('04-zones', clock='13:30')
    t.do({'camera': {'rect': [2900, -40, 1500, 1000]}})
    t.point({'world': [3000, 60]}, dur=16)
    t.do({'gesture': {'to': {'world': [4200, 860]}}}, dur=36, then=46)
    t.point({'choice': 'roast-web'}, dur=20, gap=6)
    t.click(gap=12)
    t.do({'adopt': {'as': 'webZone', 'kind': 'zone'}}, then=6)
    t.point({'window': [1200, 820]}, dur=16, gap=4)
    # Every zone on screen, so the note in Barista Admin has a jump letter.
    t.do({'camera': {'all': True, 'padding': 60}}, dur=240, then=244)
    t.do({'hold': 'option'}, dur=100, then=20)
    t.do({'jump': 'queue'}, dur=60, then=90)
    t.do({'hold': 'option'}, dur=100, then=20)
    t.do({'jumpZone': 'iosZone'}, dur=60, then=90)
    t.do({'hold': 'option'}, dur=100, then=20)
    t.do({'jumpZone': 'webZone'}, dur=60, then=90)
    return t


def evening():
    """18:00: ⌘-click two finished rows, Settle them from the bulk bar (which closes their
    tiles); the one History shelf holds them."""
    t = Take('05-evening', clock='18:00')
    t.do({'camera': {'zone': 'apiZone', 'padding': 40}})
    # A plain click reveals cart and makes it the route-active row (that re-render
    # empties the table selection, by design); ⌘-clicks after it build the selection.
    t.wait(4).point({'sidebar': 'cart'}, dur=20)
    t.click(dur=40, gap=8)
    t.click(mods=['cmd'], gap=8)
    t.point({'sidebar': 'deploy'}, dur=20)
    t.click(mods=['cmd'], gap=12)
    t.point({'bulk': 'menu'}, dur=20)
    t.click(gap=20)
    t.point({'bulk': 'settle'}, dur=18)
    t.click(gap=24)
    t.point({'sidebar': 'history'}, dur=20)
    t.click(gap=20)
    t.point({'sidebar': 'cart'}, dur=20, gap=20)
    return t


def scene():
    return {
        'schema': 'array.film.scene.v1',
        'id': 'v2-day-check',
        'window': {'width': 1600, 'height': 900},
        'sidebar': True,
        'sidebarWidth': 300,
        'cameraModel': 'v2',
        'fps': 60,
        'video': 'none',
        'png': 'none',
        'catalog': [
            {'harness': 'claude', 'model': 'anthropic/claude-opus-5', 'displayName': 'Opus 5', 'contextWindow': 200000},
            {'harness': 'codex', 'model': 'openai-codex/gpt-5.5-codex', 'displayName': 'GPT-5.5 Codex'},
        ],
        'workspace': 'Roast',
        'projects': [
            {'key': 'api', 'name': 'roast-api', 'files': '../full-day/projects/roast-api', 'git': {}},
            {'key': 'web', 'name': 'roast-web', 'files': '../full-day/projects/roast-web', 'git': {}, 'placed': False},
            {'key': 'admin', 'name': 'roast-admin'},
            {'key': 'ios', 'name': 'roast-ios'},
            {'key': 'infra', 'name': 'roast-infra'},
        ],
        'zones': [
            {'key': 'apiZone', 'project': 'api', 'name': 'Roast API', 'rect': [0, 0, 1400, 900], 'color': 'teal'},
            {'key': 'adminZone', 'project': 'admin', 'name': 'Barista Admin', 'rect': [1600, 0, 1200, 900], 'color': 'purple'},
            {'key': 'iosZone', 'project': 'ios', 'name': 'Roast iOS', 'rect': [0, 1100, 1200, 800], 'color': 'blue'},
            {'key': 'infraZone', 'project': 'infra', 'name': 'Infra', 'rect': [1400, 1100, 1200, 800], 'color': 'mint'},
        ],
        'tiles': [
            {'key': 'cart', 'kind': 'agent', 'zone': 'apiZone', 'frame': [60, 60, 600, 760], 'name': 'Cart total'},
            {'key': 'dark', 'kind': 'agent', 'zone': 'apiZone', 'frame': [720, 60, 600, 760], 'name': 'Dark mode'},
            {'key': 'queue', 'kind': 'note', 'zone': 'adminZone', 'frame': [60, 60, 500, 360], 'body': 'Barista queue filters'},
            {'key': 'ios1', 'kind': 'agent', 'harness': 'codex', 'zone': 'iosZone', 'frame': [60, 60, 520, 660], 'name': 'Widgets'},
            {'key': 'deploy', 'kind': 'agent', 'zone': 'infraZone', 'frame': [60, 60, 520, 660], 'name': 'Staging deploy'},
        ],
        'takes': [t.json() for t in (morning(), lunch(), zones(), evening())],
    }


if __name__ == '__main__':
    path = os.path.join(HERE, 'v2-day-check.json')
    with open(path, 'w') as f:
        json.dump(scene(), f, indent=1, ensure_ascii=False)
        f.write('\n')
    for take in scene()['takes']:
        print(f"{take['name']}: {take['frames']} frames")
