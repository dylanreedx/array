"""Contact sheet: a labelled grid of frames (frame, seconds, act), in frame order.

Usage: uv run --no-project --with pillow python scripts/lib/sheet.py <out.png> <cues.json> <fps> <frame pngs...>
Each png's frame number is read from 'f<N>' in its name. Cells are 480 px wide, 4 per row.
"""
import json
import re
import sys

from PIL import Image, ImageDraw

out, cues_path, fps, *files = sys.argv[1:]
fps = float(fps)
acts = json.load(open(cues_path)).get('acts', {})
frame = lambda f: int(re.search(r'f(\d+)', f.rsplit('/', 1)[-1]).group(1))
act = lambda n: next((a['name'] for a in acts.values() if a['from'] <= n < a['from'] + a['dur']), '')
files = sorted(files, key=frame)
cols, cw, label = 4, 480, 24
ims = [Image.open(f).convert('RGB') for f in files]
ch = max(round(im.height * cw / im.width) for im in ims)
rows = (len(ims) + cols - 1) // cols
sheet = Image.new('RGB', (cols * (cw + 4) + 4, rows * (ch + label + 4) + 4), (85, 85, 85))
draw = ImageDraw.Draw(sheet)
for i, (f, im) in enumerate(zip(files, ims)):
    x, y = 4 + (i % cols) * (cw + 4), 4 + (i // cols) * (ch + label + 4)
    draw.rectangle([x, y, x + cw - 1, y + label - 1], fill=(0, 0, 0))
    n = frame(f)
    draw.text((x + 6, y + 6), f'f{n}  {n / fps:.2f}s  {act(n)}', fill=(255, 255, 255))
    sheet.paste(im.resize((cw, round(im.height * cw / im.width)), Image.LANCZOS), (x, y + label))
sheet.save(out)
print(f'{out}: {len(files)} frames, {sheet.size[0]}x{sheet.size[1]}')
