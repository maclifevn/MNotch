import AppKit
import os
import SwiftUI

let mnotchLog = Logger(subsystem: "com.mnotch.app", category: "media")

struct MediaPlayback: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var duration: TimeInterval = 0
    /// Elapsed time as of `timestamp` — extrapolate for display, never poll.
    var elapsedTime: TimeInterval = 0
    var timestamp = Date.distantPast
    var playbackRate: Double = 1
    var isPlaying = false
    var bundleIdentifier = ""
    var trackIdentity = ""
    /// nil when the source doesn't support shuffle (browsers/video).
    var shuffleMode: Int?
    /// MRARepeatMode: 1 off, 2 one, 3 all; nil when unsupported.
    var repeatMode: Int?
    var isVideo = false

    var isShuffled: Bool { (shuffleMode ?? 1) != 1 }

    /// Title with "(Official MV)", "[4K]", "feat.…", "- Topic" noise removed.
    var cleanTitle: String {
        var t = title
        for pattern in [
            #"\s*[(\[][^)\]]*(?i:official|video|audio|lyric|visuali[sz]er|remaster|mv|hd|4k)[^)\]]*[)\]]"#,
            #"\s*[(\[](?i:feat|ft)\.[^)\]]*[)\]]"#,
            #"\s*-\s*Topic$"#,
        ] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return elapsedTime }
        let extrapolated = elapsedTime + date.timeIntervalSince(timestamp) * playbackRate
        return min(max(extrapolated, 0), duration > 0 ? duration : .infinity)
    }
}

enum MediaCommand: Int {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

/// System-wide now-playing via the vendored mediaremote-adapter
/// (/usr/bin/perl is Apple-entitled and dyld-loads the adapter framework).
///
/// On macOS 26.5 the adapter's `stream` (notification-based) command returns
/// nothing — notifications no longer reach unentitled listeners — but one-shot
/// `get` calls work fully. So this service POLLS `get` (cheap, no artwork)
/// and fetches artwork only when the track identity changes. Elapsed time is
/// extrapolated locally between polls, so the UI stays perfectly smooth.
@MainActor
@Observable
final class MediaRemoteService {
    private(set) var playback = MediaPlayback()
    private(set) var artwork: NSImage?
    private(set) var accentColor: Color = .white

    var hasActiveMedia: Bool { !playback.title.isEmpty }

    private var pollTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var pollInFlight = false
    private var pollRequested = false
    private var missCount = 0
    private var artworkIdentity = ""
    private(set) var lastPlayingAt = Date.distantPast
    private(set) var lastActiveAt = Date.distantPast

    /// Compact-chrome visibility. A loaded track shows whether playing or
    /// paused — many apps (MMusic, some browsers) misreport `isPlaying`, and
    /// a paused track should stay visible to resume anyway. `idleDuration` is
    /// the grace kept after the track fully clears (player closed).
    func idleVisible(after idleDuration: Double) -> Bool {
        if hasActiveMedia { return true }
        return Date().timeIntervalSince(lastActiveAt) < idleDuration
    }

    private static let activePollInterval: Duration = .seconds(2)
    private static let idlePollInterval: Duration = .seconds(10)

    /// Field types vary by media source (e.g. identifiers are strings for
    /// Music but numbers for browsers), so every field decodes leniently —
    /// one odd field must never sink the whole payload.
    private struct GetPayload: Decodable {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsedTime: Double?
        var elapsedTimeNow: Double?
        var artworkData: String?
        var playbackRate: Double?
        var playing: Bool?
        var parentApplicationBundleIdentifier: String?
        var bundleIdentifier: String?
        var contentItemIdentifier: String?
        var shuffleMode: Int?
        var repeatMode: Int?
        var mediaType: String?

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            func str(_ key: String) -> String? {
                let k = AnyKey(stringValue: key)
                if let s = try? c.decode(String.self, forKey: k) { return s }
                if let i = try? c.decode(Int64.self, forKey: k) { return String(i) }
                if let d = try? c.decode(Double.self, forKey: k) { return String(d) }
                return nil
            }
            func num(_ key: String) -> Double? {
                let k = AnyKey(stringValue: key)
                if let d = try? c.decode(Double.self, forKey: k), d.isFinite { return d }
                if let s = try? c.decode(String.self, forKey: k) { return Double(s) }
                return nil
            }
            func bool(_ key: String) -> Bool? {
                let k = AnyKey(stringValue: key)
                if let b = try? c.decode(Bool.self, forKey: k) { return b }
                if let i = try? c.decode(Int.self, forKey: k) { return i != 0 }
                return nil
            }
            title = str("title")
            artist = str("artist")
            album = str("album")
            duration = num("duration")
            elapsedTime = num("elapsedTime")
            elapsedTimeNow = num("elapsedTimeNow")
            artworkData = str("artworkData")
            playbackRate = num("playbackRate")
            playing = bool("playing")
            parentApplicationBundleIdentifier = str("parentApplicationBundleIdentifier")
            bundleIdentifier = str("bundleIdentifier")
            contentItemIdentifier = str("contentItemIdentifier")
            shuffleMode = num("shuffleMode").map(Int.init)
            repeatMode = num("repeatMode").map(Int.init)
            mediaType = str("mediaType")
        }
    }

    private static var adapterPaths: (script: String, framework: String)? {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = Bundle.main.privateFrameworksPath
        else { return nil }
        let framework = frameworks + "/MediaRemoteAdapter.framework"
        guard FileManager.default.fileExists(atPath: framework) else { return nil }
        return (script.path, framework)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.requestPoll()
                guard let self else { return }
                let interval = self.hasActiveMedia
                    ? Self.activePollInterval
                    : Self.idlePollInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        confirmationTask?.cancel()
        confirmationTask = nil
        pollRequested = false
    }

    // MARK: - Polling

    private func requestPoll() async {
        if pollInFlight {
            pollRequested = true
            return
        }
        pollInFlight = true
        repeat {
            pollRequested = false
            await pollOnce()
        } while pollRequested && !Task.isCancelled
        pollInFlight = false
    }

    private func pollOnce() async {
        guard let paths = Self.adapterPaths else { return }
        let line = await Self.captureFirstLine(
            [paths.script, paths.framework, "get", "--now", "--no-artwork"]
        )
        guard let line, line != "null",
              let data = line.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GetPayload.self, from: data),
              let title = payload.title, !title.isEmpty
        else {
            registerMiss()
            return
        }

        // Per-app source toggle (Settings → Now Playing → Source).
        let sourceBundle = payload.parentApplicationBundleIdentifier
            ?? payload.bundleIdentifier ?? ""
        if !sourceBundle.isEmpty {
            SettingsStore.shared.rememberSource(sourceBundle)
            guard SettingsStore.shared.isSourceEnabled(sourceBundle) else {
                registerMiss()
                return
            }
        }

        missCount = 0
        apply(payload)

        if playback.trackIdentity != artworkIdentity {
            artworkIdentity = playback.trackIdentity
            mnotchLog.debug("track changed bundle=\(self.playback.bundleIdentifier, privacy: .private) video=\(self.playback.isVideo)")
            // Never show the previous track's artwork on the new one.
            artwork = nil
            accentColor = .white
            await fetchArtwork()
        }
    }

    private func apply(_ p: GetPayload) {
        var new = MediaPlayback()
        new.title = p.title ?? ""
        new.artist = p.artist ?? ""
        new.album = p.album ?? ""
        new.duration = p.duration ?? 0
        new.playbackRate = p.playbackRate ?? 1
        new.isPlaying = p.playing ?? false
        new.bundleIdentifier = p.parentApplicationBundleIdentifier ?? p.bundleIdentifier ?? ""
        new.trackIdentity = p.contentItemIdentifier ?? (new.title + "|" + new.artist)
        new.elapsedTime = p.elapsedTimeNow ?? p.elapsedTime ?? 0
        new.timestamp = Date()
        new.shuffleMode = p.shuffleMode
        new.repeatMode = p.repeatMode
        new.isVideo = p.mediaType?.localizedCaseInsensitiveContains("video") ?? false
        if new.isPlaying {
            lastPlayingAt = Date()
        }
        lastActiveAt = Date()   // a track is present this poll
        SettingsStore.shared.rememberSource(new.bundleIdentifier)
        if playback != new {
            playback = new
        }
    }

    private func registerMiss() {
        missCount += 1
        // Two consecutive empty polls before clearing, so a transient hiccup
        // doesn't collapse the media chrome.
        if missCount == 2, hasActiveMedia {
            playback = MediaPlayback()
            artwork = nil
            accentColor = .white
            artworkIdentity = ""
        }
    }

    /// Browsers often publish artwork a few seconds after the metadata, so a
    /// miss retries a few times while the track is still the same.
    private func fetchArtwork(attempt: Int = 0) async {
        guard let paths = Self.adapterPaths else { return }
        let identity = playback.trackIdentity
        let line = await Self.captureFirstLine([paths.script, paths.framework, "get"])

        // The track may have changed while the adapter ran.
        guard playback.trackIdentity == identity else { return }

        guard let line, line != "null",
              let data = line.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GetPayload.self, from: data),
              let artworkString = payload.artworkData
        else {
            if attempt < 4 {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.playback.trackIdentity == identity else { return }
                    await self.fetchArtwork(attempt: attempt + 1)
                }
            }
            return
        }

        let processed = await Task.detached(priority: .utility) {
            guard let data = Data(base64Encoded: artworkString.trimmingCharacters(
                in: .whitespacesAndNewlines
            )) else { return nil as (Data, DominantColor.Components)? }
            return (data, DominantColor.accent(from: data))
        }.value
        guard playback.trackIdentity == identity,
              let (imageData, accent) = processed,
              let image = NSImage(data: imageData)
        else { return }
        artwork = image
        accentColor = Color(red: accent.red, green: accent.green, blue: accent.blue)
        mnotchLog.debug("artwork loaded (attempt \(attempt))")
    }

    // MARK: - Commands

    /// Players MNotch can start with an explicit AppleScript `play` verb. Keyed
    /// by bundle id → scripting name; values are constants (never interpolated
    /// from user input) so the generated AppleScript is safe. Any other app is
    /// launched and nudged via MediaRemote instead.
    static let scriptablePlayers: [String: String] = [
        "com.apple.Music": "Music",
        "com.spotify.client": "Spotify",
    ]

    struct PreferredPlayer: Identifiable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Apps offered in the "Play button starts" picker: the media sources the
    /// notch has actually seen plus the common scriptable players — whichever
    /// are installed, listed by display name.
    static var installedPlayers: [PreferredPlayer] {
        let candidates = Set(scriptablePlayers.keys)
            .union(SettingsStore.shared.mediaKnownSources)
        return candidates.compactMap { bundle -> PreferredPlayer? in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
            else { return nil }
            return PreferredPlayer(
                bundleID: bundle,
                name: NSWorkspace.shared.appDisplayName(forBundleID: bundle)
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func send(_ command: MediaCommand) {
        // Pressing Play from an idle notch normally resumes whatever macOS last
        // treated as Now Playing (usually Apple Music). If the user picked a
        // preferred player and it isn't already the loaded source, start it
        // directly instead so the Play button honors their choice.
        let starting = command == .play
            || (command == .togglePlayPause && !playback.isPlaying)
        if starting, startPreferredPlayerIfNeeded() { return }

        // Optimistic flip so the button responds on the same frame.
        switch command {
        case .togglePlayPause:
            setPlayingOptimistically(!playback.isPlaying)
        case .play:
            setPlayingOptimistically(true)
        case .pause:
            setPlayingOptimistically(false)
        default:
            break
        }
        runAdapter(["send", String(command.rawValue)])
        pollSoon()
    }

    /// Returns true when a configured preferred player handled the start: bring
    /// the chosen app up, then play it — AppleScript for scriptable players, a
    /// MediaRemote nudge for everything else once it's the Now Playing app.
    private func startPreferredPlayerIfNeeded() -> Bool {
        let preferred = SettingsStore.shared.mediaPreferredPlayer
        guard !preferred.isEmpty,
              preferred != playback.bundleIdentifier,   // already loaded → normal resume
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferred)
        else { return false }
        setPlayingOptimistically(true)
        let scriptName = Self.scriptablePlayers[preferred]
        let nudge = Self.adapterPaths.map { [$0.script, $0.framework, "send", "0"] }
        Task.detached(priority: .userInitiated) { [weak self] in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            if let scriptName {
                var error: NSDictionary?
                NSAppleScript(source: "tell application \"\(scriptName)\" to play")?
                    .executeAndReturnError(&error)
                if let error {
                    mnotchLog.error("Preferred player script failed: \(error, privacy: .public)")
                }
            } else if let nudge {
                // Give the freshly launched app a moment to register as the
                // system Now Playing target, then send it a play command.
                try? await Task.sleep(for: .milliseconds(900))
                Self.runAdapterSync(nudge)
            }
            // Confirm state only AFTER the play action, so the poll doesn't run
            // (and revert the optimistic flip) before the app has started.
            await self?.pollSoon()
        }
        return true
    }

    func seek(to seconds: TimeInterval) {
        var p = playback
        p.elapsedTime = seconds
        p.timestamp = Date()
        playback = p
        runAdapter(["seek", String(Int(seconds * 1_000_000))])
        pollSoon()
    }

    /// Cycle repeat: off (1) → all (3) → one (2) → off.
    func cycleRepeat() {
        let next: Int = switch playback.repeatMode ?? 1 {
        case 1: 3
        case 3: 2
        default: 1
        }
        var p = playback
        p.repeatMode = next
        playback = p
        runAdapter(["repeat", String(next)])
        pollSoon()
    }

    func copyTrackInfo() {
        let text = playback.artist.isEmpty
            ? playback.title
            : "\(playback.title) — \(playback.artist)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Favorite the current track (Apple Music only, via AppleScript).
    func favoriteCurrentTrack() {
        guard playback.bundleIdentifier == "com.apple.Music" else { return }
        Task.detached(priority: .userInitiated) {
            let script = NSAppleScript(source: """
            tell application "Music"
                try
                    set favorited of current track to not (favorited of current track)
                end try
            end tell
            """)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
        }
    }

    func toggleShuffle() {
        // MRShuffleMode: 1 = off, 3 = songs.
        let target = playback.isShuffled ? 1 : 3
        var p = playback
        p.shuffleMode = target
        playback = p
        runAdapter(["shuffle", String(target)])
        pollSoon()
    }

    /// Quick confirmation poll shortly after a command.
    private func pollSoon() {
        confirmationTask?.cancel()
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.requestPoll()
        }
    }

    private func setPlayingOptimistically(_ playing: Bool) {
        var p = playback
        p.elapsedTime = p.elapsed()
        p.timestamp = Date()
        p.isPlaying = playing
        playback = p
    }

    private func runAdapter(_ arguments: [String]) {
        guard let paths = Self.adapterPaths else { return }
        let processArguments = [paths.script, paths.framework] + arguments
        Task.detached(priority: .userInitiated) {
            Self.runAdapterSync(processArguments)
        }
    }

    private nonisolated static func runAdapterSync(_ arguments: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            mnotchLog.error("Media command failed: \(error)")
        }
    }

    // MARK: - Process helper

    private nonisolated static func captureFirstLine(_ arguments: [String]) async -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        // Watchdog: a wedged adapter (stuck mediaremoted) would otherwise
        // block this await forever and freeze the entire poll loop on stale
        // now-playing state. Terminating closes the pipe → the read returns.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            proc.terminate()
        }
        defer { watchdog.cancel() }
        var first: String?
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                first = line
                break
            }
        } catch {
            return nil
        }
        return first
    }
}
