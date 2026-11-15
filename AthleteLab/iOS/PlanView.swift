import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

struct PlanView: View {
    @EnvironmentObject var m: Model
    @ViewState var add = false
    @ViewState var month = false
    var daySessions: [Session] { m.plan.filter { Calendar.current.isDate($0.date, inSameDayAs: m.selectedDay) }.sorted { $0.date < $1.date } }
    var body: some View {
        List {
            Section {
                WeekStrip(selection: $m.selectedDay, marked: Set(m.plan.map { Calendar.current.startOfDay(for: $0.date) }))
                if month { DatePicker("Calendario", selection: $m.selectedDay, displayedComponents: .date).datePickerStyle(.graphical) }
                Text("Plan importado · 9 nov 2026 – 30 ene 2027").font(.caption).foregroundStyle(.secondary)
            }
            Section(m.selectedDay.formatted(date: .complete, time: .omitted)) {
                if daySessions.isEmpty { Text("Sin sesión planificada").foregroundStyle(.secondary) }
                ForEach(daySessions) { s in
                    HStack(alignment: .top) {
                        Button { m.toggle(s.id) } label: { Image(systemName: m.completed.contains(s.id) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless)
                        NavigationLink { SessionDetail(session: s) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(s.title).font(.headline)
                                Text(s.date.formatted(.dateTime.hour().minute()) + " · \(Int(s.minutes)) min").font(.caption).foregroundStyle(.secondary)
                                Text(TrainingText(s.detail).preview).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                            }
                        }
                    }.swipeActions { Button("Eliminar", role: .destructive) { m.plan.removeAll { $0.id == s.id }; m.savePlan() } }
                }
            }
        }.toolbar {
            Button { month.toggle() } label: { Image(systemName: "calendar") }
            Button { add = true } label: { Image(systemName: "plus") }
        }.sheet(isPresented: $add) { AddSession() }
    }
}
struct AddSession: View {
    @EnvironmentObject var m: Model; @Environment(\.dismiss) var dismiss
    @ViewState var title = ""; @ViewState var sport = "Natación"; @ViewState var date = Date.now; @ViewState var minutes = 45.0; @ViewState var detail = ""
    var body: some View { NavigationStack { Form { TextField("Nombre de la sesión", text: $title); Picker("Deporte", selection: $sport) { ForEach(["Natación", "Ciclismo", "Carrera", "Fuerza"], id: \.self) { Text($0) } }; DatePicker("Fecha", selection: $date); Stepper("\(Int(minutes)) minutos", value: $minutes, in: 5...600, step: 5); Section("Calentamiento, bloques y descansos") { TextEditor(text: $detail).frame(minHeight: 150) } }.navigationTitle("Nueva sesión").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Guardar") { m.plan.append(Session(id: UUID().uuidString, title: title, sport: sport, date: date, minutes: minutes, source: "Plan personal", detail: detail)); m.savePlan(); dismiss() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) } } } }
}
