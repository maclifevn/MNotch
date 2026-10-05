#!/usr/bin/env python3
"""Local Sparkle release preparation; publication is a separate explicit command."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

from update_metadata import archive_metadata, check_upgrade, version_tuple

ROOT = Path(__file__).resolve().parent.parent


def run(command, *, capture=False, environment=None):
    return subprocess.run(command, cwd=ROOT, env=environment, check=True,
                          text=True, capture_output=capture).stdout


def preflight(version):
    version_tuple(version)
    notes = ROOT / 'ReleaseNotes' / (version + '.md')
    if not notes.is_file() or not notes.stat().st_size:
        raise ValueError('add ReleaseNotes/' + version + '.md first')
    if run(['git', 'status', '--porcelain'], capture=True).strip():
        raise ValueError('release source must be committed and clean')
    head = run(['git', 'rev-parse', 'HEAD'], capture=True).strip()
    tag = run(['git', 'rev-parse', f'v{version}^{{commit}}'], capture=True).strip()
    if tag != head:
        raise ValueError('release tag must identify the exact checked-out commit')
    build = os.environ.get('BUILD_NUMBER') or run(['git', 'rev-list', '--count', 'HEAD'], capture=True).strip()
    if not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('BUILD_NUMBER must be a positive integer')
    return notes, head, build


def signing_preflight(environment):
    binary = ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
    if not binary.is_file():
        run(['swift', 'package', 'resolve'], environment=environment)
    env = dict(environment, ROOT=str(ROOT), SIGN_UPDATE=str(binary))
    public = run(['/bin/bash', '-c', 'set -euo pipefail; source Scripts/sparkle-signing.sh; printf "%s" "$SIGNING_PUBLIC_KEY"'],
                 capture=True, environment=env).strip()
    info = plistlib.loads((ROOT / 'Support/Info.plist').read_bytes())
    if public != info['SUPublicEDKey']:
        raise ValueError('release signing key differs from the existing MNotch public key')


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as reader:
        for block in iter(lambda: reader.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def verify_current_history(archive, version, bootstrap_allowed=False):
    """Recheck after preparation, so a newer intervening release wins."""
    with tempfile.TemporaryDirectory(prefix='mnotch-publish-history-') as temporary:
        feed = Path(temporary) / 'appcast.xml'
        local = os.environ.get('MNOTCH_CURRENT_FEED_FILE')
        if local:
            if not Path(local).is_file():
                if bootstrap_allowed:
                    return
                raise ValueError('current signed feed is missing')
            shutil.copyfile(local, feed)
        else:
            url = os.environ.get('MNOTCH_CURRENT_FEED_URL', 'https://github.com/maclifevn/MNotch/releases/latest/download/appcast.xml')
            result = subprocess.run(['/usr/bin/curl', '--fail', '--silent', '--show-error', '--location',
                                     '--connect-timeout', '10', '--max-time', '60', '--max-filesize', '2097152',
                                     '--proto', '=https', '--proto-redir', '=https', '--output', str(feed),
                                     '--write-out', '%{http_code}', url], capture_output=True, text=True)
            if result.returncode != 0:
                if result.stdout.strip() == '404' and bootstrap_allowed:
                    return
                raise ValueError('current signed feed could not be downloaded before publication')
        env = dict(os.environ, ROOT=str(ROOT), SIGN_UPDATE=str(ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'))
        run(['/bin/bash', '-c', 'set -euo pipefail; source Scripts/sparkle-signing.sh; "$SIGN_UPDATE" "${KEY_ARGS[@]}" --verify "$1"',
             'verify-history', str(feed)], capture=True, environment=env)
        check_upgrade(archive_metadata(archive, version), feed)


def prepare(version, critical):
    notes, head, build = preflight(version)
    env = dict(os.environ, VERSION=version, BUILD_NUMBER=build)
    signing_preflight(env)
    destination = ROOT / 'build/releases' / f'{version}-{build}'
    if destination.exists():
        raise ValueError('release output already exists; preserve it and use a new version/build')
    run(['Scripts/notarize.sh'], environment=env)
    run(['Scripts/create-dmg.sh'], environment=env)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f'.{version}-{build}-', dir=destination.parent) as temporary:
        stage = Path(temporary)
        run(['Scripts/build-update-feed.sh', version, str(ROOT / 'build/distribution/MNotch.zip'),
             str(notes), str(stage), str(critical).lower()], environment=env)
        shutil.copy2(ROOT / 'build/distribution/MNotch.dmg', stage / 'MNotch.dmg')
        shutil.copy2(stage / 'MNotch.dmg', stage / f'MNotch-{version}.dmg')
        symbols = ROOT / 'build/symbols' / f'{version}-{build}'
        run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(symbols), str(stage / 'MNotch-symbols.zip')])
        # A concurrent source edit must never be described as the reviewed release.
        _, final_head, final_build = preflight(version)
        if head != final_head or build != final_build:
            raise ValueError('source changed during release preparation')
        names = ['appcast.xml', f'MNotch-{version}.zip', f'MNotch-{version}.dmg', 'MNotch.dmg']
        manifest = {'schema': 1, 'version': version, 'build': build, 'commit': head,
                    'bootstrap_allowed': env.get('MNOTCH_BOOTSTRAP_UPDATE_FEED') == 'true',
                    'repository': os.environ.get('MNOTCH_RELEASE_REPOSITORY', 'maclifevn/MNotch'),
                    'assets': {name: {'sha256': digest(stage / name),
                                     'bytes': (stage / name).stat().st_size} for name in names},
                    'symbols_sha256': digest(stage / 'MNotch-symbols.zip')}
        (stage / 'release-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        stage.rename(destination)
    print('Verified release prepared at', destination)
    print('To publish:', 'make publish VERSION=' + version + ' BUILD_NUMBER=' + build)


def publish(version):
    notes, head, build = preflight(version)
    destination = ROOT / 'build/releases' / f'{version}-{build}'
    manifest = json.loads((destination / 'release-manifest.json').read_text())
    if (manifest.get('schema'), manifest.get('version'), manifest.get('build'), manifest.get('commit')) != (1, version, build, head):
        raise ValueError('release manifest does not match the clean source/tag')
    repository = os.environ.get('MNOTCH_RELEASE_REPOSITORY', 'maclifevn/MNotch')
    if manifest.get('repository') != repository:
        raise ValueError('release repository differs from the prepared manifest')
    names = ['appcast.xml', f'MNotch-{version}.zip', f'MNotch-{version}.dmg', 'MNotch.dmg']
    if set(manifest.get('assets', {})) != set(names):
        raise ValueError('release manifest has unexpected or missing assets')
    for name in names:
        file = destination / name
        if manifest['assets'][name] != {'sha256': digest(file), 'bytes': file.stat().st_size}:
            raise ValueError('release asset changed after verification: ' + name)
    archive_metadata(destination / f'MNotch-{version}.zip', version)
    run(['Scripts/verify-update-feed.sh', str(destination / 'appcast.xml'),
         str(destination / f'MNotch-{version}.zip'),
         str(ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'), version])
    verify_current_history(destination / f'MNotch-{version}.zip', version, manifest.get('bootstrap_allowed') is True)
    ref = json.loads(run(['gh', 'api', f'repos/{repository}/git/ref/tags/v{version}'], capture=True))['object']
    for _ in range(8):
        if ref['type'] == 'commit':
            break
        if ref['type'] != 'tag':
            raise ValueError('remote release tag has an unexpected type')
        ref = json.loads(run(['gh', 'api', f'repos/{repository}/git/tags/{ref["sha"]}'], capture=True))['object']
    if ref.get('type') != 'commit' or ref.get('sha') != head:
        raise ValueError('remote tag differs from the locally verified source')
    existing = subprocess.run(['gh', 'release', 'view', f'v{version}', '--repo', repository, '--json', 'isDraft'],
                              cwd=ROOT, capture_output=True, text=True)
    if existing.returncode == 0:
        if not json.loads(existing.stdout)['isDraft']:
            raise ValueError('published releases are immutable; prepare a higher version')
    else:
        run(['gh', 'release', 'create', f'v{version}', '--repo', repository, '--verify-tag', '--draft',
             '--title', 'MNotch ' + version, '--notes-file', str(notes)])
    assets = [str(destination / name) for name in names + ['release-manifest.json']]
    run(['gh', 'release', 'upload', f'v{version}', '--repo', repository, '--clobber', *assets])
    # Upload into a draft first. The stable latest/download feed changes only
    # when every archive and its manifest have been uploaded successfully.
    run(['gh', 'release', 'edit', f'v{version}', '--repo', repository, '--draft=false', '--latest'])
    print('Published MNotch', version, 'with its signed feed and versioned assets')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'prepare', 'publish'])
    parser.add_argument('version')
    parser.add_argument('--critical', action='store_true')
    args = parser.parse_args()
    try:
        if args.action == 'check':
            _, head, build = preflight(args.version)
            print('Source/tag preflight passed:', args.version, build, head)
        elif args.action == 'prepare':
            prepare(args.version, args.critical)
        else:
            publish(args.version)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Release stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
