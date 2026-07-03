import SwiftUI

/// Slider row with an Alcove-style value badge on the right.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, 2)
    }
}

/// Horizontal option cards with preview + label, Alcove-style.
struct OptionCardPicker<T: Hashable, Preview: View>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    @ViewBuilder let preview: (T) -> Preview

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.self) { option in
                VStack(spacing: 5) {
                    preview(option)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(.black, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    selection == option ? Color.accentColor : .clear,
                                    lineWidth: 2.5
                                )
                        )
                    Text(label(option))
                        .font(.system(size: 12, weight: selection == option ? .semibold : .regular))
                        .foregroundStyle(selection == option ? .primary : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = option
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Grey-background variant for icon-only options (anim speed etc.).
struct IconCardPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    let symbol: (T) -> String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.self) { option in
                VStack(spacing: 5) {
                    Image(systemName: symbol(option))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selection == option ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            selection == option
                                ? Color.accentColor.opacity(0.12)
                                : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    selection == option ? Color.accentColor : .clear,
                                    lineWidth: 2
                                )
                        )
                    Text(label(option))
                        .font(.system(size: 12, weight: selection == option ? .semibold : .regular))
                        .foregroundStyle(selection == option ? .primary : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = option
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Row for features that exist in Alcove but are not possible here.
struct UnavailableRow: View {
    let title: String
    let note: String

    var body: some View {
        HStack {
            Text(title)
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help(note)
            Spacer()
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .disabled(true)
        }
        .foregroundStyle(.secondary)
    }
}

/// Toggle with a sound preview button.
struct SoundToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let effect: SoundPlayer.Effect

    var body: some View {
        HStack {
            Text(title)
            Button {
                SoundPlayer.play(effect)
            } label: {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
    }
}
