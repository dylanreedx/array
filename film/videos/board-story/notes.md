# board-story: notes

Reference film (see legacy/README.md). It renders from film/ on legacy/.

## State

- r1 delivered 2026-10-04: `.plans/68-launch-film/board-story-r1/`.
- Dylan: "Okay, this looks pretty good. Impressive, actually. But I think we can still do better here."
  Then: faster, poppier, friendlier, a power user's perspective, an expressive cursor, and captions where
  the eyes are. That led to power-tour.
- Takes: the recorder run `~/array-scratch/film/board-story-20261004T155047Z/out/` (seven takes,
  01-wide-glide to 07-done). The edit reads 1440 x 778 pt H.264 proxies of their .mov files at
  `public/footage/board-story/<take>.mp4` (gitignored). To rebuild one:
  `node_modules/.cache/film-bin/ffmpeg -i <run>/out/<take>/<take>.mov -c:v libx264 -crf 14 -pix_fmt yuv420p -an public/footage/board-story/<take>.mp4`
- Sound: its score was the `bed` mode, whose hum followed the website fixture's working agents. That count is
  no longer derived (scripts/render exports authored cues only), so a re-render's hum is silent.
