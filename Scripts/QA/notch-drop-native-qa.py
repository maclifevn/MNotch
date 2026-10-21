#!/usr/bin/env python3
"""Native regression using MFinder's existing guarded NativeUI.swift test driver.

Only the disposable NotchDropFixture window supplies files. Settings are chosen
through the app first; this harness never changes settings or deletes tray items.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--mfinder-root', type=Path, required=True)
p.add_argument('--driver', type=Path, required=True)
p.add_argument('--label', required=True)
p.add_argument('--receiver', choices=['mnotch', 'mfinder', 'none'], required=True)
p.add_argument('--preference', choices=['automatic', 'mnotch', 'mfinder', 'off'], required=True)
p.add_argument('--source', choices=['urls', 'promises'], required=True)
p.add_argument('--fullscreen', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
output = root / 'build/notch-coexist-2026-10-21'
fixture = output / 'fixture'
sys.path.insert(0, str(a.mfinder_root / 'Scripts'))
from desktop_qa_lock import acquire_desktop_locks

def command(*args):
    return subprocess.check_output(list(map(str, args)), text=True, timeout=20).strip()

def driver(*args):
    return json.loads(command(a.driver, *args) or '{}')

def receipt(label):
    command(sys.executable, root / 'Scripts/QA/verify-notch-drop-files.py', '--label', label)
    value = json.loads((output / (label + '-files.json')).read_text())
    assert value['existingFinderRecordsPreserved']
    assert all(row['matchesSource'] for row in value['sources'])
    assert all(row.get('matchesSource') for row in value['mnotch'] + [x for x in value['mfinder'] if x.get('state') == 'ready'])
    return value

def identities(value):
    return {'mnotch': {x['path'] for x in value['mnotch']},
            'mfinder': {x['id'] for x in value['mfinder']}}

def events():
    path = fixture / 'native-events.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

report = output / (a.label + '-native.json')
assert not report.exists(), 'Use a fresh label; never replace prior evidence'
handles = acquire_desktop_locks(timeout=0)
try:
    before = receipt(a.label + '-before')
    assert before['bridge']['preference'] == a.preference
    initial = identities(before)
    pids = command('pgrep', '-x', 'NotchDropFixture').splitlines()
    assert len(pids) == 1, 'Only one disposable source may run'
    pid = int(pids[0])
    command(a.driver, 'activate', pid)
    if not a.fullscreen:
        # Keep the fixture below resident overlay canvases. Validate the
        # actual source control, rather than clicking a covered title bar.
        command(a.driver, 'resize', pid, 'Notch Drop Coexistence QA', 600, 400)
        command(a.driver, 'move', pid, 'Notch Drop Coexistence QA', 400, 500)
        command(a.driver, '--expect-pid', pid, 'key', 53)
        time.sleep(.3)
    assert driver('front')['pid'] == pid
    rows = driver('snapshot', pid, 'Notch Drop Coexistence QA')
    window = next(row for row in rows if row['role'] == 'AXWindow')
    source = next(row for row in rows if row.get('identifier') == ('notchQA.urlSource' if a.source == 'urls' else 'notchQA.promiseSource'))
    command(a.driver, 'hover', pid, 'Notch Drop Coexistence QA', source['identifier'])
    start = [source['x'] + source['width']/2, source['y'] + source['height']/2]
    screen = driver('screens')[0]
    end = [screen['x'] + screen['width'] / 2, screen['y'] + 8]
    path = [[start[0] + (end[0]-start[0])*i/45, start[1] + (end[1]-start[1])*i/45] for i in range(46)]
    # Match the existing physical-notch regression: reach the housing itself
    # and allow the native destination feedback to appear before releasing.
    path += [end] * 12
    (output / (a.label+'-input.json')).write_text(json.dumps(dict(pid=pid, window=window, start=start, end=end, path=path), indent=2)+'\n')
    offset = len(events())
    started = time.monotonic()
    result = driver('--expect-pid', pid, 'drag', json.dumps(path))
    after = None
    for _ in range(100):
        time.sleep(.1)
        after = receipt(a.label + '-after')
        delta = {app: len(ids-initial[app]) for app, ids in identities(after).items()}
        terminal = any(x['event'] == 'drag-ended' for x in events()[offset:])
        if a.receiver == 'none':
            if terminal and time.monotonic()-started > 3: break
        elif terminal and delta[a.receiver] == 2 and all(x.get('matchesSource') for x in after[a.receiver]): break
    expected = {'mnotch': 0, 'mfinder': 0}
    if a.receiver != 'none': expected[a.receiver] = 2
    assert delta == expected, (delta, expected)
    assert all(x.get('matchesSource') for x in after['mnotch'] + after['mfinder'])
    batch = events()[offset:]
    begins = [x for x in batch if x['event'] == 'drag-start']
    ends = [x for x in batch if x['event'] == 'drag-ended']
    assert len(begins) == len(ends) == 1, batch
    begin, finish = begins[0], ends[0]
    assert begin['pressedButtons'] & 1, 'The source must receive a genuine global held-button drag'
    assert begin['frontmost'] == 'com.maclife.notchdrop.qa' and begin['onActiveSpace']
    assert begin['fullscreen'] == a.fullscreen
    assert begin['promises'] == (a.source == 'promises')
    assert abs(finish['screenX']-end[0]) < 2 and abs((screen['height']-finish['screenY'])-end[1]) < 2
    lease = next(x for x in after['bridge']['leases'] if x['key'].endswith(':'+str(finish['pasteboardGeneration'])))
    if a.receiver != 'none':
        assert any(x['app'] == a.receiver for x in lease['owners'].values()), lease
        assert finish['operation'] != 0
    else:
        assert finish['operation'] == 0
        if a.preference == 'off': assert not lease['owners']
    writes = [x for x in batch if x['event'] == 'promise-written']
    assert len(writes) == (2 if a.source == 'promises' and a.receiver == 'mfinder' else 0)
    for write in writes:
        assert write['sha256'] == after['expectedSHA256'][write['sourceName']]
    if a.receiver == 'mfinder':
        assert not any(x['app'] == 'mnotch' and x['alpha'] > 0 for x in finish['peerWindows']), finish
    report.write_text(json.dumps(dict(status='PASS', label=a.label, receiver=a.receiver, source=a.source,
        fullscreen=a.fullscreen, delta=delta, nativeEvents=batch, driverResult=result,
        driverSHA256=hashlib.sha256(a.driver.read_bytes()).hexdigest(),
        originalsIntact=True, existingFinderRecordsPreserved=True), indent=2)+'\n')
    print(json.dumps(dict(status='PASS', label=a.label, delta=delta, actualMouseButtonVerified=True)))
finally:
    for handle in handles: handle.close()
