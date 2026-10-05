#!/usr/bin/env python3
"""Validate update identity, version/build, URLs and byte lengths before signing."""
import argparse
import base64
import json
import plistlib
import re
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def version_tuple(version):
    if not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', version):
        raise ValueError('stable version must be numeric, e.g. 1.5.0')
    return tuple(int(x) for x in (version.split('.') + ['0'])[:3])


def archive_metadata(archive, version):
    version_tuple(version)
    with zipfile.ZipFile(archive) as zipped:
        path = 'MNotch.app/Contents/Info.plist'
        entry = zipped.getinfo(path)
        if entry.file_size > 256 * 1024:
            raise ValueError('archive Info.plist exceeds limit')
        info = plistlib.loads(zipped.read(path))
    if info.get('CFBundleIdentifier') != 'com.mnotch.app':
        raise ValueError('archive bundle identifier is not MNotch')
    if info.get('CFBundleShortVersionString') != version:
        raise ValueError('archive version differs from release version')
    build = str(info.get('CFBundleVersion', ''))
    if not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('archive build must be a positive integer')
    for setting in ['SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction']:
        if info.get(setting) is not True:
            raise ValueError(f'{setting} must be enabled')
    key = str(info.get('SUPublicEDKey', ''))
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError('archive Sparkle public key is invalid')
    feed_url = info.get('SUFeedURL')
    if feed_url != 'https://github.com/maclifevn/MNotch/releases/latest/download/appcast.xml':
        raise ValueError('archive must retain the MNotch stable feed URL')
    return {'version': version, 'build': int(build), 'public_key': key,
            'minimum_macOS': info['LSMinimumSystemVersion'], 'feed_url': feed_url}


def read_feed(path):
    with Path(path).open('rb') as reader:
        data = reader.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024 or re.search(rb'<!\s*(?:DOCTYPE|ENTITY)', data, re.I):
        raise ValueError('appcast is too large or contains an XML entity declaration')
    return ET.fromstring(data)


def check_upgrade(metadata, feed):
    for item in read_feed(feed).findall('./channel/item'):
        build = item.findtext(SPARKLE + 'version', '')
        previous = item.findtext(SPARKLE + 'shortVersionString', '')
        if not re.fullmatch(r'[1-9][0-9]*', build):
            raise ValueError('previous appcast has an invalid build number')
        if metadata['build'] <= int(build):
            raise ValueError('new build must exceed every published build')
        if version_tuple(metadata['version']) <= version_tuple(previous):
            raise ValueError('new version must exceed every published version')


def inspect_feed(metadata, feed, archive, repository='maclifevn/MNotch'):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('invalid release repository')
    matches = [item for item in read_feed(feed).findall('./channel/item')
               if item.findtext(SPARKLE + 'shortVersionString') == metadata['version']]
    if len(matches) != 1:
        raise ValueError('expected exactly one appcast entry for the release version')
    item = matches[0]
    if item.findtext(SPARKLE + 'version') != str(metadata['build']):
        raise ValueError('appcast build differs from archive build')
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise ValueError('release enclosure is missing')
    expected = f'https://github.com/{repository}/releases/download/v{metadata["version"]}/MNotch-{metadata["version"]}.zip'
    if enclosure.get('url') != expected:
        raise ValueError('update URL differs from the versioned release asset')
    if enclosure.get('length') != str(Path(archive).stat().st_size):
        raise ValueError('appcast archive byte length differs from the actual ZIP')
    signature = enclosure.get(SPARKLE + 'edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('archive signature is missing or malformed')
    if item.findtext(SPARKLE + 'minimumSystemVersion') != metadata['minimum_macOS']:
        raise ValueError('appcast minimum macOS differs from archive metadata')
    return signature


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('version')
    parser.add_argument('--appcast', type=Path)
    parser.add_argument('--current-feed', type=Path)
    parser.add_argument('--repository', default='maclifevn/MNotch')
    parser.add_argument('--signing-public-key')
    args = parser.parse_args()
    try:
        metadata = archive_metadata(args.archive, args.version)
        if args.signing_public_key and metadata['public_key'] != args.signing_public_key:
            raise ValueError('signing key does not match the public key embedded in the app')
        if args.current_feed:
            check_upgrade(metadata, args.current_feed)
        if args.appcast:
            print(inspect_feed(metadata, args.appcast, args.archive, args.repository))
        else:
            print(json.dumps(metadata))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, ET.ParseError, plistlib.InvalidFileException) as error:
        parser.exit(1, 'Update validation failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
