import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
import update_metadata as metadata
import release


def info(version='1.5.0', build='100', key=None):
    return {'CFBundleIdentifier': 'com.mnotch.app', 'CFBundleExecutable': 'MNotch',
            'CFBundleName': 'MNotch', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': version, 'CFBundleVersion': build,
            'LSMinimumSystemVersion': '15.0', 'SUPublicEDKey': key or base64.b64encode(bytes(32)).decode(),
            'SUFeedURL': 'https://github.com/maclifevn/MNotch/releases/latest/download/appcast.xml',
            'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True}


class UpdateMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mnotch-update-metadata-')
        self.directory = Path(self.temp.name)
        self.archive = self.directory / 'MNotch-1.5.0.zip'
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('MNotch.app/Contents/Info.plist', plistlib.dumps(info()))
        self.meta = metadata.archive_metadata(self.archive, '1.5.0')
        self.signature = base64.b64encode(bytes(range(64))).decode()

    def tearDown(self):
        self.temp.cleanup()

    def feed(self, *, url=None, length=None, build='100', duplicate=False):
        url = url or 'https://github.com/maclifevn/MNotch/releases/download/v1.5.0/MNotch-1.5.0.zip'
        item = f'<item><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>1.5.0</sparkle:shortVersionString><sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion><enclosure url="{url}" length="{length if length is not None else self.archive.stat().st_size}" sparkle:edSignature="{self.signature}"/></item>'
        old = '<item><sparkle:version>99</sparkle:version><sparkle:shortVersionString>1.4</sparkle:shortVersionString><enclosure sparkle:edSignature="other"/></item>'
        path = self.directory / 'appcast.xml'
        path.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' + old + item + (item if duplicate else '') + '</channel></rss>')
        return path

    def testSelectsMatchingReleaseRatherThanFirstEnclosure(self):
        self.assertEqual(metadata.inspect_feed(self.meta, self.feed(), self.archive), self.signature)

    def testRejectsWrongLengthBuildDuplicateAndForeignHost(self):
        for kwargs in [{'length': 1}, {'build': '99'}, {'duplicate': True},
                       {'url': 'https://attacker.invalid/v1.5.0/MNotch-1.5.0.zip'}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                metadata.inspect_feed(self.meta, self.feed(**kwargs), self.archive)

    def testRejectsNonMonotonicVersionAndBuild(self):
        old = self.directory / 'old.xml'
        old.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>100</sparkle:version><sparkle:shortVersionString>1.5.0</sparkle:shortVersionString></item></channel></rss>')
        for version, build in [('1.5.1', 100), ('1.4.9', 101), ('1.5.0', 101)]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                metadata.check_upgrade(dict(self.meta, version=version, build=build), old)
        metadata.check_upgrade(dict(self.meta, version='1.5.1', build=101), old)

    def testRejectsVersionMismatchUnsignedPolicyAndInvalidBuild(self):
        for changed in [{'CFBundleShortVersionString': '1.4'}, {'SURequireSignedFeed': False},
                        {'SUVerifyUpdateBeforeExtraction': False}, {'CFBundleVersion': 'NaN'}]:
            with zipfile.ZipFile(self.archive, 'w') as archive:
                archive.writestr('MNotch.app/Contents/Info.plist', plistlib.dumps(dict(info(), **changed)))
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                metadata.archive_metadata(self.archive, '1.5.0')

    def testRejectsXMLDeclarationsAndOversizedFeed(self):
        file = self.directory / 'invalid.xml'
        for data in [b'<!DOCTYPE rss [<!ENTITY x "x">]><rss/>', b' ' * (2 * 1024 * 1024 + 1)]:
            file.write_bytes(data)
            with self.assertRaises(ValueError):
                metadata.read_feed(file)


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mnotch-release-preflight-')
        self.directory = Path(self.temp.name)
        self.root_patch = patch.object(release, 'ROOT', self.directory)
        self.root_patch.start()
        self.env_patch = patch.dict(os.environ, {'BUILD_NUMBER': '101'})
        self.env_patch.start()
        (self.directory / 'ReleaseNotes').mkdir()
        (self.directory / 'ReleaseNotes/1.5.0.md').write_text('Fixture notes')
        for command in [['git', 'init', '-q'], ['git', 'add', '.'],
                        ['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'],
                        ['git', '-c', 'tag.gpgsign=false', 'tag', 'v1.5.0']]:
            subprocess.run(command, cwd=self.directory, check=True, capture_output=True)

    def tearDown(self):
        self.env_patch.stop()
        self.root_patch.stop()
        self.temp.cleanup()

    def testCleanTaggedSourcePasses(self):
        _, head, build = release.preflight('1.5.0')
        self.assertEqual(len(head), 40)
        self.assertEqual(build, '101')

    def testDirtySourceAndInvalidBuildStopBeforeSigning(self):
        file = self.directory / 'ReleaseNotes/1.5.0.md'
        file.write_text('Changed after review')
        with self.assertRaisesRegex(ValueError, 'clean'):
            release.preflight('1.5.0')
        subprocess.run(['git', 'checkout', '--', str(file)], cwd=self.directory, check=True)
        with patch.dict(os.environ, {'BUILD_NUMBER': 'nan'}), self.assertRaisesRegex(ValueError, 'positive integer'):
            release.preflight('1.5.0')

    def testAllRegressionChecksRunBeforeReleasePreparation(self):
        with patch.object(release, 'run') as runner:
            self.assertEqual(release.validate_source(), ['debug', 'release', 'address', 'thread', 'scripts'])
        commands = [call.args[0] for call in runner.call_args_list]
        self.assertEqual(len(commands), 5)
        self.assertIn('--sanitize=address', commands[2])
        self.assertIn('--sanitize=thread', commands[3])
        self.assertEqual(commands[-1][0], 'python3')

    def testFailedRegressionStopsBeforeNotarizationOrUpload(self):
        source = release.preflight('1.5.0')
        with patch.object(release, 'preflight', return_value=source), \
             patch.object(release, 'signing_preflight'), \
             patch.object(release, 'run', side_effect=subprocess.CalledProcessError(1, ['swift', 'test'])) as runner:
            with self.assertRaises(subprocess.CalledProcessError):
                release.prepare('1.5.0', False)
        self.assertEqual(runner.call_count, 1)
        self.assertEqual(runner.call_args.args[0][0:2], ['swift', 'test'])

    def testPublishingOldManifestWithoutRegressionReceiptIsRejected(self):
        notes, head, build = source = release.preflight('1.5.0')
        destination = self.directory / 'build/releases' / f'1.5.0-{build}'
        destination.mkdir(parents=True)
        (destination / 'release-manifest.json').write_text(json.dumps({
            'schema': 1, 'version': '1.5.0', 'build': build, 'commit': head,
        }))
        with patch.object(release, 'preflight', return_value=source), patch.object(release, 'run') as runner:
            with self.assertRaisesRegex(ValueError, 'regression checks'):
                release.publish('1.5.0')
        runner.assert_not_called()


class RealSparkleSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
        if not cls.binary.is_file():
            raise unittest.SkipTest('resolve/build Sparkle first to run real signing fixtures')
        cls.temp = tempfile.TemporaryDirectory(prefix='mnotch-real-sparkle-')
        cls.directory = Path(cls.temp.name)
        script = cls.directory / 'fixture-key.swift'
        script.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let secret = root.appendingPathComponent("test-key")
try key.rawRepresentation.base64EncodedData().write(to: secret)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
try key.publicKey.rawRepresentation.base64EncodedData().write(to: root.appendingPathComponent("test-public"))
''')
        subprocess.run(['/usr/bin/swift', str(script), str(cls.directory)], cwd=ROOT, check=True, capture_output=True)
        cls.key = cls.directory / 'test-key'
        cls.public = (cls.directory / 'test-public').read_text()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def archive(self, version, build, public=None):
        directory = self.directory / (version + '-' + build + '-' + str(id(self)))
        directory.mkdir(exist_ok=True)
        app = directory / 'MNotch.app/Contents'
        (app / 'MacOS').mkdir(parents=True, exist_ok=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps(info(version, build, public or self.public)))
        shutil.copyfile('/usr/bin/true', app / 'MacOS/MNotch')
        (app / 'MacOS/MNotch').chmod(0o755)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app.parent)], check=True, capture_output=True)
        archive = directory / ('MNotch-' + version + '.zip')
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app.parent), str(archive)], check=True)
        notes = directory / 'notes.md'
        notes.write_text('# MNotch fixture\n\nTest-only signed notes.')
        return archive, notes, directory

    def build_feed(self, version, build, previous=None, public=None, bootstrap=True):
        archive, notes, directory = self.archive(version, build, public)
        env = dict(os.environ, SPARKLE_PRIVATE_KEY_FILE=str(self.key),
                   MNOTCH_CURRENT_FEED_FILE=str(previous or directory / 'missing.xml'),
                   MNOTCH_BOOTSTRAP_UPDATE_FEED=str(bootstrap).lower())
        output = directory / 'feed'
        result = subprocess.run(['Scripts/build-update-feed.sh', version, str(archive), str(notes), str(output)],
                                cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)
        return result, output

    def testRealSignedBootstrapAndUpgradePreserveHistoryAndRejectTampering(self):
        first, output = self.build_feed('1.5.0', '100')
        self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
        self.assertIn('tamper rejection passed', first.stdout)
        second, upgraded = self.build_feed('1.5.1', '101', output / 'appcast.xml', bootstrap=False)
        self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
        data = metadata.read_feed(upgraded / 'appcast.xml')
        versions = {item.findtext(metadata.SPARKLE + 'shortVersionString') for item in data.findall('./channel/item')}
        self.assertEqual(versions, {'1.5.0', '1.5.1'})
        # A concurrent newer release after preparation must also block publish.
        env = {'SPARKLE_PRIVATE_KEY_FILE': str(self.key), 'MNOTCH_CURRENT_FEED_FILE': str(upgraded / 'appcast.xml')}
        with patch.dict(os.environ, env), self.assertRaisesRegex(ValueError, 'new build'):
            release.verify_current_history(upgraded / 'MNotch-1.5.1.zip', '1.5.1')

    def testWrongKeyAndMissingHistoryLeaveNoOutput(self):
        for version, public, bootstrap in [('1.6.0', base64.b64encode(bytes(32)).decode(), True),
                                            ('1.6.1', None, False)]:
            result, output = self.build_feed(version, '102', public=public, bootstrap=bootstrap)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def testAuthenticatedHistoryRejectsDowngradeAndModifiedFeed(self):
        result, output = self.build_feed('1.7.0', '104')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        lower, failed = self.build_feed('1.6.9', '105', output / 'appcast.xml', bootstrap=False)
        self.assertNotEqual(lower.returncode, 0)
        self.assertFalse(failed.exists())
        feed = output / 'appcast.xml'
        feed.write_bytes(feed.read_bytes().replace(b'MNotch', b'MNotcx', 1))
        tampered, failed = self.build_feed('1.7.1', '105', feed, bootstrap=False)
        self.assertNotEqual(tampered.returncode, 0)
        self.assertFalse(failed.exists())
