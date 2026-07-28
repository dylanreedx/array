Allow running a command that writes outside the workspace?
command: atlas-index --shards 2 --segment-budget 1024 --catalog /work/shared/atlas-catalog.db
reason: the catalog path is outside /work/lumen-atlas
choices: allow once, allow for this session, deny
