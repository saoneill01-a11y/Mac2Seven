import SwiftUI

/// Bumped each time the calendar opens, so it starts on the current month again.
@MainActor
final class CalendarModel: ObservableObject {
    @Published var openCount = 0
}

/// The popup above the taskbar clock: a live clock (hours, minutes, seconds, AM/PM), the date, and a month.
struct CalendarPopup: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var model: CalendarModel
    @Environment(\.colorScheme) private var systemScheme

    static let width: CGFloat = 300

    private var dark: Bool {
        switch prefs.data.appearance {
        case .system: return systemScheme == .dark
        case .light: return false
        case .dark: return true
        }
    }

    var body: some View {
        CalendarContent(look: CalendarLook(style: prefs.data.taskbar.calendarStyle, dark: dark, accent: prefs.accentColor))
            .id(model.openCount)
    }
}

/// Colors and sizes for each calendar style.
struct CalendarLook {
    let style: CalendarStyle
    let dark: Bool
    let accent: Color

    var corner: CGFloat { style == .windows ? 8 : (style == .glass ? 12 : 14) }
    var timeSize: CGFloat { style == .windows ? 30 : (style == .glass ? 26 : 20) }
    var longDate: Bool { style != .compact }
    var separator: Bool { style != .glass }
    /// The glass style is always dark, like the Start menu's right-hand side.
    var isDark: Bool { style == .glass || dark }

    var text: Color {
        switch style {
        case .glass: return .white
        case .windows: return dark ? .white : Color(white: 0.1)
        case .compact: return dark ? Color(white: 0.95) : Color(red: 0.11, green: 0.11, blue: 0.12)
        }
    }
    var dim: Color {
        switch style {
        case .glass: return .white.opacity(0.45)
        case .windows: return Color(white: 0.54)
        case .compact: return dark ? Color(red: 0.49, green: 0.5, blue: 0.52) : Color(red: 0.63, green: 0.63, blue: 0.65)
        }
    }
    var header: Color {
        switch style {
        case .glass: return Color(red: 0.75, green: 0.88, blue: 1)
        case .windows: return dark ? Color(white: 0.78) : Color(white: 0.35)
        case .compact: return dark ? Color(red: 0.65, green: 0.67, blue: 0.68) : Color(red: 0.43, green: 0.43, blue: 0.45)
        }
    }
    var border: Color {
        switch style {
        case .glass: return .white.opacity(0.3)
        case .windows: return dark ? Color(white: 0.23) : Color(white: 0.82)
        case .compact: return dark ? Color(red: 0.24, green: 0.25, blue: 0.26) : Color(red: 0.85, green: 0.85, blue: 0.86)
        }
    }
    var todayFill: Color {
        switch style {
        case .glass: return .white.opacity(0.28)
        case .windows: return accent
        case .compact: return dark ? Color(red: 0.42, green: 0.43, blue: 0.45) : Color(red: 0.78, green: 0.78, blue: 0.8)
        }
    }
    var todayText: Color {
        switch style {
        case .glass, .windows: return .white
        case .compact: return .black
        }
    }

    @ViewBuilder var background: some View {
        switch style {
        case .glass:
            PanelBackground().environment(\.palette, Palette(style: .glass, dark: true, accent: accent))
        case .windows:
            ZStack {
                VisualEffect(material: .hudWindow)
                (dark ? Color(white: 0.125) : Color(white: 0.953)).opacity(0.94)
            }
        case .compact:
            ZStack {
                VisualEffect(material: .popover)
                (dark ? Color(red: 0.17, green: 0.18, blue: 0.19) : Color(red: 0.96, green: 0.96, blue: 0.97)).opacity(0.9)
            }
        }
    }
}

private struct CalendarContent: View {
    let look: CalendarLook
    @State private var month = CalendarContent.startOfMonth(Date())

    private static let cal = Calendar.current

    static func startOfMonth(_ date: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMy")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.timeFormat.string(from: context.date))
                        .font(.system(size: look.timeSize, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(look.text)
                    Text(context.date.formatted(look.longDate
                        ? .dateTime.weekday(.wide).month(.wide).day().year()
                        : .dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.system(size: 12))
                        .foregroundStyle(look.header)
                }
            }
            .padding(.horizontal, 6)

            if look.separator {
                Rectangle().fill(look.border).frame(height: 1).padding(.top, 12).padding(.bottom, 8)
            } else {
                Color.clear.frame(height: 12)
            }

            HStack {
                arrow("chevron.left", by: -1)
                Spacer()
                Button { month = Self.startOfMonth(Date()) } label: {
                    Text(Self.monthFormat.string(from: month))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(look.style == .compact ? look.header : look.text)
                }
                .buttonStyle(.plain)
                .help("Go to today")
                Spacer()
                arrow("chevron.right", by: 1)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 6)

            grid
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: CalendarPopup.width)
        .background(look.background)
        .clipShape(RoundedRectangle(cornerRadius: look.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: look.corner, style: .continuous).strokeBorder(look.border, lineWidth: 1))
        .environment(\.colorScheme, look.isDark ? .dark : .light)
    }

    private func arrow(_ symbol: String, by months: Int) -> some View {
        Button {
            month = Self.cal.date(byAdding: .month, value: months, to: month) ?? month
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(look.header)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        let cal = Self.cal
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        let headers = Array(symbols[first...] + symbols[..<first])
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: month) ?? month
        let days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(look.header)
                    .frame(height: 26)
            }
            ForEach(days, id: \.self) { day in
                dayCell(day)
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let cal = Self.cal
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let today = cal.isDateInToday(day)
        let weekend = cal.isDateInWeekend(day)
        return Text("\(cal.component(.day, from: day))")
            .font(.system(size: 13, weight: today ? .bold : (inMonth && !weekend ? .semibold : .regular)))
            .monospacedDigit()
            .foregroundStyle(today ? look.todayText : (inMonth && !weekend ? look.text : look.dim))
            .opacity(inMonth || today ? 1 : 0.55)
            .frame(width: 30, height: 30)
            .background {
                if today {
                    Circle().fill(look.todayFill)
                        .overlay(Circle().strokeBorder(look.style == .glass ? Color.white.opacity(0.7) : .clear, lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity)
    }
}
