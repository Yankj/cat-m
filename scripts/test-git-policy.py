#!/usr/bin/env python3
"""Exercise the real local hooks against temporary Git histories; never push or use network."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ZERO = '0' * 40
ORIGIN = 'https://github.com/Yankj/mimi.git'
SHORT_REF = 'refs/heads/fix/policy-regression'


class GitPolicyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='mimi-git-policy-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        self.env.update({
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_AUTHOR_NAME': 'Policy fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
            'GIT_COMMITTER_NAME': 'Policy fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
        })
        self.git('init', '-q', '--initial-branch=main')
        for name in ['scripts/check-git-policy.py', '.githooks/pre-push', '.githooks/pre-commit']:
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, destination)
        self.tree = self.git('mktree', input='').stdout.strip()
        # commit-tree constructs fixture objects only; hooks are exercised explicitly below.
        self.base = self.make_commit('integrated base')
        self.first = self.make_commit('reviewed feature one', self.base)
        self.second = self.make_commit('reviewed feature two', self.first)
        self.foreign = self.make_commit('unrelated legacy root')
        self.mixed = self.make_commit('unrelated history merge', self.second, self.foreign)
        self.git('update-ref', 'refs/heads/main', self.base)
        self.git('update-ref', 'refs/remotes/origin/main', self.base)
        self.git('update-ref', SHORT_REF, self.second)
        self.git('symbolic-ref', 'HEAD', SHORT_REF)

    def git(self, *args, input=None):
        return subprocess.run(['git', *args], cwd=self.root, env=self.env, input=input,
                              capture_output=True, text=True, check=True)

    def make_commit(self, message, *parents):
        args = ['commit-tree', self.tree]
        for parent in parents:
            args += ['-p', parent]
        return self.git(*args, input=message + '\n').stdout.strip()

    def hook(self, name, *args, input=''):
        return subprocess.run(['sh', str(self.root / '.githooks' / name), *args],
                              cwd=self.root, env=self.env, input=input,
                              capture_output=True, text=True)

    def refs(self, local=None, remote_ref=SHORT_REF, remote_oid=ZERO):
        return f'{SHORT_REF} {local or self.second} {remote_ref} {remote_oid}\n'

    def expect_push(self, accepted, *, remote='origin', url=ORIGIN, refs=None, reason=None):
        result = self.hook('pre-push', remote, url, input=refs or self.refs())
        self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
        if reason:
            self.assertIn(reason, result.stderr)

    def test_new_short_branch_accepts_only_reviewed_repository_urls(self):
        for url in [ORIGIN, 'https://github.com/Yankj/mimi', 'git@github.com:Yankj/mimi.git',
                    'https://github.com/Yankj/cat-m.git', 'https://github.com/Yankj/cat-m',
                    'git@github.com:Yankj/cat-m.git']:
            with self.subTest(url=url):
                self.expect_push(True, url=url)
        for url in ['https://github.com/Other/mimi.git', 'https://github.com/Yankj/other.git',
                    'https://github.com.example.invalid/Yankj/mimi.git', ORIGIN + '/extra']:
            with self.subTest(url=url):
                self.expect_push(False, url=url, reason='Unexpected origin destination')
        self.expect_push(False, remote='legacy-local', reason='Only origin may be pushed')

    def test_main_and_invalid_branch_names_are_rejected(self):
        self.expect_push(False, refs=self.refs(remote_ref='refs/heads/main'), reason='main accepts PR')
        self.expect_push(False, refs=self.refs(local=ZERO, remote_ref='refs/heads/main', remote_oid=self.base),
                         reason='main accepts PR')
        self.expect_push(False, refs=self.refs(remote_ref='refs/heads/develop'), reason='Use a short')
        self.expect_push(False, refs=self.refs() + self.refs(remote_ref='refs/heads/main'), reason='main accepts PR')

    def test_fast_forward_and_related_history_are_required(self):
        self.expect_push(True, refs=self.refs(remote_oid=self.first))
        self.expect_push(False, refs=self.refs(local=self.first, remote_oid=self.second), reason='Non-fast-forward')
        self.expect_push(False, refs=self.refs(remote_oid='f' * 40), reason='Non-fast-forward/unknown remote tip')
        self.expect_push(False, refs=self.refs(local=self.foreign), reason='Unrelated/legacy history')
        self.expect_push(False, refs=self.refs(local=self.mixed), reason='unrelated-history merge')
        self.git('update-ref', '-d', 'refs/remotes/origin/main')
        self.expect_push(False, reason='Verified origin/main reference required')

    def test_deletion_and_tags_require_integrated_history(self):
        self.expect_push(True, refs=self.refs(local=ZERO, remote_oid=self.base))
        self.expect_push(False, refs=self.refs(local=ZERO, remote_oid=self.first), reason='already contained')
        self.expect_push(True, refs=self.refs(local=self.base, remote_ref='refs/tags/v1.2.3'))
        self.expect_push(False, refs=self.refs(remote_ref='refs/tags/v1.2.3'), reason='integrated main history')

    def stage_only(self, name):
        self.git('read-tree', '--empty')
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('synthetic fixture\n')
        self.git('add', '--', name)

    def test_commit_checks_the_actual_staged_paths_and_branch(self):
        for name in ['apps/ios-conversation/Sources/Domain/Reviewed.swift',
                     'services/edge/supabase/functions/_shared/reviewed.mjs', '.env.example']:
            with self.subTest(allowed=name):
                self.stage_only(name)
                result = self.hook('pre-commit')
                self.assertEqual(result.returncode, 0, result.stderr)
        for name in ['local-audit/private.json', 'nested/node_modules/package/index.js',
                     '.build-cache/result.txt', 'apps/ios-conversation/Configuration/Local.xcconfig',
                     'apps/ios-conversation/Configuration/runtime-public.json', '.env.local',
                     'synthetic-fixture.pem', 'synthetic-build.ipa', 'synthetic-run.log']:
            with self.subTest(rejected=name):
                self.stage_only(name)
                result = self.hook('pre-commit')
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('Staged ', result.stderr)
        self.stage_only('docs/reviewed.md')
        self.git('symbolic-ref', 'HEAD', 'refs/heads/main')
        result = self.hook('pre-commit')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('main is integration-only', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
