#!/usr/bin/env python3
"""Run a copied, isolated release app and collect local numeric health evidence."""
import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import statistics
import subprocess
import time
import uuid


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True))
    temporary.replace(path)


def process_sample(pid):
    output = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,rss=,%cpu="],
                            capture_output=True, text=True, timeout=5, check=True).stdout
    rows = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 4:
            rows[int(fields[0])] = (int(fields[1]), int(fields[2]), float(fields[3]))
    descendants, frontier = set(), {pid}
    while frontier:
        children = {child for child, row in rows.items() if row[0] in frontier} - descendants
        descendants.update(children)
        frontier = children
    row = rows.get(pid)
    if row is None:
        raise RuntimeError("app process ended during sampling")
    descriptors = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-Ff"],
                                 capture_output=True, text=True, timeout=5)
    if descriptors.returncode != 0:
        raise RuntimeError("file descriptor measurement unavailable")
    fd_count = sum(line[1:].isdigit() for line in descriptors.stdout.splitlines() if line.startswith("f"))
    return {"rss_kib": row[1], "cpu_percent": row[2], "descriptor_count": fd_count,
            "child_count": len(descendants)}


def assess_growth(samples):
    # Review thresholds tolerate bounded warm-up/caches; raw samples remain the
    # evidence. This is an idle workload, not a proof covering hardware changes.
    warmed = [row for row in samples if row["elapsed_seconds"] >= 600]
    if len(warmed) < 20:
        return {"evaluated": False, "reason": "insufficient post-warmup samples"}
    quarter = max(5, len(warmed) // 4)
    first, last = warmed[:quarter], warmed[-quarter:]
    delta = {key: statistics.median(row[key] for row in last) - statistics.median(row[key] for row in first)
             for key in ("rss_kib", "descriptor_count", "child_count")}
    baseline = statistics.median(row["rss_kib"] for row in first)
    review = delta["rss_kib"] > max(10240, baseline * 0.1) or delta["descriptor_count"] > 5 or delta["child_count"] > 2
    return {"evaluated": True, "median_delta": delta, "resource_review_required": review,
            "cpu_percent_median": statistics.median(row["cpu_percent"] for row in warmed)}


def classify_run(reason, duration, growth):
    if reason == "host_suspended_or_sampler_paused":
        return "inconclusive"
    if reason != "completed":
        return "failed"
    # A smoke run can already provide enough post-warmup evidence to reveal
    # growth. Short duration must never turn that warning into a green result.
    if growth.get("resource_review_required"):
        return "resource_review_required"
    if duration < 8 * 3600:
        return "smoke_completed"
    return "idle_soak_completed" if growth.get("evaluated") else "resource_review_required"


def clone_signing_command(identity, clone):
    command = ["/usr/bin/codesign", "--force", "--sign", identity,
               "--preserve-metadata=entitlements"]
    if identity.startswith("Developer ID Application:"):
        command += ["--timestamp", "--options", "runtime"]
    return command + [str(clone)]


def run(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    clone = output / "MNotchAudit.app"
    subprocess.run(["/usr/bin/ditto", str(args.app.resolve()), str(clone)], check=True, timeout=60)
    info_path = clone / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleIdentifier"] = "com.mnotch.audit." + uuid.uuid4().hex
    info["CFBundleName"] = "MNotch Audit"
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(clone_signing_command(args.sign_identity, clone), check=True, timeout=45)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(clone)], check=True, timeout=30)
    environment = dict(os.environ, MNOTCH_DIAGNOSTIC_RUN="1",
                       MNOTCH_SUPPORT_DIRECTORY=str(output / "support"),
                       MNOTCH_HEALTH_FILE=str(output / "heartbeat.json"))
    app = subprocess.Popen([str(clone / "Contents/MacOS" / info["CFBundleExecutable"])],
                           env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, start_new_session=True)
    started, samples, reason = time.monotonic(), [], "completed"
    interrupted = False
    previous_sample = started

    def stop_requested(_signal, _frame):
        nonlocal interrupted
        interrupted = True

    signal.signal(signal.SIGTERM, stop_requested)
    signal.signal(signal.SIGINT, stop_requested)
    progress = {"status": "running", "pid": app.pid, "requested_seconds": args.duration,
                "signing_mode": "developer_id_hardened" if args.sign_identity.startswith("Developer ID Application:") else "local_diagnostic",
                "executable_sha256": hashlib.sha256((clone / "Contents/MacOS" / info["CFBundleExecutable"]).read_bytes()).hexdigest(),
                "workload": "isolated default features; no permission grants, agent accounts or private APIs",
                "app_version": info["CFBundleShortVersionString"], "app_build": info["CFBundleVersion"]}
    write_json(output / "progress.json", progress)
    try:
        with (output / "samples.csv").open("w", newline="") as file:
            writer = None
            while time.monotonic() - started < args.duration and not interrupted:
                elapsed = time.monotonic() - started
                now_sample = time.monotonic()
                if now_sample - previous_sample > max(120, args.interval * 3):
                    reason = "host_suspended_or_sampler_paused"
                    break
                previous_sample = now_sample
                if app.poll() is not None:
                    reason = "app_exited"
                    break
                heartbeat_path = output / "heartbeat.json"
                try:
                    heartbeat = json.loads(heartbeat_path.read_text())
                    age = max(0, time.time() - heartbeat_path.stat().st_mtime)
                except (FileNotFoundError, json.JSONDecodeError):
                    heartbeat, age = {}, elapsed
                if age > 60:
                    reason = "main_thread_or_health_writer_stalled"
                    break
                row = dict(elapsed_seconds=round(elapsed, 3), heartbeat_age_seconds=round(age, 3),
                           heartbeat_sequence=heartbeat.get("sequence", 0),
                           main_thread_interval=heartbeat.get("mainThreadInterval", 0),
                           **process_sample(app.pid))
                samples.append(row)
                if writer is None:
                    writer = csv.DictWriter(file, fieldnames=list(row))
                    writer.writeheader()
                writer.writerow(row)
                file.flush()
                progress.update(elapsed_seconds=round(elapsed, 3), latest=row)
                write_json(output / "progress.json", progress)
                time.sleep(min(args.interval, max(0, args.duration - elapsed)))
        if interrupted:
            reason = "interrupted"
    except Exception as error:
        reason = "measurement_failed_" + type(error).__name__
    finally:
        exit_code = app.poll()
        if exit_code is None:
            app.terminate()
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(app.pid, signal.SIGKILL)
                app.wait(timeout=5)
    growth = assess_growth(samples)
    verdict = classify_run(reason, args.duration, growth)
    result = dict(progress, status=verdict, reason=reason, exit_code_before_cleanup=exit_code,
                  elapsed_seconds=round(time.monotonic() - started, 3), sample_count=len(samples), growth=growth)
    write_json(output / "result.json", result)
    write_json(output / "progress.json", result)
    print(json.dumps(result, indent=2))
    return 0 if verdict in ("smoke_completed", "idle_soak_completed") else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True, help="new directory; never overwritten")
    parser.add_argument("--duration", type=float, default=8 * 3600)
    parser.add_argument("--interval", type=float, default=30)
    parser.add_argument("--sign-identity", default="-", help="sign only the isolated copy; Developer ID enables hardened runtime")
    args = parser.parse_args()
    if not math.isfinite(args.duration) or not 1 <= args.duration <= 24 * 3600:
        parser.error("duration must be between 1 and 86400 seconds")
    if not math.isfinite(args.interval) or not 1 <= args.interval <= 60:
        parser.error("interval must be between 1 and 60 seconds")
    raise SystemExit(run(args))
