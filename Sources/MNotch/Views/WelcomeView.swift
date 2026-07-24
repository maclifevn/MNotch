import AppKit
import SwiftUI

// MARK: - Welcome

/// First-launch onboarding: a clean, centered single column — brand hero, the
/// one manual permission (full-width so its description never crams), two quick
/// toggles, and the CTA. Adapts to light and dark.
///
/// Integration surface it must keep: `var onFinish: () -> Void`.
struct WelcomeView: View {
    var onFinish: () -> Void

    @Bindable private var settings = SettingsStore.shared
    private let accessibility = AppServices.shared.accessibility

    private var trusted: Bool { accessibility.isGranted }

    var body: some View {
        VStack(spacing: 22) {
            hero
            VStack(alignment: .leading, spacing: 22) {
                permissionSection
                setupSection
            }
            footer
        }
        .padding(.horizontal, 30)
        .padding(.top, 40)
        .padding(.bottom, 26)
        .frame(width: 460)
        .background(background)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            LogoPlate()
            VStack(spacing: 5) {
                Text("Welcome to MNotch")
                    .font(.system(size: 24, weight: .bold))
                Text("A Dynamic Island for your Mac")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Permission

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Permission")
            AccessibilityCard(trusted: trusted, onGrant: accessibility.requestAccess)
            OtherPermissionsNote()
        }
    }

    // MARK: Quick setup

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Quick setup")
            VStack(spacing: 0) {
                SetupToggleRow(
                    title: "Launch at login",
                    subtitle: "Open MNotch automatically after you sign in.",
                    isOn: $settings.launchAtLogin
                )
                Divider().padding(.leading, 16)
                SetupToggleRow(
                    title: "AI-agent quota & approvals",
                    subtitle: "Live Claude & Codex usage, plus inline approvals.",
                    isOn: $settings.agentEnabled
                )
                .onChange(of: settings.agentEnabled) { _, on in
                    AppServices.shared.setAgentMonitoringEnabled(on)
                }
            }
            .cardBackground()
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 9) {
            Button(action: onFinish) {
                Text("Get Started")
                    .font(.system(size: 15, weight: .semibold))
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

    // MARK: Background

    private var background: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            // Soft brand glow behind the hero, fading into the window.
            RadialGradient(
                colors: [Color.mnBrand.opacity(0.16), .clear],
                center: .top, startRadius: 0, endRadius: 260
            )
            .frame(height: 300)
            .frame(maxWidth: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

}

// MARK: - Hero logo

/// The bundled MNotch app-icon artwork, with a drawn fallback if it's missing.
private struct LogoPlate: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "icon_mnotch", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 1.0), Color(white: 0.92)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay { FacetedMark().frame(width: 54, height: 46) }
                    .overlay(
                        RoundedRectangle(cornerRadius: 21, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                    )
            }
        }
        .frame(width: 92, height: 92)
        .shadow(color: .black.opacity(0.20), radius: 11, x: 0, y: 6)
    }
}

// MARK: - Permission pieces

private struct AccessibilityCard: View {
    let trusted: Bool
    let onGrant: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.mnBrand.opacity(0.16))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "accessibility")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.mnBrand)
                    }
                Text("Accessibility")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                statusControl
            }
            Text("So the volume and brightness keys show only MNotch's HUD, not the system's.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.15), in: Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else {
            Button("Grant", action: onGrant)
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .tint(.mnBrand)
                .controlSize(.regular)
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
                Text(title).font(.system(size: 14, weight: .medium))
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

/// The three favicon polygons in the artwork's own 64 × 54.75 top-left-origin
/// space (SwiftUI shares that origin, so coords map straight through, peaks-up).
private enum Mountain {
    static let src = CGSize(width: 64, height: 54.75)
    static let backPeak: [CGPoint] = [
        CGPoint(x: 43.12, y: 2.94), CGPoint(x: 27.56, y: 26.78), CGPoint(x: 62.16, y: 50.15),
    ]
    static let leftPeak: [CGPoint] = [
        CGPoint(x: 13.77, y: 17.46), CGPoint(x: 1.29, y: 50.15),
        CGPoint(x: 12.29, y: 50.15), CGPoint(x: 27.56, y: 26.78),
    ]
    static let frontFace: [CGPoint] = [
        CGPoint(x: 27.56, y: 26.78), CGPoint(x: 12.29, y: 50.15), CGPoint(x: 62.16, y: 50.15),
    ]

    static func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + p.x / src.width * rect.width,
            y: rect.minY + p.y / src.height * rect.height
        )
    }

    static func path(for poly: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        guard let first = poly.first else { return path }
        path.move(to: point(first, in: rect))
        for p in poly.dropFirst() { path.addLine(to: point(p, in: rect)) }
        path.closeSubpath()
        return path
    }
}

private struct FacetShape: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path { Mountain.path(for: points, in: rect) }
}

/// The brand mountain drawn as three overlapping facets in graded blues.
private struct FacetedMark: View {
    var body: some View {
        ZStack {
            FacetShape(points: Mountain.frontFace).fill(Color(red: 0.04, green: 0.50, blue: 0.76))
            FacetShape(points: Mountain.leftPeak).fill(Color(red: 0.07, green: 0.66, blue: 0.90))
            FacetShape(points: Mountain.backPeak).fill(Color(red: 0.16, green: 0.80, blue: 0.97))
        }
        .aspectRatio(Mountain.src.width / Mountain.src.height, contentMode: .fit)
    }
}

// MARK: - Shared styling

private extension View {
    /// Native, appearance-adaptive card surface.
    func cardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
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
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
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
        // orderFrontRegardless so the accessory app can surface it at launch even
        // when another app is frontmost.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
