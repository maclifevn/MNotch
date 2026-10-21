#!/usr/bin/env python3
"""Real process isolation/termination tests; never touches either app's store."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/notch-coexist-2026-10-21'
OUT.mkdir(parents=True, exist_ok=True)
source = ROOT / 'Sources/MNotch/Services/NotchDropBridge.swift'
probe = OUT / 'routing-process-probe'
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', str(source),
                str(ROOT / 'Scripts/QA/NotchDropProcessProbe.swift'), '-o', str(probe)], check=True)

class Peer:
    def __init__(self, directory, app):
        self.process = subprocess.Popen([str(probe), str(directory), app], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, text=True)
    def request(self, **fields):
        self.process.stdin.write(json.dumps(fields) + '\n'); self.process.stdin.flush()
        state = json.loads(self.process.stdout.readline())
        assert 'error' not in state, state
        return state
    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close(); self.process.wait(timeout=10)

latencies = []
with tempfile.TemporaryDirectory(prefix='NotchDropProcessQA-') as directory:
    notch, finder = Peer(directory, 'mnotch'), Peer(directory, 'mfinder')
    try:
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            first = [pool.submit(peer.request) for peer in (notch, finder)]
            for item in first: item.result()
            for generation in range(100):
                began = time.monotonic()
                replies = [pool.submit(peer.request, generation=generation) for peer in (notch, finder)]
                a, b = [item.result()['leases'][-1] for item in replies]
                assert a == b
                assert a['owners']['1']['app'] == 'mfinder'
                assert a['owners']['2']['app'] == 'mnotch'
                latencies.append((time.monotonic() - began) * 1000)
        frozen = notch.request(generation=100)['leases'][-1]
        finder.process.kill(); finder.process.wait(timeout=10)
        assert notch.request(generation=100)['leases'][-1] == frozen
        assert notch.request(generation=101)['leases'][-1]['owners']['1']['app'] == 'mnotch'
        finder = Peer(directory, 'mfinder'); finder.request()
        assert finder.request(generation=100)['leases'][-2] == frozen  # generation 101 was already reserved
        assert finder.request(generation=102)['leases'][-1]['owners']['1']['instance'] != frozen['owners']['1']['instance']
        assert notch.request(preference='off', generation=103)['leases'][-1]['owners'] == {}
        assert finder.request(preference='mnotch', generation=104)['leases'][-1]['owners']['1']['app'] == 'mnotch'
        assert finder.request(preference='mfinder', displays=[], generation=105)['leases'][-1]['owners'] == {}
        final = notch.request(preference='automatic', generation=106)
        assert final['leases'][-1]['owners']['1']['app'] == 'mnotch'
        assert len(final['leases']) == 16
        assert Path(directory, 'routing.json').stat().st_size < 65536
    finally:
        notch.close(); finder.close()
# Repeated simultaneous first launches exercise atomic directory creation.
for attempt in range(20):
    with tempfile.TemporaryDirectory(prefix='NotchDropStartupQA-') as parent:
        directory = Path(parent, 'absent-parent', 'routing')
        peers = [Peer(directory, app) for app in ('mnotch', 'mfinder')]
        try:
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                for future in [pool.submit(peer.request) for peer in peers]: future.result()
        finally:
            for peer in peers: peer.close()
report = dict(status='PASS', sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),
              simultaneousFirstLaunches=20, concurrentGestures=100,
              processDeath='frozen-current-gesture-next-gesture-fallback',
              restart='new-instance-cannot-inherit-old-claim',
              policy=['automatic', 'off', 'mnotch', 'mfinder-unavailable'],
              metadataRoundTripMs=dict(median=statistics.median(latencies), maximum=max(latencies)))
(OUT / 'process-qa.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
