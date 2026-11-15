#!/usr/bin/env python3
"""Report surviving fixture CLIs in one run's private TMPDIR. Never signal them."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def fixtures(root):
    # Match an executable argument, never a path embedded inside a prompt.
    aliases = {str(root), str(root).removeprefix('/private')}
    prefix = '(?:' + '|'.join(re.escape(alias) for alias in aliases) + ')'
    pattern = re.compile(r'(?:^|\s)(' + prefix + r'/\S*/(?:claude|codex|pi))(?=\s|$)')
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,command='], text=True)
    found = {}
    for row in rows.splitlines():
        fields = row.split(None, 3)
        if len(fields) != 4:
            continue
        pid, parent, group, command = fields
        match = pattern.search(command)
        if match:
            found[pid] = dict(ppid=int(parent), pgid=int(group), executable=match[1])
    return found


def main():
    mode, snapshot, *args = sys.argv[1:]
    path = Path(snapshot)
    if mode == 'snapshot':
        root = Path(args[0]).resolve()
        # A private namespace avoids blaming checks another bench starts later.
        if not root.is_dir() or root == Path('/'):
            raise ValueError('snapshot requires an existing private temporary directory')
        before = fixtures(root)
        path.write_text(json.dumps(dict(root=str(root), before=before)) + '\n')
        print(f'Fake CLI snapshot: {len(before)} existing process(es), root {root}')
    elif mode == 'check':
        saved = json.loads(path.read_text())
        deadline = time.monotonic() + 3
        while True:
            after = fixtures(Path(saved['root']))
            leaked = {pid: row for pid, row in after.items() if saved['before'].get(pid, {}).get('executable') != row['executable']}
            if not leaked or time.monotonic() >= deadline:
                break
            time.sleep(.05)
        print(f'Fake CLI leak check: {len(leaked)} new survivor(s)')
        for pid, row in leaked.items():
            print(f"  pid={pid} ppid={row['ppid']} pgid={row['pgid']} {row['executable']}")
        return bool(leaked)
    else:
        raise ValueError('expected snapshot or check')
    return 0


if __name__ == '__main__':
    sys.exit(main())
