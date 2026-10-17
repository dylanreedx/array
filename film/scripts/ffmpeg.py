#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["imageio-ffmpeg==0.6.0"]
# ///
"""Puts a pinned, full ffmpeg (7.1, from the imageio-ffmpeg wheel) at node_modules/.cache/film-bin/ffmpeg.

Remotion bundles its own ffmpeg, but it is a minimal build: no rawvideo/f32le muxers and no
drawtext/tile/hstack filters, which the Tessel motion-blur, sync-check and sheet scripts need.
A wheel pins the exact binary per platform without Homebrew drift.

The link lives under node_modules/ on purpose: a symlink to an external binary anywhere else in
the Remotion root crashes webpack's filesystem-cache snapshot (wasm-hash TypeError, reproduced)."""
import os
import imageio_ffmpeg

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bindir = os.path.join(root, 'node_modules', '.cache', 'film-bin')
os.makedirs(bindir, exist_ok=True)
link = os.path.join(bindir, 'ffmpeg')
if os.path.lexists(link):
    os.remove(link)
os.symlink(imageio_ffmpeg.get_ffmpeg_exe(), link)
print(link, '->', imageio_ffmpeg.get_ffmpeg_exe())
