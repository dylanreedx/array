"""The live pilot: every task once per arm, on Claude Code.

Arms come from live-config.json: solo, managed (Managed mode as built), and
managed-strict (Managed mode with the strict-lead switch on). managed-strict
runs only once live-config.json names the switch's environment variable.

Run order: the cache columns depend on what ran just before, so the arms
rotate per task (task 1 starts with the first arm, task 2 with the second,
...), and each record carries its position and the task's sequence.

Starts the egress proxy, puts live_claude.py first on PATH as `claude`, and
runs `Array --replay-live-run` once per condition, one after another, in a
fresh environment (no inherited agent, tmux or Array variables). The driver
cuts a run at the configured deadline; this script kills it five minutes
later as a backstop. No reruns: each condition runs once unless named with
--only.

usage: run_pilot.py ARRAY_BINARY OUT_DIR TASK_JSON... [--only TASK:ARM]"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
CONFIG = json.loads((HERE / 'live-config.json').read_text())


def runnable_arms(config):
    arms = list(config['arms'])
    if 'managed-strict' in arms and not (config.get('strictLeadSwitch') or {}).get('env'):
        print('managed-strict is not runnable: strictLeadSwitch.env is not set in live-config.json', flush=True)
        arms.remove('managed-strict')
    return arms


def sequence(arms, index):
    """The arms rotated so task `index` starts with arms[index % len]."""
    shift = index % len(arms)
    return arms[shift:] + arms[:shift]


def main(argv):
    only = None
    if '--only' in argv:
        only = argv[argv.index('--only') + 1]
        argv = argv[:argv.index('--only')]
    binary, out, tasks = os.path.realpath(argv[0]), Path(argv[1]).resolve(), argv[2:]
    arms = runnable_arms(CONFIG)
    deadline = int(CONFIG['deadlineSeconds'])
    for folder in ('bin', 'tmp', 'app-support', 'logs', 'runs'):
        (out / folder).mkdir(parents=True, exist_ok=True)
    claude = os.path.realpath(os.path.expanduser('~/.local/bin/claude'))
    shim = out / 'bin' / 'claude'
    shim.write_text('#!/bin/sh\nexec /usr/bin/python3 -I %s "$@"\n' % json.dumps(str(HERE / 'live_claude.py')))
    shim.chmod(0o755)
    port_file = out / 'logs' / 'proxy-port'
    port_file.unlink(missing_ok=True)
    proxy = subprocess.Popen(['/usr/bin/python3', '-I', str(HERE / 'egress_proxy.py'), str(port_file),
                              str(out / 'logs' / 'egress.jsonl')] + CONFIG['allowedHosts'])
    try:
        for _ in range(50):
            if port_file.exists() and port_file.read_text():
                break
            time.sleep(0.1)
        base_env = dict(HOME=os.environ['HOME'], USER=os.environ['USER'], LOGNAME=os.environ['USER'],
                        LANG='en_US.UTF-8', PATH='%s:/usr/bin:/bin' % (out / 'bin'), TMPDIR=str(out / 'tmp'),
                        CONTINUUM_APP_SUPPORT=str(out / 'app-support'), CONTINUUM_ARRAY_MANAGED_AGENT='1',
                        PYTHONDONTWRITEBYTECODE='1', REPLAY_LIVE_CLAUDE=claude,
                        REPLAY_LIVE_PROXY_PORT=port_file.read_text(), REPLAY_LIVE_LOG=str(out / 'logs'))
        for index, task_json in enumerate(tasks):
            name = json.loads(Path(task_json).read_text())['fixture']
            order = sequence(arms, index)
            for position, arm in enumerate(order, 1):
                label = '%s:%s' % (name, arm)
                if only and only != label:
                    continue
                env = dict(base_env)
                if arm == 'managed-strict':
                    switch = CONFIG['strictLeadSwitch']
                    env[switch['env']] = switch['value']
                    env['REPLAY_LIVE_SWITCHES'] = switch['env']
                started = time.time()
                with open(out / 'logs' / ('%s-%s.out' % (name, arm)), 'w') as stdout, \
                        open(out / 'logs' / ('%s-%s.err' % (name, arm)), 'w') as stderr:
                    process = subprocess.Popen([binary, '--replay-live-run', task_json, str(out / 'records.jsonl'), arm,
                                                CONFIG['model'], CONFIG['effort'], str(deadline), str(out / 'runs'),
                                                '%d/%d:%s' % (position, len(order), ','.join(order))],
                                               env=env, stdout=stdout, stderr=stderr, stdin=subprocess.DEVNULL,
                                               start_new_session=True)
                    try:
                        code = process.wait(timeout=deadline + 300)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, 9)
                        code = 'killed by backstop'
                print('%s (%d/%d) exit %s after %.0fs' % (label, position, len(order), code, time.time() - started),
                      flush=True)
    finally:
        proxy.terminate()


if __name__ == '__main__':
    main(sys.argv[1:])
