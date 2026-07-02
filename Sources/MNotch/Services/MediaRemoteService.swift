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
    var isVideo = false

    var isShuffled: Bool { (shuffleMode ?? 1) != 1 }

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
    private var missCount = 0
    private var artworkIdentity = ""

    private static let pollInterval: Duration = .seconds(2)

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
                await self?.pollOnce()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

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

        missCount = 0
        apply(payload)

        if playback.trackIdentity != artworkIdentity {
            artworkIdentity = playback.trackIdentity
            mnotchLog.notice("track: \"\(self.playback.title, privacy: .public)\" — \(self.playback.artist, privacy: .public) [\(self.playback.bundleIdentifier, privacy: .public)] video=\(self.playback.isVideo)")
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
        new.isVideo = p.mediaType?.localizedCaseInsensitiveContains("video") ?? false
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

    private func fetchArtwork() async {
        guard let paths = Self.adapterPaths else { return }
        let line = await Self.captureFirstLine([paths.script, paths.framework, "get"])
        guard let line, line != "null",
              let data = line.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GetPayload.self, from: data),
              let artworkString = payload.artworkData,
              let imageData = Data(base64Encoded: artworkString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let image = NSImage(data: imageData)
        else { return }
        artwork = image
        accentColor = DominantColor.accent(from: image)
        mnotchLog.notice("artwork loaded for \(self.playback.title, privacy: .public)")
    }

    // MARK: - Commands

    func send(_ command: MediaCommand) {
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

    func seek(to seconds: TimeInterval) {
        var p = playback
        p.elapsedTime = seconds
        p.timestamp = Date()
        playback = p
        runAdapter(["seek", String(Int(seconds * 1_000_000))])
        pollSoon()
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
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            await self?.pollOnce()
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [paths.script, paths.framework] + arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
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
