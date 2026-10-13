#!/usr/bin/env python3
"""Local CLI guard. No Git writes/network; connector writes require separate review."""
import re
import subprocess
import sys
from pathlib import Path

ZERO = '0' * 40
SHORT = re.compile(r'^(feat|fix|docs|refactor|test|chore)/[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)?$')

def git(*args):
    return subprocess.run(['git', *args], capture_output=True)

def require(condition, message):
    if not condition:
        raise ValueError(message)

def ancestor(a, b):
    return git('merge-base', '--is-ancestor', a, b).returncode == 0

def branch(name):
    require(bool(SHORT.fullmatch(name)), 'Use a short feat/fix/docs/refactor/test/chore branch; main is integration-only.')

def commit():
    current = git('branch', '--show-current')
    require(current.returncode == 0, 'Cannot determine current branch.')
    branch(current.stdout.decode().strip())
    paths = git('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z')
    require(paths.returncode == 0, 'Cannot inspect staged paths.')
    for name in (x.decode() for x in paths.stdout.split(b'\0') if x):
        p = Path(name)
        require(not any(x in ['local-audit', 'node_modules', 'DerivedData', 'xcuserdata', '.aws', '.codex']
                        or x.startswith('.build') for x in p.parts), 'Staged runtime/private directory: ' + name)
        require(not (p.name.startswith('.env') and p.name != '.env.example'), 'Staged local environment file.')
        require(p.name not in ['Local.xcconfig', 'runtime-public.json'], 'Staged machine runtime configuration.')
        require(p.suffix.lower() not in ['.pem', '.key', '.p12', '.mobileprovision', '.ipa', '.log', '.zip'],
                'Staged credential or generated artifact: ' + name)
    print('PASS short branch and staged-path policy; content sensitivity requires scan-repository.py')

def push(remote, url):
    require(remote == 'origin', 'Only origin may be pushed; legacy-local is read-only.')
    require(url in ['https://github.com/Yankj/catpaw-m.git', 'https://github.com/Yankj/catpaw-m',
                    'git@github.com:Yankj/catpaw-m.git'], 'Unexpected origin destination.')
    require(git('rev-parse', '--verify', 'refs/remotes/origin/main').returncode == 0,
            'Verified origin/main reference required.')
    for line in sys.stdin:
        fields = line.strip().split()
        require(len(fields) == 4, 'Invalid push input.')
        local_ref, local_oid, remote_ref, remote_oid = fields
        require(remote_ref != 'refs/heads/main', 'main accepts PR integration only; direct CLI push/delete blocked.')
        if remote_ref.startswith('refs/heads/'):
            branch(remote_ref.removeprefix('refs/heads/'))
        else:
            require(bool(re.fullmatch(r'refs/tags/v[0-9][a-zA-Z0-9.-]*', remote_ref)), 'Only version tags or short branches may be pushed.')
        if local_oid == ZERO:
            require(remote_ref.startswith('refs/heads/') and ancestor(remote_oid, 'origin/main'),
                    'Only branches already contained in verified main may be deleted.')
            continue
        require(bool(re.fullmatch(r'[a-f0-9]{40}', local_oid)), 'Invalid local commit identity.')
        target = git('rev-parse', local_oid + '^{commit}')
        require(target.returncode == 0, 'Push target must resolve to a commit.')
        target = target.stdout.decode().strip()
        if remote_oid != ZERO:
            require(ancestor(remote_oid, local_oid), 'Non-fast-forward/unknown remote tip rejected; reread remote before updating.')
        if remote_ref.startswith('refs/tags/'):
            require(ancestor(target, 'origin/main'), 'Release tags must name integrated main history.')
            continue
        base = git('merge-base', target, 'origin/main')
        require(base.returncode == 0 and bool(base.stdout.strip()), 'Unrelated/legacy history cannot be pushed.')
        base = base.stdout.decode().strip()
        commits = git('rev-list', target, '^origin/main')
        require(commits.returncode == 0, 'Cannot verify outgoing history.')
        require(all(ancestor(base, c) for c in commits.stdout.decode().splitlines()),
                'Outgoing history contains an unrelated-history merge; import reviewed bytes instead.')
    print('PASS destination, protected main, fast-forward and history policy')

try:
    mode = sys.argv[1]
    if mode == 'branch':
        branch(sys.argv[2]); print('PASS branch name')
    elif mode == 'commit':
        commit()
    elif mode == 'push':
        push(sys.argv[2], sys.argv[3])
    else:
        raise ValueError('Mode must be branch, commit or push.')
except (ValueError, IndexError) as error:
    print('REJECT:', error, file=sys.stderr)
    sys.exit(1)
