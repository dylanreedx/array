# Third-party notices

## Tessel launch film

Source: https://github.com/Leonxlnx/claude-launchvideo (commit f0906e8). MIT License, Copyright (c) 2026 Leonxlnx.

Files in film/ that contain code copied or adapted from it, each marked in its header:

| film/ file | Upstream | How |
| --- | --- | --- |
| kit/anim.ts, legacy/lib/anim.ts | src/lib/anim.ts | adapted (fps parameter, E.native added) |
| kit/blur.tsx (sampleTimes, subframes), legacy/lib/blur.ts | src/blur.ts | adapted (acts and total from a cue sheet) |
| src/Root.tsx (`Sub`) | src/LaunchSub.tsx | adapted |
| legacy/acts/edu/Cursor.tsx | src/fx/Cursor.tsx | verbatim |
| scripts/tessel/measure-speed.py | scripts/measure-speed.py | verbatim |
| scripts/tessel/accumulate.py | scripts/accumulate.py | verbatim |
| scripts/check-sync.py | scripts/check-sync.py | rewritten (whole-track correlation); the true-peak test is upstream's |
| kit/soundtrack.py | scripts/soundtrack.py | DSP helpers and limiter adapted |

```
MIT License

Copyright (c) 2026 Leonxlnx

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Tailwind CSS preflight

kit/base.css contains the preflight reset of Tailwind CSS v4.3.3 (https://github.com/tailwindlabs/tailwindcss),
with its theme functions resolved to fixed values:

```
MIT License

Copyright (c) Tailwind Labs, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Fonts

SIL Open Font License 1.1, each licence beside its file in public/fonts/: Schibsted Grotesk (variable,
fontsource 5.2.8), JetBrains Mono 2.304 (variable), Geist (variable, vercel/geist-font 1.7.2).
