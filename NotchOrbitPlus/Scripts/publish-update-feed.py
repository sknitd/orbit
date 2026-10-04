#!/usr/bin/env python3
"""Publish a real stable feed and immutable ZIP using the existing Git remote authorization."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'NotchOrbitPlus'
BRANCH = 'codex/notch-plus-updates'


def git(*args, input=None, environment=None):
    return subprocess.check_output(['git', *args], cwd=ROOT, input=input, env=environment)


def main():
    source = os.environ.get('GITHUB_SHA') or git('rev-parse', 'HEAD').decode().strip()
    if not re.fullmatch(r'[a-f0-9]{40}', source):
        raise SystemExit('A concrete source commit is required.')
    verification = json.loads((APP / 'build/package-verification.json').read_text())
    signing = json.loads((APP / 'build/distribution-signing.json').read_text())
    version = verification['version']
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise SystemExit('The public channel requires a stable three-part version.')
    package = APP / 'dist/NotchOrbitPlus.app.zip'
    digest = hashlib.file_digest(package.open('rb'), 'sha256').hexdigest()
    recorded = (APP / 'dist/NotchOrbitPlus.app.zip.sha256').read_text().split()[0]
    if digest != recorded or not verification['codesign_verified']:
        raise SystemExit('The application checksum/signature evidence is invalid.')
    prefix = f'packages/{version}/{source}'
    manifest = {'schema_version': 1, 'product': 'NotchOrbitPlus', 'bundle_identifier': verification['bundle_identifier'],
                'version': version, 'minimum_macos': verification['minimum_macos'], 'source_commit': source,
                'archive_url': f'https://raw.githubusercontent.com/sknitd/orbit/{BRANCH}/{prefix}/NotchOrbitPlus.app.zip',
                'archive_sha256': digest, 'archive_bytes': package.stat().st_size,
                'release_notes_url': f'https://github.com/sknitd/orbit/tree/{source}/NotchOrbitPlus',
                'published_at': datetime.now(timezone.utc).isoformat(),
                'signing': {key: signing[key] for key in ('kind', 'team_identifier', 'notarized')}}
    manifest_bytes = (json.dumps(manifest, indent=2) + '\n').encode()
    (APP / 'build/update-feed.json').write_bytes(manifest_bytes)
    if os.environ.get('NOTCHORBITPLUS_UPDATE_FEED_DRY_RUN') == '1':
        print('Generated reviewable feed; no Git publication was requested.')
        return
    if os.environ.get('GITHUB_REF_NAME'):
        remote_source = git('ls-remote', '--heads', 'origin', os.environ['GITHUB_REF_NAME']).decode().split()
        if not remote_source or remote_source[0] != source:
            raise SystemExit('A newer source is present; the obsolete build cannot update the stable channel.')
    remote = git('ls-remote', '--heads', 'origin', BRANCH).decode().split()
    parent = remote[0] if remote else None
    if parent:
        git('fetch', '--no-tags', 'origin', f'refs/heads/{BRANCH}')
        previous = json.loads(git('show', parent + ':stable.json'))
        if tuple(map(int, previous['version'].split('.'))) > tuple(map(int, version.split('.'))):
            raise SystemExit('Refusing to downgrade the stable update channel.')
        existing = subprocess.run(['git', 'cat-file', '-e', parent + ':' + prefix + '/NotchOrbitPlus.app.zip'], cwd=ROOT, capture_output=True)
        if existing.returncode == 0:
            old_digest = hashlib.sha256(git('show', parent + ':' + prefix + '/NotchOrbitPlus.app.zip')).hexdigest()
            if old_digest != digest:
                raise SystemExit('This version/source already has an immutable archive with a different checksum; publication was refused.')
    with tempfile.TemporaryDirectory(prefix='notchorbitplus-update-index-') as directory:
        environment = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / 'index'))
        git('read-tree', parent if parent else '--empty', environment=environment)
        files = {'stable.json': manifest_bytes, prefix + '/update-feed.json': manifest_bytes,
                 prefix + '/NotchOrbitPlus.app.zip': package.read_bytes(),
                 prefix + '/NotchOrbitPlus.app.zip.sha256': (APP / 'dist/NotchOrbitPlus.app.zip.sha256').read_bytes()}
        for path, contents in files.items():
            blob = git('hash-object', '-w', '--stdin', input=contents).decode().strip()
            git('update-index', '--add', '--cacheinfo', '100644', blob, path, environment=environment)
        tree = git('write-tree', environment=environment).decode().strip()
        commit_arguments = ['-c', 'user.name=github-actions', '-c', 'user.email=github-actions@users.noreply.github.com',
                            'commit-tree', tree]
        if parent:
            commit_arguments += ['-p', parent]
        commit = git(*commit_arguments, input=f'Publish NotchOrbitPlus {version} from {source}\n'.encode()).decode().strip()
        git('push', 'origin', f'{commit}:refs/heads/{BRANCH}')
    report = {'published': True, 'source_commit': source, 'feed_commit': commit,
              'channel_url': f'https://raw.githubusercontent.com/sknitd/orbit/{BRANCH}/stable.json',
              'version': version, 'archive_sha256': digest, 'archive_bytes': package.stat().st_size,
              'notarized': signing['notarized']}
    (APP / 'build/update-publication.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Published the actual stable manifest and checksum-matched application archive.')


if __name__ == '__main__':
    main()
