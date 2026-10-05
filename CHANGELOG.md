# Changelog

## 1.5 — Stability and macOS 27 compatibility

- Complete the MFinder-style Sparkle release flow with local release/publish
  commands, signed history/version/build validation and artifact manifests.
- Wait for File Tray copies, cleanup and active drags before update installation;
  allow cancelling the wait and retrying the downloaded update.
- Validate media, quota and numeric preferences before conversions and geometry.
- Bound subprocess deadlines/output and reap processes ignoring termination;
  handle closed Codex pipes without SIGPIPE and coalesce callback bursts.
- Prevent late Calendar/agent/Bluetooth results from restoring stopped resources;
  bound agent connections and session history.
- Preserve sleep/wake notification ordering, reconcile missed unlock state and
  rebuild stale notch panels after clamshell wake.
- Protect hook configuration from malformed input and failed script deployment;
  use bounded JSON relay parsing and preserve native approval fallbacks.
- Restrict File Tray cleanup to its own files and roll back failed copy batches.
- Gate unverified direct private macOS integrations with a Settings explanation.
- Add local diagnostics export, isolated soak instrumentation, regression tests,
  sanitizer CI, deployment-target verification and matching dSYM preservation.
- Update Sparkle to 2.10.0 with upstream security and macOS 27 reliability fixes.

## 1.4

- **Signed automatic updates** — Sparkle 2.9.4 checks daily, supports manual
  checks from the menu bar and Settings, and can download updates for install
  on quit. Both the appcast and notarized ZIP are protected by Ed25519
  signatures, with phased rollout and tamper tests in the release workflow.

## 1.2

- **New: Pomodoro focus timer** 🍅 — a fifth tab in the notch with a progress
  ring, cycle dots, and Start/Pause · Skip · Reset. While a session runs the
  closed notch shows the live countdown beside the camera; when a phase ends
  the notch pops a break/focus reminder with an optional sound. Configure
  focus/break lengths, cycles per long break, sound, and auto-continue in
  Settings → Live Activities → Pomodoro. (Đề xuất từ cộng đồng Maclife.)

## 1.1

- Optimization pass: content-driven notch sizing, File Tray (multi-select,
  Quick Look, AirDrop), FeatureCoordinator service lifecycle, quota shown as
  % remaining, off-main-thread media/focus work, English/Vietnamese
  localization, notarized Developer ID distribution.

## 1.0

- Initial Maclife release: Now Playing, volume/brightness HUD, battery &
  Bluetooth pops, Calendar, Focus, lock-screen overlay, AI-agent monitoring
  (Claude & Codex quota + inline approvals).
