import AppKit
@preconcurrency import ApplicationServices
import Combine
import SwiftUI

// MARK: - Welcome

/// First-launch onboarding. A two-column layout: a brand hero rail on the left
/// (logo + name + tagline on a tinted panel) and a setup column on the right —
/// the one manual permission, two quick toggles, and the CTA.
///
/// Integration surface it must keep: `var onFinish: () -> Void`.
struct WelcomeView: View {
    var onFinish: () -> Void

    @Bindable private var settings = SettingsStore.shared
    @State private var trusted = AXIsProcessTrusted()

    // 1 Hz Accessibility poll so the status pill flips to "Granted" live the
    // moment the user allows MNotch in System Settings — no window reopen.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            HeroRail()
                .frame(width: 208)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 560, height: 640)
        .onReceive(ticker) { _ in refreshTrust() }
    }

    // MARK: Right column

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Let's get set up")
                    .font(.system(size: 20, weight: .bold))
                Text("One quick permission and you're ready to go.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            permissionsSection
            setupSection

            Spacer(minLength: 8)

            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Permission")
            AccessibilityCard(trusted: trusted, onGrant: requestAccessibility)
            OtherPermissionsNote()
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Quick setup")
            VStack(spacing: 0) {
                SetupToggleRow(
                    title: "Launch at login",
                    subtitle: "Open MNotch automatically after you sign in.",
                    isOn: $settings.launchAtLogin
                )
                Divider().padding(.leading, 14)
                SetupToggleRow(
                    title: "AI-agent quota & approvals",
                    subtitle: "Live Claude & Codex usage, plus inline approvals.",
                    isOn: $settings.agentEnabled
                )
                .onChange(of: settings.agentEnabled) { _, on in
                    // Mirror Settings → Agents: flipping the toggle actually
                    // starts/stops the monitor + quota services.
                    AppServices.shared.setAgentMonitoringEnabled(on)
                }
            }
            .cardBackground()
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button(action: onFinish) {
                Text("Get Started")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.mnBrand)
            .keyboardShortcut(.defaultAction)

            if !trusted {
                Text("You can grant Accessibility later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func requestAccessibility() {
        // Open the exact pane…
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // …and fire the system prompt so MNotch is pre-listed with a checkbox.
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func refreshTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        withAnimation(.smooth(duration: 0.35)) { trusted = now }
        // The event tap can go live the instant the grant lands — no relaunch.
        if now { AppServices.shared.keys.start() }
    }
}

// MARK: - Hero rail (left column)

private struct HeroRail: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.16, green: 0.80, blue: 0.97),
                Color(red: 0.05, green: 0.60, blue: 0.86),
                Color(red: 0.03, green: 0.40, blue: 0.66),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        // Soft light bloom in the top-left corner.
        .overlay(alignment: .topLeading) {
            RadialGradient(
                colors: [Color.white.opacity(0.30), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 230
            )
        }
        // Oversized ghost peak anchored bottom-trailing for quiet depth.
        .overlay(alignment: .bottomTrailing) {
            MountainSilhouette()
                .fill(Color.white.opacity(0.08))
                .frame(width: 250, height: 214)
                .offset(x: 74, y: 58)
        }
        .overlay { railContent }
        .clipped()
    }

    private var railContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            LogoPlate()
                .padding(.bottom, 20)

            Text("MNotch")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text("A Dynamic Island for your Mac")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Spacer(minLength: 24)

            FeatureGlyphs()
        }
        .padding(.horizontal, 24)
        .padding(.top, 52) // clear the window's traffic-light buttons
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Near-white "app icon" plate holding the faceted brand mountain.
private struct LogoPlate: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 1.0), Color(white: 0.90)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 74, height: 74)
            .overlay {
                FacetedMark()
                    .frame(width: 46, height: 39)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 9, x: 0, y: 5)
    }
}

/// A subtle translucent strip hinting at what MNotch does.
private struct FeatureGlyphs: View {
    private let glyphs = ["music.note", "sun.max.fill", "battery.100", "sparkles"]

    var body: some View {
        HStack(spacing: 15) {
            ForEach(glyphs, id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Right-column pieces

private struct AccessibilityCard: View {
    let trusted: Bool
    let onGrant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mnBrand.opacity(0.16))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "accessibility")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.mnBrand)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("Accessibility")
                    .font(.system(size: 14, weight: .semibold))
                Text("So the volume and brightness keys show only MNotch's HUD instead of the system's.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            statusControl
        }
        .padding(14)
        .cardBackground()
    }

    @ViewBuilder private var statusControl: some View {
        if trusted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.15), in: Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            Button("Grant", action: onGrant)
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .tint(.mnBrand)
                .controlSize(.small)
        }
    }
}

private struct OtherPermissionsNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("Calendar, Bluetooth, and AI-agent hooks are requested only when you first use those features.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

private struct SetupToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.mnBrand)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

// MARK: - Brand mountain mark

/// The three favicon polygons, in the artwork's own 64 × 54.75 top-left-origin
/// space. SwiftUI shares that origin (y grows downward), so the coordinates map
/// straight through and the range reads peaks-up.
private enum Mountain {
    static let src = CGSize(width: 64, height: 54.75)

    static let backPeak: [CGPoint] = [ // tall main peak (favicon p2)
        CGPoint(x: 43.12, y: 2.94),
        CGPoint(x: 27.56, y: 26.78),
        CGPoint(x: 62.16, y: 50.15),
    ]
    static let leftPeak: [CGPoint] = [ // foothill (favicon p1)
        CGPoint(x: 13.77, y: 17.46),
        CGPoint(x: 1.29, y: 50.15),
        CGPoint(x: 12.29, y: 50.15),
        CGPoint(x: 27.56, y: 26.78),
    ]
    static let frontFace: [CGPoint] = [ // front base (favicon p3)
        CGPoint(x: 27.56, y: 26.78),
        CGPoint(x: 12.29, y: 50.15),
        CGPoint(x: 62.16, y: 50.15),
    ]
    static let all: [[CGPoint]] = [frontFace, leftPeak, backPeak]

    static func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + p.x / src.width * rect.width,
            y: rect.minY + p.y / src.height * rect.height
        )
    }

    static func path(for polys: [[CGPoint]], in rect: CGRect) -> Path {
        var path = Path()
        for poly in polys {
            guard let first = poly.first else { continue }
            path.move(to: point(first, in: rect))
            for p in poly.dropFirst() { path.addLine(to: point(p, in: rect)) }
            path.closeSubpath()
        }
        return path
    }
}

/// One facet of the mountain (a single polygon), so each can carry its own tint.
private struct FacetShape: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path { Mountain.path(for: [points], in: rect) }
}

/// The full merged silhouette — used for the faint ghost peak on the rail.
private struct MountainSilhouette: Shape {
    func path(in rect: CGRect) -> Path { Mountain.path(for: Mountain.all, in: rect) }
}

/// The brand mountain drawn as three overlapping facets in graded blues.
private struct FacetedMark: View {
    var body: some View {
        ZStack {
            FacetShape(points: Mountain.frontFace)
                .fill(Color(red: 0.04, green: 0.50, blue: 0.76))
            FacetShape(points: Mountain.leftPeak)
                .fill(Color(red: 0.07, green: 0.66, blue: 0.90))
            FacetShape(points: Mountain.backPeak)
                .fill(Color(red: 0.16, green: 0.80, blue: 0.97))
        }
        .aspectRatio(Mountain.src.width / Mountain.src.height, contentMode: .fit)
    }
}

// MARK: - Shared styling

private extension View {
    /// Native, appearance-adaptive card surface used behind the setup groups.
    func cardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

private extension Color {
    /// MNotch brand blue (#12C3F4).
    static let mnBrand = Color(red: 18 / 255, green: 195 / 255, blue: 244 / 255)
}

/// First-launch Welcome window. Shown once (guarded by SettingsStore.hasSeenWelcome).
@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: WelcomeView(onFinish: { [weak self] in self?.window?.close() })
            )
            window.center()
            self.window = window
            // Mark seen on first show so it never reappears, however it's closed.
            SettingsStore.shared.hasSeenWelcome = true
        }
        // orderFrontRegardless (not just makeKeyAndOrderFront) so the window
        // appears even though MNotch is an accessory app that can't self-activate
        // when another app is frontmost at launch.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
