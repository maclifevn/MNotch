import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case battery, connectivity, focus, display, sound
    case nowPlaying, calendar, fileTray, lockScreen, agent
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .battery: "Battery"
        case .connectivity: "Connectivity"
        case .focus: "Focus"
        case .display: "Display"
        case .sound: "Sound"
        case .nowPlaying: "Now Playing"
        case .calendar: "Calendar"
        case .fileTray: "File Tray"
        case .lockScreen: "Lock Screen"
        case .agent: "Agents"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .battery: "bolt.fill"
        case .connectivity: "headphones"
        case .focus: "moon.fill"
        case .display: "sun.max.fill"
        case .sound: "speaker.wave.2.fill"
        case .nowPlaying: "play.fill"
        case .calendar: "calendar"
        case .fileTray: "tray.fill"
        case .lockScreen: "lock.fill"
        case .agent: "terminal.fill"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .battery: .orange
        case .focus: .indigo
        case .connectivity: .green
        case .display: .purple
        case .sound: .pink
        case .nowPlaying: .red
        case .calendar: .red
        case .fileTray: Color(white: 0.45)
        case .lockScreen: .black
        case .agent: .teal
        case .about: .gray
        }
    }
}

struct SettingsView: View {
    @State private var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                sidebarRow(.general)
                Section("Notifications") {
                    sidebarRow(.battery)
                    sidebarRow(.connectivity)
                    sidebarRow(.focus)
                    sidebarRow(.display)
                    sidebarRow(.sound)
                }
                Section("Live Activities") {
                    sidebarRow(.nowPlaying)
                    sidebarRow(.calendar)
                    sidebarRow(.fileTray)
                    sidebarRow(.lockScreen)
                }
                Section("Developer") {
                    sidebarRow(.agent)
                }
                Section("MNotch") {
                    sidebarRow(.about)
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            detailPane
                .navigationTitle(section.title)
        }
        .frame(width: 760, height: 620)
    }

    private func sidebarRow(_ s: SettingsSection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(s.color.gradient, in: RoundedRectangle(cornerRadius: 6))
            Text(s.title)
        }
        .tag(s)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch section {
        case .general: GeneralPane()
        case .battery: BatteryPane()
        case .connectivity: ConnectivityPane()
        case .focus: FocusPane()
        case .display: DisplayPane()
        case .sound: SoundPane()
        case .nowPlaying: NowPlayingPane()
        case .calendar: CalendarPane()
        case .fileTray: FileTrayPane()
        case .lockScreen: LockScreenPane()
        case .agent: AgentPane()
        case .about: AboutPane()
        }
    }
}

/// Hand-managed settings window (no SwiftUI Settings scene in an SPM binary).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "MNotch Settings"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
