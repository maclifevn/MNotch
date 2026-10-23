# Changelog

## 1.5.5 — Persistent hang diagnostics

- Save bounded local diagnostics across relaunches, including the previous
  session, Mac/OS build, service/input state, CPU time and resident memory.
- Detect a main run loop that stops responding for 5 seconds from a separate
  watchdog queue; record recovery and try a bounded stack sample of MNotch.
  Distinguish sleep/wake, watchdog delays and unclosed sessions from confirmed
  main-thread stalls. Include saved history in Export Diagnostics.

## 1.5.4 — Codex discovery and persistent Claude quota

- Discover the CLI bundled inside current Codex applications, including moved
  or renamed apps, while preserving CLI overrides and legacy paths.
- Read Claude subscription session and weekly quota through the read-only OAuth
  usage endpoint instead of interpreting CLI token/cost statistics.
- Connect Claude Desktop's encrypted saved sign-in explicitly through macOS
  Keychain so quota continues updating after Claude Code and Desktop close.
  Reuse only unexpired tokens for the selected account and organization; do not
  refresh shared tokens or change Claude's files.
- Update connection guidance, Vietnamese translations, and regression coverage
  for application discovery, quota responses, and encrypted credential caches.

## 1.5.3 — Brightness compatibility, finer volume and compact notifications

- Detect built-in display brightness support at runtime instead of limiting
  the HUD to one Mac model, macOS patch and build. Display-only configurations
  start brightness polling and key handling, including after sleep/wake.
- Show actual brightness control failures in Settings and diagnostics; retain
  native key handling when controls are missing, fail or stop responding.
- Resample after a stalled hardware call before taking control of brightness
  keys again, so an old result cannot overwrite newer native adjustments.
- Adjust volume by 1% per key press (0.25% with Shift + Option), with consistent
  steps while holding a key. Ignore snapshots from earlier audio requests until
  the latest request completes, and preserve the order of volume/mute commands.
- Keep charging, battery, Bluetooth, Focus, calendar, Pomodoro, accessibility
  and agent notifications within the menu-bar band. Agent confirmations use
  side wings, and hover feedback expands horizontally without dipping below it.

## 1.5.2 — Horizontal HUDs and notch polish

- Fill the entire visible menu-bar band and contain the contrast border; volume
  and brightness HUDs keep the closed notch height while expanding sideways.
- Allow temporary passive HUDs in full screen while keeping the normal notch
  hidden, with Mission Control and gaming suppression preserved.
- Add simulated-notch auto-hide and refresh application/menu-bar icons.
- Bound thumbnail ownership, background rendering, service shutdown and file
  reads; enforce debug/release/sanitizer/script checks before release signing.
- Enable brightness on the locally verified Mac17,3 / macOS 27.0.1 (26A434)
  combination through one serial hardware worker, coalesced writes and a
  freshness lease that returns unavailable controls to macOS.

## 1.5.1 — Volume control recovery

- Let macOS handle volume keys when audio controls are unavailable, writes fail,
  or the audio driver stops responding; recover output tracking after missed
  device changes and audio service resets.
- Include audio failures and control availability in diagnostics, and retain
  errors when successful media polls fill the diagnostic buffer.

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
