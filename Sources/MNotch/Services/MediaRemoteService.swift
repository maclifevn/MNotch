import AppKit
import os
import SwiftUI

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
    var isPolling: Bool { pollTask != nil }

    private var commandTask: Task<Void, Never>?
    private var pendingCommands: [SubprocessRunner.Request] = []
    private var pollTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var idleExpiryTask: Task<Void, Never>?
    private var preferredStartTask: Task<Void, Never>?
    private var preferredStartRevision: UInt64 = 0
    private var playbackIntent: PlaybackIntent?
    private(set) var visibilityRevision: UInt64 = 0
    private var pollInFlight = false
    private var pollRequested = false
    private var runGeneration: UInt64 = 0
    private var missCount = 0
    private var artworkIdentity = ""
    private(set) var lastPlayingAt = Date.distantPast
    private(set) var lastActiveAt = Date.distantPast

    private struct PlaybackIntent {
        let desiredPlaying: Bool
        let sourceBundleID: String
        let expiresAt: Date
    }

    /// Compact-chrome visibility. A loaded track shows whether playing or
    /// paused — many apps (MMusic, some browsers) misreport `isPlaying`, and
    /// a paused track should stay visible to resume anyway. `idleDuration` is
    /// the grace kept after the track fully clears (player closed).
    func idleVisible(after idleDuration: Double) -> Bool {
        _ = visibilityRevision
        if hasActiveMedia { return true }
        return Date().timeIntervalSince(lastActiveAt) < idleDuration
    }

    private static let activePollInterval: Duration = .seconds(2)
    private static let idlePollInterval: Duration = .seconds(10)

    /// Field types vary by media source (e.g. identifiers are strings for
    /// Music but numbers for browsers), so every field decodes leniently —
    /// one odd field must never sink the whole payload.
    struct GetPayload: Decodable {
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
                if let s = try? c.decode(String.self, forKey: k) { return SafeNumeric.number(s) }
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
            shuffleMode = SafeNumeric.integer(num("shuffleMode"))
            repeatMode = SafeNumeric.integer(num("repeatMode"))
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
        runGeneration &+= 1
        let generation = runGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.requestPoll(generation: generation)
                guard let self, self.runGeneration == generation else { return }
                let interval = self.hasActiveMedia
                    ? Self.activePollInterval
                    : Self.idlePollInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        runGeneration &+= 1
        commandTask?.cancel()
        commandTask = nil
        pendingCommands.removeAll()
        pollTask?.cancel()
        pollTask = nil
        confirmationTask?.cancel()
        confirmationTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        idleExpiryTask?.cancel()
        idleExpiryTask = nil
        preferredStartRevision &+= 1
        preferredStartTask?.cancel()
        preferredStartTask = nil
        playbackIntent = nil
        pollRequested = false
        pollInFlight = false
        missCount = 0
        playback = MediaPlayback()
        artwork = nil
        accentColor = .white
        artworkIdentity = ""
        lastPlayingAt = .distantPast
        lastActiveAt = .distantPast
        visibilityRevision &+= 1
    }

    // MARK: - Polling

    private func requestPoll(generation: UInt64) async {
        guard generation == runGeneration else { return }
        if pollInFlight {
            pollRequested = true
            return
        }
        pollInFlight = true
        repeat {
            pollRequested = false
            await pollOnce(generation: generation)
        } while generation == runGeneration
            && pollRequested
            && !Task.isCancelled
        guard generation == runGeneration else { return }
        pollInFlight = false
    }

    private func pollOnce(generation: UInt64) async {
        guard let paths = Self.adapterPaths else { return }
        let line = await Self.captureFirstLine(
            [paths.script, paths.framework, "get", "--now", "--no-artwork"]
        )
        guard !Task.isCancelled, generation == runGeneration else { return }
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
            artworkTask?.cancel()
            let identity = playback.trackIdentity
            artworkTask = Task { [weak self] in
                await self?.fetchArtwork(for: identity)
                guard let self, self.runGeneration == generation, self.artworkIdentity == identity else { return }
                self.artworkTask = nil
            }
        }
    }

    private func apply(_ p: GetPayload) {
        idleExpiryTask?.cancel()
        idleExpiryTask = nil
        let now = Date()
        var new = MediaPlayback()
        new.title = p.title ?? ""
        new.artist = p.artist ?? ""
        new.album = p.album ?? ""
        new.duration = Self.safeMediaSeconds(p.duration)
        new.bundleIdentifier = p.parentApplicationBundleIdentifier ?? p.bundleIdentifier ?? ""
        new.trackIdentity = p.contentItemIdentifier ?? (new.title + "|" + new.artist)
        new.elapsedTime = Self.safeMediaSeconds(p.elapsedTimeNow ?? p.elapsedTime)
        new.timestamp = now
        new.shuffleMode = p.shuffleMode
        new.repeatMode = p.repeatMode
        new.isVideo = p.mediaType?.localizedCaseInsensitiveContains("video") ?? false

        let reportedPlaying = Self.reportedPlaying(
            flag: p.playing,
            playbackRate: p.playbackRate
        )
        var resolvedPlaying = reportedPlaying
        if let intent = playbackIntent {
            let sameSource = intent.sourceBundleID.isEmpty
                || intent.sourceBundleID == new.bundleIdentifier
            if reportedPlaying == intent.desiredPlaying {
                playbackIntent = nil
            } else if sameSource,
                      Self.shouldHoldOptimisticState(
                        desired: intent.desiredPlaying,
                        reported: reportedPlaying,
                        deadline: intent.expiresAt,
                        now: now
                      ) {
                // MediaRemote's independent `playing` and metadata callbacks
                // can still describe the frame before our command. Do not let
                // that stale poll flip the button back and then forward again.
                resolvedPlaying = intent.desiredPlaying
            } else {
                playbackIntent = nil
            }
        }
        new.isPlaying = resolvedPlaying
        new.playbackRate = p.playbackRate.flatMap { (-16...16).contains($0) ? $0 : nil } ?? (resolvedPlaying ? 1 : 0)

        if new.isPlaying {
            lastPlayingAt = now
        }
        lastActiveAt = now   // a track is present this poll
        SettingsStore.shared.rememberSource(new.bundleIdentifier)
        if Self.shouldPublishPlayback(current: playback, candidate: new, at: now) {
            playback = new
        }
    }

    /// MediaRemote obtains the boolean and playback-rate metadata through two
    /// separate callbacks. During a pause transition either one can arrive
    /// first; a definite paused value wins so the notch never keeps animating
    /// merely because the other field is one sample behind.
    nonisolated static func reportedPlaying(
        flag: Bool?,
        playbackRate: Double?
    ) -> Bool {
        if flag == false { return false }
        if let playbackRate, playbackRate <= 0 { return false }
        if flag == true { return true }
        return (playbackRate ?? 0) > 0
    }

    nonisolated static func shouldHoldOptimisticState(
        desired: Bool,
        reported: Bool,
        deadline: Date,
        now: Date
    ) -> Bool {
        desired != reported && now < deadline
    }

    /// Polling is only a correction mechanism; the seek bar extrapolates time
    /// locally. Ignore timestamp-only samples (and tiny clock drift) so the
    /// entire observable media tree is not invalidated every two seconds.
    nonisolated static func shouldPublishPlayback(
        current: MediaPlayback,
        candidate: MediaPlayback,
        at now: Date
    ) -> Bool {
        guard current.title == candidate.title,
              current.artist == candidate.artist,
              current.album == candidate.album,
              abs(current.duration - candidate.duration) < 0.05,
              abs(current.playbackRate - candidate.playbackRate) < 0.01,
              current.isPlaying == candidate.isPlaying,
              current.bundleIdentifier == candidate.bundleIdentifier,
              current.trackIdentity == candidate.trackIdentity,
              current.shuffleMode == candidate.shuffleMode,
              current.repeatMode == candidate.repeatMode,
              current.isVideo == candidate.isVideo
        else { return true }

        return abs(current.elapsed(at: now) - candidate.elapsedTime) > 1.25
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
            artworkTask?.cancel()
            artworkTask = nil
            scheduleIdleExpiry(after: SettingsStore.shared.mediaIdleDuration)
        }
    }

    /// `idleVisible` is time-based, but Observation only redraws on a property
    /// change. Schedule that exact boundary so a 3-second grace doesn't remain
    /// on screen until the next 10-second idle media poll.
    func scheduleIdleExpiry(after duration: Double) {
        idleExpiryTask?.cancel()
        idleExpiryTask = nil
        guard !hasActiveMedia else { return }
        let remaining = duration - Date().timeIntervalSince(lastActiveAt)
        guard remaining > 0 else {
            visibilityRevision &+= 1
            return
        }
        idleExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self, !self.hasActiveMedia else { return }
            self.idleExpiryTask = nil
            self.visibilityRevision &+= 1
        }
    }

    /// Browsers often publish artwork a few seconds after the metadata, so a
    /// miss retries a few times while the track is still the same.
    private func fetchArtwork(for identity: String) async {
        guard let paths = Self.adapterPaths else { return }
        for attempt in 0...4 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled, playback.trackIdentity == identity else { return }

            let line = await Self.captureFirstLine([paths.script, paths.framework, "get"])
            guard !Task.isCancelled, playback.trackIdentity == identity else { return }
            guard let line, line != "null",
                  let data = line.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(GetPayload.self, from: data),
                  let artworkString = payload.artworkData
            else { continue }

            let processed = await Task.detached(priority: .utility) {
                guard let data = Data(base64Encoded: artworkString.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )) else { return nil as (Data, DominantColor.Components)? }
                guard let thumbnail = ArtworkDecoder.thumbnailData(data) else { return nil }
                return (thumbnail, DominantColor.accent(from: thumbnail))
            }.value
            guard !Task.isCancelled,
                  playback.trackIdentity == identity,
                  let (imageData, accent) = processed,
                  let image = NSImage(data: imageData)
            else { return }
            artwork = image
            accentColor = Color(red: accent.red, green: accent.green, blue: accent.blue)
            mnotchLog.debug("artwork loaded (attempt \(attempt))")
            return
        }
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
        // Until a newly opened preferred app has positively become the system
        // Now Playing source, no command may fall through to the global route.
        // A second click during launch would otherwise wake the previous target
        // (commonly Apple Music), recreating the exact cross-player bug this
        // guarded start path is intended to prevent.
        guard preferredStartTask == nil else { return }

        // Pressing Play from an idle notch normally resumes whatever macOS last
        // treated as Now Playing (usually Apple Music). If the user picked a
        // preferred player and it isn't already the loaded source, start it
        // directly instead so the Play button honors their choice.
        let starting = command == .play
            || (command == .togglePlayPause && !playback.isPlaying)
        if starting, startPreferredPlayerIfNeeded() { return }

        // Optimistic flip so the button responds on the same frame. Convert a
        // toggle into an explicit idempotent Play/Pause command; this prevents
        // rapid clicks or delayed helpers from toggling an already-correct
        // player back to the wrong state.
        var adapterCommand = command
        switch command {
        case .togglePlayPause:
            let desired = !playback.isPlaying
            beginPlaybackIntent(desired)
            setPlayingOptimistically(desired)
            adapterCommand = desired ? .play : .pause
        case .play:
            beginPlaybackIntent(true)
            setPlayingOptimistically(true)
        case .pause:
            beginPlaybackIntent(false)
            setPlayingOptimistically(false)
        default:
            break
        }
        runAdapter(["send", String(adapterCommand.rawValue)])
        pollSoon()
    }

    /// Called for a hardware media key observed by the global event tap. The
    /// event itself is passed through untouched; this method only predicts the
    /// resulting UI state and schedules confirmation polls.
    func observeExternalCommand(_ command: MediaCommand) {
        switch command {
        case .togglePlayPause:
            let desired = !playback.isPlaying
            beginPlaybackIntent(desired)
            setPlayingOptimistically(desired)
        case .play:
            beginPlaybackIntent(true)
            setPlayingOptimistically(true)
        case .pause:
            beginPlaybackIntent(false)
            setPlayingOptimistically(false)
        case .nextTrack, .previousTrack:
            break
        }
        pollSoon(initialDelay: .milliseconds(180))
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
        let paths = Self.adapterPaths
        preferredStartRevision &+= 1
        let revision = preferredStartRevision
        preferredStartTask = Task.detached(priority: .userInitiated) { [weak self] in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            guard !Task.isCancelled else {
                await self?.finishPreferredStart(revision: revision)
                return
            }
            if let scriptName {
                _ = await SubprocessRunner.run(.init(
                    executable: "/usr/bin/osascript",
                    arguments: ["-e", #"tell application "\#(scriptName)" to play"#],
                    component: .media
                ))
            } else if let paths {
                // MediaRemote's send command has no target bundle ID. Never
                // broadcast on a timer: wait until the selected player itself
                // is the observed Now Playing source, then an idempotent Play
                // is safe. If it never registers, fail closed and merely leave
                // the requested app open instead of waking Apple Music.
                await Self.playWhenPreferredTargetIsReady(
                    preferredBundleID: preferred,
                    paths: paths
                )
            }
            // Confirm state only AFTER the play action, so the poll doesn't run
            // (and revert the optimistic flip) before the app has started.
            await self?.finishPreferredStart(revision: revision)
        }
        return true
    }

    private func finishPreferredStart(revision: UInt64) {
        guard revision == preferredStartRevision else { return }
        preferredStartTask = nil
        pollSoon()
    }

    /// Pure routing rule kept internal for regression tests. Unknown playback
    /// state is treated as paused only after the source bundle is an exact
    /// match; a different or missing source must never receive a global Play.
    nonisolated static func shouldSendPreferredPlay(
        preferredBundleID: String,
        observedBundleID: String?,
        observedPlaying: Bool?
    ) -> Bool {
        observedBundleID == preferredBundleID && observedPlaying != true
    }

    nonisolated static func playWhenPreferredTargetIsReady(
        preferredBundleID: String,
        paths: (script: String, framework: String),
        registrationTimeout: TimeInterval = 8
    ) async {
        // Registration has one total deadline. Twelve individually timed-out
        // helpers must not hold a preferred start for 96 seconds.
        guard registrationTimeout.isFinite, registrationTimeout > 0 else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + min(8, registrationTimeout)
        for attempt in 0..<12 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard !Task.isCancelled, remaining > 0 else { return }
            let line = await captureFirstLine([
                paths.script, paths.framework, "get", "--now", "--no-artwork",
            ], timeout: min(8, remaining))
            guard !Task.isCancelled else { return }

            if let line, line != "null",
               let data = line.data(using: .utf8),
               let payload = try? JSONDecoder().decode(GetPayload.self, from: data) {
                let observed = payload.parentApplicationBundleIdentifier
                    ?? payload.bundleIdentifier
                if observed == preferredBundleID {
                    if shouldSendPreferredPlay(
                        preferredBundleID: preferredBundleID,
                        observedBundleID: observed,
                        observedPlaying: payload.playing
                    ) {
                        _ = await SubprocessRunner.run(.init(
                            executable: "/usr/bin/perl",
                            arguments: [paths.script, paths.framework, "send", "0"], component: .media
                        ))
                    }
                    return
                }
            }

            if attempt < 11 {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0,
              let microseconds = SafeNumeric.integer(seconds * 1_000_000) else { return }
        var p = playback
        p.elapsedTime = seconds
        p.timestamp = Date()
        playback = p
        runAdapter(["seek", String(microseconds)])
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
        enqueueCommand(.init(executable: "/usr/bin/osascript", arguments: ["-e", """
            tell application "Music"
                try
                    set favorited of current track to not (favorited of current track)
                end try
            end tell
            """], component: .media))
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
    private func pollSoon(initialDelay: Duration = .milliseconds(350)) {
        guard pollTask != nil else { return }
        confirmationTask?.cancel()
        let generation = runGeneration
        confirmationTask = Task { [weak self] in
            // One early read gives responsive shortcut feedback; two spaced
            // confirmations cover slow players without increasing idle polling
            // or leaving a stale optimistic state indefinitely.
            for delay in [initialDelay, .milliseconds(700), .milliseconds(950)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.requestPoll(generation: generation)
            }
        }
    }

    private func beginPlaybackIntent(_ desiredPlaying: Bool) {
        playbackIntent = PlaybackIntent(
            desiredPlaying: desiredPlaying,
            sourceBundleID: playback.bundleIdentifier,
            expiresAt: Date().addingTimeInterval(2.5)
        )
    }

    private func setPlayingOptimistically(_ playing: Bool) {
        var p = playback
        p.elapsedTime = p.elapsed()
        p.timestamp = Date()
        p.isPlaying = playing
        playback = p
    }

    nonisolated static func safeMediaSeconds(_ value: Double?) -> Double {
        // A finite but enormous duration still traps display-time Int conversion.
        // One year supports long streams while bounding all display arithmetic.
        guard let value, value.isFinite, (0...31_536_000).contains(value) else { return 0 }
        return value
    }

    private func runAdapter(_ arguments: [String]) {
        guard let paths = Self.adapterPaths else { return }
        let request = SubprocessRunner.Request(executable: "/usr/bin/perl",
            arguments: [paths.script, paths.framework] + arguments, component: .media)
        if arguments.first == "seek", let index = pendingCommands.lastIndex(where: { $0.arguments.dropFirst(2).first == "seek" }) {
            pendingCommands[index] = request
            return
        }
        enqueueCommand(request)
    }

    private func enqueueCommand(_ request: SubprocessRunner.Request) {
        guard pendingCommands.count < 16 else {
            AppDiagnostics.record(.media, .outputLimit)
            return
        }
        pendingCommands.append(request)
        guard commandTask == nil else { return }
        let generation = runGeneration
        commandTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.runGeneration == generation else { return }
                guard !self.pendingCommands.isEmpty else { self.commandTask = nil; return }
                let next = self.pendingCommands.removeFirst()
                _ = await SubprocessRunner.run(next)
            }
        }
    }

    // The artwork response is larger; metadata-only responses use a 1 MiB cap.
    private nonisolated static func captureFirstLine(_ arguments: [String], timeout: TimeInterval = 8) async -> String? {
        let limit = arguments.contains("--no-artwork") ? 1_024 * 1_024 : 16 * 1_024 * 1_024
        let result = await SubprocessRunner.run(.init(
            executable: "/usr/bin/perl", arguments: arguments,
            timeout: timeout, outputLimit: limit, component: .media
        ))
        guard result.succeeded, !Task.isCancelled else { return nil }
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n", maxSplits: 1).first.map(String.init)
    }
}
