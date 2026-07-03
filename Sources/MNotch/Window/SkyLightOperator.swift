import AppKit

/// Places windows on the macOS lock screen. The modern lock screen composites
/// in a secure WindowServer space that ordinary user-session windows never
/// join — no public window level reaches it. The private SkyLight framework
/// can create a space at the lock-screen level and move a window into it.
///
/// Technique from Lakr233/SkyLightWindow. All symbols are resolved at runtime
/// via dlopen, so nothing is linked against a private framework.
@MainActor
final class SkyLightOperator {
    static let shared = SkyLightOperator()

    /// Absolute space levels (a subset). NotificationCenterAtScreenLock (400)
    /// sits above the lock UI, where Notification Center draws on the lock
    /// screen — exactly where a lock widget belongs.
    private static let lockLevel: Int32 = 400

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsRemoveSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindowsRemoveSpaces?

    let available: Bool

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW
        ),
            let mainConn = dlsym(handle, "SLSMainConnectionID"),
            let create = dlsym(handle, "SLSSpaceCreate"),
            let setLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
            let show = dlsym(handle, "SLSShowSpaces"),
            let add = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else {
            connection = 0
            space = 0
            addWindows = nil
            available = false
            mnotchLog.error("SkyLight unavailable; lock screen overlay disabled")
            return
        }

        let mainConnFn = unsafeBitCast(mainConn, to: MainConnectionID.self)
        let createFn = unsafeBitCast(create, to: SpaceCreate.self)
        let setLevelFn = unsafeBitCast(setLevel, to: SpaceSetAbsoluteLevel.self)
        let showFn = unsafeBitCast(show, to: ShowSpaces.self)
        addWindows = unsafeBitCast(add, to: AddWindowsRemoveSpaces.self)

        connection = mainConnFn()
        space = createFn(connection, 1, 0)
        _ = setLevelFn(connection, space, Self.lockLevel)
        _ = showFn(connection, [space] as CFArray)
        available = space != 0
        mnotchLog.notice("SkyLight lock space created id=\(self.space) conn=\(self.connection)")
    }

    /// Move a window into the lock-screen space so it draws over the shield.
    func addToLockSpace(_ window: NSWindow) {
        guard available, let addWindows else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
