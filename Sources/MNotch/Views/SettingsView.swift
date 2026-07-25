import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case battery, connectivity, focus, hud
    case nowPlaying, calendar, pomodoro, fileTray, lockScreen, agent
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.string("General")
        case .battery: L10n.string("Battery")
        case .connectivity: L10n.string("Connectivity")
        case .focus: L10n.string("Focus")
        case .hud: L10n.string("Display & Sound")
        case .nowPlaying: L10n.string("Now Playing")
        case .calendar: L10n.string("Calendar")
        case .pomodoro: L10n.string("Pomodoro")
        case .fileTray: L10n.string("File Tray")
        case .lockScreen: L10n.string("Lock Screen")
        case .agent: L10n.string("Agents")
        case .about: L10n.string("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .battery: "bolt.fill"
        case .connectivity: "headphones"
        case .focus: "moon.fill"
        case .hud: "slider.horizontal.3"
        case .nowPlaying: "play.fill"
        case .calendar: "calendar"
        case .pomodoro: "timer"
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
        case .hud: .purple
        case .nowPlaying: .red
        case .calendar: .red
        case .pomodoro: .orange
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
                    sidebarRow(.hud)
                }
                Section("Live Activities") {
                    sidebarRow(.nowPlaying)
                    sidebarRow(.calendar)
                    sidebarRow(.pomodoro)
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
        case .hud: HUDPane()
        case .nowPlaying: NowPlayingPane()
        case .calendar: CalendarPane()
        case .pomodoro: PomodoroPane()
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
            window.title = L10n.string("MNotch Settings")
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
