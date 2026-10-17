"""Shared by the probes: read numbered PNG frames from a folder (a take's frames/, a render's frames/ or
stills/), or decode them from a video with film's pinned ffmpeg. Frame numbers come from the file names
(the last run of digits), so 000412.png, 412.png and element-412.png all read as frame 412."""
import glob
import os
import re
import subprocess

import numpy as np
from PIL import Image

FILM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG = os.path.join(FILM, 'node_modules', '.cache', 'film-bin', 'ffmpeg')


def number(path):
    m = re.findall(r'(\d+)', os.path.basename(path))
    return int(m[-1]) if m else -1


def frames(src, lo=0, hi=10**9):
    """Yield (frame, RGB float array) for frames lo..hi of a folder or a video."""
    if os.path.isdir(src):
        d = src if glob.glob(os.path.join(src, '*.png')) else os.path.join(src, 'frames')
        for f in sorted(glob.glob(os.path.join(d, '*.png')), key=number):
            n = number(f)
            if lo <= n <= hi:
                yield n, np.asarray(Image.open(f).convert('RGB')).astype(float)
        return
    err = subprocess.run([FFMPEG, '-hide_banner', '-i', src], capture_output=True, text=True).stderr
    w, h = map(int, re.search(r'Video:.*?(\d{2,5})x(\d{2,5})', err).groups())
    p = subprocess.Popen([FFMPEG, '-v', 'error', '-i', src, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
    n = 0
    while True:
        buf = p.stdout.read(w * h * 3)
        if len(buf) < w * h * 3 or n > hi:
            break
        if n >= lo:
            yield n, np.frombuffer(buf, np.uint8).reshape(h, w, 3).astype(float)
        n += 1
    p.kill()


def lum(im):
    return 0.2126 * im[..., 0] + 0.7152 * im[..., 1] + 0.0722 * im[..., 2]
