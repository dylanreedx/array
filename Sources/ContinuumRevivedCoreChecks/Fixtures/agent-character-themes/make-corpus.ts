// Builds the parity corpus for Array's agent-character theme parser: theme files that the
// reference parser (parseTheme in the MIT-licensed hooks/themes.ts) accepts or rejects, with
// each verdict and message recorded when the fixture is made.
// Usage: bun make-corpus.ts <reference hooks dir> <out dir>
const [hooks, out] = process.argv.slice(2)
const T = await import(`${hooks}/themes.ts`)
const fs = await import('node:fs')

const helperFrame = (c: string, w = 20, h = 12) => Array.from({ length: h }, (_, y) => (y >= 4 && y < 8 ? `.....${c.repeat(8)}${'.'.repeat(w - 13)}` : '.'.repeat(w)))
const leadFrame = (c: string) => Array.from({ length: 16 }, (_, y) => (y >= 4 && y < 12 ? `.....${c.repeat(10)}.............` : '.'.repeat(28)))
function base(id: string, names: string[] = [`${id.replace(/[^A-Za-z0-9]/g, "")}One`, `${id.replace(/[^A-Za-z0-9]/g, "")}Two`]): any {
  const loop = { frameMs: 200, frames: [helperFrame('A'), helperFrame('B')] }
  const helper = (name: string, own: string[]) => ({
    name, names: own, blink: ['B', 'A'],
    loops: { dabble: loop, read: loop, type: loop, run: loop, think: loop },
    ends: {
      done: helperFrame('A'), failed: helperFrame('B'),
      cheer: [helperFrame('A')], droop: [helperFrame('B')], asleep: [helperFrame('A')], idle: [helperFrame('A'), helperFrame('B')],
      idleMove: [helperFrame('B')], flinch: [helperFrame('A')], wave: [helperFrame('B')], noticed: [helperFrame('A')],
    },
  })
  return {
    duckherdTheme: 1, id, title: `Theme ${id}`,
    palette: { A: '#112233', B: '#ffcc00', S: '#99ccff' },
    marks: { star: 'B', starLit: 'B', drop: 'S', dropLit: 'S', asked: 'B', told: 'A' },
    stuck: { drop: [2, 5], mark: 16 },
    helpers: [helper('First', names.slice(0, 1)), helper('Second', names.slice(1))],
    lead: { rest: [leadFrame('A')], rising: [leadFrame('B')], levels: [[leadFrame('A'), leadFrame('B')]], flare: { small: [[[1, 1, 'B']]], big: [[[2, 2, 'B']]] } },
    sounds: { quack: 'done.wav' },
  }
}
const clone = (o: any) => JSON.parse(JSON.stringify(o))
const big = (json: string) => JSON.stringify(JSON.parse(json), (k, v) => {
  const isFrame = Array.isArray(v) && v.length > 0 && v.every(r => typeof r === 'string' && r.length >= 20)
  return isFrame ? (v as string[]).flatMap(r => Array.from({ length: 4 }, () => [...r].map(c => c.repeat(4)).join(''))) : v
})
const cases: Record<string, string> = {}
const put = (name: string, value: any) => { cases[name] = typeof value === 'string' ? value : JSON.stringify(value) }

put('good-pond', base('pond'))
put('good-pond-scale4', big(JSON.stringify({ ...base('pond-big'), scale: 4 })))
{ const t = base('minimal'); delete t.marks; delete t.stuck; delete t.lead; delete t.sounds; delete t.title
  for (const h of t.helpers) { delete h.ends.idleMove; delete h.blink; delete h.names }
  t.helpers[1].name = 'Other'; put('good-minimal', t) }
{ const t = base('wide'); t.helperSize = [40, 24]; const loop = { frameMs: 120.5, frames: [helperFrame('A', 40, 24)] }
  for (const h of t.helpers) { for (const a of ['dabble', 'read', 'type', 'run', 'think']) h.loops[a] = loop
    for (const k of ['done', 'failed']) h.ends[k] = helperFrame('B', 40, 24)
    for (const k of ['cheer', 'droop', 'asleep', 'idle', 'idleMove', 'flinch', 'wave', 'noticed']) h.ends[k] = [helperFrame('A', 40, 24)] }
  put('good-wide-size', t) }
{ const t = base('long-title'); t.title = '  ' + 'T'.repeat(80) + '  '; t.helpers[0].name = '  ' + 'N'.repeat(40); put('good-long-title', t) }
{ const t = base('own-colours'); t.helpers[0].colors = { x: '#4FB6A8', X: '#377f76' }; t.helpers[0].loops.type = { frameMs: 50, frames: [helperFrame('x'), helperFrame('X')] }; put('good-own-colours', t) }
{ const t = base('frames-64'); t.helpers[0].loops.think = { frameMs: 5000, frames: Array.from({ length: 64 }, () => helperFrame('A')) }; put('good-64-frames', t) }

put('bad-not-json', '{nope')
put('bad-array', '[]')
put('bad-version-2', { ...base('x'), duckherdTheme: 2 })
put('bad-version-true', { ...base('x'), duckherdTheme: true })
put('bad-version-string', { ...base('x'), duckherdTheme: '1' })
put('bad-reserved-id', base('ducks'))
put('bad-id-spaces', base('Bad Id'))
put('bad-id-too-long', base('a'.repeat(32)))
put('bad-scale-2', { ...base('x'), scale: 2 })
put('bad-helper-size', { ...base('x'), helperSize: [21, 12] })
put('bad-lead-size-too-big', { ...base('x'), leadSize: [82, 16] })
put('bad-palette-hex', { ...base('x'), palette: { A: 'red', B: '#ffcc00', S: '#99ccff' } })
put('bad-palette-key', { ...base('x'), palette: { AB: '#112233', A: '#112233', B: '#ffcc00', S: '#99ccff' } })
put('bad-palette-dot', { ...base('x'), palette: { '.': '#112233', A: '#112233', B: '#ffcc00', S: '#99ccff' } })
put('bad-palette-emoji', { ...base('x'), palette: { '😀': '#112233', A: '#112233', B: '#ffcc00', S: '#99ccff' } })
put('bad-palette-missing', (() => { const t = base('x'); delete t.palette; return t })())
put('bad-unknown-letter', { ...base('x'), palette: { A: '#112233' } })
{ const t = base('x'); t.helpers[0].loops.run = { frameMs: 200, frames: [helperFrame('A').map((r, i) => i === 3 ? r.slice(1) : r)] }; put('bad-short-row', t) }
{ const t = base('x'); t.helpers[0].loops.run = { frameMs: 200, frames: [['....']] }; put('bad-row-count', t) }
{ const t = base('x'); t.helpers[0].loops.type = { frameMs: 200, frames: [] }; put('bad-zero-frames', t) }
{ const t = base('x'); t.helpers[0].loops.type = { frameMs: 200, frames: Array.from({ length: 65 }, () => helperFrame('A')) }; put('bad-65-frames', t) }
{ const t = base('x'); t.helpers[0].loops.read = { frameMs: 49, frames: [helperFrame('A')] }; put('bad-frame-ms-49', t) }
{ const t = base('x'); t.helpers[0].loops.read = { frameMs: 5001, frames: [helperFrame('A')] }; put('bad-frame-ms-5001', t) }
{ const t = base('x'); t.helpers[0].loops.read = { frameMs: '200', frames: [helperFrame('A')] }; put('bad-frame-ms-string', t) }
{ const t = base('x'); const h = t.helpers[0]; t.helpers = Array.from({ length: 13 }, (_, i) => ({ ...clone(h), names: [`n${i}x`] })); put('bad-13-helpers', t) }
put('bad-no-helpers', { ...base('x'), helpers: [] })
put('bad-duplicate-name', base('x', ['same', 'Same']))
{ const t = base('x'); t.helpers[0].names = ['1abc']; put('bad-name-shape', t) }
put('bad-sound-folder', { ...base('x'), sounds: { quack: '../x.wav' } })
put('bad-sound-subfolder', { ...base('x'), sounds: { honk: 'sub/x.wav' } })
put('bad-sound-absolute', { ...base('x'), sounds: { quack: '/etc/x.wav' } })
put('bad-sound-ogg', { ...base('x'), sounds: { snore: 'zzz.ogg' } })
put('bad-stuck', { ...base('x'), stuck: { drop: [20, 1], mark: 3 } })
put('bad-marks', { ...base('x'), marks: { star: 'Z' } })
{ const t = base('x'); delete t.helpers[1].loops.think; put('bad-missing-loop', t) }
{ const t = base('x'); delete t.helpers[0].ends.wave; put('bad-missing-end', t) }
{ const t = base('x'); delete t.helpers[0].ends.done; put('bad-missing-done', t) }
{ const t = base('x'); t.helpers[0] = 'nope'; put('bad-helper-not-object', t) }
{ const t = base('x'); t.helpers[0].name = '   '; put('bad-helper-no-name', t) }
{ const t = base('x'); t.helpers[0].blink = ['B']; put('bad-blink', t) }
{ const t = base('x'); t.helpers[0].colors = { x: 'teal' }; put('bad-own-colour', t) }
{ const t = base('x'); t.lead.levels = [1, 2, 3, 4, 5].map(() => [leadFrame('A')]); put('bad-lead-levels', t) }
{ const t = base('x'); t.lead.flare = { small: [[[1, 1, 'Q']]], big: [] }; put('bad-lead-flare', t) }
put('bad-opus-mark', { ...base('x'), opusMark: 'no' })
put('bad-many-problems', { ...base('Bad Id'), duckherdTheme: 3, scale: 3, palette: { AB: '#1', CD: '#2', EF: '#3', GH: '#4', IJ: '#5', KL: '#6', MN: '#7', OP: '#8', QR: '#9' } })

fs.mkdirSync(out, { recursive: true })
const manifest: any[] = []
for (const [name, text] of Object.entries(cases)) {
  fs.writeFileSync(`${out}/${name}.theme.json`, text)
  const got = T.parseTheme(text)
  manifest.push('errors' in got
    ? { file: `${name}.theme.json`, accepted: false, errors: got.errors }
    : { file: `${name}.theme.json`, accepted: true, id: got.theme.id, title: got.theme.title, helpers: got.theme.helpers.map((h: any) => h.name), hasLead: got.theme.lead !== undefined, scale: got.theme.scale ?? 1 })
}
fs.writeFileSync(`${out}/manifest.json`, JSON.stringify({ reference: 'parseTheme, hooks/themes.ts at ea44e834632e91c17fc410e3227e7ba060ce0674 (v0.4.10, MIT)', cases: manifest }, null, 1) + '\n')
console.log('cases', manifest.length, 'accepted', manifest.filter(m => m.accepted).length)
for (const m of manifest) if ((m.file.startsWith('good') !== m.accepted)) console.log('UNEXPECTED', m.file, m.errors)
