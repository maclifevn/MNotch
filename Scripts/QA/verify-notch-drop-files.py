#!/usr/bin/env python3
"""Read-only receipts for this task's disposable native fixture files."""
import argparse
import hashlib
import json
from pathlib import Path
from urllib.parse import unquote, urlparse

parser = argparse.ArgumentParser()
parser.add_argument('--label', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
output = root / 'build/notch-coexist-2026-10-21'
fixture = output / 'fixture'
expected_hashes = json.loads((fixture / 'expected-hashes.json').read_text())

def receipt(path, name=None):
    if not path.is_file(): return dict(path=str(path), exists=False)
    name = name or path.name
    expected_name = next((x for x in expected_hashes if Path(name).stem.startswith(Path(x).stem)), None)
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    return dict(path=str(path), bytes=len(data), sha256=digest, expectedSource=expected_name,
                matchesSource=expected_name is not None and digest == expected_hashes[expected_name])

sources = [receipt(fixture / name) for name in expected_hashes]
notch = [receipt(p) for p in (Path.home() / 'Library/Application Support/MNotch/Shelf').glob('NotchCoexist*') if p.is_file()]
finder_root = Path.home() / 'Library/Application Support/MFinder/DropTray'
finder = []
existing_rows = {}
manifest = finder_root / 'manifest.json'
if manifest.exists():
    state = json.loads(manifest.read_text())
    for row in state.get('items', []):
        if not row.get('name', '').startswith('NotchCoexist-'):
            identity = {key: row.get(key) for key in ('id', 'name', 'source', 'shelfID')}
            existing_rows[row['id']] = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
            continue
        source = row.get('source', {})
        if 'ownedCopy' in source:
            path = finder_root / source['ownedCopy']['relativePath']
        elif 'reference' in source:
            path = Path(unquote(urlparse(source['reference']['url']).path))
        else:
            finder.append(dict(id=row['id'], name=row['name'], state=row['state'], pending=True)); continue
        finder.append(dict(id=row['id'], name=row['name'], state=row['state'], **receipt(path, row['name'])))
bridge_path = Path.home() / 'Library/Application Support/MacLife/NotchDropBridge/routing.json'
bridge = json.loads(bridge_path.read_text()) if bridge_path.exists() else None
baseline = json.loads((output / 'user-store-baseline.json').read_text())
preserved = all(existing_rows.get(key) == digest for key, digest in baseline['mfinder'].items())
report = dict(label=args.label, expectedSHA256=expected_hashes, sources=sources, mnotch=notch, mfinder=finder, bridge=bridge,
              existingFinderRecordsPreserved=preserved, existingFinderRecordCount=len(existing_rows))
(output / (args.label + '-files.json')).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(dict(label=args.label, originalsIntact=all(x.get('matchesSource') for x in sources),
                     mnotchCopies=len(notch), mfinderItems=len(finder),
                     allReadyBytesMatch=all(x.get('matchesSource') for x in notch + [x for x in finder if x.get('state') == 'ready']),
                     pendingFinderItems=sum(x.get('state') != 'ready' for x in finder),
                     existingFinderRecordsPreserved=preserved,
                     preference=bridge.get('preference') if bridge else None), indent=2))
