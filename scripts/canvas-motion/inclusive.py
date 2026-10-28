"""Inclusive main-thread samples per Array function (recursion counted once)."""
import re, sys, collections
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if 'Main Thread' in l and re.match(r'^ {4}\d+ Thread_', l))
nodes = []
for l in lines[start + 1:]:
    if re.match(r'^ {4}\d+ Thread_', l) or l.strip() == '': break
    m = re.match(r'^(\s*[+!:| ]*?)(\d+) (.*)$', l)
    if m: nodes.append((len(m.group(1)), int(m.group(2)), re.sub(r'\s+\(in ([^)]*)\).*', r' [\1]', m.group(3))))
inc = collections.Counter(); stack = []
for d, n, name in nodes:
    while stack and stack[-1][0] >= d: stack.pop()
    if '[Array]' in name and name not in [s[1] for s in stack]: inc[name] += n
    stack.append((d, name))
skip = ('main', 'closure #1 in static ContinuumApp.main', 'thunk', 'partial apply', '@objc', 'runCanvasMotion')
for name, n in inc.most_common(80):
    if not name.startswith(skip): print(f'{n:6d}  {name[:130]}')
