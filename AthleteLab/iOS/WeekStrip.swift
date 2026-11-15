import SwiftUI

struct WeekStrip: View {
    @Binding var selection: Date
    var marked: Set<Date> = []
    private var calendar: Calendar { var c = Calendar(identifier: .iso8601); c.timeZone = .current; return c }
    private var days: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: selection)!.start
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.borderless).accessibilityLabel("Día anterior")
                Spacer()
                DatePicker("Fecha", selection: $selection, displayedComponents: .date).labelsHidden()
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.borderless).accessibilityLabel("Día siguiente")
            }
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { date in
                    Button { selection = date } label: {
                        VStack(spacing: 8) {
                            Text(date.formatted(.dateTime.weekday(.narrow))).font(.caption).foregroundStyle(.secondary)
                            Text(date.formatted(.dateTime.day())).font(.subheadline.bold()).frame(maxWidth: .infinity).frame(height: 40)
                                .background(calendar.isDate(date, inSameDayAs: selection) ? Color(red: 1, green: 0.43, blue: 0.39) : Color(.tertiarySystemFill), in: Circle())
                                .foregroundStyle(calendar.isDate(date, inSameDayAs: selection) ? Color.white : Color.primary)
                            Circle().fill(marked.contains(calendar.startOfDay(for: date)) ? Color.primary : Color.clear).frame(width: 4, height: 4)
                        }
                    }.buttonStyle(.plain).accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                }
            }
        }
    }
    private func move(_ value: Int) { selection = calendar.date(byAdding: .day, value: value, to: selection)! }
}
