import AppKit
import Darwin

@main
struct NotchDropProcessProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let app = NotchDropApp(rawValue: args[2])!
        let store = NotchDropDiskStore(directory: URL(fileURLWithPath: args[1]), epoch: "qa-boot", isAlive: { kill($0.pid, 0) == 0 })
        var peer = NotchDropPeer(app: app, instance: UUID(), pid: getpid(), launched: 1, displays: app == .mfinder ? [1] : [1, 2])
        while let line = readLine() {
            do {
                let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let generation = request["generation"] as? Int
                let preference = (request["preference"] as? String).flatMap(NotchDropPreference.init(rawValue:))
                if let displays = request["displays"] as? [UInt32] { peer.displays = displays }
                var result: NotchDropState?
                for attempt in 0..<9 {
                    do { result = try store.transaction(peer: peer, remove: request["remove"] as? Bool == true,
                                                        preference: preference, generation: generation).0; break }
                    catch NotchDropDiskStore.StoreError.busy { if attempt == 8 { throw NotchDropDiskStore.StoreError.busy }; usleep(2_000 << attempt) }
                }
                let state = try JSONEncoder().encode(result!)
                FileHandle.standardOutput.write(state + Data([10]))
            } catch {
                let data = try JSONSerialization.data(withJSONObject: ["error": String(describing: error)])
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
    }
}
