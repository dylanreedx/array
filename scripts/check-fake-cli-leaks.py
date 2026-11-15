#!/usr/bin/env python3
"""Report surviving QA fixture CLIs tagged by this matrix run. Never signal them."""
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

RUN_KEY = 'ARRAY_CHECK_RUN_ID'
UUID = r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}'
BENCH = re.compile(r'continuum-[^/]+-' + UUID + r'\Z')


def executable(command):
    # A script is argv[0], or argv[1] after its Python/shell interpreter.
    # A later argument or quoted prompt mentioning a fixture is not a CLI.
    for token in command.split(None, 2)[:2]:
        path = Path(token)
        if not path.is_absolute() or path.name not in ('claude', 'codex', 'pi'):
            continue
        parent = path.parent
        if ((BENCH.fullmatch(parent.name) and '-bin-' in parent.name)
                or (parent.name == 'bin' and BENCH.fullmatch(parent.parent.name))):
            return str(path)
    return None


def fixtures(run_id):
    uuid.UUID(run_id)  # Refuse an empty/ambiguous ownership marker.
    marker = re.compile(r'(?:^|\s)' + RUN_KEY + '=' + re.escape(run_id) + r'(?=\s|$)')
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,command='], text=True)
    found = {}
    for row in rows.splitlines():
        fields = row.split(None, 3)
        if len(fields) != 4:
            continue
        pid, parent, group, command = fields
        script = executable(command)
        if script is None:
            continue
        # Read environments only for candidate QA scripts. Never print them.
        current = subprocess.run(['/bin/ps', 'eww', '-p', pid, '-o', 'command='],
                                 text=True, capture_output=True)
        if current.returncode or not marker.search(current.stdout) or executable(current.stdout) != script:
            continue
        found[pid] = dict(ppid=int(parent), pgid=int(group), executable=script)
    return found


def main():
    mode, snapshot, *args = sys.argv[1:]
    path = Path(snapshot)
    if mode == 'snapshot':
        run_id = args[0]
        before = fixtures(run_id)
        path.write_text(json.dumps(dict(runID=run_id, before=before)) + '\n')
        print(f'Fake CLI snapshot: {len(before)} existing process(es), run {run_id}')
    elif mode == 'check':
        saved = json.loads(path.read_text())
        deadline = time.monotonic() + 3
        while True:
            after = fixtures(saved['runID'])
            leaked = {pid: row for pid, row in after.items()
                      if saved['before'].get(pid, {}).get('executable') != row['executable']}
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
