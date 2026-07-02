import SwiftUI

/// Calendar tab: today's remaining events as a compact list.
struct CalendarStripView: View {
    let viewModel: NotchViewModel
    let calendar: CalendarService

    var body: some View {
        Group {
            if !calendar.authorized && calendar.requested {
                message("Calendar access needed", symbol: "lock.fill")
            } else if calendar.items.isEmpty {
                message("No more events today", symbol: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(calendar.items) { item in
                        HStack(spacing: 8) {
                            Capsule()
                                .fill(Color(
                                    red: item.colorRed,
                                    green: item.colorGreen,
                                    blue: item.colorBlue
                                ))
                                .frame(width: 3, height: 16)
                            Text(item.start, style: .time)
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.55))
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, viewModel.geometry.notchHeight + 8)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            calendar.ensureStarted()
            calendar.reload()
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.35))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
