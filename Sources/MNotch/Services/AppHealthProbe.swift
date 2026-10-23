import Foundation

/// Extra opt-in soak instrumentation, separate from the always-on persistent
/// journal/watchdog. The harness supplies its destination and unique bundle ID.
@MainActor
final class AppHealthProbe {
    private var timer: Timer?
    private var writing = false
    private var sequence: UInt64 = 0
    private var previousTick = ProcessInfo.processInfo.systemUptime

    private struct Heartbeat: Encodable, Sendable {
        let sequence: UInt64
        let uptime: TimeInterval
        let mainThreadInterval: TimeInterval
        let diagnostics: AppDiagnostics.Report
    }

    func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard timer == nil, environment["MNOTCH_DIAGNOSTIC_RUN"] == "1",
              let path = environment["MNOTCH_HEALTH_FILE"], path.hasPrefix("/") else { return }
        let destination = URL(fileURLWithPath: path)
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(destination: destination) }
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick(destination: destination)
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick(destination: URL) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let interval = uptime - previousTick
        previousTick = uptime
        sequence &+= 1
        guard !writing else { return }
        writing = true
        let heartbeat = Heartbeat(sequence: sequence, uptime: uptime,
                                  mainThreadInterval: interval, diagnostics: AppDiagnostics.report())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(heartbeat) { try? data.write(to: destination, options: .atomic) }
            Task { @MainActor [weak self] in self?.writing = false }
        }
    }
}
