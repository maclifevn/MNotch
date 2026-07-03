import SwiftUI

/// Closed-state calendar chrome: day number on the left wing, next event
/// (time + truncated title) on the right wing. Both sides are FIXED-width
/// (viewModel.calendarWingContentWidth) so content can never overflow into
/// the camera cutout.
struct CalendarCompactView: View {
    let viewModel: NotchViewModel
    let calendar: CalendarService

    private var settings: SettingsStore { .shared }

    var body: some View {
        let wing = viewModel.calendarWingContentWidth
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Text(Date().formatted(.dateTime.day()))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.red)
                Text(Date().formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                if settings.calendarEventIndicators, !calendar.today.isEmpty {
                    Circle()
                        .fill(.red)
                        .frame(width: 4, height: 4)
                }
            }
            .frame(width: wing, alignment: .leading)

            Spacer(minLength: viewModel.geometry.notchWidth)

            CalendarCompactEventOnly(calendar: calendar)
                .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, viewModel.topRadius + 6)
        .frame(height: viewModel.geometry.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.expand(.calendar)
        }
    }
}

/// Duo idle: media artwork on the left wing, next event on the right.
struct DuoCompactView: View {
    let viewModel: NotchViewModel
    let media: MediaRemoteService
    let calendar: CalendarService

    var body: some View {
        let wing = viewModel.calendarWingContentWidth
        HStack(spacing: 0) {
            ArtworkView(
                image: media.artwork,
                cornerRadius: 5,
                identity: media.playback.title + media.playback.artist
            )
            .frame(width: 20, height: 20)
            .frame(width: wing, alignment: .leading)

            Spacer(minLength: viewModel.geometry.notchWidth)

            CalendarCompactEventOnly(calendar: calendar)
                .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, viewModel.topRadius + 6)
        .frame(height: viewModel.geometry.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.expand(.media)
        }
    }
}

/// Next-event capsule: colored indicator + optional time + truncated title.
struct CalendarCompactEventOnly: View {
    let calendar: CalendarService

    var body: some View {
        if let event = calendar.nextEvent {
            HStack(spacing: 4) {
                if SettingsStore.shared.calendarUseColor {
                    Capsule()
                        .fill(Color(
                            red: event.colorRed,
                            green: event.colorGreen,
                            blue: event.colorBlue
                        ))
                        .frame(width: 2.5, height: 12)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !event.isAllDay {
                        Text(event.start, style: .time)
                            .font(.system(size: 7.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(event.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
        } else {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}
