# Changelog

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
