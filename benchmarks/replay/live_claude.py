"""Stand-in for `claude` on a live replay run's PATH.

The production runner resolves `claude` from PATH, so the live driver puts
this script first and the production argv reaches it unchanged. It runs the
real CLI inside a deny-default sandbox:

- Login: the CLI's own Keychain item, read by the CLI itself through
  /usr/bin/security. CLAUDE_CONFIG_DIR moves its config, sessions and history
  into the run root; CLAUDE_SECURESTORAGE_CONFIG_DIR="" keeps the Keychain
  item name the default one. Nothing is copied, and nothing is written under
  ~/.claude (writes are allowed only inside the run root).
- Network: loopback only, to the host's egress proxy (which forwards nothing
  but the allowed provider hosts) and to this run's workspace MCP listener.
- Reads: the run root, the toolchain, the CLI binary, the workspace MCP server
  and its config files, and the Keychain files. Not the host repository, not
  the task file, not the user's home.
- Built-in subagents: `--disallowedTools Agent` on every agent, so the only
  fan-out is delegation through Array.

Environment from the driver: REPLAY_LIVE_ROOT, REPLAY_LIVE_CLAUDE,
REPLAY_LIVE_PROXY_PORT, and optionally REPLAY_LIVE_LOG (a host directory for
one launch line per process)."""
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
import sys
from urllib.parse import urlparse

HOME = Path(os.path.expanduser('~'))
TOOLCHAIN = ['/bin', '/usr/bin', '/usr/lib', '/usr/libexec', '/usr/share', '/System/Library', '/System/Cryptexes',
             '/System/Volumes/Preboot/Cryptexes', '/private/var/db/dyld', '/Library/Developer/CommandLineTools',
             '/Applications/Xcode.app/Contents', '/private/var/db/xcode_select_link',
             '/private/etc', '/private/var/db/timezone', '/Library/Preferences/Logging']
KEYCHAIN = [str(HOME / 'Library/Keychains'), '/Library/Keychains', '/private/var/db/mds',
            str(HOME / 'Library/Preferences/com.apple.security.plist'),
            '/Library/Preferences/com.apple.security.plist', '/Library/Preferences/com.apple.dt.Xcode.plist']
MACH = ['com.apple.SecurityServer', 'com.apple.securityd.xpc', 'com.apple.system.opendirectoryd.libinfo',
        'com.apple.system.opendirectoryd.membership', 'com.apple.system.notification_center',
        'com.apple.system.logger', 'com.apple.logd', 'com.apple.diagnosticd']
# Device files a shell, git and python need; never a terminal's tty.
DEVICES = ['/dev/null', '/dev/zero', '/dev/random', '/dev/urandom', '/dev/dtracehelper']
HOOK_PROBE_PARENT = os.path.realpath(subprocess.check_output(['/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR']).decode().strip()).rstrip('/')
CORE_RESOURCES = 'continuum-revived_ContinuumRevivedCore.bundle'
# Host-owned stand-ins first on the agent's PATH (read-only to the agent).
LIVE_BIN = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'live-bin')
# Single extra binaries a task's own checks may run (node runs the perf
# runner's report check); each readable and runnable by its exact path.
EXTRA_TOOLS = [os.path.realpath(t) for t in
               (shutil.which(name, path='/usr/local/bin:/opt/homebrew/bin') for name in ('node',)) if t]
XCODE_TOOLS = '/Applications/Xcode.app/Contents/Developer/usr/bin'
# The subagent tool's name, and its older one.
BUILT_IN_SUBAGENTS = 'Agent,Task'


def q(text):
    return json.dumps(str(text))


def workspace_mcp(args):
    """Paths and port of the workspace MCP server named in --mcp-config."""
    if '--mcp-config' not in args:
        return [], [], [], []
    config_path = args[args.index('--mcp-config') + 1]
    server = json.loads(Path(config_path).read_text())['mcpServers']['array_workspace']
    env = server.get('env', {})
    port = urlparse(env['ARRAY_WORKSPACE_MCP_ENDPOINT']).port
    # The sandbox matches resolved paths: /var/folders is /private/var/folders.
    # The server binary links only system libraries and the Swift runtime.
    files = [os.path.realpath(config_path), os.path.realpath(env['ARRAY_WORKSPACE_MCP_TOKEN_FILE'])]
    server_binary = os.path.realpath(server['command'])
    # Its tool catalogue is a resource in Core's bundle beside the binary;
    # without it the server lists no tools at all. Bundle.main also lists the
    # binary's own folder (names only: a literal rule, not its contents).
    folder = os.path.dirname(server_binary)
    return [server_binary], files + [folder], [os.path.join(folder, CORE_RESOURCES)], [port]


def hook_probe_folder(cwd):
    """Array's hook probe (AgentHookSurfaceCatalog) runs the CLI in its own
    fresh folder in the user's temp directory and has a hook touch a marker
    there. That launch, and only that one, may write in that one folder."""
    cwd = os.path.realpath(cwd)
    if os.path.dirname(cwd) == HOOK_PROBE_PARENT and os.path.basename(cwd).startswith('array-hook-probe-'):
        return cwd
    return None


def profile(root, claude, proxy_port, programs=(), extra_files=(), extra_folders=(), extra_ports=(), probe_folder=None):
    """Exec: the toolchain, the run root, the CLI and the MCP server binary.
    Read: those, plus the Keychain files and the MCP config and token files.
    Write: the run root and a few device files. Metadata (stat) is readable
    everywhere; directory listings and contents are not."""
    readable = TOOLCHAIN + KEYCHAIN + [root, LIVE_BIN] + list(extra_folders)
    programs = [claude] + list(programs) + EXTRA_TOOLS
    literals = programs + list(extra_files)
    executable = TOOLCHAIN + [root, LIVE_BIN]
    writable = [root] + ([probe_folder] if probe_folder else [])
    ports = [proxy_port] + list(extra_ports)
    return ''.join([
        '(version 1)(deny default)',
        '(allow process-fork)(allow sysctl-read)(allow signal (target same-sandbox))',
        '(allow file-read-metadata)(allow ipc-posix-shm)(allow ipc-posix-sem)',
        '(allow process-exec ', ' '.join('(subpath %s)' % q(p) for p in executable), ' ',
        ' '.join('(literal %s)' % q(p) for p in programs), ')',
        '(allow file-read* (literal "/") (subpath "/dev/fd") ',
        ' '.join('(subpath %s)' % q(p) for p in readable), ' ',
        ' '.join('(literal %s)' % q(p) for p in literals + DEVICES), ')',
        '(allow file-write* (subpath "/dev/fd") ',
        ' '.join('(literal %s)' % q(p) for p in DEVICES), ' ',
        ' '.join('(subpath %s)' % q(p) for p in writable), ')',
        '(allow file-ioctl (literal "/dev/dtracehelper"))',
        '(allow network-outbound ', ' '.join('(remote tcp %s)' % q('localhost:%d' % p) for p in ports), ')',
        '(allow mach-lookup ', ' '.join('(global-name %s)' % q(m) for m in MACH), ')'])


def main(argv):
    env = os.environ
    root = os.path.realpath(env['REPLAY_LIVE_ROOT'])
    claude = os.path.realpath(env['REPLAY_LIVE_CLAUDE'])
    port = int(env['REPLAY_LIVE_PROXY_PORT'])
    programs, files, folders, ports = workspace_mcp(argv)
    config = Path(root) / 'claude-config'
    config.mkdir(exist_ok=True)
    child = {k: v for k, v in env.items() if not k.startswith('REPLAY_LIVE_')}
    proxy = 'http://127.0.0.1:%d' % port
    # Xcode's own git and python3 first: the /usr/bin shims need a cache in the
    # user's temp folder, which is outside the run.
    child['PATH'] = ':'.join([LIVE_BIN, XCODE_TOOLS, child.get('PATH', '/usr/bin:/bin')]
                             + sorted({os.path.dirname(t) for t in EXTRA_TOOLS}))
    child.update(CLAUDE_CONFIG_DIR=str(config), CLAUDE_SECURESTORAGE_CONFIG_DIR='',
                 HTTPS_PROXY=proxy, HTTP_PROXY=proxy, https_proxy=proxy, http_proxy=proxy,
                 NO_PROXY='localhost,127.0.0.1', no_proxy='localhost,127.0.0.1',
                 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1',
                 TMPDIR=str(Path(root) / 'tmp'), CLAUDE_CODE_TMPDIR=str(Path(root) / 'tmp'),
                 TMPPREFIX=str(Path(root) / 'tmp' / 'zsh'),
                 # The user's git config is unreadable here; a placeholder identity
                 # lets a helper commit inside the run.
                 XDG_CONFIG_HOME=str(Path(root) / 'tmp' / 'xdg'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
                 GIT_AUTHOR_NAME='replay agent', GIT_AUTHOR_EMAIL='replay@invalid',
                 GIT_COMMITTER_NAME='replay agent', GIT_COMMITTER_EMAIL='replay@invalid')
    args = ['--disallowedTools', BUILT_IN_SUBAGENTS] + argv
    if env.get('REPLAY_LIVE_LOG'):
        with open(os.path.join(env['REPLAY_LIVE_LOG'], 'launches.jsonl'), 'a') as log:
            log.write(json.dumps(dict(pid=os.getpid(), cwd=os.getcwd(), root=root, args=args, ports=[port] + ports)) + '\n')
    sandbox = profile(root, claude, port, programs, files, folders, ports, hook_probe_folder(os.getcwd()))
    os.execve('/usr/bin/sandbox-exec', ['/usr/bin/sandbox-exec', '-p', sandbox, claude] + args, child)


if __name__ == '__main__':
    main(sys.argv[1:])
