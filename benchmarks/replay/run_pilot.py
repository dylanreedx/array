"""The live pilot: each task once solo and once with fan-out, on Claude Code.

Starts the egress proxy, puts live_claude.py first on PATH as `claude`, and
runs `Array --replay-live-run` once per condition, one after another, in a
fresh environment (no inherited agent, tmux or Array variables). The driver
cuts a run at DEADLINE seconds; this script kills it a few minutes after that
as a backstop. No reruns: each condition runs once unless named on the
command line.

usage: run_pilot.py ARRAY_BINARY OUT_DIR MODEL EFFORT TASK_JSON... [--only TASK:MODE]"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
DEADLINE = 1200
BACKSTOP = DEADLINE + 300
ALLOWED_HOSTS = ['api.anthropic.com']


def main(argv):
    only = None
    if '--only' in argv:
        only = argv[argv.index('--only') + 1]
        argv = argv[:argv.index('--only')]
    binary, out, model, effort, tasks = os.path.realpath(argv[0]), Path(argv[1]).resolve(), argv[2], argv[3], argv[4:]
    for folder in ('bin', 'tmp', 'app-support', 'logs', 'runs'):
        (out / folder).mkdir(parents=True, exist_ok=True)
    claude = os.path.realpath(os.path.expanduser('~/.local/bin/claude'))
    shim = out / 'bin' / 'claude'
    shim.write_text('#!/bin/sh\nexec /usr/bin/python3 -I %s "$@"\n' % json.dumps(str(HERE / 'live_claude.py')))
    shim.chmod(0o755)
    port_file = out / 'logs' / 'proxy-port'
    port_file.unlink(missing_ok=True)
    proxy = subprocess.Popen(['/usr/bin/python3', '-I', str(HERE / 'egress_proxy.py'), str(port_file),
                              str(out / 'logs' / 'egress.jsonl')] + ALLOWED_HOSTS)
    try:
        for _ in range(50):
            if port_file.exists() and port_file.read_text():
                break
            time.sleep(0.1)
        port = port_file.read_text()
        env = dict(HOME=os.environ['HOME'], USER=os.environ['USER'], LOGNAME=os.environ['USER'],
                   LANG='en_US.UTF-8', PATH='%s:/usr/bin:/bin' % (out / 'bin'), TMPDIR=str(out / 'tmp'),
                   CONTINUUM_APP_SUPPORT=str(out / 'app-support'), CONTINUUM_ARRAY_MANAGED_AGENT='1',
                   PYTHONDONTWRITEBYTECODE='1', REPLAY_LIVE_CLAUDE=claude, REPLAY_LIVE_PROXY_PORT=port,
                   REPLAY_LIVE_LOG=str(out / 'logs'))
        for task_json in tasks:
            name = json.loads(Path(task_json).read_text())['fixture']
            for mode in ('solo', 'managed'):
                label = '%s:%s' % (name, mode)
                if only and only != label:
                    continue
                started = time.time()
                with open(out / 'logs' / ('%s-%s.out' % (name, mode)), 'w') as stdout, \
                        open(out / 'logs' / ('%s-%s.err' % (name, mode)), 'w') as stderr:
                    process = subprocess.Popen([binary, '--replay-live-run', task_json, str(out / 'records.jsonl'), mode,
                                                model, effort, str(DEADLINE), str(out / 'runs')],
                                               env=env, stdout=stdout, stderr=stderr, stdin=subprocess.DEVNULL,
                                               start_new_session=True)
                    try:
                        code = process.wait(timeout=BACKSTOP)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, 9)
                        code = 'killed by backstop'
                print('%s exit %s after %.0fs' % (label, code, time.time() - started), flush=True)
    finally:
        proxy.terminate()


if __name__ == '__main__':
    main(sys.argv[1:])
