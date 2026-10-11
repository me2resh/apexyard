"""Synthetic counting-rule and offline CLI regression tests."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4]
SCRIPT = ROOT / 'bin/token-cost.py'
FIXTURES = Path(__file__).resolve().parent / 'fixtures'
spec = importlib.util.spec_from_file_location('token_cost', SCRIPT)
tc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tc)


def stamp(seconds=0):
    return '2030-01-01T%02d:%02d:%02dZ' % (seconds // 3600, seconds // 60 % 60, seconds % 60)


def assistant(n, seconds=0, commands=(), inp=10, cc=0, cr=90, hour=0):
    return {'type': 'assistant', 'timestamp': stamp(seconds), 'message': {
        'id': 'msg_%03d' % n,
        'usage': {'input_tokens': inp, 'cache_creation_input_tokens': cc,
                  'cache_read_input_tokens': cr, 'output_tokens': 5,
                  'cache_creation': {'ephemeral_5m_input_tokens': cc,
                                     'ephemeral_1h_input_tokens': hour}},
        'content': [{'type': 'tool_use', 'id': 'toolu_%03d_%d' % (n, i),
                     'name': name, 'input': {'command': cmd}}
                    for i, (name, cmd) in enumerate(commands)]}}


def bash(command):
    return [('Bash', command)]


def user(content, seconds=0):
    return {'type': 'user', 'timestamp': stamp(seconds), 'message': {'content': content}}


def write_jsonl(path, records):
    path.write_text(''.join(json.dumps(r) + '\n' for r in records), encoding='utf-8')


def commit(oid, seconds, parents=None, headline='fixture text'):
    result = {'oid': oid, 'committedDate': stamp(seconds), 'messageHeadline': headline}
    if parents is not None:
        result['parents'] = parents
    return result


def review(head, seconds, verdict='APPROVED', heading='Code Review'):
    return {'body': 'fixture text\n## %s\nVerdict: %s' % (heading, verdict),
            'state': verdict, 'submittedAt': stamp(seconds), 'commit': {'oid': head}}


def pr(commits=None, reviews=None):
    return {'number': 12, 'createdAt': stamp(), 'mergedAt': stamp(7200),
            'baseRefName': 'dev', 'files': [{'path': 'docs/orbit/fixture.md'}],
            'reviews': reviews or [], 'comments': [], 'commits': commits or []}


class TokenCostTests(unittest.TestCase):
    def run_records(self, records):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'session.jsonl'
            write_jsonl(path, records)
            return tc.measure_run(str(path), tc.Window())

    def cli(self, *args, code=0):
        # No test uses forge without --forge-from. Tool commands remain inert JSON.
        result = subprocess.run([sys.executable, '-I', str(SCRIPT)] + list(map(str, args)),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stderr)
        return result.stdout

    def test_ci_wait_first_and_second_check(self):
        self.assertEqual(self.run_records([assistant(1, commands=bash('gh pr checks 12'))])['ci_wait_turns'], 0)
        self.assertEqual(self.run_records([assistant(1, commands=bash('gh pr checks 12')),
                                          assistant(2, commands=bash('gh pr checks 12'))])['ci_wait_turns'], 1)

    def test_ci_wait_exemption_spent_by_check_in_multi_tool_turn(self):
        # The first checks call of the run uses up the exemption even when it
        # shares its turn with another tool, so a later lone check counts.
        run = self.run_records([
            assistant(1, commands=bash('gh pr checks 12') + bash('echo fixture')),
            assistant(2, commands=bash('gh pr checks 12'))])
        self.assertEqual(run['ci_wait_turns'], 1)
        # A poll that is not a plain check does not use up the exemption.
        run = self.run_records([
            assistant(1, commands=bash('gh run view 1') + bash('echo fixture')),
            assistant(2, commands=bash('gh pr checks 12'))])
        self.assertEqual(run['ci_wait_turns'], 0)

    def test_watch_flag_counts_only_for_ci_commands(self):
        for command, expected in [('gh pr checks 12 --watch', 1), ('gh run watch 1', 1),
                                  ('npm test -- --watch', 0), ('fixture-tool --watch', 0)]:
            with self.subTest(command=command):
                self.assertEqual(self.run_records([assistant(1, commands=bash(command))])['ci_wait_turns'], expected)

    def test_session_tolerates_wrong_type_fields(self):
        data = json.loads(self.cli('session', '--transcript', FIXTURES / 'session-malformed.jsonl'))
        self.assertEqual(data['api_turns'], 2)
        self.assertEqual(data['compactions']['count'], 1)
        self.assertEqual(data['compactions']['mean_pre'], 0)
        self.assertEqual(data['context_per_turn']['max'], 100)

    def test_ci_wait_only_tool(self):
        for commands in [bash('gh run view 1') + bash('echo fixture'), bash('echo fixture')]:
            with self.subTest(commands=commands):
                self.assertEqual(self.run_records([assistant(1, commands=commands)])['ci_wait_turns'], 0)

    def test_ci_watch_sleep_and_poll(self):
        for command in ['gh pr checks --watch', 'gh run watch 1',
                        'sleep 60 && gh pr checks 1', 'sleep 120']:
            with self.subTest(command=command):
                self.assertEqual(self.run_records([assistant(1, commands=bash(command))])['ci_wait_turns'], 1)

    def test_cache_rebuild_threshold_and_first_request(self):
        for cc, expected in [(49, 0), (50, 0), (51, 1)]:
            with self.subTest(cc=cc):
                records = [assistant(1, cc=99, inp=1, cr=0, commands=bash('echo fixture')),
                           assistant(2, cc=cc, inp=20, cr=80-cc)]
                self.assertEqual(self.run_records(records)['cache_rebuilds'], expected)
        self.assertEqual(self.run_records([assistant(1, cc=99, inp=1, cr=0)])['cache_rebuilds'], 0)

    def test_resume_handback_and_ci_green(self):
        for tools in [[], [('SubagentHandback', 'fixture text')]]:
            for text, green in [('fixture text', 0), ('CI is now green', 1)]:
                with self.subTest(tools=tools, text=text):
                    run = self.run_records([assistant(1, commands=tools), user(text, 1),
                                            assistant(2, 2, cc=90, cr=0)])
                    self.assertEqual((run['resumes'], run['resume_rebuilds'],
                                      run['resume_rebuilds_ci_green']), (1, 1, green))
        run = self.run_records([assistant(1), assistant(2)])
        self.assertEqual((run['resumes'], run['resume_rebuilds']), (1, 0))

    def test_long_wait_boundary_and_rebuild(self):
        for delay, cc, expected in [(299, 90, (0, 0)), (300, 90, (1, 1)),
                                    (301, 90, (1, 1)), (300, 0, (1, 0))]:
            with self.subTest(delay=delay, cc=cc):
                run = self.run_records([assistant(1, commands=bash('gh run watch 1')),
                    user([{'type': 'tool_result', 'tool_use_id': 'toolu_001_0', 'content': 'ok'}], delay),
                    assistant(2, delay+1, cc=cc, cr=0)])
                self.assertEqual((run['long_waits'], run['long_wait_rebuilds']), expected)

    def test_reviewer_cli_ttl_and_nonreviewers(self):
        data = json.loads(self.cli('reviewers', '--subagents', FIXTURES / 'subagents'))
        self.assertEqual(data['reviewer_runs'], 3)
        self.assertEqual(data['all_reviewers_by_ttl']['1h']['runs'], 1)
        self.assertEqual(data['all_reviewers_by_ttl']['5m']['runs'], 2)
        self.assertEqual(data['per_reviewer']['Rex']['by_ttl']['1h']['runs'], 1)
        self.assertEqual(set(data['other_agents']), {'contrarian', 'fork'})
        self.assertEqual(data['all_reviewers']['resume_rebuilds_ci_green'], 1)
        self.assertEqual(data['resume_rebuilds_excluding_ci_green'], 1)
        self.assertEqual(data['resume_rebuilds_per_100_runs'], 33.33)

    def test_session_cli_metrics(self):
        # tracked_skills() reads `git ls-files`. Outside a git work tree every
        # skill is "other" by design, so the skill assertions need a checkout.
        if not tc.tracked_skills(str(ROOT)):
            self.skipTest('not a git work tree: tracked skills are unknown')
        data = json.loads(self.cli('session', '--transcript', FIXTURES / 'session.jsonl'))
        self.assertEqual(data['api_turns'], 10)
        self.assertEqual(data['context_per_turn']['mean'], 550)
        self.assertEqual(data['context_per_turn']['p90'], 1000)
        self.assertEqual(data['tokens']['output'], 50)
        self.assertEqual(data['compactions']['count'], 3)
        self.assertEqual(data['compactions']['near_cap'], 2)
        self.assertEqual(data['auto_code_review_banners'], 1)
        skills = {r['skill']: r for r in data['skills']}
        self.assertEqual(set(skills), {'approve-merge', 'other'})
        self.assertEqual(skills['other']['injections'], 1)
        self.assertEqual(skills['approve-merge']['compaction_reinjections'], 1)
        self.assertAlmostEqual(sum(r['share_pct'] for r in data['context_share_by_category']), 100, delta=.05)
        self.assertEqual(data['cache']['rebuilds_during_ci_wait'], 1)

    def test_session_until(self):
        data = json.loads(self.cli('session', '--transcript', FIXTURES / 'session.jsonl', '--until', stamp(2)))
        self.assertEqual(data['api_turns'], 2)
        self.assertEqual(data['compactions']['count'], 0)

    def test_report_markdown_privacy_and_hash(self):
        path = FIXTURES / 'session.jsonl'
        raw = path.read_bytes()
        for until, prefix in [(stamp(100), raw), (stamp(2), b''.join(
                line for line in raw.splitlines(keepends=True)
                if json.loads(line)['timestamp'] <= stamp(2)))]:
            with self.subTest(until=until):
                args = ('report', '--transcript', path, '--subagents', FIXTURES / 'subagents',
                        '--forge-from', FIXTURES / 'forge.json', '--until', until)
                md = self.cli(*args, '--format', 'md')
                self.assertNotIn(str(FIXTURES), md)
                self.assertNotIn('fixture text', md)
                self.assertIn('Transcript SHA-256', md)
                self.assertIn('<session.jsonl>', md)
                digest = hashlib.sha256(prefix).hexdigest()
                self.assertIn(digest, md)
                report = json.loads(self.cli(*args))
                self.assertEqual(report['meta']['transcript_sha256'], digest)

    def test_round_dedup_verdict_and_reviewer_identity(self):
        data = pr([commit('head_001', 1)], [review('head_001', 2, 'COMMENT'),
                  review('head_001', 3, 'COMMENT'), review('head_001', 4),
                  review('head_001', 5, heading='Security Review'),
                  review('head_001', 6, heading='Design Review'),
                  {'body': '', 'state': 'APPROVED', 'submittedAt': stamp(7)}])
        result = tc.analyze_pr(data)
        self.assertEqual((result['rex_rounds'], result['hakim_rounds'], result['tariq_rounds']), (2, 1, 1))
        self.assertIsNone(tc.reviewer_of('fixture ## Code Review'))

    def test_comment_head_at_post_time(self):
        data = pr([commit('head_001', 1), commit('head_002', 10)])
        data['comments'] = [{'body': '## Code Review\nVerdict: APPROVED', 'createdAt': stamp(s)} for s in (2, 3, 11)]
        self.assertEqual(tc.analyze_pr(data)['rex_rounds'], 2)

    def test_refresh_only_base_merges(self):
        for middle, expected in [([commit('head_002', 3, ['head_001', 'base_001']),
                                  commit('head_003', 5, ['head_002', 'base_002'])], (2, 1)),
                                 ([commit('head_002', 3, ['head_001'])], (0, 0)),
                                 ([commit('head_002', 3, ['head_001', 'head_003']),
                                   commit('head_003', 5, ['head_002'])], (0, 0))]:
            with self.subTest(middle=middle):
                data = pr([commit('head_001', 1)] + middle,
                          [review('head_001', 2), review(middle[-1]['oid'], 6, 'COMMENT')])
                result = tc.analyze_pr(data)
                self.assertEqual((result['refresh_events'], result['pure_refresh_rounds']), expected)

    def test_refresh_requires_approval_and_stops_at_nonmerge(self):
        commits = [commit('head_001', 1), commit('head_002', 3, ['head_001', 'base_001']),
                   commit('head_003', 5, ['head_002']), commit('head_004', 7, ['head_003', 'base_002'])]
        for verdict, events in [('CHANGES REQUESTED', 0), ('APPROVED', 1)]:
            result = tc.analyze_pr(pr(commits, [review('head_001', 2, verdict), review('head_004', 8, 'COMMENT')]))
            self.assertEqual(result['refresh_events'], events)
            self.assertEqual(result['pure_refresh_rounds'], 0)

    def test_refresh_needs_an_approved_head(self):
        commits = [commit('head_001', 1), commit('head_002', 3, ['head_001', 'base_001'])]
        for verdict, expected in [('CHANGES REQUESTED', (0, 0)), ('COMMENT', (0, 0)), ('APPROVED', (1, 1))]:
            with self.subTest(verdict=verdict):
                result = tc.analyze_pr(pr(commits, [review('head_001', 2, verdict), review('head_002', 4)]))
                self.assertEqual((result['refresh_events'], result['pure_refresh_rounds']), expected)

    def test_report_takes_several_forge_samples(self):
        args = ('report', '--forge-from', FIXTURES / 'forge.json', '--forge-from', FIXTURES / 'forge.json')
        report = json.loads(self.cli(*args))
        self.assertEqual(len(report['forge_samples']), 1)
        self.assertEqual(report['metrics']['forge.sample2.prs'], report['metrics']['forge.prs'])
        md = self.cli(*args, '--format', 'md')
        headings = [line for line in md.splitlines() if line.startswith('## Forge view')]
        self.assertEqual(len(headings), 2)
        self.cli('forge', '--forge-from', FIXTURES / 'forge.json', '--forge-from', FIXTURES / 'forge.json', code=2)

    def test_agent_ids_filter(self):
        with tempfile.TemporaryDirectory() as directory:
            ids = Path(directory) / 'ids.txt'
            ids.write_text('a000000000000001\n', encoding='utf-8')
            data = json.loads(self.cli('reviewers', '--subagents', FIXTURES / 'subagents', '--agent-ids', ids))
        self.assertEqual(data['reviewer_runs'], 1)

    def test_refresh_headline_fallback(self):
        for headline, expected in [("Merge branch 'dev'", 1), ("Merge branch 'other'", 0)]:
            data = pr([commit('head_001', 1), commit('head_002', 3, headline=headline)],
                      [review('head_001', 2), review('head_002', 4, 'COMMENT')])
            result = tc.analyze_pr(data)
            self.assertEqual(result['pure_refresh_rounds'], expected)
            self.assertEqual(result['refresh_events'], expected)

    def test_records_pr_rules(self):
        orbit = ['docs/orbit/fixture.md', 'docs/orbit/nested/fixture.md']
        agdr = 'docs/agdr/AgDR-0001-fixture.md'
        for paths, expected in [(orbit, True), (orbit+[agdr], True),
                (orbit+[agdr, 'docs/agdr/AgDR-0002-fixture.md'], False),
                (orbit+['bin/fixture.py'], False), ([agdr], False), ([], False)]:
            with self.subTest(paths=paths):
                self.assertEqual(tc.is_records_pr(paths), expected)

    def test_forge_cli_means(self):
        data = json.loads(self.cli('forge', '--forge-from', FIXTURES / 'forge.json'))
        self.assertEqual(data['prs'], 2)
        self.assertEqual(data['rex_rounds_per_pr_mean'], 1.5)
        self.assertEqual(data['hours_open_to_merge_mean'], 3)
        self.assertEqual(data['per_pr'][0]['hours_open_to_merge'], 2)

    def test_forge_rejects_other_repo(self):
        self.cli('forge', '--forge-from', FIXTURES / 'forge-other.json', code=1)

    def test_lock_blocks_count_once_per_tool_call(self):
        block_text = ('PreToolUse:Bash hook error: [dispatch]: BLOCKED: review-class agent is read-only '
                      'while an active review is in flight.')

        def result(tool_id, text, seconds):
            return {'type': 'user', 'timestamp': stamp(seconds), 'message': {'content': [
                {'type': 'tool_result', 'tool_use_id': tool_id, 'is_error': True, 'content': text}]}}

        records = [
            assistant(1, 1, bash('git ' + 'commit -m x')),
            result('toolu_001_0', block_text, 2),
            assistant(2, 3, bash('git -C repo ' + 'push origin x')),
            result('toolu_002_0', block_text, 4),
            assistant(3, 5, bash('git status')),
            result('toolu_003_0', 'Exit code 1\nissue text: ' + block_text, 6),
            assistant(4, 7, bash('git clone x')),
            result('toolu_004_0', block_text.replace('is read-only while an active review', 'cannot'), 8),
        ]
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / 'a.jsonl'
            second = Path(directory) / 'b.jsonl'
            write_jsonl(first, records)
            write_jsonl(second, records[:2])  # a resumed session repeats an earlier call
            data = json.loads(self.cli('locks', '--transcript', first, '--transcript', second))
        self.assertEqual(data['blocks'], {'total': 3, 'git_commit': 1, 'git_push': 1,
                                          'other': 1, 'commit_or_push': 2})
        self.assertEqual(data['by_day']['2030-01-01']['total'], 3)
        self.assertEqual(data['transcripts'], 2)

    def test_git_subcommands_are_fast_and_exact(self):
        import time
        flags = ' '.join('-c k%d=v' % i for i in range(100)) + ' ' + ' '.join('--flag%d' % i for i in range(100))
        started = time.time()
        found = tc.git_subcommands('git ' + flags + ' ' + 'commit -m x')
        self.assertLess(time.time() - started, 1)
        self.assertEqual(found, ['commit'])
        long_miss = 'git ' + ' '.join('-x%d' % i for i in range(200)) + ' status'
        started = time.time()
        self.assertEqual(tc.git_subcommands(long_miss), ['status'])
        self.assertLess(time.time() - started, 1)
        self.assertEqual(tc.git_subcommands('cd r && git -C r ' + 'push origin x; echo git commit'), ['push'])
        self.assertEqual(tc.git_subcommands('echo "git commit"'), [])
        self.assertEqual(tc.git_subcommands('GIT_AUTHOR_NAME=a git ' + 'commit -m x'), ['commit'])

    def test_compare_cli_change_pct(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ('before.json', 'after.json')]
            for path, value in zip(paths, (80, 100)):
                path.write_text(json.dumps({'forge': {'rex_rounds': value}}), encoding='utf-8')
            rows = json.loads(self.cli('compare', *paths))
        self.assertEqual(rows, [{'metric': 'forge.rex_rounds', 'before': 80, 'after': 100, 'change_pct': 25.0}])
        self.assertEqual(tc.compare({'forge': {'prs': 100}}, {'forge': {'prs': 80}})[0]['change_pct'], -20)


if __name__ == '__main__':
    unittest.main()
