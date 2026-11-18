import SwiftUI

struct WeekStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(LabActionStyle(prominent: false)).accessibilityLabel("Día anterior")
                Spacer()
                DatePicker("Fecha", selection: $selection, displayedComponents: .date).labelsHidden()
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(LabActionStyle(prominent: false)).accessibilityLabel("Día siguiente")
            }
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { date in
                    let selected = calendar.isDate(date, inSameDayAs: selection)
                    let today = calendar.isDateInToday(date)
                    let hasSession = marked.contains(calendar.startOfDay(for: date))
                    Button { select(date) } label: {
                        VStack(spacing: 8) {
                            Text(date.formatted(.dateTime.weekday(.narrow))).font(.caption).foregroundStyle(.secondary)
                            Text(date.formatted(.dateTime.day()))
                                .font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                                .frame(width: 32, height: 32)
                                .background(selected ? LabPalette.coral : LabPalette.surface, in: Circle())
                                .overlay { Circle().strokeBorder(today && !selected ? LabPalette.accent : .clear, lineWidth: 1.5) }
                                .foregroundStyle(selected ? LabPalette.ink : Color.primary)
                            Circle().fill(hasSession ? LabPalette.accent : .clear).frame(width: 5, height: 5)
                        }.frame(maxWidth: .infinity, minHeight: 62).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityHint(hasSession ? "Con entrenamiento previsto" : "").accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                }
            }
        }
    }
    private func move(_ value: Int) {
        if let date = calendar.date(byAdding: .day, value: value, to: selection) { select(date) }
    }
    private func select(_ date: Date) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = date }
    }
}
