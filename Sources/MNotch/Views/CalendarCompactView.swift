import SwiftUI

/// Closed-state calendar chrome: day number on the left wing, next event
/// (time + truncated title) on the right wing.
struct CalendarCompactView: View {
    let viewModel: NotchViewModel
    let calendar: CalendarService

    private var settings: SettingsStore { .shared }

    var body: some View {
        HStack {
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

            Spacer(minLength: viewModel.geometry.notchWidth)

            eventSide
        }
        .padding(.horizontal, viewModel.topRadius + 6)
        .frame(height: viewModel.geometry.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.expand(.calendar)
        }
    }

    @ViewBuilder
    private var eventSide: some View {
        if let event = calendar.nextEvent {
            HStack(spacing: 4) {
                if settings.calendarUseColor {
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
            .frame(maxWidth: 90, alignment: .leading)
        } else {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// Duo idle: media artwork on the left wing, next event on the right.
struct DuoCompactView: View {
    let viewModel: NotchViewModel
    let media: MediaRemoteService
    let calendar: CalendarService

    var body: some View {
        HStack {
            ArtworkView(
                image: media.artwork,
                cornerRadius: 5,
                identity: media.playback.title + media.playback.artist
            )
            .frame(width: 20, height: 20)

            Spacer(minLength: viewModel.geometry.notchWidth)

            CalendarCompactEventOnly(calendar: calendar)
        }
        .padding(.horizontal, viewModel.topRadius + 6)
        .frame(height: viewModel.geometry.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.expand(.media)
        }
    }
}

struct CalendarCompactEventOnly: View {
    let calendar: CalendarService

    var body: some View {
        if let event = calendar.nextEvent {
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
            .frame(maxWidth: 90, alignment: .leading)
        } else {
            Text(Date().formatted(.dateTime.day()))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.red)
        }
    }
}
