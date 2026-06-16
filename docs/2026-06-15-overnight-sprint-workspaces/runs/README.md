# Run artifacts — source of truth

One folder per task. The orchestrator and its agents write here as work lands; these files
are how you (and the orchestrator) inspect what happened without re-deriving it.

```
runs/<task-id>/
  launch.md     # exactly what the builder was dispatched with: spec path, model, scope, branch
  build.md      # builder's summary + diff stat + the RED→GREEN check output
  review.md     # reviewer's structured verdict (PASS | PASS WITH RISKS | CHANGES REQUESTED | BLOCKED) + evidence
  result.json   # {task, verdict, commit, iterations, matrix}
```

See `../REVIEW.md` for the triaged morning review guide.
