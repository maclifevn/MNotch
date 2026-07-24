import SwiftUI

/// Shared layout for the Display (brightness) and Sound (volume) HUD panes.
struct HUDSettingsPane: View {
    let title: String
    let symbol: String
    @Binding var enabled: Bool
    @Binding var duration: Double
    @Binding var barStyle: HUDBarStyle
    @Binding var showPercentage: Bool
    @Binding var hideLabel: Bool
    @Binding var animSpeed: AnimSpeed
    var extra: AnyView? = nil

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Label(title, systemImage: symbol)
                }
                Group {
                    SliderRow(
                        title: "Duration",
                        value: $duration,
                        range: 0.5...3,
                        step: 0.25
                    ) { String(format: "%.1f s", $0) }

                    OptionCardPicker(
                        selection: $barStyle,
                        options: HUDBarStyle.allCases,
                        label: { style in
                            switch style {
                            case .white: "White"
                            case .accent: "Accent"
                            case .decibel: "Decibel"
                            }
                        }
                    ) { style in
                        BarStylePreview(style: style)
                    }

                    Toggle("Show percentage", isOn: $showPercentage)
                    Toggle("Hide label", isOn: $hideLabel)

                    IconCardPicker(
                        selection: $animSpeed,
                        options: AnimSpeed.allCases,
                        label: { speed in
                            switch speed {
                            case .smooth: "Smooth"
                            case .fast: "Fast"
                            case .instant: "Instant"
                            }
                        },
                        symbol: { speed in
                            switch speed {
                            case .smooth: "tortoise.fill"
                            case .fast: "hare.fill"
                            case .instant: "bolt.fill"
                            }
                        }
                    )

                    if let extra {
                        extra
                    }
                }
                .disabled(!enabled)
            }
        }
        .formStyle(.grouped)
    }
}

private enum HUDSettingsKind: String, CaseIterable {
    case display = "Display"
    case sound = "Sound"
}

struct HUDPane: View {
    @State private var kind: HUDSettingsKind = .display

    var body: some View {
        VStack(spacing: 0) {
            Picker("HUD", selection: $kind) {
                ForEach(HUDSettingsKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .padding(.vertical, 10)

            Divider()
            switch kind {
            case .display: DisplayPane()
            case .sound: SoundPane()
            }
        }
    }
}

struct BarStylePreview: View {
    let style: HUDBarStyle

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.25))
            Capsule()
                .fill(fillStyle)
                .frame(width: 52)
        }
        .frame(width: 76, height: 6)
    }

    private var fillStyle: AnyShapeStyle {
        switch style {
        case .white:
            AnyShapeStyle(.white)
        case .accent:
            AnyShapeStyle(Color.teal)
        case .decibel:
            AnyShapeStyle(
                LinearGradient(
                    colors: [.green, .yellow, .orange],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}

struct DisplayPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        HUDSettingsPane(
            title: "Display",
            symbol: "sun.max.fill",
            enabled: $settings.displayHUDEnabled,
            duration: $settings.displayHUDDuration,
            barStyle: $settings.displayBarStyle,
            showPercentage: $settings.displayShowPercentage,
            hideLabel: $settings.displayHideLabel,
            animSpeed: $settings.displayAnimSpeed
        )
    }
}

struct SoundPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        HUDSettingsPane(
            title: "Sound",
            symbol: "speaker.wave.2.fill",
            enabled: $settings.soundHUDEnabled,
            duration: $settings.soundHUDDuration,
            barStyle: $settings.soundBarStyle,
            showPercentage: $settings.soundShowPercentage,
            hideLabel: $settings.soundHideLabel,
            animSpeed: $settings.soundAnimSpeed,
            extra: AnyView(SoundIconStylePicker())
        )
    }
}

struct SoundIconStylePicker: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        OptionCardPicker(
            selection: $settings.soundIconStyle,
            options: SoundIconStyle.allCases,
            label: { style in
                style == .symbol ? "Show symbol" : "Show device"
            }
        ) { style in
            Image(systemName: style == .symbol
                ? "speaker.wave.2.fill"
                : AppServices.shared.audio.outputSymbol)
                .font(.system(size: 15))
                .foregroundStyle(.white)
        }
    }
}
