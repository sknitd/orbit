#!/usr/bin/env python3
"""Read-only Git inspection of CornerOrbit's strict new-directory boundary.

No checkout, remote, index, branch or repository configuration is changed. The
report is confined to CornerOrbit/Validation and is not a product test result.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


BASE = '3b8647749e770c85e6faa9cf34e65bfe4a2d6242'


def git(repository, *arguments):
    return subprocess.check_output(['git', '-C', str(repository), *arguments], stderr=subprocess.PIPE)


def paths(value):
    return [item.decode('utf-8', errors='strict') for item in value.split(b'\0') if item]


def inspect(repository, base, source, include_working_tree):
    for commit in (base, source):
        if not re.fullmatch(r'[0-9a-f]{40}', commit):
            raise ValueError('Supply immutable full base/source commit SHAs.')
        if git(repository, 'rev-parse', commit + '^{commit}').decode().strip() != commit:
            raise ValueError('Commit is not available locally: ' + commit)
    subprocess.run(['git', '-C', str(repository), 'merge-base', '--is-ancestor', base, source], check=True, capture_output=True)
    committed = paths(git(repository, 'diff', '--no-renames', '--name-only', '-z', base, source))
    working, untracked = [], []
    if include_working_tree:
        working = paths(git(repository, 'diff', '--no-renames', '--name-only', '-z', source))
        untracked = paths(git(repository, 'ls-files', '--others', '--exclude-standard', '-z'))
    changed = sorted(set(committed + working + untracked))
    violations = [path for path in changed if not path.startswith('CornerOrbit/')]
    if not include_working_tree and not committed:
        raise ValueError('No committed CornerOrbit changes: this is not a completed implementation audit.')
    if any(path == 'CornerOrbit' for path in changed):
        violations.append('CornerOrbit')
    return {'outcome': 'failed' if violations else 'passed', 'base_commit': base, 'source_commit': source,
            'working_tree_inspected': include_working_tree, 'committed_changed_paths': committed,
            'working_tree_changed_paths': sorted(set(working)), 'untracked_paths': untracked,
            'outside_cornerorbit_paths': sorted(set(violations)), 'changed_path_count': len(changed),
            'scope': 'All changed tracked paths are compared to the immutable base; deletions/renames cannot conceal changes outside CornerOrbit/.',
            'limitations': ['Git content/path isolation does not prove that the running app avoids user-file effects.',
                'Ignored build outputs are not tracked source changes and are inspected separately as package/runtime evidence.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--base', default=BASE)
    parser.add_argument('--source-commit')
    parser.add_argument('--working-tree', action='store_true', help='Include tracked/index changes and non-ignored untracked paths.')
    parser.add_argument('--report-file', type=Path)
    args = parser.parse_args()
    source = args.source_commit or git(args.repository, 'rev-parse', 'HEAD').decode().strip()
    report_path = args.report_file or Path(__file__).resolve().parent / 'independent-isolation.json'
    allowed = Path(__file__).resolve().parent
    if not report_path.resolve().is_relative_to(allowed):
        parser.error('Write reports only inside CornerOrbit/Validation/.')
    try:
        report = inspect(args.repository, args.base, source, args.working_tree)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        report = {'outcome': 'failed', 'base_commit': args.base, 'source_commit': source, 'failure': str(error)}
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in report if key in ('outcome', 'source_commit', 'changed_path_count', 'outside_cornerorbit_paths', 'failure')}, indent=2))
    return 0 if report['outcome'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
